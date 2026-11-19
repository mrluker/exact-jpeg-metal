import Foundation
import Metal
import os

/// The Metal device, queue and compiled kernels shared by every decoder and encoder.
/// Kernels are compiled from the bundled .metal sources at first use (Metal caches the compiled code).
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    public let compileSeconds: Double
    /// this device's self-check results (SelfCheck.swift), shared by every context on the device
    let selfCheckState: SelfCheckRegistry.State

    /// Testing: EJM_TEST_METAL_SETUP=nodevice (MetalContext.shared finds no device), compile (every context's shader
    /// library fails to compile) or pipeline:<kernel> (that kernel's pipeline state fails to build). Read once.
    static let setupHook = ProcessInfo.processInfo.environment["EJM_TEST_METAL_SETUP"]
    private static let sharedResult: Result<MetalContext, Error> = {
        let device = setupHook == "nodevice" ? nil : MTLCreateSystemDefaultDevice()
        do { return .success(try MetalContext(device: device)) } catch { return .failure(error) }
    }()

    /// The context on the system default GPU, set up at first use. Traps when that setup failed (no Metal device,
    /// the shader library does not compile): check sharedSetupError first, or use Decoder() / Encoder(), which
    /// never trap and decline or throw with that error instead.
    public static var shared: MetalContext {
        switch sharedResult {
        case .success(let c): return c
        case .failure(let e): fatalError("ExactJPEG: Metal setup failed: \(e)")
        }
    }
    /// nil when MetalContext.shared is usable, else why its setup failed ("Metal setup failed: ...")
    public static var sharedSetupError: String? {
        if case .failure(let e) = sharedResult { return "Metal setup failed: \(e)" }
        return nil
    }
    /// MetalContext.shared, nil when its setup failed
    static var sharedIfAvailable: MetalContext? { try? sharedResult.get() }

    /// salt: appended as a comment to force a cold compile (to measure it); normal use leaves it nil
    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), salt: String? = nil) throws {
        guard let device else { throw Unsupported("no Metal device") }
        self.device = device
        selfCheckState = SelfCheckRegistry.shared.state(device)
        guard let q = device.makeCommandQueue(maxCommandBufferCount: 64) else { throw Unsupported("no command queue") }
        queue = q
        let t0 = CFAbsoluteTimeGetCurrent()
        let body = [ShaderSource.decode, ShaderSource.encode].map { $0.replacingOccurrences(of: "#include <metal_stdlib>", with: "") }
        var src = ([ShaderSource.common] + body).joined(separator: "\n")
        if let salt { src += "\n// \(salt)\n" }
        if MetalContext.setupHook == "compile" { throw Unsupported("shader library did not compile (simulated: EJM_TEST_METAL_SETUP=compile)") }
        let opts = MTLCompileOptions()
        opts.fastMathEnabled = false
        opts.languageVersion = .version3_0
        library = try device.makeLibrary(source: src, options: opts)
        compileSeconds = CFAbsoluteTimeGetCurrent() - t0
    }

    /// Every kernel without function constants (decoder, encoder, shared scans). The decoder's default colour kernel
    /// `color_k` is built per specialisation instead (see warmUp()).
    public static let kernelNames = ["scan_up", "scan_mid", "scan_down", "fill_u32", "unstuff_count", "unstuff_scatter",
        "fix_segs", "seg_chunks", "make_chunks", "sync_pass", "first_blocks", "decode_write", "idct_islow", "color", "packed_unpack",
        "enc_dct", "enc_dummy_dc", "enc_count", "enc_write", "stuff_count", "stuff_scatter",
        "enc_fused", "enc_dummy_dcq", "enc_len", "enc_compact"]

    /// The `color_k` function constants (as Decoder.run derives them: three upsampling kinds, mode, channels) of the layouts libjpeg-turbo, Pillow and cameras
    /// write: luma at full resolution and both chroma components with the same upsampling kind (0 full size, 1 h2v1
    /// fancy, 2 h1v2 fancy, 3 h2v2 fancy, 4 replication), in the four colour output modes, plus the three gray modes.
    static let colorSpecialisations: [[Int32]] = {
        var s: [[Int32]] = []
        for (mode, c) in [(0, 3), (1, 3), (4, 4), (5, 4)] as [(Int32, Int32)] { for k: Int32 in 0...4 { s.append([0, k, k, mode, c]) } }
        for (mode, c) in [(2, 1), (3, 3), (6, 4)] as [(Int32, Int32)] { s.append([0, 0, 0, mode, c]) }
        return s
    }()

    /// Build the pipeline states now (otherwise each is built at its first use): every kernel in kernelNames and the
    /// 23 specialisations of the colour kernel in colorSpecialisations (other, unusual sampling layouts still build
    /// theirs at first use), then run both halves of the device's self-check (selfCheck()) if they have not run yet.
    public func warmUp() {
        for k in MetalContext.kernelNames { _ = tryPipeline(k) }
        for c in MetalContext.colorSpecialisations { _ = tryPipeline("color_k", constants: c) }
        _ = selfCheck()
    }

    /// How many pipeline states this context has built so far (each kernel name, and each function-constant
    /// specialisation, counts once).
    public var pipelineCount: Int { lock.lock(); defer { lock.unlock() }; return pipelines.count }

    /// kernels whose pipeline state failed to build, with the error (not retried)
    private var failures: [String: String] = [:]

    /// A pipeline with int function constants 0..n-1 set to `constants` (cached per name and values). Traps when
    /// the kernel cannot be built; the decoder and the encoder use a form that declines or throws instead.
    public func pipeline(_ name: String, constants: [Int32]) -> MTLComputePipelineState {
        guard let p = tryPipeline(name, constants: constants) else { fatalError("ExactJPEG: \(pipelineError(name, constants: constants))") }
        return p
    }

    /// A pipeline without function constants (cached per name). Traps when the kernel cannot be built.
    public func pipeline(_ name: String) -> MTLComputePipelineState {
        guard let p = tryPipeline(name) else { fatalError("ExactJPEG: \(pipelineError(name))") }
        return p
    }

    private static func key(_ name: String, _ constants: [Int32]?) -> String {
        constants.map { name + ":" + $0.map(String.init).joined(separator: ",") } ?? name
    }

    /// The pipeline, nil when it cannot be built (pipelineError then says why)
    func tryPipeline(_ name: String, constants: [Int32]? = nil) -> MTLComputePipelineState? {
        let key = MetalContext.key(name, constants)
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[key] { return p }
        if failures[key] != nil { return nil }
        SetupWork.bump()
        do {
            if MetalContext.setupHook == "pipeline:" + name { throw Unsupported("simulated: EJM_TEST_METAL_SETUP=pipeline:\(name)") }
            let f: MTLFunction
            if let constants {
                let cv = MTLFunctionConstantValues()
                for (i, v) in constants.enumerated() { var x = v; cv.setConstantValue(&x, type: .int, index: i) }
                f = try library.makeFunction(name: name, constantValues: cv)
            } else {
                guard let g = library.makeFunction(name: name) else { throw Unsupported("no function \(name) in the library") }
                f = g
            }
            let p = try device.makeComputePipelineState(function: f)
            pipelines[key] = p
            return p
        } catch {
            failures[key] = "cannot build GPU kernel \(key): \(error)"
            return nil
        }
    }

    /// why tryPipeline(name, constants:) returned nil
    func pipelineError(_ name: String, constants: [Int32]? = nil) -> String {
        let key = MetalContext.key(name, constants)
        lock.lock(); defer { lock.unlock() }
        return failures[key] ?? "cannot build GPU kernel \(key)"
    }
}

/// A growable scratch arena: one shared MTLBuffer, sub-allocated by 256-byte aligned offsets for each decode.
final class Arena {
    let device: MTLDevice
    private(set) var buffer: MTLBuffer?
    private var top = 0
    /// bytes of the buffers allocated so far; failAllocations: every allocation fails (testing)
    private(set) var allocatedBytes = 0
    var failAllocations = false

    let options: MTLResourceOptions
    init(device: MTLDevice, untracked: Bool = false) {
        self.device = device
        options = untracked ? [.storageModeShared, .hazardTrackingModeUntracked] : [.storageModeShared]
    }

    struct Slice { let buffer: MTLBuffer; let offset: Int; let length: Int
        var contents: UnsafeMutableRawPointer { buffer.contents() + offset }
    }

    /// Call begin() with the total of every allocation (each rounded up by align()), then take() in the same order.
    /// begin() returns false when the buffer cannot be allocated (larger than the device's maxBufferLength, or the
    /// allocation fails); take() must not be called then.
    @discardableResult func begin(total: Int) -> Bool {
        top = 0
        if let b = buffer, b.length >= total { return true }
        buffer = nil                                        // the old one goes first: lower peak memory
        let len = max(total, 1 << 20)
        guard !failAllocations, len <= device.maxBufferLength, let b = device.makeBuffer(length: len, options: options) else { return false }
        SetupWork.bump()
        buffer = b
        allocatedBytes += len
        return true
    }

    static func align(_ n: Int) -> Int { (n + 255) & ~255 }

    func take(_ bytes: Int) -> Slice {
        guard let b = buffer else { preconditionFailure("arena: take() after begin(total:) failed") }
        let s = Slice(buffer: b, offset: top, length: bytes)
        top += Arena.align(max(bytes, 4))
        precondition(top <= b.length, "arena overflow")
        return s
    }
}

extension MTLComputeCommandEncoder {
    @inline(__always) func set(_ s: Arena.Slice, _ index: Int, plus: Int = 0) {
        setBuffer(s.buffer, offset: s.offset + plus, index: index)
    }
    @inline(__always) func setValue<T: BitwiseCopyable>(_ v: T, _ index: Int) {
        var x = v
        setBytes(&x, length: MemoryLayout<T>.stride, index: index)
    }
    @inline(__always) func setArray<T: BitwiseCopyable>(_ a: [T], _ index: Int) {
        a.withUnsafeBytes { setBytes($0.baseAddress!, length: $0.count, index: index) }
    }
}

@inline(__always) func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }


/// One call at a time on a Decoder or an Encoder: their buffers and per-call state belong to the call in progress,
/// so a second thread calling while one runs must not touch them. enter() never waits: it fails when another call
/// holds the gate. The thread it failed on reads `busyReason` as the decoder's reason until its next call on this
/// gate; that is recorded in the thread's own storage (ThreadRejections), not in the gate, so a thread that exits
/// leaves nothing behind and a later thread with the same id sees nothing. The gate is an os_unfair_lock held for
/// the whole call and released by the thread that took it (every public call is synchronous). Cost: one try-lock,
/// one thread-specific read and one lock per call. Also the C API's per-handle gate.
package final class CallGate: @unchecked Sendable {
    private let gate = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let side = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var _reason: String?                    // the decoder's reason (under side)
    private let id = ThreadRejections.newGateID()   // never reused, so a record of a gate since freed matches nothing
    package let busyReason: String

    package init(busyReason: String) {
        self.busyReason = busyReason
        gate.initialize(to: os_unfair_lock())
        side.initialize(to: os_unfair_lock())
    }
    deinit { gate.deinitialize(count: 1); gate.deallocate(); side.deinitialize(count: 1); side.deallocate() }

    /// true: this thread now holds the gate (call leave() when the call ends); false: another call holds it
    package func enter() -> Bool {
        if os_unfair_lock_trylock(gate) {
            ThreadRejections.current(create: false)?.remove(id)
            return true
        }
        ThreadRejections.current(create: true)!.add(id)
        return false
    }

    package func leave() { os_unfair_lock_unlock(gate) }

    /// this thread's last call on this gate found it taken
    package var rejectedHere: Bool { ThreadRejections.current(create: false)?.contains(id) ?? false }

    /// the reason as this thread should see it: busyReason when its last call found the gate taken
    var reason: String? {
        get {
            if rejectedHere { return busyReason }
            os_unfair_lock_lock(side); defer { os_unfair_lock_unlock(side) }
            return _reason
        }
        set { os_unfair_lock_lock(side); _reason = newValue; os_unfair_lock_unlock(side) }
    }

    /// Testing: the per-thread rejection records alive in this process (each freed when its thread exits)
    static var recordCount: Int { ThreadRejections.live }
}

/// A thread's rejected calls (CallGate): the ids of the gates whose last call from this thread found them taken,
/// in the thread's own storage (a pthread key whose destructor frees it when the thread exits). At most `cap` ids:
/// a thread rejected by more gates than that without calling them again forgets the oldest (it then reads that
/// gate's ordinary reason), so a long-lived thread cannot grow it either.
final class ThreadRejections {
    private var ids: [UInt64] = []
    static let cap = 8

    func add(_ id: UInt64) {
        if ids.contains(id) { return }
        if ids.count == ThreadRejections.cap { ids.removeFirst() }
        ids.append(id)
    }
    func remove(_ id: UInt64) { if !ids.isEmpty { ids.removeAll { $0 == id } } }
    func contains(_ id: UInt64) -> Bool { ids.contains(id) }

    nonisolated(unsafe) private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); l.initialize(to: os_unfair_lock()); return l
    }()
    nonisolated(unsafe) private static var nextID: UInt64 = 0
    nonisolated(unsafe) private static var liveCount = 0
    static func newGateID() -> UInt64 { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; nextID += 1; return nextID }
    static var live: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return liveCount }
    private static func count(_ d: Int) { os_unfair_lock_lock(lock); liveCount += d; os_unfair_lock_unlock(lock) }

    private static let key: pthread_key_t = {
        var k = pthread_key_t()
        let rc = pthread_key_create(&k) { p in
            Unmanaged<ThreadRejections>.fromOpaque(p).release()
            ThreadRejections.count(-1)
        }
        precondition(rc == 0, "pthread_key_create failed")
        return k
    }()

    /// this thread's record; nil when it has none and create is false
    static func current(create: Bool) -> ThreadRejections? {
        if let p = pthread_getspecific(key) { return Unmanaged<ThreadRejections>.fromOpaque(p).takeUnretainedValue() }
        guard create else { return nil }
        let r = ThreadRejections()
        pthread_setspecific(key, Unmanaged.passRetained(r).toOpaque())
        count(1)
        return r
    }
}
