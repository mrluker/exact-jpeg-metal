// Portions are derived from libjpeg-turbo 3.1.2 (see THIRD_PARTY_NOTICES.md for the routines and changes):
//   Copyright (C) 1991-1998, Thomas G. Lane. Modifications by Guido Vollbeding.
//   libjpeg-turbo Modifications: Copyright (C) 2009-2025, D. R. Commander, and the other contributors named
//   in the original file headers.
// Re-implemented and modified by Luke Riley, 2026. Those portions remain under the IJG License
// (licenses/README.ijg); the rest is MIT (LICENSE).

import Foundation
import Metal

/// Output pixel layouts. gray JPEGs decoded as rgb/bgr/rgba/bgra replicate the luminance (alpha 255).
public enum PixelFormat: Int, Sendable {
    case rgb = 0, bgr = 1, gray = 2, rgba = 4, bgra = 5
    public var channels: Int { switch self { case .gray: 1; case .rgba, .bgra: 4; default: 3 } }
}

/// A decoded image living in a shared (unified-memory) Metal buffer: rows of width * channels bytes.
public struct GPUImage {
    public let buffer: MTLBuffer
    public let offset: Int
    public let width: Int
    public let height: Int
    public let channels: Int
    public var bytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: buffer.contents() + offset, count: width * height * channels)
    }
}

let LB = 10, NT = 6
let TABW = (1 << LB) / 2 + 18 + 18 + 64     // 32-bit words per Huffman table slot (Decode.metal TABW)
let PAD = 4096, TILE = 4096
let maxInput = 1 << 28
let errTrailer: Int32 = 128, errSync: Int32 = 256        // Decode.metal ERR_TRAILER, ERR_SYNC (not in decodeErrors)
let decodeErrors: [(Int32, String)] = [(1, "bad Huffman code"), (2, "entropy-coded data too short"),
    (4, "AC coefficient index past 63"), (8, "block runs past its restart marker"),
    (16, "restart markers missing or out of order"),
    (32, "coefficients outside the range where all libjpeg-turbo IDCTs agree"), (64, "DC value outside int16")]

// zig-zag position -> natural (row-major) index (jutils.c jpeg_natural_order)
let NAT: [Int] = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,
                  7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31,
                  39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

/// A decoded symbol as the kernels use it (Decode.metal sym_entry): (code length + value bits) | value bits << 5 |
/// z step << 9, z step = how far the coefficient index moves (DC: 1; AC: run + 1 with a value, 16 for ZRL, 64 = end
/// of block for EOB and any other run with no value bits).
func symEntry(_ sym: Int, _ l: Int, _ dc: Bool) -> Int {
    let s = sym & 15, r = sym >> 4
    let za = dc ? 1 : s != 0 ? r + 1 : r == 15 ? 16 : 64
    return (l + s) | (s << 5) | (za << 9)
}

/// Host-side tables for one header (Huffman tables, MCU layout, plane geometry, quantisers, upsampling).
struct DecodeLayout {
    var tabs: [UInt8]          // header (24 words), then ntab table slots (Decode.metal Tabs)
    var ntab: Int
    var pix: [Int32]           // Pix struct
    var q: [Int32]             // 3 x 64 natural order
    var up: [Int32]            // Up struct: fh[3], fv[3], dw[3], dh[3], fancy[3]
    var bpm: Int, mcux: Int, mcuy: Int, nmcu: Int, nblk: Int, planeBytes: Int
    /// a quantisation value above 32767 (16-bit DQT): libjpeg-turbo keeps the table as int16 (jddctmgr.c
    /// ISLOW_MULT_TYPE), so such a value is negative there, and its C and SIMD IDCTs can differ (32768 times a -1
    /// coefficient is +32768 in C, -32768 in 16-bit SIMD): declined
    var bigQuant: Bool
    var blocks: [(ci: Int, dx: Int, dy: Int)]

    init(_ h: JPEGHeader) {
        // Huffman tables, de-duplicated into NT slots (jdhuff.c jpeg_make_d_derived_tbl). The LUT entries depend on
        // whether the table is used for DC or AC (symEntry), so a DC and an AC table never share a slot.
        struct Key: Hashable { let tab: HuffTable; let dc: Bool }
        var slots: [Key: Int] = [:]
        var arrays: [Key] = []
        var dct: [Int] = [], act: [Int] = []
        for ci in 0..<h.ncomp {
            for (tab, isDC) in [(h.dcTabs[ci], true), (h.acTabs[ci], false)] {
                let key = Key(tab: tab, dc: isDC)
                let slot: Int
                if let s = slots[key] { slot = s } else { slot = arrays.count; slots[key] = slot; arrays.append(key) }
                if isDC { dct.append(slot) } else { act.append(slot) }
            }
        }
        let K = arrays.count                                        // slots in use (the kernels load only these)
        var lut = [UInt16](repeating: 0, count: K << LB)
        var maxc = [Int32](repeating: -1, count: K * 18)
        var voff = [Int32](repeating: 0, count: K * 18)
        var hv = [UInt8](repeating: 0, count: K * 256)
        for t in 0..<K {
            let key = arrays[t], tab = key.tab
            for (k, v) in tab.vals.enumerated() { hv[t * 256 + k] = v }
            var code = 0, p = 0
            for l in 1...16 {
                let nl = Int(tab.counts[l - 1])
                if nl > 0 {
                    voff[t * 18 + l] = Int32(p - code)
                    for k in 0..<nl where l <= LB {
                        let lo = (code + k) << (LB - l)
                        let e = UInt16(symEntry(Int(tab.vals[p + k]), l, key.dc))
                        for x in lo..<(lo + (1 << (LB - l))) { lut[(t << LB) + x] = e }
                    }
                    p += nl
                    code += nl
                    maxc[t * 18 + l] = Int32(code - 1)
                }
                code <<= 1
            }
            maxc[t * 18 + 17] = 0x7FFFFFFF
        }
        var blocks: [(ci: Int, dx: Int, dy: Int)] = []
        for (ci, s) in h.samp.enumerated() { for dy in 0..<s.v { for dx in 0..<s.h { blocks.append((ci, dx, dy)) } } }
        let bpm = blocks.count
        var hdr = [Int32](repeating: 0, count: 24)                 // bpm, dct[10], act[10], pad[3]
        hdr[0] = Int32(bpm)
        for (k, b) in blocks.enumerated() { hdr[1 + k] = Int32(dct[b.ci]); hdr[11 + k] = Int32(act[b.ci]) }
        var bytes: [UInt8] = []
        hdr.withUnsafeBytes { bytes += $0 }
        lut.withUnsafeBytes { bytes += $0 }
        maxc.withUnsafeBytes { bytes += $0 }
        voff.withUnsafeBytes { bytes += $0 }
        bytes += hv
        tabs = bytes
        ntab = K

        let hmax = h.hmax, vmax = h.vmax
        let mcux = ceilDiv(h.width, 8 * hmax), mcuy = ceilDiv(h.height, 8 * vmax)
        self.mcux = mcux; self.mcuy = mcuy
        let pitch = (0..<3).map { $0 < h.ncomp ? mcux * h.samp[$0].h * 8 : 0 }
        let rows = (0..<3).map { $0 < h.ncomp ? mcuy * h.samp[$0].v * 8 : 0 }
        var off = [0, 0, 0]
        for k in 1..<3 { off[k] = off[k - 1] + pitch[k - 1] * rows[k - 1] }
        planeBytes = zip(pitch, rows).reduce(0) { $0 + $1.0 * $1.1 }
        let nmcu = mcux * mcuy, nblk = nmcu * bpm
        self.nmcu = nmcu; self.nblk = nblk
        self.bpm = bpm
        self.blocks = blocks
        var P = [Int32](repeating: 0, count: 45)
        P[0] = Int32(bpm)
        for (k, b) in blocks.enumerated() { P[1 + k] = Int32(b.ci); P[11 + k] = Int32(b.dx); P[21 + k] = Int32(b.dy) }
        for ci in 0..<h.ncomp { P[31 + ci] = Int32(h.samp[ci].h); P[34 + ci] = Int32(h.samp[ci].v) }
        for k in 0..<3 { P[37 + k] = Int32(truncatingIfNeeded: off[k]); P[40 + k] = Int32(pitch[k]) }
        P[43] = Int32(mcux); P[44] = Int32(nblk)
        pix = P
        var qq = [Int32](repeating: 0, count: 192)
        for ci in 0..<h.ncomp { for z in 0..<64 { qq[ci * 64 + NAT[z]] = h.quant[ci][z] } }
        q = qq
        bigQuant = qq.contains { $0 > 32767 }
        var U = [Int32](repeating: 0, count: 15)
        for (ci, s) in h.samp.enumerated() {
            let fh = hmax / s.h, fv = vmax / s.v
            let dw = ceilDiv(h.width * s.h, hmax), dh = ceilDiv(h.height * s.v, vmax)
            // jdsample.c jinit_upsampler with do_fancy_upsampling; other integral factors: int_upsample (box)
            let fancy: Int
            switch (fh, fv) {
            case (2, 1), (2, 2): fancy = dw > 2 ? 1 : 0
            case (1, 2): fancy = 1
            default: fancy = 0
            }
            U[ci] = Int32(fh); U[3 + ci] = Int32(fv); U[6 + ci] = Int32(dw); U[9 + ci] = Int32(dh); U[12 + ci] = Int32(fancy)
        }
        up = U
    }
}

/// Decodes JPEGs on the GPU, byte-identical to libjpeg-turbo (JDCT_ISLOW, fancy upsampling) or declines.
/// Not thread-safe: use one Decoder per thread. A call made while another thread's call on the same decoder is
/// running declines at once with the reason "decoder used from two threads at once" (it never waits). The returned
/// image lives in the decoder's output buffer and is valid until the next decode() on this decoder, from any
/// thread (copy it, or pass `output` to decode into your own buffer).
public final class Decoder {
    /// the context given to init(ctx:), or MetalContext.shared; nil only when that setup failed (setupError)
    public let ctx: MetalContext!
    /// why this decoder has no usable Metal setup (every call then declines with it as the reason); nil normally
    public let setupError: String?
    /// bits per Huffman chunk (one thread each in the synchronisation passes); nil: chosen per image (chunking(_:):
    /// 2048 below 256 KB of entropy-coded data, else 4096)
    public var chunkBits: Int? = nil
    /// checkpoints per chunk (the write pass decodes each piece between them with its own thread); nil: per image
    public var checkpoints: Int? = nil
    /// synchronisation passes the first attempt encodes (a second attempt with 64 follows if they were not enough).
    /// Clamped to 1...64 on assignment: the pass-status array holds 64 entries.
    public var eagerPasses = 8 { didSet { eagerPasses = min(max(eagerPasses, 1), 64) } }
    public var maxPixels = 1 << 28
    /// decline images whose decode would need more memory than this (default: half the GPU working set)
    public var maxGPUBytes: Int? = nil
    /// why the last call declined, nil when it did not. A thread whose last call found another call running sees
    /// "decoder used from two threads at once" (Decoder.busyReason).
    public private(set) var reason: String? { get { gate.reason } set { gate.reason = newValue } }
    /// the reason of a call that found another thread's call on this decoder running
    public static let busyReason = "decoder used from two threads at once"
    let gate = CallGate(busyReason: Decoder.busyReason)
    /// Testing: the per-thread records of rejected calls alive in this process, for any gate (CallGate.recordCount;
    /// a gate keeps none itself)
    @_spi(Testing) public var gateRecordCount: Int { CallGate.recordCount }
    /// Testing: run body while this thread holds the gate, so that calls from other threads find it taken
    @_spi(Testing) public func withGateHeld<R>(_ body: () -> R) -> R {
        precondition(gate.enter(), "withGateHeld: the gate is taken")
        defer { gate.leave() }
        return body()
    }
    public private(set) var passes = 0      // 0 after a call that declined before its GPU run
    public private(set) var gpuSeconds: Double = 0
    /// host timing of the last decode: before the command buffer (parse, layout, scratch), encoding, commit to completion
    public private(set) var hostPrepSeconds = 0.0, hostEncodeSeconds = 0.0, waitSeconds = 0.0
    var startT = 0.0                     // start of the last decode(buffer:...), for hostPrepSeconds
    let arena: Arena!
    private var outBuf: MTLBuffer?
    private var inBuf: MTLBuffer?
    /// layouts by a hash of the header bytes; each entry keeps those bytes, and a hit must match them exactly
    private var layoutCache: [String: (header: [UInt8], layout: DecodeLayout)] = [:]
    var selfCheckExempt = false          // the self-check's own decoder
    /// the library's own work (the self-check, the profile's routing measurement): no trace line, no stage
    /// recording from EJM_TRACE=stages, so that work runs and is timed as it does untraced
    var internalUse = false
    /// Profiling only (`ejm decode-profile`, the iOS check app): encode just the first N GPU dispatches of a decode,
    /// which then returns nil with reason "profile stop" (gpuSeconds is that prefix's GPU time). Int.max: normal.
    @_spi(Testing) public var profileStopAfter = Int.max
    /// Testing: bytes of the MTLBuffers this decoder has allocated so far (input, output and scratch buffers)
    @_spi(Testing) public var allocatedBytes: Int { ownAllocated + (arena?.allocatedBytes ?? 0) }
    private var ownAllocated = 0
    /// Testing: when true, every buffer allocation of this decoder fails (as when the device is out of memory)
    @_spi(Testing) public var failAllocations = false { didSet { arena?.failAllocations = failAllocations } }
    /// a shared buffer of `len` bytes on this decoder's device, nil when that fails (or failAllocations)
    private func makeShared(_ len: Int) -> MTLBuffer? {
        if failAllocations || len > ctx.device.maxBufferLength { return nil }
        SetupWork.bump()
        guard let b = ctx.device.makeBuffer(length: len, options: .storageModeShared) else { return nil }
        ownAllocated += len
        return b
    }
    /// Testing: when set, every header gets this layout cache key (a forced hash collision)
    @_spi(Testing) public var layoutKeyOverride: String? = nil
    /// Profiling only: when true, profileDispatches lists the dispatches of the last decode ("stage:kernel").
    @_spi(Testing) public var profileRecord = false
    @_spi(Testing) public private(set) var profileDispatches: [String] = []
    /// Packed path (Packed.swift): decodeAndPack sets packRequest so that a successful run records its arrays
    var packRequest = false
    var lastArrays: (coef: UnsafeMutableRawPointer, dc: UnsafeMutableRawPointer, nq: UnsafeMutableRawPointer, nblk: Int)?
    /// Testing: host time of the last decodeAndPack's packing (after its decode), seconds
    @_spi(Testing) public internal(set) var packSeconds = 0.0
    /// Testing: the last decode(packed:) decoded the kept JPEG normally instead (a check on the packed copy failed)
    @_spi(Testing) public internal(set) var packedFellBack = false
    /// Opt-in per-stage GPU timing (default false). When true, each decode encodes one compute encoder per stage,
    /// still in one command buffer with one commit and one wait, with GPU timestamps at the encoder boundaries,
    /// and stageTimes lists the stages of the last decode. Same bytes either way. Costs about 0.2 ms of GPU on a
    /// 30 MP decode (API.md). Setting it to false clears stageTimes.
    public var recordStages = false { didSet { if !recordStages { stageTimes = [] } } }
    /// The stages of the last decode that recorded them (recordStages, or EJM_TRACE=stages) in order: unstuff,
    /// segments, chunks, sync0 ... sync<n>, first_blocks, decode_write, dc_scan, idct, colour. Empty where the
    /// device cannot sample timestamps at stage boundaries, and until a decode records.
    public private(set) var stageTimes: [StageTime] = []
    private var recorder: StageRecorder?, recorderTried = false
    private var pathLength = 0           // the file size of the last decode(path:), for its trace line
    private var pathRead = false         // the last decode(path:) read its file into inBuf (the trace line parses it)
    private var headBuf: [UInt8] = []    // decode(path:): the file's first bytes, read before the input buffer
    private var runCount = 0             // GPU submissions so far (the trace line tells a decline before one)
    private var retried = false          // the current call needed the 64-pass retry (then it is no load sample)
    var untimed = false                  // a call that is never a load sample itself (decode(packed:), tracked whole)

    /// false (reason set) when the device's self-check failed; runs its decode half before the first decode;
    /// after that passed, one flag check
    @inline(__always) private func selfCheckOK() -> Bool {
        if selfCheckExempt || ctx.selfCheckState.decodeOK { return true }
        if let f = ctx.selfCheck(decode: true, encode: false) { reason = f; return false }
        return true
    }

    /// ctx nil: MetalContext.shared. When its setup failed the decoder is still made, and every call declines with
    /// the setup error (setupError) as the reason.
    public init(ctx: MetalContext? = nil) {
        let c = ctx ?? MetalContext.sharedIfAvailable
        self.ctx = c
        setupError = c == nil ? MetalContext.sharedSetupError ?? "Metal setup failed" : nil
        arena = c.map { Arena(device: $0.device) }
        TraceState.noteEnv()
    }

    /// the start of a public call that holds the gate: false (reason set) when there is no Metal setup
    /// Also resets the last call's GPU and host timings, passes and stages, so that a call ending before any GPU
    /// work does not show the call before's.
    @inline(__always) func callStart() -> Bool {
        gpuSeconds = 0; passes = 0; hostPrepSeconds = 0; hostEncodeSeconds = 0; waitSeconds = 0
        if !stageTimes.isEmpty { stageTimes = [] }
        if _slowPath(setupError != nil) { reason = setupError; return false }
        return true
    }

    /// Decode a JPEG held in memory.
    public func decode(_ data: Data, format: PixelFormat = .rgb) -> GPUImage? {
        data.withUnsafeBytes { decode(bytes: $0, format: format) }
    }

    /// Decode a JPEG held in memory (copied into a GPU buffer first). `output`: decode into this buffer (offset 0)
    /// instead of the decoder's own; a declined decode leaves it untouched.
    public func decode(bytes: UnsafeRawBufferPointer, format: PixelFormat = .rgb, output: MTLBuffer? = nil) -> GPUImage? {
        guard gate.enter() else { return nil }
        defer { gate.leave() }
        guard callStart() else { return nil }
        return decodeBytesCall(bytes, format, output)
    }

    /// decode(bytes:format:output:) once the call holds the gate
    func decodeBytesCall(_ bytes: UnsafeRawBufferPointer, _ format: PixelFormat, _ output: MTLBuffer?) -> GPUImage? {
        if _slowPath(TraceState.enabled) && !internalUse {
            return traced(bytes, bytes.count, format) { decodeBytes(bytes, format, output) }
        }
        return decodeBytes(bytes, format, output)
    }

    func decodeBytes(_ bytes: UnsafeRawBufferPointer, _ format: PixelFormat, _ output: MTLBuffer?) -> GPUImage? {
        reason = nil
        guard selfCheckOK() else { return nil }
        startT = CFAbsoluteTimeGetCurrent()
        let n = bytes.count
        if n < 4 { reason = "not a JPEG"; return nil }
        // every check before the input buffer is allocated (or grown) and filled
        guard let p = plan(bytes, n: n, format: format, output: output, input: true), let src = inputBuffer(n) else { return nil }
        src.contents().copyMemory(from: bytes.baseAddress!, byteCount: n)
        return decodeBuffer(src, n, format, output, plan: p)
    }

    /// The decoder's input buffer, grown to hold n bytes when needed (nil, reason set, when that allocation fails)
    private func inputBuffer(_ n: Int) -> MTLBuffer? {
        if let b = inBuf, b.length >= n { return b }
        inBuf = nil                                         // the old one goes first: lower peak memory
        let want = max(min(n * 5 / 4, ctx.device.maxBufferLength), n, 1 << 20)
        guard let b = makeShared(want) else { reason = "cannot allocate the input buffer (\(want >> 20) MB)"; return nil }
        inBuf = b
        return b
    }

    /// count bytes of fd from offset into dst; false on a short read
    private static func readFully(_ fd: Int32, _ dst: UnsafeMutableRawPointer, _ count: Int, at offset: Int) -> Bool {
        var got = 0
        while got < count {
            let r = pread(fd, dst + got, count - got, off_t(offset + got))
            if r <= 0 { return false }
            got += r
        }
        return true
    }

    /// The reason decode(bytes:format:) would decline this JPEG before any GPU work (the header, the size limits,
    /// the memory budget: every check that needs no GPU buffer), nil when those pass. The decode itself can still
    /// decline later (the GPU's checks of the entropy-coded data). Allocates nothing. A query: the last decode's
    /// reason, gpuSeconds, passes, host timings and stageTimes stay as they were.
    public func declineReason(bytes: UnsafeRawBufferPointer, format: PixelFormat = .rgb) -> String? {
        guard gate.enter() else { return Decoder.busyReason }
        defer { gate.leave() }
        if let setupError { return setupError }
        // the checks below report through reason (and plan may touch the timings): put the last call's back
        let kept = (reason: reason, gpu: gpuSeconds, passes: passes, prep: hostPrepSeconds, enc: hostEncodeSeconds,
                    wait: waitSeconds, stages: stageTimes)
        defer {
            reason = kept.reason; gpuSeconds = kept.gpu; passes = kept.passes; hostPrepSeconds = kept.prep
            hostEncodeSeconds = kept.enc; waitSeconds = kept.wait; stageTimes = kept.stages
        }
        reason = nil
        guard selfCheckOK() else { return reason }
        if bytes.count < 4 { return "not a JPEG" }
        if plan(bytes, n: bytes.count, format: format, output: nil, input: true) == nil { return reason ?? "declined" }
        return nil
    }

    /// Decode a JPEG file, read straight into a GPU-visible buffer (no extra copy).
    public func decode(path: String, format: PixelFormat = .rgb) -> GPUImage? {
        guard gate.enter() else { return nil }
        defer { gate.leave() }
        guard callStart() else { return nil }
        if _slowPath(TraceState.enabled) && !internalUse {
            pathLength = 0
            return traced(nil, -1, format, fromPath: true) { decodePath(path, format) }
        }
        return decodePath(path, format)
    }

    private func decodePath(_ path: String, _ format: PixelFormat) -> GPUImage? {
        reason = nil
        pathRead = false
        guard selfCheckOK() else { return nil }
        startT = CFAbsoluteTimeGetCurrent()
        guard let fh = FileHandle(forReadingAtPath: path) else { reason = "cannot open"; return nil }
        defer { try? fh.close() }
        let n = Int((try? fh.seekToEnd()) ?? 0)
        pathLength = n
        if n < 4 { reason = "not a JPEG"; return nil }
        let fd = fh.fileDescriptor
        if let b = inBuf, b.length >= n, n <= maxInput {
            // the buffer holds it already: read it straight in, then check (nothing is allocated)
            guard Decoder.readFully(fd, b.contents(), n, at: 0) else { reason = "short read"; return nil }
            pathRead = true
            guard let p = plan(UnsafeRawBufferPointer(start: b.contents(), count: n), n: n, format: format, output: nil, input: true) else { return nil }
            return decodeBuffer(b, n, format, nil, plan: p)
        }
        // the header first (the file's first 64 KB, or the whole file mapped when its header is longer), so that every
        // check runs before the input buffer is allocated or the rest of the file is read
        let pre = min(n, 1 << 16)
        if headBuf.count < pre { headBuf = [UInt8](repeating: 0, count: pre) }
        let ok = headBuf.withUnsafeMutableBytes { Decoder.readFully(fd, $0.baseAddress!, pre, at: 0) }
        guard ok else { reason = "short read"; return nil }
        if let p = headBuf.withUnsafeBytes({ plan(UnsafeRawBufferPointer(rebasing: $0[0..<pre]), n: n, format: format, output: nil, input: true, quiet: pre < n) }) {
            guard let src = inputBuffer(n) else { return nil }
            headBuf.withUnsafeBytes { src.contents().copyMemory(from: $0.baseAddress!, byteCount: pre) }   // the bytes p was made from
            guard Decoder.readFully(fd, src.contents() + pre, n - pre, at: pre) else { reason = "short read"; return nil }
            pathRead = true
            return decodeBuffer(src, n, format, nil, plan: p)
        }
        guard pre < n && reason == nil else { return nil }
        // a header longer than 64 KB: check it in the mapped file, then read the file and check it again there (the
        // plan must come from the bytes the GPU decodes)
        guard let m = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), m.count >= n else { reason = "short read"; return nil }
        guard m.withUnsafeBytes({ plan(UnsafeRawBufferPointer(rebasing: $0[0..<n]), n: n, format: format, output: nil, input: true) }) != nil,
              let src = inputBuffer(n) else { return nil }
        guard Decoder.readFully(fd, src.contents(), n, at: 0) else { reason = "short read"; return nil }
        pathRead = true
        guard let p = plan(UnsafeRawBufferPointer(start: src.contents(), count: n), n: n, format: format, output: nil, input: true) else { return nil }
        return decodeBuffer(src, n, format, nil, plan: p)
    }

    /// Decode a JPEG already in a shared MTLBuffer (bytes 0..<length). Declines (nothing read) when the buffer is
    /// not .storageModeShared, is from another device than the decoder's, or is shorter than length.
    public func decode(buffer src: MTLBuffer, length n: Int, format: PixelFormat = .rgb, output: MTLBuffer? = nil) -> GPUImage? {
        guard gate.enter() else { return nil }
        defer { gate.leave() }
        guard callStart() else { return nil }
        // checked before anything reads src.contents(): a .private buffer has none, another device's is not ours
        let unusable = inputUnusable(src, n)
        if _slowPath(TraceState.enabled) && !internalUse {
            let raw = unusable == nil ? UnsafeRawBufferPointer(start: src.contents(), count: n) : nil
            return traced(raw, n, format) {
                if let unusable { reason = unusable; return nil }
                return decodeBuffer(src, n, format, output)
            }
        }
        if let unusable { reason = unusable; return nil }
        return decodeBuffer(src, n, format, output)
    }

    /// why decode(buffer:length:) cannot read src (nil: it can)
    private func inputUnusable(_ src: MTLBuffer, _ n: Int) -> String? {
        if src.device !== ctx.device { return "input buffer is from another Metal device than the decoder's" }
        if src.storageMode != .shared { return "input buffer must be .storageModeShared (the decoder reads it on the CPU)" }
        if n < 0 || n > src.length { return "length larger than the buffer" }
        return nil
    }

    /// Runs one public decode call and reports it (TraceState.emit). raw: the JPEG, when known before the call;
    /// else (decode(path:)) the decoder's input buffer, `length` bytes, afterwards.
    func traced(_ raw: UnsafeRawBufferPointer?, _ n: Int, _ format: PixelFormat, fromPath: Bool = false,
                        _ call: () -> GPUImage?) -> GPUImage? {
        let runs0 = runCount, t0 = CFAbsoluteTimeGetCurrent()
        let img = call()
        let wall = CFAbsoluteTimeGetCurrent() - t0
        var n = n, raw = raw
        if fromPath {
            n = pathLength
            if pathRead, let b = inBuf, n > 0, n <= b.length { raw = UnsafeRawBufferPointer(start: b.contents(), count: n) }
        }
        let h = raw.flatMap { try? parseJPEGHeader($0) }
        var s = "ejm decode " + (h.map { "\($0.width)x\($0.height) \($0.subsampling)" } ?? "?") + " \(n) B \(format)"
        s += img != nil ? " ok" : " declined (\(reason ?? "unknown"))"
        s += " wall " + TraceState.ms(wall)
        let ran = runCount != runs0
        if ran {
            s += " prep \(TraceState.ms(hostPrepSeconds)) encode \(TraceState.ms(hostEncodeSeconds)) wait "
                + "\(TraceState.ms(waitSeconds)) gpu \(TraceState.ms(gpuSeconds)) ms"
        } else {
            s += " ms (no GPU work)"
        }
        if img != nil { s += " passes \(passes)" }
        if let h {
            let (S, ncp) = chunking(n - h.scanStart)
            s += " chunk \(S)/\(ncp)" + TraceState.route(ctx, h.width, h.height, .decode)
        }
        if ran && TraceState.stages(recordStages) { s += TraceState.stageList(stageTimes) }
        TraceState.emit(s)
        return img
    }

    private func stageRecorder() -> StageRecorder? {
        if !recorderTried { recorderTried = true; recorder = StageRecorder(device: ctx.device) }
        return recorder
    }

    /// plan: the checks decodeBytes / decodePath already ran (src then holds the same JPEG); nil: run them here
    private func decodeBuffer(_ src: MTLBuffer, _ n: Int, _ format: PixelFormat, _ output: MTLBuffer?, plan: Plan? = nil) -> GPUImage? {
        // each public decode is one load-correction sample (DeviceProfile.loadFactors): its wall time against the
        // profile's prediction for the GPU state it started in; the library's own calibration calls are not
        // a call that needed the 64-pass retry is no sample (its time is two attempts); a packed decode (untimed)
        // runs inside its caller's track()
        guard LoadCorrection.isEnabled, !untimed else { return decodeBufferTimed(src, n, format, output, plan) }
        guard !internalUse else { return LoadCorrection.track { decodeBufferTimed(src, n, format, output, plan) } }
        let start = LoadCorrection.start()
        retried = false
        let img = decodeBufferTimed(src, n, format, output, plan)
        LoadCorrection.finish(start, gpu: .decode, ctx.device, width: retried ? nil : img?.width, height: img?.height)
        return img
    }

    private func decodeBufferTimed(_ src: MTLBuffer, _ n: Int, _ format: PixelFormat, _ output: MTLBuffer?, _ pre: Plan?) -> GPUImage? {
        let p: Plan
        if let pre { p = pre } else {
            reason = nil
            guard selfCheckOK() else { return nil }
            startT = CFAbsoluteTimeGetCurrent()
            if n > src.length || n < 0 { reason = "length larger than the buffer"; return nil }
            guard let q = plan(UnsafeRawBufferPointer(start: src.contents(), count: n), n: n, format: format, output: output, input: false) else { return nil }
            p = q
        }
        guard let out = outputBuffer(p, output) else { return nil }
        var res = run(src: src, n: n, p: p, out: out, passesToEncode: eagerPasses)
        if res == .notConverged { retried = true; res = run(src: src, n: n, p: p, out: out, passesToEncode: 64) }
        switch res {
        case .ok: return GPUImage(buffer: out, offset: 0, width: p.h.width, height: p.h.height, channels: p.C)
        case .notConverged: reason = "Huffman chunks did not synchronise"; return nil
        case .failed: return nil
        }
    }

    /// Everything decided before a GPU buffer is allocated: the header, its layout, the output and scratch sizes.
    struct Plan {
        let h: JPEGHeader, L: DecodeLayout
        let mode: Int, C: Int, nout: Int
        let S: Int, NCP: Int, nseg: Int, nmax: Int, ntile: Int, wordsBytes: Int
        let sizes: [Int], total: Int
    }

    /// Buffers the kernels index must stay below this many bytes: they use 32-bit offsets (u32 byte and element
    /// offsets of the output, the coefficients and the planes; the planes' Int32 offsets in Pix).
    static let maxKernelBytes = 1 << 31

    /// Parses the header in raw (at least the bytes before the scan; n: the whole JPEG's length) and runs every check
    /// that needs no GPU buffer, in this order: header, entropy-coded data size, maxPixels, the 32-bit offset limit,
    /// quantisers, output buffer, data long enough for the frame, GPU budget, device buffer limit. nil (reason set)
    /// when one declines. input: the JPEG goes into the decoder's input buffer (decodeBytes, decodePath). quiet: a
    /// header that does not parse leaves reason nil (decodePath then parses the whole file).
    private func plan(_ raw: UnsafeRawBufferPointer, n: Int, format: PixelFormat, output: MTLBuffer?, input: Bool,
                      quiet: Bool = false) -> Plan? {
        let h: JPEGHeader
        do { h = try parseJPEGHeader(raw) } catch { if !quiet { reason = "\(error)" }; return nil }
        let s0 = h.scanStart, ne = n - s0
        if ne > maxInput { reason = "entropy-coded data larger than 256 MB"; return nil }
        if h.width * h.height > maxPixels { reason = "more than maxPixels"; return nil }
        let L = layout(raw, h)
        let C = format.channels
        let nout = h.width * h.height * C
        if nout >= Decoder.maxKernelBytes || L.nblk * 128 >= Decoder.maxKernelBytes || L.planeBytes >= Decoder.maxKernelBytes {
            reason = "image too large: its output, coefficient or plane buffer would reach 2 GB (the kernels use 32-bit offsets)"
            return nil
        }
        if L.bigQuant { reason = "quantisation value above 32767"; return nil }
        var mode = format.rawValue
        if h.ncomp == 1 && format != .gray { mode = format == .rgb || format == .bgr ? 3 : 6 }
        if let o = output {
            if !outputUsable(o) { reason = outputUnusable; return nil }
            if o.length < nout { reason = "output buffer too small"; return nil }
        }
        let (S, NCP) = chunking(ne)
        let nblk = L.nblk
        if 2 * nblk > 8 * ne { reason = "entropy-coded data too short for the image size"; return nil }
        let dri = h.dri
        let nseg = dri > 0 ? ceilDiv(L.nmcu, dri) : 1
        let nmax = (8 * ne) / S + nseg + 2
        let ntile = ne / TILE + 1
        let wordsBytes = ceilDiv(ne + PAD, 4) * 4
        // scratch layout
        let sizes: [Int] = [
            4 * 8,                       // 0 misc: end, nbits, found, err, nmax...
            4 * (ntile + 1), 4 * (ntile + 1),      // 1 tilecnt, 2 tilerst
            wordsBytes,                  // 3 words
            4 * (nseg + 1),              // 4 seg
            4 * (nseg + 1),              // 5 cfirst
            4 * nmax, 4 * nmax, 4 * nmax, // 6 cstart, 7 cend, 8 cseg
            8 * nmax, 8 * nmax,          // 9 st_in, 10 st_out
            4 * (nmax + 1),              // 11 cnt (index 0 = 0, chunk i at i + 1) -> exclusive scan
            8 * nmax * NCP, 4 * nmax * NCP, // 12 cps, 13 cpc
            4 * 64,                      // 14 changed
            4 * nmax,                    // 15 first
            nblk * 128,                  // 16 coef
            4 * nblk, nblk,              // 17 dcd, 18 nq
            L.planeBytes,                // 19 planes
            8 * (ceilDiv(max(nblk, nmax, ntile + 1, nseg + 1), 4096) + 1),  // 20 scan aux
            L.tabs.count,                // 21 tabs
        ]
        let total = sizes.reduce(0) { $0 + Arena.align(max($1, 4)) } + 256
        // peak GPU memory: the scratch arena, the JPEG, the output (the caller's, or the decoder's own as it will be)
        let budget = maxGPUBytes ?? DeviceProfile.gpuBudget(ctx.device.recommendedMaxWorkingSetSize)
        let outLen = output?.length ?? max(outBuf?.length ?? 0, nout)
        if total + n + outLen > budget {
            reason = "needs about \((total + n) >> 20) MB of GPU memory, more than allowed (\(budget >> 20) MB)"
            return nil
        }
        let maxBuf = ctx.device.maxBufferLength
        if total > maxBuf || (output == nil && nout > maxBuf) || (input && n > maxBuf) {
            reason = "needs a buffer larger than the device allows (\(maxBuf >> 20) MB)"
            return nil
        }
        return Plan(h: h, L: L, mode: mode, C: C, nout: nout, S: S, NCP: NCP, nseg: nseg, nmax: nmax, ntile: ntile,
                    wordsBytes: wordsBytes, sizes: sizes, total: total)
    }

    /// `output`, or the decoder's own output buffer grown to the plan's size (nil, reason set, when that fails)
    private func outputBuffer(_ p: Plan, _ output: MTLBuffer?) -> MTLBuffer? {
        if let output { return output }
        if let b = outBuf, b.length >= p.nout { return b }
        outBuf = nil                                        // the old one goes first: lower peak memory
        guard let b = makeShared(p.nout) else { reason = "cannot allocate the output buffer (\(p.nout >> 20) MB)"; return nil }
        outBuf = b
        return b
    }

    /// The layout of this header: from the cache when an entry's header bytes equal raw[0..<scanStart] exactly (the
    /// hash key alone is not trusted), else built and cached.
    private func layout(_ raw: UnsafeRawBufferPointer, _ h: JPEGHeader) -> DecodeLayout {
        let key = layoutKey(raw, h)
        let hdr = UnsafeRawBufferPointer(rebasing: raw[0..<h.scanStart])
        if let c = layoutCache[key], c.header.count == hdr.count,
           c.header.withUnsafeBytes({ memcmp($0.baseAddress!, hdr.baseAddress!, hdr.count) == 0 }) { return c.layout }
        let L = DecodeLayout(h)
        if layoutCache.count > 32 { layoutCache.removeAll() }
        layoutCache[key] = ([UInt8](hdr), L)
        return L
    }

    private func layoutKey(_ raw: UnsafeRawBufferPointer, _ h: JPEGHeader) -> String {
        // everything before the scan determines the layout (tables, sizes); hash it
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[0..<h.scanStart]))
        if let k = layoutKeyOverride { return k }
        return "\(hasher.finalize())-\(h.scanStart)"
    }

    /// decode(packed:) without the fallback (Packed.swift): nil when anything fails, the caller then decodes raw
    func decodePacked(_ pk: PackedCoefficients, _ raw: UnsafeRawBufferPointer, _ format: PixelFormat, _ output: MTLBuffer?) -> GPUImage? {
        reason = nil
        guard selfCheckOK() else { return nil }
        startT = CFAbsoluteTimeGetCurrent()
        guard pk.idx.device === ctx.device, pk.data.device === ctx.device else { reason = "packed copy is for another device"; return nil }
        guard let p = plan(raw, n: raw.count, format: format, output: output, input: false) else { return nil }
        // the block count is the frame's; the packed buffers must cover it
        let nblk = p.L.nblk
        guard nblk == pk.nblk, pk.idx.length >= 4 * nblk, pk.dlen >= 0, pk.dlen <= Int(UInt32.max) - Packer.tail,
              pk.data.length >= pk.dlen + Packer.tail else { reason = "packed copy does not match the JPEG"; return nil }
        guard let out = outputBuffer(p, output) else { return nil }
        guard run(src: nil, n: raw.count, p: p, out: out, passesToEncode: 1, packed: pk) == .ok else { return nil }
        return GPUImage(buffer: out, offset: 0, width: p.h.width, height: p.h.height, channels: p.C)
    }

    /// The kernels write `output` and GPUImage.bytes reads it through contents(): it must be CPU-visible shared
    /// memory on this decoder's device.
    private func outputUsable(_ o: MTLBuffer) -> Bool { o.device === ctx.device && o.storageMode == .shared }
    private let outputUnusable = "output buffer must be .storageModeShared on the decoder's device"

    enum RunResult { case ok, notConverged, failed }

    /// (bits per chunk, checkpoints per chunk) for ne bytes of entropy-coded data: 2048 bits below smallStream bytes,
    /// else 4096; 7 checkpoints. A small stream has few chunks, so the serial decode of one chunk per thread in the
    /// first synchronisation pass dominates and shorter chunks finish sooner (2026-11-17, interleaved A/B: 22-210 KB
    /// streams 5-17% faster on the M1 Max and 5-15% on an iPhone 13 (A15) with one decoder thread; at 470 KB no
    /// clear difference, at 723 KB 4096 was faster on the A15). exact-gpu-jpeg's 8192 bits for large files was
    /// slower on the M1 Max (5-8 MB files). chunkBits / checkpoints, or EJM_CHUNK_BITS / EJM_NCP, override (testing).
    static let smallStream = 256 << 10
    /// the chunk size chosen for ne bytes of entropy-coded data when nothing overrides it
    static func defaultChunkBits(_ ne: Int) -> Int { ne < smallStream ? 2048 : 4096 }
    func chunking(_ ne: Int) -> (Int, Int) {
        let S = max(chunkBits ?? Decoder.envChunkBits ?? Decoder.defaultChunkBits(ne), 64)
        let ncp = min(max(checkpoints ?? Decoder.envNCP ?? 7, 1), S / 8 - 1)
        return (S, ncp)
    }
    static let envChunkBits = Int(ProcessInfo.processInfo.environment["EJM_CHUNK_BITS"] ?? "")
    static let envNCP = Int(ProcessInfo.processInfo.environment["EJM_NCP"] ?? "")
    /// EJM_COLOR_SPEC, read once per process: false (the generic `color` kernel) only for "0". Reading the
    /// environment rebuilds the whole dictionary (about 22 µs with 48 variables, 88 µs with 248), too much per decode.
    static let envColorSpec = ProcessInfo.processInfo.environment["EJM_COLOR_SPEC"] != "0"

    /// packed: decode(packed:) (src nil): its unpack replaces unstuffing through the DC scans, no trailer check
    private func run(src: MTLBuffer?, n: Int, p: Plan, out: MTLBuffer, passesToEncode: Int, packed: PackedCoefficients? = nil) -> RunResult {
        let h = p.h, L = p.L, mode = p.mode, C = p.C
        let s0 = h.scanStart
        let ne = n - s0
        let S = p.S, NCP = p.NCP
        let nblk = L.nblk, bpm = L.bpm
        let dri = h.dri
        let nseg = p.nseg, nmax = p.nmax, ntile = p.ntile, wordsBytes = p.wordsBytes
        let sizes = p.sizes
        let G = passesToEncode
        guard arena.begin(total: p.total) else { reason = "cannot allocate the scratch buffer (\(p.total >> 20) MB)"; return .failed }
        let B = sizes.map { arena.take($0) }
        let misc = B[0]
        let mp = misc.contents.assumingMemoryBound(to: Int32.self)
        mp[0] = Int32(ne); mp[1] = 0; mp[2] = 0; mp[3] = 0                 // end, nbits, found, err
        if packed == nil {
            B[1].contents.storeBytes(of: 0, as: Int32.self); B[2].contents.storeBytes(of: 0, as: Int32.self)
            memset(B[3].contents, 0, wordsBytes)
            memset(B[4].contents, 0, 4 * (nseg + 1))
            memset(B[11].contents, 0, 4 * (nmax + 1))
            memset(B[14].contents, 0, 4 * 64)
            L.tabs.withUnsafeBytes { B[21].contents.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }

        let tEnc0 = CFAbsoluteTimeGetCurrent()
        hostPrepSeconds = tEnc0 - startT
        let record = !internalUse && TraceState.stages(recordStages)
        let rec = record ? stageRecorder() : nil
        rec?.reset()
        guard let cb = ctx.queue.makeCommandBufferWithUnretainedReferences(),
              var enc = rec == nil ? cb.makeComputeCommandEncoder(dispatchType: .serial)
                                   : rec!.encoder(cb, packed == nil ? "unstuff" : "unpack", .serial, after: nil) else { reason = "no command buffer"; return .failed }
        var ndisp = 0, stage = ""
        var encoderFailed = false
        var encOpen = true                       // enc not ended yet (a failed StageRecorder.encoder ends it first)
        var kernelFailure: String?               // a pipeline state that could not be built: the run declines
        func pso(_ name: String, constants: [Int32]? = nil) -> MTLComputePipelineState? {
            if let p = ctx.tryPipeline(name, constants: constants) { return p }
            kernelFailure = ctx.pipelineError(name, constants: constants); encoderFailed = true
            return nil
        }
        func begin(_ name: String) {                   // a new stage: its own encoder when recording
            stage = name
            guard let rec, !encoderFailed else { return }
            if let e = rec.encoder(cb, name, .serial, after: enc) { enc = e } else { encoderFailed = true; encOpen = false }
        }
        if profileRecord { profileDispatches.removeAll() }
        func counted(_ name: String) -> Bool {         // false once the profiling stop point is reached
            if ndisp >= profileStopAfter || encoderFailed { return false }
            ndisp += 1
            if profileRecord { profileDispatches.append(stage + ":" + name) }
            return true
        }
        func dispatch(_ name: String, _ groups: Int, _ tpg: Int, _ setup: (MTLComputeCommandEncoder) -> Void) {
            guard counted(name), let ps = pso(name) else { return }
            enc.setComputePipelineState(ps)
            setup(enc)
            enc.dispatchThreadgroups(MTLSize(width: max(groups, 1), height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        }
        func scan(_ a: Arena.Slice, plus: Int = 0, base: Int = 0, w: Int = 1, stride: Int = 1, count: Int, L seg: Int = 0) {
            let view: [UInt32] = [UInt32(base), UInt32(w), UInt32(stride), UInt32(count), UInt32(seg)]
            let ntg = ceilDiv(count, 4096)
            dispatch("scan_up", ntg, 256) { $0.set(a, 0, plus: plus); $0.setArray(view, 1); $0.set(B[20], 2) }
            dispatch("scan_mid", 1, 256) { $0.set(B[20], 0); $0.setValue(UInt32(ntg), 1) }
            dispatch("scan_down", ntg, 256) { $0.set(a, 0, plus: plus); $0.setArray(view, 1); $0.set(B[20], 2) }
        }

        if let pk = packed {
            // the packed copy's arrays instead of the Huffman stage (Decode.metal packed_unpack)
            stage = "unpack"
            var pa = (UInt32(nblk), UInt32(pk.dlen))
            dispatch("packed_unpack", ceilDiv(4 * nblk, 256), 256) {
                $0.setBuffer(pk.idx, offset: 0, index: 0); $0.setBuffer(pk.data, offset: 0, index: 1)
                $0.set(B[16], 2); $0.set(B[17], 3); $0.set(B[18], 4); $0.setBytes(&pa, length: 8, index: 5)
                $0.set(misc, 6, plus: 12)
            }
        } else {
            let src = src!
            // unstuffing
            stage = "unstuff"
            let ua: [Int32] = [Int32(ne), Int32(dri), Int32(nseg)]
            dispatch("unstuff_count", ntile, 256) {
                $0.setBuffer(src, offset: s0, index: 0); $0.setArray(ua, 1); $0.set(B[1], 2); $0.set(B[2], 3); $0.set(misc, 4)
            }
            scan(B[1], count: ntile + 1)
            scan(B[2], count: ntile + 1)
            dispatch("unstuff_scatter", ntile, 256) {
                $0.setBuffer(src, offset: s0, index: 0); $0.setArray(ua, 1); $0.set(B[1], 2); $0.set(B[2], 3)
                $0.set(misc, 4); $0.set(B[3], 5); $0.set(misc, 6, plus: 4); $0.set(B[4], 7); $0.set(misc, 8, plus: 8)
                $0.set(misc, 9, plus: 12)
            }
            let sa: [Int32] = [Int32(nseg), Int32(S)]
            begin("segments")
            dispatch("fix_segs", ceilDiv(nseg + 1, 256), 256) {
                $0.set(B[4], 0); $0.setArray(sa, 1); $0.set(misc, 2, plus: 8); $0.set(misc, 3, plus: 4); $0.set(misc, 4, plus: 12)
            }
            dispatch("seg_chunks", ceilDiv(nseg + 1, 256), 256) { $0.set(B[4], 0); $0.setArray(sa, 1); $0.set(B[5], 2) }
            scan(B[5], count: nseg + 1)
            let ca: [Int32] = [Int32(nseg), Int32(S), Int32(nmax)]
            begin("chunks")
            dispatch("make_chunks", ceilDiv(nmax, 128), 128) {
                $0.set(B[4], 0); $0.setArray(ca, 1); $0.set(B[5], 2); $0.set(B[6], 3); $0.set(B[7], 4); $0.set(B[8], 5)
            }
            // synchronisation passes; a pass after the fixed point exits at once
            let nw = UInt32(wordsBytes / 4)
            let tabTG = (L.ntab * TABW * 4 + 15) & ~15          // threadgroup bytes for the table slots in use
            for p in 0..<G {
                begin("sync\(p)")
                var args = (nw, Int32(S), Int32(nmax), Int32(p), Int32(NCP))
                dispatch("sync_pass", ceilDiv(nmax, 128), 128) {
                    $0.set(B[3], 0); $0.setBytes(&args, length: 20, index: 1); $0.set(B[21], 2)
                    $0.set(B[5], 3, plus: 4 * nseg); $0.set(B[6], 4); $0.set(B[7], 5); $0.set(B[8], 6); $0.set(B[4], 7)
                    $0.set(B[9], 8); $0.set(B[10], 9); $0.set(B[11], 10, plus: 4); $0.set(B[12], 11); $0.set(B[13], 12)
                    $0.set(B[14], 13); $0.setValue(Int32(L.ntab), 14); $0.setThreadgroupMemoryLength(tabTG, index: 0)
                }
            }
            begin("first_blocks")
            scan(B[11], count: nmax + 1)          // exclusive block counts per chunk
            let seglen = dri > 0 ? dri * bpm : nblk
            let fa: [Int32] = [Int32(nmax), Int32(seglen)]
            let ta: [Int32] = [Int32(ne), Int32(G - 1)]
            dispatch("first_blocks", ceilDiv(nmax, 256), 256) {
                $0.set(B[11], 0); $0.setArray(fa, 1); $0.set(B[8], 2); $0.set(B[5], 3); $0.set(B[15], 4)
                $0.setValue(Int32(nseg), 5); $0.setBuffer(src, offset: s0, index: 6); $0.setArray(ta, 7); $0.set(misc, 8)
                $0.set(B[14], 9); $0.set(misc, 10, plus: 12)
            }
            begin("decode_write")
            var wa = (nw, Int32(S), Int32(nmax), Int32(seglen), Int32(nblk), Int32(NCP))
            dispatch("decode_write", ceilDiv(nmax * (NCP + 1), 256), 256) {
                $0.set(B[3], 0); $0.setBytes(&wa, length: 24, index: 1); $0.set(B[21], 2); $0.set(B[5], 3)
                $0.set(B[6], 4); $0.set(B[7], 5); $0.set(B[8], 6); $0.set(B[4], 7); $0.set(B[9], 8); $0.set(B[12], 9)
                $0.set(B[13], 10); $0.set(B[15], 11); $0.set(B[16], 12); $0.set(B[17], 13); $0.set(B[18], 14)
                $0.set(misc, 15, plus: 12); $0.setValue(Int32(nseg), 16); $0.setValue(Int32(L.ntab), 17)
                $0.setThreadgroupMemoryLength(tabTG, index: 0)
            }
            // DC prediction: per component, a running sum over its blocks in MCU order, restarting per interval
            var col = 0
            begin("dc_scan")
            for ci in 0..<h.ncomp {
                let w = h.samp[ci].h * h.samp[ci].v
                scan(B[17], base: col, w: w, stride: bpm, count: L.nmcu * w, L: dri > 0 ? dri * w : 0)
                col += w
            }
        }
        begin("idct")
        dispatch("idct_islow", ceilDiv(nblk, 32), 256) {
            $0.set(B[16], 0); $0.set(B[18], 1); $0.set(B[17], 2); $0.setArray(L.q, 3); $0.setArray(L.pix, 4)
            $0.set(B[19], 5); $0.set(misc, 6, plus: 12)
        }
        let cargs: [Int32] = [Int32(h.width), Int32(h.height), Int32(mode), Int32(C)]
        begin("colour")
        if counted("color") {
            let colour: MTLComputePipelineState?
            if Decoder.envColorSpec {
                // each component's upsampling kind as the kernel's row_ctx derives it (0 full size, 1 h2v1 fancy,
                // 2 h1v2 fancy, 3 h2v2 fancy, 4 plain replication); fh/fv/fancy are the Up struct's first and last rows
                let nc = (mode == 2 || mode == 3 || mode == 6) ? 1 : 3
                var k: [Int32] = [0, 0, 0]
                for ci in 0..<nc {
                    let fh = L.up[ci], fv = L.up[3 + ci], fancy = L.up[12 + ci]
                    k[ci] = fh == 1 && fv == 1 ? 0 : fancy == 0 ? 4 : fv == 1 ? 1 : fh == 1 ? 2 : 3
                }
                colour = pso("color_k", constants: k + [Int32(mode), Int32(C)])
            } else {
                colour = pso("color")
            }
            if let colour {
                enc.setComputePipelineState(colour)
                enc.set(B[19], 0); enc.setArray(L.pix, 1); enc.setArray(L.up, 2); enc.setArray(cargs, 3)
                enc.setBuffer(out, offset: 0, index: 4); enc.set(misc, 5, plus: 12)
                enc.dispatchThreadgroups(MTLSize(width: ceilDiv(h.width, 1024), height: h.height, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }
        }
        if let kernelFailure {
            // nothing is committed: the encoder, if still open, is ended and the command buffer dropped
            if encOpen { enc.endEncoding() }
            reason = kernelFailure
            return .failed
        }
        if encoderFailed {
            // as above: an encoder still open is ended before the command buffer is dropped
            if encOpen { enc.endEncoding() }
            reason = "no compute encoder"
            return .failed
        }
        enc.endEncoding()
        runCount &+= 1
        if record { stageTimes = [] }        // a GPU error below leaves no stale stages
        let tC = CFAbsoluteTimeGetCurrent()
        hostEncodeSeconds = tC - tEnc0
        GPUActivity.begin()                 // our own GPU work, which the profile's busy gate ignores
        cb.commit()
        cb.waitUntilCompleted()
        GPUActivity.end()
        waitSeconds = CFAbsoluteTimeGetCurrent() - tC
        if let e = cb.error { reason = "GPU error: \(e)"; return .failed }
        gpuSeconds = cb.gpuEndTime - cb.gpuStartTime
        if record { stageTimes = rec?.times() ?? [] }
        if ndisp >= profileStopAfter { reason = "profile stop"; return .failed }
        if packed != nil {
            // any error bit (ERR_PACKED from the unpack's checks, or anything else) sends the caller to the
            // normal decode of the JPEG; a packed copy of a decode that passed never sets one
            if mp[3] != 0 { reason = "packed copy rejected (error bits \(mp[3]))"; return .failed }
            return .ok
        }
        let ch = B[14].contents.assumingMemoryBound(to: Int32.self)
        if ch[G - 1] != 0 { return .notConverged }
        passes = (0..<G).first { ch[$0] == 0 }.map { $0 + 1 } ?? G
        let err = mp[3] & ~(errTrailer | errSync), endpos = Int(mp[0])
        if err != 0 {
            reason = decodeErrors.filter { err & $0.0 != 0 }.map(\.1).joined(separator: "; ")
            return .failed
        }
        let raw = UnsafeRawBufferPointer(start: src!.contents(), count: n)
        let why = checkTrailer(raw, s0 + endpos)
        // the GPU applies the same rules (first_blocks) so that the colour kernel skips a declined decode
        if (mp[3] & errTrailer != 0) != (why != nil) { reason = "internal: GPU and host trailer checks disagree"; return .failed }
        if let why { reason = why; return .failed }
        if packRequest { lastArrays = (B[16].contents, B[17].contents, B[18].contents, nblk) }
        return .ok
    }
}
