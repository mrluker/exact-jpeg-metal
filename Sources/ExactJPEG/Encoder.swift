// Portions are derived from libjpeg-turbo 3.1.2 (see THIRD_PARTY_NOTICES.md for the routines and changes):
//   Copyright (C) 1991-1998, Thomas G. Lane. Modifications by Guido Vollbeding.
//   libjpeg-turbo Modifications: Copyright (C) 2009-2025, D. R. Commander, and the other contributors named
//   in the original file headers.
// Re-implemented and modified by Luke Riley, 2026. Those portions remain under the IJG License
// (licenses/README.ijg); the rest is MIT (LICENSE).
// The port was made from the 3.1.2 sources; the output target is libjpeg-turbo 3.2.0 (whole files byte-identical,
// verified by ejm encode-corpus and the manifest in testdata/manifest-libjpeg-turbo-3.2.0.json).

import Foundation
import Metal

/// Invalid arguments to the encoder.
public struct InvalidInput: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = s }
}

/// JPEG chroma subsampling for the encoder.
public enum Subsampling: Sendable {
    case s444, s422, s420
    var factors: (h: Int, v: Int) { switch self { case .s444: (1, 1); case .s422: (2, 1); case .s420: (2, 2) } }
    var name: String { switch self { case .s444: "4:4:4"; case .s422: "4:2:2"; case .s420: "4:2:0" } }
}

// jcparam.c std_luminance_quant_tbl / std_chrominance_quant_tbl (JPEG Annex K.1), natural order
let stdLum: [Int] = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
                     14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
                     49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
let stdChr: [Int] = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
                     47, 66, 99, 99, 99, 99, 99, 99] + [Int](repeating: 99, count: 32)

/// jcparam.c jpeg_set_quality(quality, force_baseline = TRUE): two tables, natural order.
func quantTables(_ quality: Int) -> [[Int]] {
    let q = min(max(quality, 1), 100)
    let scale = q < 50 ? 5000 / q : 200 - 2 * q
    return [stdLum, stdChr].map { $0.map { min(max(($0 * scale + 50) / 100, 1), 255) } }
}

/// jcdctmgr.c compute_reciprocal(q << 3) with a 16-bit DCTELEM (libjpeg-turbo SIMD builds): recip, corr, shift.
func reciprocals(_ table: [Int]) -> [Int32] {
    var rec: [Int32] = [], cor: [Int32] = [], sh: [Int32] = []
    for qv in table {
        let d = qv << 3
        let b = (Int.bitWidth - d.leadingZeroBitCount) - 1
        var r = 16 + b
        var fq = (1 << r) / d
        let fr = (1 << r) % d
        var c = d / 2
        if fr == 0 { fq >>= 1; r -= 1 } else if fr <= d / 2 { c += 1 } else { fq += 1 }
        rec.append(Int32(fq)); cor.append(Int32(c)); sh.append(Int32(r - 16))
    }
    return rec + cor + sh
}

/// jchuff.c jpeg_make_c_derived_tbl: code and size per symbol.
func huffmanCodes(_ t: HuffTable) -> ([UInt16], [UInt8]) {
    var code = [UInt16](repeating: 0, count: 256), size = [UInt8](repeating: 0, count: 256)
    var c = 0, p = 0
    for l in 1...16 {
        for _ in 0..<Int(t.counts[l - 1]) { code[Int(t.vals[p])] = UInt16(c); size[Int(t.vals[p])] = UInt8(l); c += 1; p += 1 }
        c <<= 1
    }
    return (code, size)
}

/// The bytes libjpeg-turbo (and Pillow on top of it) writes before the entropy-coded data: SOI, JFIF 1.01 without
/// density, optional EXIF (APP1) and ICC profile (APP2 chunks), DQT x2, SOF0, DHT x4, SOS.
/// Throws InvalidInput, with the encoder's messages, for a width or height outside 1...65500, a quality outside
/// 1...100, an EXIF block over 65533 bytes, or an empty ICC profile or one over 255 chunks.
public func jpegHeader(width: Int, height: Int, quality: Int, subsampling: Subsampling, icc: Data? = nil, exif: Data? = nil) throws -> Data {
    guard (1...65500).contains(width), (1...65500).contains(height) else { throw InvalidInput("image size \(width)x\(height) outside 1...65500") }
    guard (1...100).contains(quality) else { throw InvalidInput("quality must be 1...100") }
    try checkMetadata(icc: icc, exif: exif)
    var out = Data([0xFF, 0xD8])
    func seg(_ m: UInt8, _ payload: Data) {
        let L = payload.count + 2       // at most 65535: the payloads are bounded above
        out.append(contentsOf: [0xFF, m, UInt8(L >> 8), UInt8(L & 255)])
        out.append(payload)
    }
    seg(0xE0, Data([0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]))
    if let exif { seg(0xE1, exif) }
    if let icc {
        let chunk = 65533 - 14
        let n = (icc.count + chunk - 1) / chunk
        for k in 0..<n {
            var p = Data("ICC_PROFILE".utf8); p.append(contentsOf: [0, UInt8(k + 1), UInt8(n)])
            p.append(icc.subdata(in: (icc.startIndex + k * chunk)..<(icc.startIndex + min((k + 1) * chunk, icc.count))))
            seg(0xE2, p)
        }
    }
    let tq = quantTables(quality)
    for k in 0..<2 { seg(0xDB, Data([UInt8(k)] + (0..<64).map { UInt8(tq[k][NAT[$0]]) })) }
    let (h, v) = subsampling.factors
    seg(0xC0, Data([8, UInt8(height >> 8), UInt8(height & 255), UInt8(width >> 8), UInt8(width & 255), 3,
                    1, UInt8((h << 4) | v), 0, 2, 0x11, 1, 3, 0x11, 1]))
    for (tc, t) in [(0x00, stdDCLum), (0x10, stdACLum), (0x01, stdDCChr), (0x11, stdACChr)] {
        seg(0xC4, Data([UInt8(tc)] + t.counts + t.vals))
    }
    seg(0xDA, Data([3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]))
    return out
}

/// One image to encode: pixels in a shared MTLBuffer, `channels` (3 or 4, RGB first) bytes per pixel, rows `rowBytes`
/// apart, plus the JPEG settings.
public struct EncodeJob {
    public var buffer: MTLBuffer
    public var offset: Int
    public var width: Int, height: Int, channels: Int, rowBytes: Int
    public var quality: Int
    public var subsampling: Subsampling
    public var icc: Data?, exif: Data?
    public init(buffer: MTLBuffer, offset: Int = 0, width: Int, height: Int, channels: Int = 3, rowBytes: Int? = nil,
                quality: Int = 75, subsampling: Subsampling = .s420, icc: Data? = nil, exif: Data? = nil) {
        self.buffer = buffer; self.offset = offset; self.width = width; self.height = height; self.channels = channels
        self.rowBytes = rowBytes ?? defaultRowBytes(width, channels); self.quality = quality; self.subsampling = subsampling
        self.icc = icc; self.exif = exif
    }
}

/// Everything about an image's encode that depends only on its size, layout and settings (cached).
struct EncodePlan {
    let el: [Int32], div: [Int32], header: Data
    let nblk: Int, nmcu: Int, dummies: Bool

    init(_ j: EncodeJob) {
        let W = j.width, H = j.height
        let (hs, vs) = j.subsampling.factors
        let comps = [(hs, vs), (1, 1), (1, 1)]
        var blocks: [(ci: Int, dx: Int, dy: Int)] = []
        for (ci, s) in comps.enumerated() { for dy in 0..<s.1 { for dx in 0..<s.0 { blocks.append((ci, dx, dy)) } } }
        let bpm = blocks.count
        let mcux = ceilDiv(W, 8 * hs), mcuy = ceilDiv(H, 8 * vs)
        let nmcu = mcux * mcuy, nblk = nmcu * bpm
        var el = [Int32](repeating: 0, count: 61)
        el[0] = Int32(bpm)
        for (k, b) in blocks.enumerated() { el[1 + k] = Int32(b.ci); el[11 + k] = Int32(b.dx); el[21 + k] = Int32(b.dy) }
        for ci in 0..<3 {
            el[31 + ci] = Int32(comps[ci].0); el[34 + ci] = Int32(comps[ci].1)
            el[40 + ci] = Int32(ceilDiv(W * comps[ci].0, hs * 8)); el[43 + ci] = Int32(ceilDiv(H * comps[ci].1, vs * 8))
            let js = blocks.indices.filter { blocks[$0].ci == ci }
            el[48 + ci] = Int32(js.first!); el[51 + ci] = Int32(js.last!)
        }
        el[37] = Int32(hs); el[38] = Int32(vs); el[39] = Int32(mcux)
        el[46] = Int32(W); el[47] = Int32(H)
        el[54] = 0; el[55] = 1; el[56] = 1
        el[57] = Int32(j.channels); el[58] = Int32(j.rowBytes); el[59] = Int32(nblk); el[60] = Int32(nmcu)
        self.el = el
        self.nblk = nblk; self.nmcu = nmcu
        dummies = (0..<3).contains { ci in
            ceilDiv(W * comps[ci].0, hs * 8) < mcux * comps[ci].0 || ceilDiv(H * comps[ci].1, vs * 8) < mcuy * comps[ci].1
        }
        div = quantTables(j.quality).flatMap(reciprocals)
        // validate(j) has already made every check jpegHeader makes
        header = try! jpegHeader(width: W, height: H, quality: j.quality, subsampling: j.subsampling, icc: j.icc, exif: j.exif)
    }
}

/// the standard Huffman tables as the encoder kernels read them (code[4][256] u16, size[4][256] u8)
let encoderHuffmanTables: [UInt8] = {
    var ht: [UInt8] = []
    let codes = [stdDCLum, stdACLum, stdDCChr, stdACChr].map(huffmanCodes)
    for c in codes { c.0.withUnsafeBytes { ht += $0 } }
    for c in codes { ht += c.1 }
    return ht
}()

/// The entropy-coded bits of one block can be at most 64 x (16 + 11) + 16 = 1744: a JPEG Huffman code is at most 16
/// bits, a coefficient's magnitude at most 11 bits for 8-bit samples (the DC difference; AC coefficients need at most
/// 10), runs of zeros only shorten the block (one ZRL code of at most 16 bits stands for 16 coefficients, an EOB for
/// the rest of the block), and the 16 covers one EOB as margin. The standard tables' own worst case is 1676 bits
/// (ejm api-check encoder-limits, bits-bound). Used to size the bit buffers (never beyond the worst case) and to
/// reject a GPU count outside 0...bound. The 32-bit limit itself is checked on the image's exact bit count, which
/// the count kernels sum in 64 bits (Encode.metal add_total): an image whose entropy-coded data exceeds 2^31 - 1
/// bits (about 256 MB) throws InvalidInput.
let maxEntropyBitsPerBlockValue = 64 * (16 + 11) + 16

/// blocks of an image as EncodePlan counts them (luminance blocks of every MCU plus one per chroma component)
func encodeBlockCount(_ W: Int, _ H: Int, _ s: Subsampling) -> Int {
    let (hs, vs) = s.factors
    return ceilDiv(W, 8 * hs) * ceilDiv(H, 8 * vs) * (hs * vs + 2)
}

/// width * channels, or Int.max when that overflows (an argument the checks below reject)
func defaultRowBytes(_ width: Int, _ channels: Int) -> Int {
    let (r, o) = width.multipliedReportingOverflow(by: channels)
    return o ? Int.max : r
}

/// The checks of an encode's arguments, in an order where no step can overflow. Returns the bytes the pixels span
/// from the first one: rowBytes * (height - 1) + width * channels.
func checkEncodeArguments(width W: Int, height H: Int, channels: Int, rowBytes: Int, quality: Int,
                          subsampling: Subsampling, icc: Data?, exif: Data?) throws -> Int {
    guard (1...65500).contains(W), (1...65500).contains(H) else { throw InvalidInput("image size \(W)x\(H) outside 1...65500") }
    guard (1...100).contains(quality) else { throw InvalidInput("quality must be 1...100") }
    guard channels == 3 || channels == 4 else { throw InvalidInput("channels must be 3 (RGB) or 4 (RGBA/RGBX)") }
    guard rowBytes >= W * channels else { throw InvalidInput("rowBytes smaller than width * channels") }
    guard rowBytes <= Int(Int32.max) else { throw InvalidInput("rowBytes above 2^31 - 1") }
    try checkMetadata(icc: icc, exif: exif)
    if W * H > 1 << 28 { throw InvalidInput("more than 2^28 pixels") }
    // at most (2^31 - 1) * 65499 + 65500 * 4: no overflow in Int
    let span = rowBytes * (H - 1) + W * channels
    // the kernels address a pixel as y * rowBytes + x * channels in 32 bits, from the job's offset
    if span - 1 > Int(UInt32.max) {
        throw InvalidInput("the pixels span \(span) bytes, past 4 GiB (the kernels address pixels with 32-bit offsets)")
    }
    return span
}

/// libjpeg-turbo's limits on the metadata blocks: jpeg_write_icc_profile rejects an empty profile
/// (JERR_BUFFER_SIZE) and takes at most 255 chunks of 65519 bytes; an APP1 marker holds at most 65533 bytes, and
/// an empty one (jpeg_write_marker with length 0) is written as an empty APP1 segment, as here.
func checkMetadata(icc: Data?, exif: Data?) throws {
    if let exif, exif.count > 65533 { throw InvalidInput("EXIF block longer than 65533 bytes") }
    if let icc, icc.isEmpty { throw InvalidInput("empty ICC profile (libjpeg-turbo rejects one); pass nil for none") }
    if let icc, (icc.count + 65518) / 65519 > 255 { throw InvalidInput("ICC profile too long") }
}

/// a job's arguments and its input buffer, before anything binds or reads the buffer: shared storage on the
/// encoder's device, offset + span within it
func validate(_ j: EncodeJob, device: MTLDevice) throws {
    let span = try checkEncodeArguments(width: j.width, height: j.height, channels: j.channels, rowBytes: j.rowBytes,
                                        quality: j.quality, subsampling: j.subsampling, icc: j.icc, exif: j.exif)
    if j.buffer.device !== device { throw InvalidInput("input buffer is from another Metal device than the encoder's") }
    if j.buffer.storageMode != .shared { throw InvalidInput("input buffer must be .storageModeShared") }
    let (end, o) = j.offset.addingReportingOverflow(span)
    guard j.offset >= 0, !o, end <= j.buffer.length else { throw InvalidInput("buffer too small for the image") }
}

/// Testing hooks (`ejm api-check encoder-limits`): each simulates a failure the encoder must report as an error.
@_spi(Testing) public struct EncoderTestHooks {
    /// "staging", "output" or "scratch": that buffer allocation fails (as makeBuffer returning nil)
    public var failAllocation: String? = nil
    /// replaces the entropy-coded bit count the GPU reports for every image
    public var totalBitsOverride: Int32? = nil
    /// replaces the stuffed byte count the GPU reports for every image
    public var tileBytesOverride: Int32? = nil
    public init() {}
}

/// Encodes RGB(A) images on the GPU, byte-identical to libjpeg-turbo's baseline compressor with Pillow's settings
/// (quality tables, standard Huffman tables, islow DCT, no smoothing). Not thread-safe: one Encoder per thread. A
/// call made while another thread's call on the same encoder is running throws InvalidInput("encoder used from two
/// threads at once") at once (it never waits).
/// encode() does one image; encodeBatch() puts many images in one command buffer with one wait, which is much
/// faster for small images (the per-submission latency is paid once per batch).
public final class Encoder {
    /// the context given to init(ctx:), or MetalContext.shared; nil only when that setup failed (setupError)
    public let ctx: MetalContext!
    /// why this encoder cannot run (no Metal setup, a kernel that did not build): every call then throws
    /// Unsupported with it; nil normally
    public let setupError: String?
    /// the error of a call that found another thread's call on this encoder running
    public static let busyError = "encoder used from two threads at once"
    let gate = CallGate(busyReason: Encoder.busyError)
    public private(set) var gpuSeconds: Double = 0
    public private(set) var retries = 0
    let arena: Arena!
    private var outBuf: MTLBuffer?
    private var staging: MTLBuffer?
    private var bytesPerBlockEstimate = 12.0
    @_spi(Testing) public var testHooks = EncoderTestHooks()
    /// the output-size estimate (bytes per block) the next submission sizes its buffers from
    @_spi(Testing) public var bytesPerBlockEstimateForTesting: Double {
        get { bytesPerBlockEstimate } set { bytesPerBlockEstimate = newValue }
    }
    public var maxGPUBytes: Int? = nil
    /// the bound on one block's entropy-coded bits (maxEntropyBitsPerBlockValue), and an image's bound with its
    /// final padding
    @_spi(Testing) public static let maxEntropyBitsPerBlock = maxEntropyBitsPerBlockValue
    @_spi(Testing) public static func maxEntropyBits(blocks: Int) -> Int { blocks * maxEntropyBitsPerBlock + 7 }
    /// Profiling only (`ejm perf-small`): run just the first N stages of each image; the output is invalid (empty
    /// Data). Int.max: normal.
    @_spi(Testing) public var profileStages = Int.max
    /// Opt-in per-stage GPU timing (default false). When true, each submission encodes one compute encoder per
    /// stage, still in one command buffer with one commit and one wait, with GPU timestamps at the encoder
    /// boundaries, and stageTimes lists the stages of the last call. Same bytes either way. Costs about 0.2 ms of GPU
    /// on a 30 MP encode (API.md). Setting it to false clears stageTimes.
    public var recordStages = false { didSet { if !recordStages { stageTimes = [] } } }
    /// The stages of the last encode or encodeBatch call that recorded them (recordStages, or EJM_TRACE=stages), in
    /// order: fill+dct (two-pass) or fill+fused (single pass), count or len, scan, write or compact, stuff_count,
    /// stuff_scan, stuff_scatter; a batch whose images take both paths names those stages "fill+dct|fill+fused",
    /// "count|len" and "write|compact". Summed over the call's submissions (a retry is another one). Empty where
    /// the device cannot sample timestamps at stage boundaries, and until a call records.
    public private(set) var stageTimes: [StageTime] = []
    private var recorder: StageRecorder?, recorderTried = false
    // host timing of the last call, measured only while tracing: before the first command buffer, encoding, waiting
    private var tracePrep = 0.0, traceEncode = 0.0, traceWait = 0.0, traceSubmissions = 0
    /// single-pass entropy coding (fused kernel) for images up to this many blocks (128 bytes of slots per block);
    /// 0 disables it (two-pass). Default: EJM_FUSED_MAX_BLOCKS if set, else 0 where the device profile's
    /// encoderPath is twoPass (Apple9 and later), else 2M blocks, less on devices with a small GPU working set.
    /// Both paths give identical bytes.
    public var fusedMaxBlocks: Int
    public private(set) var fusedFallbacks = 0
    private var twoPass = Set<Int>()
    private var knownBits: [Int: Int] = [:]          // this call's images left out for capacity: their real bit counts
    /// the output estimate's ceiling, bytes per block: the worst case (maxEntropyBitsPerBlock / 8)
    static let maxEstimate = Double(maxEntropyBitsPerBlockValue) / 8
    private var plans: [String: EncodePlan] = [:]
    private let pso: [String: MTLComputePipelineState]
    private var htBuf: MTLBuffer?
    var selfCheckExempt = false          // the self-check's own encoder
    /// the library's own work (the self-check, the profile's routing measurement): no trace line, no stage
    /// recording from EJM_TRACE=stages, so that work runs and is timed as it does untraced
    var internalUse = false

    /// the start of a public call that holds the gate: the last call's GPU time and stages are reset, so that a call
    /// ending before any GPU work does not show the call before's
    @inline(__always) private func callStart() {
        gpuSeconds = 0
        if !stageTimes.isEmpty { stageTimes = [] }
    }

    /// throws SelfCheckFailed when the device's self-check failed; runs its encode half before the first encode;
    /// after that passed, one flag check
    @inline(__always) private func requireSelfCheck() throws {
        if selfCheckExempt || ctx.selfCheckState.encodeOK { return }
        if let f = ctx.selfCheck(decode: false, encode: true) { throw SelfCheckFailed(f) }
    }

    /// ctx nil: MetalContext.shared. When its setup failed, or a kernel's pipeline state does not build, the encoder
    /// is still made, and every call throws Unsupported with that error (setupError).
    public init(ctx: MetalContext? = nil) {
        guard let ctx = ctx ?? MetalContext.sharedIfAvailable else {
            self.ctx = nil
            setupError = MetalContext.sharedSetupError ?? "Metal setup failed"
            fusedMaxBlocks = 0; arena = nil; pso = [:]; htBuf = nil
            return
        }
        self.ctx = ctx
        fusedMaxBlocks = Encoder.envFusedMaxBlocks
            ?? (DeviceProfileRegistry.shared.profile(ctx.device).encoderPath == .twoPass ? 0 : Encoder.fusedCap(ctx.device))
        // untracked: the batch path orders its work with explicit stage barriers
        arena = Arena(device: ctx.device, untracked: true)
        var p: [String: MTLComputePipelineState] = [:]
        var failure: String?
        for n in ["scan_up", "scan_mid", "scan_down", "fill_u32", "enc_dct", "enc_dummy_dc", "enc_count", "enc_write",
                  "stuff_count", "stuff_scatter", "enc_fused", "enc_dummy_dcq", "enc_len", "enc_compact"] {
            if let ps = ctx.tryPipeline(n) { p[n] = ps } else if failure == nil { failure = ctx.pipelineError(n) }
        }
        pso = p
        setupError = failure
        // nil when the allocation fails: every encode then throws (init cannot)
        htBuf = encoderHuffmanTables.withUnsafeBytes { ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        TraceState.noteEnv()
    }

    /// the largest image (in blocks) the fused path takes by default: 2M blocks, or 1/16 of the working set
    static func fusedCap(_ d: MTLDevice) -> Int { min(2_000_000, Int(d.recommendedMaxWorkingSetSize / 16 / 128)) }
    /// EJM_FUSED_MAX_BLOCKS, read once (negative values count as 0)
    static let envFusedMaxBlocks = Int(ProcessInfo.processInfo.environment["EJM_FUSED_MAX_BLOCKS"] ?? "").map { max($0, 0) }

    private func plan(_ j: EncodeJob) -> EncodePlan {
        if j.icc != nil || j.exif != nil { return EncodePlan(j) }
        let key = "\(j.width)x\(j.height)c\(j.channels)r\(j.rowBytes)q\(j.quality)s\(j.subsampling)"
        if let p = plans[key] { return p }
        if plans.count > 64 { plans.removeAll() }
        let p = EncodePlan(j)
        plans[key] = p
        return p
    }

    /// Encode pixels from memory (copied into a GPU buffer; pass an MTLBuffer to avoid the copy).
    public func encode(bytes: UnsafeRawBufferPointer, width: Int, height: Int, channels: Int = 3, rowBytes: Int? = nil,
                       quality: Int = 75, subsampling: Subsampling = .s420, icc: Data? = nil, exif: Data? = nil) throws -> Data {
        guard gate.enter() else { throw InvalidInput(Encoder.busyError) }
        defer { gate.leave() }
        if let e = setupError { throw Unsupported(e) }
        callStart()
        if _slowPath(TraceState.enabled) && !internalUse {
            return try traced([(width, height, quality, subsampling, channels)]) {
                [try encodeBytes(bytes, width, height, channels, rowBytes, quality, subsampling, icc, exif, tracing: true)]
            }[0]
        }
        return try encodeBytes(bytes, width, height, channels, rowBytes, quality, subsampling, icc, exif, tracing: false)
    }

    private func encodeBytes(_ bytes: UnsafeRawBufferPointer, _ width: Int, _ height: Int, _ channels: Int, _ rowBytes: Int?,
                             _ quality: Int, _ subsampling: Subsampling, _ icc: Data?, _ exif: Data?, tracing: Bool) throws -> Data {
        try requireSelfCheck()
        let rb = rowBytes ?? defaultRowBytes(width, channels)
        // every argument is checked before anything is allocated or copied
        let need = try checkEncodeArguments(width: width, height: height, channels: channels, rowBytes: rb, quality: quality,
                                            subsampling: subsampling, icc: icc, exif: exif)
        guard bytes.count >= need, let src = bytes.baseAddress else { throw InvalidInput("buffer too small for the image") }
        if staging == nil || staging!.length < need {
            SetupWork.bump()
            staging = nil
            if need <= ctx.device.maxBufferLength && testHooks.failAllocation != "staging" {
                staging = ctx.device.makeBuffer(length: need, options: .storageModeShared)
            }
        }
        guard let stagingBuf = staging else { throw InvalidInput("could not allocate a \(need)-byte staging buffer for the pixels") }
        stagingBuf.contents().copyMemory(from: src, byteCount: need)
        return try encodeJobs([EncodeJob(buffer: stagingBuf, width: width, height: height, channels: channels, rowBytes: rb,
                                         quality: quality, subsampling: subsampling, icc: icc, exif: exif)], tracing: tracing)[0]
    }

    /// Encode pixels in a shared MTLBuffer: `channels` (3 or 4, RGB first) bytes per pixel, rows `rowBytes` apart.
    public func encode(buffer: MTLBuffer, offset: Int = 0, width W: Int, height H: Int, channels: Int = 3, rowBytes: Int? = nil,
                       quality: Int = 75, subsampling: Subsampling = .s420, icc: Data? = nil, exif: Data? = nil) throws -> Data {
        try encodeBatch([EncodeJob(buffer: buffer, offset: offset, width: W, height: H, channels: channels, rowBytes: rowBytes,
                                   quality: quality, subsampling: subsampling, icc: icc, exif: exif)])[0]
    }

    /// Encode several images with one command buffer and one wait. Results are in the same order as the jobs.
    public func encodeBatch(_ jobs: [EncodeJob]) throws -> [Data] {
        guard gate.enter() else { throw InvalidInput(Encoder.busyError) }
        defer { gate.leave() }
        if let e = setupError { throw Unsupported(e) }
        callStart()
        if _slowPath(TraceState.enabled) && !internalUse {
            return try traced(jobs.map { ($0.width, $0.height, $0.quality, $0.subsampling, $0.channels) }) {
                try encodeJobs(jobs, tracing: true)
            }
        }
        return try encodeJobs(jobs, tracing: false)
    }

    /// Runs one public encode call and reports it (TraceState.emit).
    private func traced(_ jobs: [(w: Int, h: Int, q: Int, s: Subsampling, c: Int)], _ call: () throws -> [Data]) throws -> [Data] {
        let retries0 = retries, fallbacks0 = fusedFallbacks, t0 = CFAbsoluteTimeGetCurrent()
        tracePrep = 0; traceEncode = 0; traceWait = 0; traceSubmissions = 0; traceStart = t0
        var out: [Data]?, failure: Error?
        do { out = try call() } catch { failure = error }
        let wall = CFAbsoluteTimeGetCurrent() - t0
        let j = jobs.first ?? (0, 0, 0, .s420, 3)
        let name: (Subsampling) -> String = { $0 == .s444 ? "4:4:4" : $0 == .s422 ? "4:2:2" : "4:2:0" }
        var s = jobs.count == 1 ? "ejm encode \(j.w)x\(j.h) \(name(j.s)) q\(j.q) \(j.c)ch"
                                : "ejm encode batch of \(jobs.count) (first \(j.w)x\(j.h) \(name(j.s)) q\(j.q) \(j.c)ch)"
        if let out { s += " \(out.reduce(0) { $0 + $1.count }) B ok" } else { s += " failed (\(failure!))" }
        s += " wall \(TraceState.ms(wall))"
        if traceSubmissions > 0 {
            s += " prep \(TraceState.ms(tracePrep)) encode \(TraceState.ms(traceEncode)) wait \(TraceState.ms(traceWait)) gpu "
                + "\(TraceState.ms(gpuSeconds)) ms submissions \(traceSubmissions)"
        } else {
            s += " ms (no GPU work)"
        }
        s += " retries \(retries - retries0) fused fallbacks \(fusedFallbacks - fallbacks0)"
        if jobs.count == 1 {
            let (hs, vs) = j.s.factors
            let nblk = ceilDiv(j.w, 8 * hs) * ceilDiv(j.h, 8 * vs) * (hs * vs + 2)      // as EncodePlan counts them
            s += " path " + (nblk > fusedMaxBlocks ? "two-pass" : fusedFallbacks > fallbacks0 ? "two-pass (fallback)" : "fused")
            s += TraceState.route(ctx, j.w, j.h, .encode)
        }
        if traceSubmissions > 0 && TraceState.stages(recordStages) { s += TraceState.stageList(stageTimes) }
        TraceState.emit(s)
        if let failure { throw failure }
        return out!
    }
    private var traceStart = 0.0

    private func stageRecorder() -> StageRecorder? {
        if !recorderTried { recorderTried = true; recorder = StageRecorder(device: ctx.device) }
        return recorder
    }

    private func encodeJobs(_ jobs: [EncodeJob], tracing: Bool) throws -> [Data] {
        // a single-image encode is one load-correction sample (DeviceProfile.loadFactors); batches are not, since
        // the profile predicts one image at a time
        guard LoadCorrection.isEnabled else { return try encodeJobsTimed(jobs, tracing: tracing) }
        guard !internalUse, jobs.count == 1 else { return try LoadCorrection.track { try encodeJobsTimed(jobs, tracing: tracing) } }
        let start = LoadCorrection.start()
        // a call resubmitted inside (a retry for capacity, a fused-path fallback) is no sample: its time is not one
        // attempt's
        let retries0 = retries, fallbacks0 = fusedFallbacks
        var ok = false
        defer {
            let once = retries == retries0 && fusedFallbacks == fallbacks0
            LoadCorrection.finish(start, gpu: .encode, ctx.device, width: ok && once ? jobs[0].width : nil, height: jobs[0].height)
        }
        let out = try encodeJobsTimed(jobs, tracing: tracing)
        ok = true
        return out
    }

    /// the memory budget for one submission's scratch and output: maxGPUBytes, else half the GPU working set (the
    /// decoder's rule)
    private var budget: Int { maxGPUBytes ?? DeviceProfile.gpuBudget(ctx.device.recommendedMaxWorkingSetSize) }

    private func encodeJobsTimed(_ jobs: [EncodeJob], tracing: Bool) throws -> [Data] {
        try requireSelfCheck()
        // all or nothing: every job is checked before any GPU work; in a batch the error names the job
        for (k, j) in jobs.enumerated() {
            do { try validate(j, device: ctx.device) } catch let e as InvalidInput { throw jobs.count > 1 ? InvalidInput("job \(k): \(e.description)") : e }
        }
        guard htBuf != nil else { throw InvalidInput("could not allocate the encoder's Huffman table buffer") }
        let plans = jobs.map(plan)
        var results = [Data?](repeating: nil, count: jobs.count)
        var attempts = [Int](repeating: 0, count: jobs.count)
        twoPass = []
        knownBits = [:]
        gpuSeconds = 0
        let record = !internalUse && TraceState.stages(recordStages)
        if record { stageTimes = [] }
        let budget = self.budget, maxLen = ctx.device.maxBufferLength
        func named(_ i: Int, _ s: String) -> InvalidInput { InvalidInput(jobs.count > 1 ? "job \(i): \(s)" : s) }
        // Submissions of at most 256 MB of scratch and output each (or the budget, if smaller), sized from the
        // current output estimate; an image the estimate or its slots did not fit goes into a later submission.
        var todo = Array(jobs.indices)
        while !todo.isEmpty {
            var take: [Int] = [], lays: [Layout] = [], scratch = 256, output = 0
            for i in todo {
                func fits(_ l: Layout) -> Bool { l.scratch + 256 + l.outBytes * 5 / 4 <= budget && l.scratch + 256 <= maxLen && l.outBytes * 5 / 4 <= maxLen }
                var l = layout(plans[i], i)
                // Over the budget at the current estimate: the smallest capacity (or the image's real count, once
                // known). So whether an image is refused depends only on the image and the budget, not on the
                // estimate earlier images left.
                if !fits(l) { l = layout(plans[i], i, minimal: true) }
                if !fits(l) {
                    throw named(i, "\(jobs[i].width)x\(jobs[i].height) needs about \((l.scratch + l.outBytes * 5 / 4) >> 20) MB of GPU memory, "
                                   + "more than allowed (\(min(budget, maxLen) >> 20) MB)")
                }
                if !take.isEmpty && (scratch + l.scratch + (output + l.outBytes) * 5 / 4 > min(256 << 20, budget)
                                     || scratch + l.scratch > maxLen || (output + l.outBytes) * 5 / 4 > maxLen) { break }
                take.append(i); lays.append(l); scratch += l.scratch; output += l.outBytes
            }
            switch attempt(jobs, plans, take, lays, tracing: tracing, record: record) {
            case .success(let r): for (i, d) in r { results[i] = d }
            case .failure(let e): throw e
            }
            // left out: the output estimate was too small, or a fused slot overflowed. Each image needs at most three
            // submissions (fused, two-pass, two-pass sized from its real count, knownBits).
            for i in take where results[i] == nil {
                attempts[i] += 1
                if attempts[i] >= 4 { throw named(i, "internal error: not encoded after \(attempts[i]) submissions") }
            }
            todo = todo.filter { results[$0] == nil }
        }
        return results.map { $0! }
    }

    private struct Lay { var capBytes = 0, capWords = 0, outCap = 0, ntile = 0, outOff = 0, fused = false; var B: [Arena.Slice] = [] }
    private typealias Layout = (lay: Lay, sizes: [Int], scratch: Int, outBytes: Int)

    /// An image's buffers for the next submission: capacity from the output estimate (minimal: the smallest, 16 KB),
    /// never above the worst case and never below the image's real count once known (so a resubmission always
    /// fits, and a high estimate after one large image costs memory, never a trap).
    private func layout(_ p: EncodePlan, _ i: Int, minimal: Bool = false) -> Layout {
        var L = Lay()
        L.fused = p.nblk <= fusedMaxBlocks && !twoPass.contains(i)
        func bytes(_ bits: Int) -> Int { (bits + 31) / 32 * 4 + 4 }          // capWords then holds bits + 2 words
        // past 2^31 - 1 bits the image is rejected anyway (the exact total), so capacity stops there: 2^28 + 4 bytes
        let worst = bytes(min(Encoder.maxEntropyBits(blocks: p.nblk), Int(Int32.max)))
        let e = bytesPerBlockEstimate
        let est = minimal || e.isNaN ? 0 : min(max(e, 0), Encoder.maxEstimate)
        L.capBytes = max(min(Int(Double(p.nblk) * est), worst), 1 << 14)
        if let known = knownBits[i] { L.capBytes = max(L.capBytes, bytes(known)) }   // a resubmission always fits
        L.capWords = L.capBytes / 4 + 2
        L.outCap = 2 * L.capBytes + 16
        L.ntile = L.capBytes / TILE + 1
        let aux = 8 * (ceilDiv(max(p.nblk + 1, L.ntile + 1), 4096) + 1)
        // two-pass: coef, nb, bit words, tile counts, scan aux, exact bit total
        // fused:    dcq, nb, bit words, tile counts, scan aux, aclen, slots, overflow flag, exact bit total
        let sizes = L.fused ? [2 * p.nblk, 4 * (p.nblk + 1), 4 * L.capWords, 4 * (L.ntile + 1), aux, 4 * p.nblk, 128 * p.nblk, 4, 8]
                            : [p.nblk * 128, 4 * (p.nblk + 1), 4 * L.capWords, 4 * (L.ntile + 1), aux, 8]
        return (L, sizes, sizes.reduce(0) { $0 + Arena.align($1) }, Arena.align(p.header.count + L.outCap + 2))
    }

    // One GPU submission for the jobs in `todo`. Returns the finished images; an image whose output estimate was too
    // small is left out (the estimate is updated and the caller resubmits it).
    // Kept separate from the throwing functions: with the retry loop, nested dispatch helpers and the throws in one
    // function, release builds (Swift 6.2.4) reported a bogus thrown error after a normal return; this split
    // avoids it. Root cause not isolated.
    private func attempt(_ jobs: [EncodeJob], _ plans: [EncodePlan], _ todo: [Int], _ layouts: [Layout], tracing: Bool, record: Bool)
        -> Result<[(Int, Data)], InvalidInput> {
        var lays: [Lay] = []
        var total = 256, outTotal = 0
        var allSizes: [[Int]] = []
        for l in layouts {
            var L = l.lay
            total += l.scratch
            allSizes.append(l.sizes)
            L.outOff = outTotal
            outTotal += l.outBytes
            lays.append(L)
        }
        // an error about one image names it in a batch of several
        func failed(_ i: Int, _ s: String) -> Result<[(Int, Data)], InvalidInput> { .failure(InvalidInput(jobs.count > 1 ? "job \(i): \(s)" : s)) }
        // the 32-bit kernel arguments (capWords, outCap, ntile, offsets into the output buffer) fit: capacity is at
        // most the worst case, about 2^28 bytes per image; checked here so a change elsewhere cannot make them trap
        guard outTotal <= Int(UInt32.max), lays.allSatisfy({ $0.outCap <= Int(UInt32.max) && $0.capWords <= Int(UInt32.max) }) else {
            return .failure(InvalidInput("output buffers past 4 GiB in one submission"))
        }
        // Arena.begin returns false when the allocation fails, and take() must not be called then: checked here
        guard testHooks.failAllocation != "scratch", arena.begin(total: total) else {
            return .failure(InvalidInput("could not allocate \(total) bytes of GPU scratch memory"))
        }
        for k in lays.indices { lays[k].B = allSizes[k].map { arena.take($0) } }
        if outBuf == nil || outBuf!.length < outTotal {
            SetupWork.bump()
            outBuf = nil
            let len = min(outTotal * 5 / 4, max(ctx.device.maxBufferLength, outTotal))
            if testHooks.failAllocation != "output" {
                outBuf = ctx.device.makeBuffer(length: len, options: [.storageModeShared, .hazardTrackingModeUntracked])
            }
        }
        guard let out = outBuf, out.length >= outTotal else {
            return .failure(InvalidInput("could not allocate \(outTotal) bytes of GPU memory for the output"))
        }
        for k in lays.indices {
            if lays[k].fused { lays[k].B[7].contents.storeBytes(of: 0, as: Int32.self) }
            lays[k].B.last!.contents.storeBytes(of: 0, as: UInt64.self)       // the exact bit total
        }
        for (k, i) in todo.enumerated() {
            plans[i].header.withUnsafeBytes { (out.contents() + lays[k].outOff).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        let tEnc0 = tracing ? CFAbsoluteTimeGetCurrent() : 0
        if tracing && traceSubmissions == 0 { tracePrep = tEnc0 - traceStart }
        let rec = record ? stageRecorder() : nil
        rec?.reset()
        // stage names (Encoder.stageTimes): the stage indices of stages() that share one encoder when recording
        let nFused = lays.filter(\.fused).count
        func pick(_ twoPass: String, _ fused: String) -> String {
            nFused == 0 ? twoPass : nFused == lays.count ? fused : twoPass + "|" + fused
        }
        func stageName(_ s: Int) -> String {
            switch s {
            case 0, 1: return pick("fill+dct", "fill+fused")
            case 2: return pick("count", "len")
            case 3, 4, 5: return "scan"
            case 6: return pick("write", "compact")
            case 7: return "stuff_count"
            case 8, 9, 10: return "stuff_scan"
            default: return "stuff_scatter"
            }
        }
        guard let cb = ctx.queue.makeCommandBufferWithUnretainedReferences(),
              var enc = rec == nil ? cb.makeComputeCommandEncoder(dispatchType: .concurrent)
                                   : rec!.encoder(cb, stageName(0), .concurrent, after: nil) else {
            return .failure(InvalidInput("no Metal command buffer"))
        }
        let perImage = todo.enumerated().map { (k, i) in
            stages(jobs[i], plans[i], lays[k].B, capWords: lays[k].capWords, ntile: lays[k].ntile, out: out,
                   outOffset: lays[k].outOff + plans[i].header.count, outCap: lays[k].outCap, fused: lays[k].fused)
        }
        for s in 0..<min(perImage.map(\.count).max() ?? 0, profileStages) {
            if let rec, s > 0, stageName(s) != stageName(s - 1) {
                guard let e = rec.encoder(cb, stageName(s), .concurrent, after: enc) else {
                    return .failure(InvalidInput("no Metal compute encoder"))
                }
                enc = e
            }
            for st in perImage where s < st.count { for f in st[s] { f(enc) } }
            enc.memoryBarrier(scope: .buffers)
        }
        enc.endEncoding()
        let tC = tracing ? CFAbsoluteTimeGetCurrent() : 0
        GPUActivity.begin()                 // our own GPU work, which the profile's busy gate ignores
        cb.commit()
        cb.waitUntilCompleted()
        GPUActivity.end()
        if tracing {
            traceEncode += tC - tEnc0; traceWait += CFAbsoluteTimeGetCurrent() - tC; traceSubmissions += 1
        }
        if let e = cb.error { return .failure(InvalidInput("GPU error: \(e)")) }
        gpuSeconds += cb.gpuEndTime - cb.gpuStartTime
        if let rec {
            for t in rec.times() {
                if let k = stageTimes.firstIndex(where: { $0.name == t.name }) {
                    stageTimes[k] = StageTime(name: t.name, gpuSeconds: stageTimes[k].gpuSeconds + t.gpuSeconds)
                } else { stageTimes.append(t) }
            }
        }
        var done: [(Int, Data)] = []
        for (k, i) in todo.enumerated() {
            let L = lays[k], p = plans[i]
            let totalBits = Int(testHooks.totalBitsOverride ?? L.B[1].contents.assumingMemoryBound(to: Int32.self)[p.nblk])
            let nbytes = (totalBits + 7) / 8
            if profileStages != Int.max { done.append((i, Data())); continue }
            // the exact total (low word, carries): past 2^31 - 1 the 32-bit scans wrapped and nothing after them can
            // be used; at or below it no partial sum overflowed (each block's count is at least 0)
            let tw = L.B.last!.contents.assumingMemoryBound(to: UInt32.self)
            let exact = Int(tw[1]) << 32 | Int(tw[0])
            if exact > Int(Int32.max) {
                return failed(i, "\(jobs[i].width)x\(jobs[i].height): the entropy-coded data is \(exact) bits, more than "
                                 + "2^31 - 1 (about 256 MB), the limit of the GPU's 32-bit bit offsets")
            }
            if L.fused && L.B[7].contents.load(as: Int32.self) != 0 {   // a block's AC bits overflowed its slot
                fusedFallbacks += 1
                twoPass.insert(i)
                continue
            }
            // the scanned total must equal the exact one and lie in 0...bound; anything else is a GPU or driver
            // fault, never a file
            let bound = Encoder.maxEntropyBits(blocks: p.nblk)
            guard totalBits >= 0 && totalBits <= bound && totalBits == exact else {
                return failed(i, "internal error: implausible entropy-coded bit count \(totalBits) for \(p.nblk) blocks (at most \(bound))")
            }
            if (totalBits + 31) / 32 + 2 > L.capWords {          // estimate too small: size from the real count and redo
                retries += 1
                bytesPerBlockEstimate = min(max(bytesPerBlockEstimate, Double(nbytes) / Double(p.nblk) * 1.25), Encoder.maxEstimate)
                knownBits[i] = totalBits
                continue
            }
            let nout = Int(testHooks.tileBytesOverride ?? L.B[3].contents.assumingMemoryBound(to: Int32.self)[L.ntile])
            // byte stuffing adds at most one byte per byte
            guard nout >= nbytes && nout <= 2 * nbytes && nout <= L.outCap else {
                return failed(i, "internal error: implausible stuffed byte count \(nout) for \(nbytes) bytes")
            }
            let base = out.contents() + L.outOff
            (base + p.header.count + nout).storeBytes(of: 0xFF, as: UInt8.self)
            (base + p.header.count + nout + 1).storeBytes(of: 0xD9, as: UInt8.self)
            done.append((i, Data(bytes: base, count: p.header.count + nout + 2)))
            // keep the estimate close to recent images (with headroom) so most encodes need one pass
            // (bounded by the worst case: one pathological image cannot make later buffers grow without limit)
            bytesPerBlockEstimate = min(max(bytesPerBlockEstimate * 0.98, Double(nbytes) / Double(p.nblk) * 1.25), Encoder.maxEstimate)
        }
        return .success(done)
    }

    typealias Stage = [(MTLComputeCommandEncoder) -> Void]

    /// One image's work as stages: dispatches inside a stage are independent of each other; a stage depends on the
    /// one before. A batch runs stage k of every image, then a memory barrier, then stage k + 1, so the images of a
    /// batch share each launch wave instead of running one after another.
    private func stages(_ j: EncodeJob, _ p: EncodePlan, _ B: [Arena.Slice], capWords: Int, ntile: Int, out: MTLBuffer,
                        outOffset: Int, outCap: Int, fused: Bool) -> [Stage] {
        let pso = self.pso, htBuf = self.htBuf!       // encodeJobsTimed checked it
        func d(_ name: String, _ groups: Int, _ tpg: Int, _ setup: @escaping (MTLComputeCommandEncoder) -> Void) -> (MTLComputeCommandEncoder) -> Void {
            { enc in
                enc.setComputePipelineState(pso[name]!)
                setup(enc)
                enc.dispatchThreadgroups(MTLSize(width: max(groups, 1), height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            }
        }
        func scan(_ a: Arena.Slice, count: Int) -> [Stage] {
            let view: [UInt32] = [0, 1, 1, UInt32(count), 0]
            let ntg = ceilDiv(count, 4096)
            return [[d("scan_up", ntg, 256) { $0.set(a, 0); $0.setArray(view, 1); $0.set(B[4], 2) }],
                    [d("scan_mid", 1, 256) { $0.set(B[4], 0); $0.setValue(UInt32(ntg), 1) }],
                    [d("scan_down", ntg, 256) { $0.set(a, 0); $0.setArray(view, 1); $0.set(B[4], 2) }]]
        }
        let nblk = p.nblk, el = p.el, div = p.div
        var st: [Stage] = []
        let fill = d("fill_u32", ceilDiv(capWords, 256), 256) { $0.set(B[2], 0); $0.setValue(UInt32(0), 1); $0.setValue(UInt32(capWords), 2) }
        if fused {
            // B: 0 dcq, 1 nb/offsets, 2 bit words, 3 tile counts, 4 scan aux, 5 aclen, 6 slots, 7 overflow, 8 exact total
            st.append([fill, d("enc_fused", ceilDiv(nblk, 32), 256) {
                $0.setBuffer(j.buffer, offset: j.offset, index: 0); $0.setArray(el, 1); $0.setArray(div, 2)
                $0.setBuffer(htBuf, offset: 0, index: 3); $0.set(B[0], 4); $0.set(B[5], 5); $0.set(B[6], 6); $0.set(B[7], 7) }])
            st.append(p.dummies ? [d("enc_dummy_dcq", ceilDiv(p.nmcu, 128), 128) { $0.setArray(el, 0); $0.set(B[0], 1) }] : [])
            st.append([d("enc_len", ceilDiv(nblk, 128), 128) {
                $0.setArray(el, 0); $0.set(B[0], 1); $0.set(B[5], 2); $0.setBuffer(htBuf, offset: 0, index: 3); $0.set(B[1], 4)
                $0.set(B[8], 5) }])
            st += scan(B[1], count: nblk + 1)
            st.append([d("enc_compact", ceilDiv(nblk, 128), 128) {
                $0.setArray(el, 0); $0.set(B[0], 1); $0.set(B[5], 2); $0.set(B[6], 3); $0.setBuffer(htBuf, offset: 0, index: 4)
                $0.set(B[1], 5); $0.set(B[2], 6); $0.setValue(UInt32(capWords), 7) }])
        } else {
            st.append([fill, d("enc_dct", ceilDiv(nblk, 32), 256) {
                $0.setBuffer(j.buffer, offset: j.offset, index: 0); $0.setArray(el, 1); $0.setArray(div, 2); $0.set(B[0], 3) }])
            st.append(p.dummies ? [d("enc_dummy_dc", ceilDiv(p.nmcu, 128), 128) { $0.setArray(el, 0); $0.set(B[0], 1) }] : [])
            st.append([d("enc_count", ceilDiv(nblk, 128), 128) {
                $0.set(B[0], 0); $0.setArray(el, 1); $0.setBuffer(htBuf, offset: 0, index: 2); $0.set(B[1], 3); $0.set(B[5], 4) }])
            st += scan(B[1], count: nblk + 1)
            st.append([d("enc_write", ceilDiv(nblk, 128), 128) {
                $0.set(B[0], 0); $0.setArray(el, 1); $0.setBuffer(htBuf, offset: 0, index: 2); $0.set(B[1], 3); $0.set(B[2], 4)
                $0.setValue(UInt32(capWords), 5) }])
        }
        st.append([d("stuff_count", ntile, 256) {
            $0.set(B[2], 0); $0.set(B[1], 1); $0.setValue(Int32(nblk), 2); $0.set(B[3], 3); $0.setValue(UInt32(capWords), 4) }])
        st += scan(B[3], count: ntile + 1)
        st.append([d("stuff_scatter", ntile, 256) {
            $0.set(B[2], 0); $0.set(B[1], 1); $0.setValue(Int32(nblk), 2); $0.set(B[3], 3)
            $0.setBuffer(out, offset: outOffset, index: 4); $0.setValue(UInt32(outCap), 5); $0.setValue(UInt32(ntile), 6)
            $0.setValue(UInt32(outOffset & 3), 7); $0.setValue(UInt32(capWords), 8) }])
        return st
    }
}
