import Foundation
import ExactJPEG
import TurboRef
import ImageIO
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import CryptoKit

// ejm public-bench <dir> [<dir> ...] [iters] [--quick] [--out <path>]
// Exactness and speed on real public JPEGs. Per directory: <dir>/420/*.jpg and <dir>/444/*.jpg when those exist,
// else the *.jpg files in <dir>; each checked against <dir>/SHA256SUMS (`shasum -a 256` lines) when present, else
// against <dir>/expected.txt ("<420|444> <name> <sha256>" per line). The sampling comes from each file's SOF.
// Progressive and arithmetic-coded files are declined by the GPU path by design: reported as "declined: <kind>"
// (progressive, arithmetic sequential, ...), with the other
// decoders still measured, and not counted as a failure. Per file, in order of coded bytes per pixel within each
// directory: Metal decode (exactness against libjpeg-turbo, sustained wall and GPU medians,
// sync passes, per-stage GPU times of one decode), libjpeg-turbo decode (1 thread, and images/s with one image per
// core), Metal images/s with 2 decoders in flight, ImageIO (hardware key true, and a software control with it
// false) and VideoToolbox (hardware JPEG engine: BGRA, whose comparison includes VideoToolbox's YCbCr to RGB
// conversion, and a bi-planar full-range YCbCr control whose Y plane is compared with libjpeg-turbo's) decode times
// and pixel identity against libjpeg-turbo, and the q95 re-encode of libjpeg-turbo's pixels (Metal against
// libjpeg-turbo, byte for byte). Writes results/public/<chip>-gpu<cores>-<yyyy-MM-dd-HHmm>.json (or --out).
// The reference decode is TurboRef tr_decode: the libjpeg API of libjpeg-turbo, JDCT_ISLOW, fancy upsampling (the
// corpus test's reference). Timing rule: `warm` seconds of the same work first, then `iters` timed calls, median
// (1 s and 15 by default; --quick: 0.5 s and 3, throughput 1 s instead of 2 s), on a monotonic clock. A call that
// fails is counted, not timed as fast: a case with any failure is marked invalid. Exit 1 if a Metal decode or
// encode is not byte-identical (a decline by design does not count), 2 if a file was skipped (SHA-256 mismatch,
// listed in SHA256SUMS or expected.txt but missing, libjpeg-turbo warning, unreadable; or a whole directory whose
// SHA256SUMS matches none of its files) or
// no files were found.

/// The libjpeg-turbo-published images (the 3 vgl frames ship with libjpeg-turbo's test images; artificial and
/// nightshot_iso_100 are the imagecompression.info images libjpeg-turbo publishes timings for)
let publishedImages: Set<String> = ["artificial", "nightshot_iso_100", "vgl_5674_0098", "vgl_6434_0018", "vgl_6548_0026"]

private struct PBConfig { var iters = 15; var warm = 1.0; var rateSeconds = 2.0; var quick = false }

/// Run each closure on its own thread (user-initiated QoS) and wait for all (as in research/hw-hybrid).
private func pbRunThreads(_ bodies: [() -> Void]) {
    let g = DispatchGroup()
    for b in bodies {
        let ub = Unchecked(b)
        g.enter()
        let t = Thread { ub.value(); g.leave() }
        t.qualityOfService = .userInitiated
        t.stackSize = 8 << 20
        t.start()
    }
    g.wait()
}

private struct Rate {
    var ips = Double.nan, latencyMs = Double.nan, failures = 0, threads = 0
    var valid: Bool { failures == 0 && ips.isFinite && ips > 0 }
    var text: String { valid ? fmt(ips) : "invalid (\(failures) failed)" }
    func json() -> [String: Any] {
        ["ips": valid ? jnum(ips, 100) : NSNull(), "ms_per_call": valid ? jnum(latencyMs) : NSNull(),
         "ms_per_image": valid ? jnum(1000 / ips) : NSNull(), "threads": threads, "failures": failures, "valid": valid]
    }
}

/// One worker per state in `states` (built before the clock starts) runs `job` for `seconds`: successful images per
/// second over all workers, the median call latency, and the failed calls.
private func pbRate<S>(states: [S], seconds: Double, job: @escaping (inout S) -> Bool) -> Rate {
    var states = states
    let n = states.count
    let lat = (0..<n).map { _ in Slot([Double]()) }, fails = (0..<n).map { _ in Slot(0) }
    let t0 = mono()
    states.withUnsafeMutableBufferPointer { st in
        let base = Unchecked(st.baseAddress!), uj = Unchecked(job)
        pbRunThreads((0..<n).map { k in {
            while mono() - t0 < seconds {
                let a = mono()
                if uj.value(&base.value[k]) { lat[k].value.append(mono() - a) } else { fails[k].value += 1 }
            }
        } })
    }
    let wall = mono() - t0
    let all = lat.flatMap { $0.value }
    return Rate(ips: Double(all.count) / wall, latencyMs: all.isEmpty ? .nan : median(all) * 1000,
                failures: fails.reduce(0) { $0 + $1.value }, threads: n)
}

// MARK: - VideoToolbox JPEG (from research/hw-hybrid, Sources/ejm/HWResearch.swift at 0c0510d)

/// One VTDecompressionSession for JPEG frames of one size and pixel format. The sample buffer (a CMBlockBuffer
/// holding a copy of the file) is made once by sample(_:), outside the timed calls.
final class VTHardwareJPEGDecoder {
    let session: VTDecompressionSession
    let fmt: CMVideoFormatDescription
    var last: CVPixelBuffer?
    var lastStatus: OSStatus = 0

    /// nil and `status` set when the session cannot be created (with requireHW: no hardware decoder for this format)
    init?(width: Int, height: Int, pixelFormat: OSType, requireHW: Bool, status: inout OSStatus) {
        var f: CMVideoFormatDescription?
        status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: Int32(width), height: Int32(height),
                                                extensions: nil, formatDescriptionOut: &f)
        guard status == 0, let f else { return nil }
        fmt = f
        let spec: [CFString: Any] = requireHW ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
                                              : [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var s: VTDecompressionSession?
        status = VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard status == 0, let s else { return nil }
        session = s
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    /// the file as a ready CMSampleBuffer for this session's format description
    func sample(_ d: Data) -> CMSampleBuffer? {
        var bb: CMBlockBuffer?
        let n = d.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == 0,
              let bb else { return nil }
        guard d.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: n) }) == 0
        else { return nil }
        var sb: CMSampleBuffer?
        var size = n
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == 0
        else { return nil }
        return sb
    }

    /// decode one frame synchronously; nil (lastStatus set) on failure
    @discardableResult func decode(_ sb: CMSampleBuffer) -> CVPixelBuffer? {
        last = nil; lastStatus = 0
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [unowned self] status, _, img, _, _ in
            self.lastStatus = status
            self.last = img
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if st != 0 { lastStatus = st; return nil }
        return lastStatus == 0 ? last : nil
    }
}

/// A BGRA CVPixelBuffer as dense RGB.
func bgraPixelBufferRGB(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    rgb.withUnsafeMutableBufferPointer { o in
        for y in 0..<h {
            let row = base + y * bpr
            for x in 0..<w { let q = row + 4 * x, i = 3 * (y * w + x); o[i] = q[2]; o[i + 1] = q[1]; o[i + 2] = q[0] }
        }
    }
    return rgb
}

/// plane 0 (Y) of a bi-planar CVPixelBuffer as dense w*h bytes
private func lumaPlane(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var out = [UInt8](repeating: 0, count: w * h)
    out.withUnsafeMutableBytes { o in for y in 0..<h { (o.baseAddress! + y * w).copyMemory(from: base + y * bpr, byteCount: w) } }
    return out
}

private func fourCC(_ v: OSType) -> String {
    String(bytes: [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)], encoding: .ascii) ?? "\(v)"
}

/// the colour attachments of a pixel buffer (YCbCr matrix, primaries, transfer function, chroma siting) and its
/// pixel format, whose FourCC says the range ('420f' full, '420v' video; BGRA has none)
private func colourAttachments(_ pb: CVPixelBuffer) -> [String: Any] {
    var r: [String: Any] = ["pixel_format": fourCC(CVPixelBufferGetPixelFormatType(pb))]
    for (name, key) in [("ycbcr_matrix", kCVImageBufferYCbCrMatrixKey), ("color_primaries", kCVImageBufferColorPrimariesKey),
                        ("transfer_function", kCVImageBufferTransferFunctionKey), ("chroma_location", kCVImageBufferChromaLocationTopFieldKey)] {
        r[name] = CVBufferCopyAttachment(pb, key, nil).map { "\($0)" } ?? NSNull()
    }
    return r
}

// MARK: - inputs

struct PBFile { let dir: String; let sub: String; let name: String; let path: String; let data: Data; let sha: String; let checked: Bool }

/// expected SHA-256 per file, keyed by the path relative to `dir` ("420/artificial.jpg", "speed_bench.jpg"), and
/// the list it came from: <dir>/SHA256SUMS (`<hash>  <path>`, `*<path>` in binary mode) if present, else
/// <dir>/expected.txt (`<420|444> <name> <hash>`, name without .jpg)
func loadExpected(_ dir: String) -> (map: [String: String], source: String)? {
    if let s = try? String(contentsOfFile: dir + "/SHA256SUMS", encoding: .utf8) {
        var m: [String: String] = [:]
        for line in s.split(whereSeparator: \.isNewline) {   // "\r\n" is one Character: split on isNewline
            let p = line.split(separator: " ", maxSplits: 1)
            guard p.count == 2 else { continue }
            var name = p[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            m[name] = String(p[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return (m, "SHA256SUMS")
    }
    if let s = try? String(contentsOfFile: dir + "/expected.txt", encoding: .utf8) {
        var m: [String: String] = [:]
        for line in s.split(whereSeparator: \.isNewline) {   // "\r\n" is one Character: split on isNewline
            let p = line.split(separator: " ")
            if p.count == 3 { m["\(p[0])/\(p[1]).jpg"] = String(p[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        }
        return (m, "expected.txt")
    }
    return nil
}

/// The process of a SOFn marker: nil for baseline / extended sequential Huffman (SOF0, SOF1), which the GPU path
/// decodes; otherwise its kind. byDesign: progressive or arithmetic-coded, which the GPU path declines by design.
func sofKind(_ m: UInt8) -> (kind: String, byDesign: Bool)? {
    switch m {
    case 0xC0, 0xC1: return nil
    case 0xC2: return ("progressive", true)
    case 0xC3: return ("lossless", false)
    case 0xC5: return ("differential sequential", false)
    case 0xC6: return ("differential progressive", true)
    case 0xC7: return ("differential lossless", false)
    case 0xC9: return ("arithmetic sequential", true)
    case 0xCA: return ("arithmetic progressive", true)
    case 0xCB: return ("arithmetic lossless", true)
    case 0xCD: return ("arithmetic differential sequential", true)
    case 0xCE: return ("arithmetic differential progressive", true)
    case 0xCF: return ("arithmetic differential lossless", true)
    default: return ("SOF 0x\(String(m, radix: 16))", false)
    }
}

typealias SOFInfo = (progressive: Bool, kind: (kind: String, byDesign: Bool)?, ncomp: Int, samp: [(h: Int, v: Int)])

/// From the frame header (SOFn): its kind (sofKind), components, sampling factors (h, v) per component.
/// JPEGHeader (parseJPEGHeader) throws for progressive files, so the sampling is read here for every file.
func readSOF(_ d: Data) -> SOFInfo? {
    let p = [UInt8](d.prefix(1 << 20))
    var i = 2
    guard p.count > 4, p[0] == 0xFF, p[1] == 0xD8 else { return nil }
    while i + 3 < p.count {
        guard p[i] == 0xFF else { return nil }
        let m = p[i + 1]
        if m == 0xFF { i += 1; continue }
        if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) { i += 2; continue }
        let len = Int(p[i + 2]) << 8 | Int(p[i + 3])
        if (0xC0...0xCF).contains(m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
            guard i + 2 + len <= p.count, len >= 8 else { return nil }
            let nc = Int(p[i + 9])
            guard i + 10 + 3 * nc <= p.count else { return nil }
            let samp = (0..<nc).map { k -> (h: Int, v: Int) in let b = p[i + 11 + 3 * k]; return (Int(b >> 4), Int(b & 15)) }
            return ([0xC2, 0xC6, 0xCA, 0xCE].contains(m), sofKind(m), nc, samp)
        }
        if m == 0xDA { return nil }
        i += 2 + len
    }
    return nil
}

func listFiles(_ dir: String) -> [(sub: String, name: String, path: String)] {
    let fm = FileManager.default
    func jpgs(_ d: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { ["jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }
    var out: [(String, String, String)] = []
    for sub in ["420", "444"] where fm.fileExists(atPath: dir + "/" + sub) {
        for f in jpgs(dir + "/" + sub) { out.append((sub, (f as NSString).deletingPathExtension, dir + "/" + sub + "/" + f)) }
    }
    if out.isEmpty { for f in jpgs(dir) { out.append(("", (f as NSString).deletingPathExtension, dir + "/" + f)) } }
    return out
}

/// sampling name from the SOF (luma factors over chroma factors, JPEGHeader.subsampling), TurboRef's samp code and
/// the Encoder's Subsampling (nil where the Encoder has none: 4:4:0, 4:1:1, anything else)
func sampling(_ sof: SOFInfo?) -> (name: String, turbo: Int?, metal: Subsampling?) {
    guard let sof else { return ("unknown (no frame header)", nil, nil) }
    // as JPEGHeader.subsampling: luma factors over chroma factors
    var name = sof.samp.map { "\($0.h)x\($0.v)" }.joined(separator: "/")
    if sof.ncomp == 1 { name = "gray" }
    else if sof.ncomp == 3 {
        let names: [String: String] = ["1,1": "4:4:4", "2,1": "4:2:2", "2,2": "4:2:0", "1,2": "4:4:0", "4,1": "4:1:1"]
        let (y, c1, c2) = (sof.samp[0], sof.samp[1], sof.samp[2])
        if c1 == c2, c1.h > 0, c1.v > 0, y.h % c1.h == 0, y.v % c1.v == 0, let n = names["\(y.h / c1.h),\(y.v / c1.v)"] { name = n }
    }
    switch name {
    case "gray": return ("gray", nil, nil)
    case "4:4:4": return ("4:4:4", 0, .s444)
    case "4:2:2": return ("4:2:2", 1, .s422)
    case "4:2:0": return ("4:2:0", 2, .s420)
    case "4:4:0": return ("4:4:0", 3, nil)
    case "4:1:1": return ("4:1:1", 4, nil)
    case let s: return (s, nil, nil)
    }
}

/// VideoToolbox's bi-planar full-range format for a sampling (nil: none)
private func biPlanarFormat(_ name: String) -> OSType? {
    switch name {
    case "4:2:0": return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    case "4:2:2": return kCVPixelFormatType_422YpCbCr8BiPlanarFullRange
    case "4:4:4": return kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
    default: return nil
    }
}

/// public-bench's file selection (also `ejm export-public`): per directory, listFiles, each file checked against
/// loadExpected's list (a mismatch, an entry listed but missing, or a SHA256SUMS matching no file is printed and
/// added to `skipped`), sorted by coded bytes per pixel within its directory. sources: the SHA-256 list per directory.
func selectPublicFiles(_ dirs: [String], label: (String) -> String = { ($0 as NSString).lastPathComponent }) -> (files: [PBFile], skipped: [[String: Any]], sources: [String: String]) {
    var files: [PBFile] = [], skipped: [[String: Any]] = [], sources: [String: String] = [:]
    func bpp(_ f: PBFile) -> Double { let i = Turbo.info(f.data); return i.map { Double(f.data.count) / Double($0.w * $0.h) } ?? 0 }
    for dir in dirs {
        let expected = loadExpected(dir)
        sources[dir] = expected?.source ?? "none"
        var here: [PBFile] = []
        let listed = listFiles(dir)
        if let expected {
            let onDisk = Set(listed.map { (($0.sub.isEmpty ? "" : $0.sub + "/") + ($0.path as NSString).lastPathComponent) })
            let missing = expected.map.keys.filter { !onDisk.contains($0) }.sorted()
            for mf in missing {
                print("listed in \(label(dir))/\(expected.source) but not found: \(mf)")
                skipped.append(["dir": label(dir), "file": mf, "reason": "listed in \(expected.source), not found"])
            }
            if expected.source == "SHA256SUMS" && !listed.isEmpty && onDisk.isDisjoint(with: expected.map.keys) {
                print("\(label(dir)): SHA256SUMS present but none of its \(expected.map.count) entries matches a file here; directory skipped")
                skipped.append(["dir": label(dir), "file": "*", "reason": "SHA256SUMS matches no file"])
                continue
            }
        }
        for f in listed {
            let rel = (f.sub.isEmpty ? "" : f.sub + "/") + (f.path as NSString).lastPathComponent
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: f.path)) else { skipped.append(["dir": label(dir), "file": rel, "reason": "unreadable"]); continue }
            let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            if let e = expected?.map[rel], e != sha {
                print("SHA-256 MISMATCH \(label(dir))/\(rel): \(sha), expected \(e) (\(expected!.source)); skipped")
                skipped.append(["dir": label(dir), "file": rel, "reason": "sha256 mismatch", "sha256": sha, "expected": e]); continue
            }
            if expected != nil && expected!.map[rel] == nil { print("note: \(label(dir))/\(rel) is not in \(expected!.source)") }
            here.append(PBFile(dir: dir, sub: f.sub, name: f.name, path: f.path, data: d, sha: sha, checked: expected?.map[rel] != nil))
        }
        here.sort { bpp($0) < bpp($1) }
        files += here
    }
    return (files, skipped, sources)
}

// MARK: - the command

func runPublicBench(_ argv: [String]) -> Int32 {
    var cfg = PBConfig(), out: String? = nil, pos: [String] = []
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--quick": cfg.quick = true
        case "--out": i += 1; guard i < argv.count else { print("--out needs a path"); return 2 }; out = argv[i]
        default: pos.append(argv[i])
        }
        i += 1
    }
    if cfg.quick { cfg.iters = 3; cfg.warm = 0.5; cfg.rateSeconds = 1 }
    var dirs: [String] = []
    for a in pos {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue {
            let canon = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
            if dirs.contains(canon) { print("note: \((canon as NSString).lastPathComponent) given twice; measured once") } else { dirs.append(canon) }
        }
        else if let n = Int(a), n > 0 { cfg.iters = n }
        else { print("not a directory or a positive iteration count: \(a)"); return 2 }
    }
    guard !dirs.isEmpty else { print("usage: ejm public-bench <dir> [<dir> ...] [iters] [--quick] [--out <path>]"); return 2 }

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    benchProfile()
    var cond = Bench.conditions()           // load average at start is in here
    let cores = ProcessInfo.processInfo.activeProcessorCount
    print("reference: \(Turbo.version); \(cfg.quick ? "QUICK (smoke test, not results): " : "")iters \(cfg.iters), warm-up \(cfg.warm) s, throughput \(cfg.rateSeconds) s; load at start \(cond["load_average"] ?? "?")")

    // a label per directory: its last path component only ("jpeg", "zune-jpeg"), never the absolute path, so the
    // output and the JSON carry no home folder; a later directory with the same last component gets " (2)", " (3)"
    var dirLabel: [String: String] = [:]
    for d in dirs {
        let base = (d as NSString).lastPathComponent
        var l = base, n = 2
        while dirLabel.values.contains(l) { l = "\(base) (\(n))"; n += 1 }
        dirLabel[d] = l
    }
    func lbl(_ d: String) -> String { dirLabel[d] ?? (d as NSString).lastPathComponent }
    let selected = selectPublicFiles(dirs, label: lbl)
    let files = selected.files, sources = selected.sources
    var skipped = selected.skipped
    guard !files.isEmpty else { print("no JPEG files under \(dirs.map(lbl).joined(separator: ", "))"); return 2 }

    var records: [[String: Any]] = []
    var decodeBad = 0, encodeBad = 0
    var invalidCases: [String] = []
    let enc = Encoder()
    for f in files {
        let label = lbl(f.dir) + "/" + (f.sub.isEmpty ? f.name : "\(f.sub)/\(f.name)")
        var r: [String: Any] = ["dir": lbl(f.dir), "subsampling_dir": f.sub, "name": f.name, "sha256": f.sha,
                                "sha256_checked": f.checked, "bytes": f.data.count,
                                "published_by_libjpeg_turbo": publishedImages.contains(f.name)]
        func note(_ t: Timed, _ what: String) { if !t.valid { invalidCases.append("\(label) \(what): \(t.failures) failed") } }
        func noteRate(_ t: Rate, _ what: String) { if !t.valid { invalidCases.append("\(label) \(what): \(t.failures) failed") } }
        guard let ref = Turbo.decode(f.data) else {
            print("\(label): libjpeg-turbo cannot decode it; skipped")
            skipped.append(["dir": lbl(f.dir), "file": label, "reason": "libjpeg-turbo decode error"]); continue
        }
        if ref.warned {
            let code = tr_last_warning()
            let msg = String(cString: tr_message(code))
            print("\(label): libjpeg-turbo warned (\(msg)); not used as a reference, skipped")
            skipped.append(["dir": lbl(f.dir), "file": label, "reason": "libjpeg-turbo warning", "warning": msg]); continue
        }
        let sof = readSOF(f.data)
        let samp = sampling(sof)
        let progressive = sof?.progressive ?? false
        r["progressive"] = progressive
        r["sof_kind"] = sof?.kind?.kind ?? (sof == nil ? "unknown" : "sequential Huffman")
        let byDesign = sof?.kind?.byDesign == true ? sof!.kind!.kind : nil
        let gray = samp.name == "gray"
        let w = ref.w, h = ref.h, px = w * h
        r["width"] = w; r["height"] = h; r["mp"] = jnum(Double(px) / 1e6); r["bytes_per_pixel"] = jnum(Double(f.data.count) / Double(px), 1e4)
        r["subsampling"] = samp.name
        print("\n== \(label): \(w)x\(h) (\(fmt(Double(px) / 1e6, 1)) MP), \(f.data.count / 1024) KB, \(fmt(Double(f.data.count) / Double(px), 3)) B/px, \(samp.name)\(sof?.kind.map { ", " + $0.kind } ?? "")")

        // Metal decode: exactness, sustained wall/GPU, passes, stages
        var m: [String: Any] = [:]
        let dec = Decoder()
        if let img = dec.decode(f.data) {
            let same = ref.px.withUnsafeBytes { $0.elementsEqual(img.bytes) }
            m["identical"] = same
            if !same { decodeBad += 1 }
            var gpu: [Double] = []
            let wall = pbTimes(cfg.iters, warm: cfg.warm) { let ok = dec.decode(f.data) != nil; gpu.append(dec.gpuSeconds); return ok }
            note(wall, "Metal decode")
            gpu = Array(gpu.suffix(cfg.iters))
            for (k, v) in wall.json("wall_ms") { m[k] = v }
            m["gpu_ms"] = wall.valid ? jnum(median(gpu) * 1000) : NSNull()
            m["passes"] = dec.passes
            dec.recordStages = true
            _ = dec.decode(f.data)
            let ok = dec.decode(f.data) != nil       // the second decode's stages (recorder set up by the first)
            let stages = ok ? dec.stageTimes : []
            dec.recordStages = false                 // (clears stageTimes)
            m["stages"] = stages.map { ["stage": $0.name, "gpu_ms": jnum($0.gpuSeconds * 1000)] }
            m["stages_total_gpu_ms"] = jnum(stages.reduce(0) { $0 + $1.gpuSeconds } * 1000)
            print("  Metal decode: \(same ? "byte-identical" : "DIFFERENT") to libjpeg-turbo; wall \(wall.text) ms, GPU \(fmt(median(gpu) * 1000)) ms, sync passes \(dec.passes)")
            print("    stages (GPU ms, one decode): " + stages.map { "\($0.name) \(fmt($0.gpuSeconds * 1000, 3))" }.joined(separator: ", "))
            // 2 decoders in flight
            let states = (0..<2).map { _ -> Decoder in let d = Decoder(); _ = d.decode(f.data); return d }
            let t = pbRate(states: states, seconds: cfg.rateSeconds, job: { d in d.decode(f.data) != nil })
            noteRate(t, "Metal x2")
            m["throughput_2_decoders"] = t.json()
            print("  Metal 2 decoders in flight: \(t.text) images/s")
        } else {
            if let k = byDesign {
                m["declined"] = k; m["declined_by_design"] = true   // the GPU path decodes sequential Huffman files only
                print("  Metal decode: declined: \(k) (\(dec.reason ?? "?"))")
            } else {
                m["identical"] = false; m["declined"] = dec.reason ?? "?"; decodeBad += 1
                print("  Metal decode DECLINED: \(dec.reason ?? "?")")
            }
        }
        r["metal_decode"] = m

        // libjpeg-turbo decode
        do {
            var buf = [UInt8](repeating: 0, count: px * 3)
            let t1 = pbTimes(cfg.iters, warm: cfg.warm) { buf.withUnsafeMutableBufferPointer { Turbo.decodeInto(f.data, $0.baseAddress!) } == 0 }
            let all = pbRate(states: (0..<cores).map { _ in [UInt8](repeating: 0, count: px * 3) }, seconds: cfg.rateSeconds,
                             job: { b in b.withUnsafeMutableBufferPointer { Turbo.decodeInto(f.data, $0.baseAddress!) } == 0 })
            note(t1, "libjpeg-turbo decode"); noteRate(all, "libjpeg-turbo all cores")
            var td = t1.json("ms_1_thread")
            td["all_cores"] = all.json()
            r["turbo_decode"] = td
            print("  libjpeg-turbo decode: \(t1.text) ms (1 thread); \(all.text) images/s on \(cores) threads")
        }

        // ImageIO: hardware key true, and the software control (key false)
        for (key, hw) in [("imageio", true), ("imageio_sw", false)] {
            var lastImg: CGImage? = nil
            let t = pbTimes(cfg.iters, warm: cfg.warm) { lastImg = imageIODecodeKey(f.data, hardware: hw); return lastImg != nil }
            note(t, key)
            var io = t.json("ms_1_thread")
            io["kCGImageSourceUseHardwareAcceleration"] = hw
            if let li = lastImg, let rgb = cgImageRawRGB(li) {
                for (k, v) in rgb.withUnsafeBytes({ identity($0, ref.px) }) { io[k] = v }
            } else if let li = lastImg {
                io["error"] = "no pixels: \(li.bitsPerComponent)-bit, \(li.bitsPerPixel) bits per pixel, colour model \(li.colorSpace.map { "\($0.model.rawValue)" } ?? "?")"
            } else { io["error"] = "decode failed" }
            r[key] = io
            print("  ImageIO decode (hardware key \(hw)): \(t.text) ms; vs libjpeg-turbo: \(identityText(io))")
        }

        // VideoToolbox, hardware JPEG engine: BGRA (includes VideoToolbox's YCbCr to RGB conversion), and the
        // bi-planar full-range YCbCr control: its Y plane against libjpeg-turbo's (tr_decode to JCS_GRAYSCALE of a
        // YCbCr JPEG is the decoded Y component, no colour conversion, no upsampling)
        do {
            var vt: [String: Any] = ["pixel_format": "32BGRA", "require_hardware": true,
                                     "comparison": "RGB from BGRA; includes VideoToolbox's YCbCr to RGB conversion",
                                     "timing": "decode of a prepared CMSampleBuffer (made outside the timed calls)"]
            var st: OSStatus = 0, stage = "session"
            let v0 = VTHardwareJPEGDecoder(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA, requireHW: true, status: &st)
            let sb0 = v0?.sample(f.data)
            if v0 != nil { stage = sb0 == nil ? "sample buffer" : "decode" }
            let pb0 = sb0.flatMap { v0!.decode($0) }
            if pb0 == nil, let v0, sb0 != nil { st = v0.lastStatus }
            if let v = v0, let sb = sb0, let pb = pb0 {
                vt["available"] = true
                vt["attachments"] = colourAttachments(pb)
                for (k, val) in bgraPixelBufferRGB(pb).withUnsafeBytes({ identity($0, ref.px) }) { vt[k] = val }
                let t = pbTimes(cfg.iters, warm: cfg.warm) { v.decode(sb) != nil }
                note(t, "VideoToolbox 1 thread")
                for (k, val) in t.json("ms_1_thread") { vt[k] = val }
                // 4 threads, each with its own session and sample buffer; fail soft if a session cannot be made
                var x4: [(VTHardwareJPEGDecoder, CMSampleBuffer)] = []
                var s4: OSStatus = 0
                for _ in 0..<4 {
                    guard let d = VTHardwareJPEGDecoder(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA, requireHW: true, status: &s4),
                          let s = d.sample(f.data) else { break }
                    d.decode(s); x4.append((d, s))
                }
                if x4.count == 4 {
                    let rt = pbRate(states: x4, seconds: cfg.rateSeconds, job: { p in p.0.decode(p.1) != nil })
                    noteRate(rt, "VideoToolbox x4")
                    vt["four_threads"] = rt.json()
                    print("  VideoToolbox hw decode (BGRA): \(t.text) ms (1 thread); 4 threads \(rt.text) images/s (\(fmt(rt.latencyMs)) ms per call)")
                } else {
                    vt["four_threads"] = ["available": false, "status": Int(s4), "sessions_made": x4.count]
                    invalidCases.append("\(label) VideoToolbox x4: only \(x4.count) sessions (status \(s4))")
                    print("  VideoToolbox hw decode (BGRA): \(t.text) ms (1 thread); 4 threads unavailable (status \(s4))")
                }
                print("    BGRA vs libjpeg-turbo (includes VideoToolbox's YCbCr to RGB conversion): \(identityText(vt)); attachments \(colourAttachments(pb))")
            } else {
                vt["available"] = false; vt["status"] = Int(st); vt["failed_at"] = stage
                print("  VideoToolbox hw decode (BGRA): unavailable (\(stage) failed, status \(st))")
            }
            // Y-plane control
            var yc: [String: Any] = ["require_hardware": true]
            let pfY = biPlanarFormat(samp.name)
            let refYDec = pfY == nil ? nil : Turbo.decode(f.data, gray: true)
            if let pf = pfY, let refY = refYDec, !refY.warned {
                yc["pixel_format"] = fourCC(pf)
                var sy: OSStatus = 0, ystage = "session"
                let v1 = VTHardwareJPEGDecoder(width: w, height: h, pixelFormat: pf, requireHW: true, status: &sy)
                let sb1 = v1?.sample(f.data)
                if v1 != nil { ystage = sb1 == nil ? "sample buffer" : "decode" }
                let pb1 = sb1.flatMap { v1!.decode($0) }
                if pb1 == nil, let v1, sb1 != nil { sy = v1.lastStatus }
                if v1 != nil, sb1 != nil, let pb = pb1 {
                    yc["available"] = true
                    yc["attachments"] = colourAttachments(pb)
                    // plane 0 geometry: VideoToolbox's 444f output on odd-width images was intermittently wrong
                    let pw = CVPixelBufferGetWidthOfPlane(pb, 0), ph = CVPixelBufferGetHeightOfPlane(pb, 0), pbr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                    let geomOK = pw == w && ph == h && pbr >= w
                    yc["plane0"] = ["width": pw, "height": ph, "bytes_per_row": pbr, "matches_image": geomOK]
                    if !geomOK { print("    Y plane geometry \(pw)x\(ph), stride \(pbr): does not match the image \(w)x\(h)") }
                    if geomOK { for (k, val) in lumaPlane(pb).withUnsafeBytes({ identity($0, refY.px) }) { yc[k] = val } }
                    else { yc["error"] = "plane 0 is \(pw)x\(ph) stride \(pbr), image \(w)x\(h)" }
                    print("    YCbCr \(fourCC(pf)) Y plane vs libjpeg-turbo's Y: \(identityText(yc)); attachments \(colourAttachments(pb))")
                } else {
                    yc["available"] = false; yc["status"] = Int(sy); yc["failed_at"] = ystage
                    print("    YCbCr \(fourCC(pf)) control: unavailable (\(ystage) failed, status \(sy))")
                }
            } else {
                yc["available"] = false
                yc["reason"] = pfY == nil ? "no bi-planar format for \(samp.name)"
                             : refYDec == nil ? "libjpeg-turbo Y-plane reference decode failed" : "libjpeg-turbo warned on the Y-plane reference decode"
            }
            vt["y_plane_control"] = yc
            r["videotoolbox"] = vt
        }

        // encode: Metal vs libjpeg-turbo, q95, the file's subsampling, from libjpeg-turbo's pixels
        do {
            var e: [String: Any] = ["quality": 95, "subsampling": samp.name]
            if gray {
                // the reference for a gray file is a 1-channel encode of the gray decode; the Metal Encoder is not run
                e["skipped"] = "grayscale"
                if let g = Turbo.decode(f.data, gray: true) {
                    let tt = pbTimes(cfg.iters, warm: cfg.warm) { !Turbo.encode(g.px, w, h, gray: true, quality: 95, samp: 0).isEmpty }
                    for (k, v) in tt.json("turbo_ms_1_thread") { e[k] = v }
                }
            } else if let ts = samp.turbo {
                let want = Turbo.encode(ref.px, w, h, quality: 95, samp: ts)
                if let ms = samp.metal {
                    let buf = sharedBuffer(ref.px, enc.ctx.device)
                    do {
                        let got = try enc.encode(buffer: buf, width: w, height: h, quality: 95, subsampling: ms)
                        let same = got == want
                        if !same { encodeBad += 1 }
                        let t = pbTimes(cfg.iters, warm: cfg.warm) { (try? enc.encode(buffer: buf, width: w, height: h, quality: 95, subsampling: ms)) != nil }
                        note(t, "Metal encode")
                        e["identical"] = same; e["bytes"] = got.count; e["turbo_bytes"] = want.count
                        for (k, v) in t.json("metal_ms") { e[k] = v }
                        print("  encode q95 \(samp.name): Metal \(t.text) ms, \(same ? "byte-identical" : "DIFFERENT") to libjpeg-turbo")
                    } catch {
                        e["identical"] = false; e["error"] = "\(error)"; encodeBad += 1
                        print("  encode q95 \(samp.name): Metal FAILED: \(error)")
                    }
                } else {
                    e["skipped"] = "sampling \(samp.name) not supported by the Encoder"
                    print("  encode: Metal skipped (\(samp.name) not supported by the Encoder)")
                }
                let tt = pbTimes(cfg.iters, warm: cfg.warm) { !Turbo.encode(ref.px, w, h, quality: 95, samp: ts).isEmpty }
                note(tt, "libjpeg-turbo encode")
                for (k, v) in tt.json("turbo_ms_1_thread") { e[k] = v }
                print("    libjpeg-turbo encode: \(tt.text) ms (1 thread)")
            } else {
                e["skipped"] = "sampling \(samp.name) has no encoder setting"
                print("  encode: skipped (sampling \(samp.name))")
            }
            r["encode"] = e
        }
        records.append(r)
    }
    cond["load_average_end"] = Bench.shell("sysctl -n vm.loadavg | tr -d '{}' | xargs")
    cond["corpus"] = dirs.map { d in "\(lbl(d)) (\(files.filter { $0.dir == d }.count) files; SHA-256 list: \(sources[d] ?? "none"))" }.joined(separator: "; ")
    cond["directories"] = dirs.map(lbl)
    cond["gpu_warmup"] = "\(cfg.warm) s of the same work before each timed case, then \(cfg.iters) timed calls, median; no discarded iterations"
    cond["cpu_timing"] = "libjpeg-turbo, ImageIO and VideoToolbox 1-thread cases: the same rule, calling thread at user-interactive QoS"
    cond["clock"] = "clock_gettime_nsec_np(CLOCK_UPTIME_RAW); failed calls are counted, not timed, and make a case invalid"
    cond["throughput_seconds"] = cfg.rateSeconds
    cond["throughput_threads"] = ["libjpeg-turbo": cores, "metal": 2, "videotoolbox": 4]
    cond["iters"] = cfg.iters
    cond["quick"] = cfg.quick
    cond["reference_decode"] = "TurboRef tr_decode: libjpeg-turbo's libjpeg API, JDCT_ISLOW, do_fancy_upsampling TRUE, JCS_RGB (as the corpus test); Y plane: the same with JCS_GRAYSCALE"
    cond["reference_encode"] = "TurboRef tr_encode: libjpeg API, quality 95, the file's sampling factors, JDCT_ISLOW, standard Huffman tables"

    // summaries and tables, per directory and in total
    func sub(_ r: [String: Any], _ a: String) -> [String: Any] { r[a] as? [String: Any] ?? [:] }
    func dbl(_ r: [String: Any], _ a: String, _ b: String) -> Double? { sub(r, a)[b] as? Double }
    func fileName(_ r: [String: Any]) -> String {
        let sd = r["subsampling_dir"] as? String ?? ""
        return (sd.isEmpty ? "" : sd + "/") + (r["name"] as? String ?? "?")
    }
    // String(format:) ignores field widths for %@, so the columns are padded here; negative width: left-aligned
    func row(_ cells: [(String, Int)]) -> String {
        cells.map { c, w in
            let n = abs(w)
            return c.count >= n ? c : (w < 0 ? c + String(repeating: " ", count: n - c.count) : String(repeating: " ", count: n - c.count) + c)
        }.joined(separator: " ")
    }
    func summarize(_ recs: [[String: Any]], title: String, table: Bool) -> [String: Any] {
        let published = recs.filter { $0["published_by_libjpeg_turbo"] as? Bool == true }.map { r -> [String: Any] in
            ["file": fileName(r), "metal_wall_ms": dbl(r, "metal_decode", "wall_ms") ?? NSNull(),
             "metal_gpu_ms": dbl(r, "metal_decode", "gpu_ms") ?? NSNull(), "turbo_ms_1_thread": dbl(r, "turbo_decode", "ms_1_thread") ?? NSNull(),
             "metal_identical": sub(r, "metal_decode")["identical"] ?? (sub(r, "metal_decode")["declined"].map { "declined: \($0)" } ?? NSNull()), "passes": sub(r, "metal_decode")["passes"] ?? NSNull()]
        }
        // least squares: Metal wall (and GPU) ms against MB of coded data, valid cases only
        func fit(_ key: String) -> [String: Any] {
            let pts = recs.compactMap { r -> (Double, Double)? in
                guard let y = dbl(r, "metal_decode", key), let b = r["bytes"] as? Int else { return nil }
                return (Double(b) / 1e6, y)
            }
            guard pts.count >= 2 else { return ["n": pts.count] }
            let n = Double(pts.count), sx = pts.reduce(0) { $0 + $1.0 }, sy = pts.reduce(0) { $0 + $1.1 }
            let sxx = pts.reduce(0) { $0 + $1.0 * $1.0 }, sxy = pts.reduce(0) { $0 + $1.0 * $1.1 }
            let slope = (n * sxy - sx * sy) / (n * sxx - sx * sx), icept = (sy - slope * sx) / n
            let my = sy / n
            let ssr = pts.reduce(0) { $0 + pow($1.1 - (icept + slope * $1.0), 2) }, sst = pts.reduce(0) { $0 + pow($1.1 - my, 2) }
            return ["n": pts.count, "ms_per_mb": jnum(slope), "intercept_ms": jnum(icept), "r2": jnum(sst > 0 ? 1 - ssr / sst : .nan, 1e4)]
        }
        // identity totals: files compared, identical, errors (no pixels, size mismatch: not counted as non-identical)
        func totals(_ get: ([String: Any]) -> [String: Any]?, sampling: String? = nil) -> [String: Any] {
            let rs = recs.filter { sampling == nil || $0["subsampling"] as? String == sampling }.compactMap(get)
                .filter { $0["skipped"] == nil && $0["declined_by_design"] as? Bool != true && $0["available"] as? Bool != false && ($0["identical"] != nil || $0["error"] != nil) }
            let errs = rs.filter { $0["error"] != nil }, ok = rs.filter { $0["error"] == nil }
            let ident = ok.filter { $0["identical"] as? Bool == true }.count
            let ps = ok.compactMap { $0["psnr_db"] as? Double }
            return ["files": ok.count, "identical": ident, "errors": errs.count, "max_diff": ok.compactMap { $0["max_diff"] as? Int }.max() ?? 0,
                    "psnr_min_db": ps.min() ?? NSNull(), "psnr_max_db": ps.max() ?? NSNull(),
                    "note": "psnr over non-identical files only (identical files have infinite PSNR); errors and declines are excluded from files"]
        }
        let vtBGRA: ([String: Any]) -> [String: Any]? = { $0["videotoolbox"] as? [String: Any] }
        let vtY: ([String: Any]) -> [String: Any]? = { ($0["videotoolbox"] as? [String: Any])?["y_plane_control"] as? [String: Any] }
        var idt: [String: Any] = [
            "metal_decode": totals({ $0["metal_decode"] as? [String: Any] }), "metal_encode": totals({ $0["encode"] as? [String: Any] }),
            "imageio_hardware_key": totals({ $0["imageio"] as? [String: Any] }), "imageio_software_key": totals({ $0["imageio_sw"] as? [String: Any] }),
            "videotoolbox_bgra_includes_vt_colour_conversion": totals(vtBGRA), "videotoolbox_y_plane": totals(vtY),
        ]
        for sm in Set(recs.compactMap { $0["subsampling"] as? String }).sorted() {
            idt["videotoolbox_bgra_includes_vt_colour_conversion \(sm)"] = totals(vtBGRA, sampling: sm)
            idt["videotoolbox_y_plane \(sm)"] = totals(vtY, sampling: sm)
        }
        let declinedProg = recs.filter { sub($0, "metal_decode")["declined_by_design"] as? Bool == true }.count
        let summary: [String: Any] = ["files": recs.count, "metal_declined_by_design": declinedProg,
                                      "libjpeg_turbo_published": published, "metal_decode_fit_wall": fit("wall_ms"), "metal_decode_fit_gpu": fit("gpu_ms"),
                                      "identity": idt]

        print("\n== \(title)\(cfg.quick ? " (QUICK: smoke test, not results)" : ""): \(recs.count) files")
        if table && !recs.isEmpty {
            print("IIO: ImageIO, hardware key true; IIOsw: key false. VT: VideoToolbox hardware, BGRA (identity includes VT's YCbCr to RGB conversion); VT Y: Y plane of the bi-planar YCbCr control. inv: invalid (a call failed); prog / arith: declined by design (progressive / arithmetic-coded)")
            let widths = [-36, 10, 6, 6, 6, -5, -6, 8, 8, 3, 8, 8, 8, 7, 8, -7, 8, -7, 8, 8, -7, -7, 7, -4, 8]
            let head = row(zip(["file", "WxH", "MP", "KB", "B/px", "samp", "exact", "Metal ms", "GPU ms", "ps", "x2 img/s", "turbo ms", "all/s", "speedup",
                                "IIO ms", "IIO id", "IIOsw ms", "IIOsw id", "VT ms", "VTx4/s", "VT id", "VT Y id", "enc ms", "enc", "tenc ms"], widths).map { ($0, $1) })
            print(head); print(String(repeating: "-", count: head.count))
            for r in recs {
                let m = sub(r, "metal_decode"), t = sub(r, "turbo_decode"), io = sub(r, "imageio"), iosw = sub(r, "imageio_sw")
                let vt = sub(r, "videotoolbox"), e = sub(r, "encode")
                let yc = vt["y_plane_control"] as? [String: Any] ?? [:]
                func s(_ x: Any?) -> String { x.map { $0 is NSNull ? "inv" : "\($0)" } ?? "-" }
                func yn(_ x: Any?) -> String { (x as? Bool).map { $0 ? "yes" : "NO" } ?? "-" }
                func idc(_ d: [String: Any]) -> String {
                    if d.isEmpty { return "-" }
                    if d["available"] as? Bool == false { return "n/a" }
                    if d["error"] != nil { return "ERROR" }
                    return d["identical"] as? Bool == true ? "yes" : "max \(s(d["max_diff"]))"
                }
                let dk = m["declined"] as? String ?? ""
                let exact = m["declined_by_design"] as? Bool == true ? (dk.contains("arithmetic") ? "arith" : "prog") : m["declined"] != nil ? "DECL" : yn(m["identical"])
                let sp = (t["ms_1_thread"] as? Double).flatMap { a in (m["wall_ms"] as? Double).map { fmt(a / $0, 2) + "x" } } ?? "-"
                let x2 = (m["throughput_2_decoders"] as? [String: Any])?["ips"], all = (t["all_cores"] as? [String: Any])?["ips"]
                let vt4 = (vt["four_threads"] as? [String: Any])?["ips"]
                let cells = [(fileName(r)), "\(s(r["width"]))x\(s(r["height"]))", s(r["mp"]),
                             "\((r["bytes"] as? Int ?? 0) / 1024)", s(r["bytes_per_pixel"]), s(r["subsampling"]), exact, s(m["wall_ms"]), s(m["gpu_ms"]), s(m["passes"]),
                             s(x2), s(t["ms_1_thread"]), s(all), sp, s(io["ms_1_thread"]), idc(io), s(iosw["ms_1_thread"]), idc(iosw),
                             s(vt["ms_1_thread"]), s(vt4), idc(vt), idc(yc), s(e["metal_ms"]), e["skipped"] != nil ? "skip" : yn(e["identical"]),
                             s(e["turbo_ms_1_thread"])]
                print(row(zip(cells, widths).map { ($0, $1) }))
            }
        }
        if !published.isEmpty {
            print("libjpeg-turbo-published images:")
            for p in published.sorted(by: { "\($0["file"]!)" < "\($1["file"]!)" }) {
                print("  \(p["file"]!): Metal \(p["metal_wall_ms"]!) ms (GPU \(p["metal_gpu_ms"]!)), libjpeg-turbo \(p["turbo_ms_1_thread"]!) ms, sync passes \(p["passes"]!), identical \(p["metal_identical"]!)")
            }
        }
        for (k, label) in [("metal_decode_fit_wall", "wall"), ("metal_decode_fit_gpu", "GPU")] {
            let f = summary[k] as! [String: Any]
            print("Metal decode \(label) ms = \(f["intercept_ms"] ?? "?") + \(f["ms_per_mb"] ?? "?") x MB coded (n \(f["n"]!), R^2 \(f["r2"] ?? "?"))")
        }
        for (k, v) in idt.sorted(by: { $0.key < $1.key }) {
            let v = v as! [String: Any]
            let ps = v["psnr_min_db"] is NSNull ? "n/a (none differ)" : "\(v["psnr_min_db"]!)...\(v["psnr_max_db"]!) dB over the files that differ"
            print("identity \(k): \(v["identical"]!)/\(v["files"]!) identical, \(v["errors"]!) errors, max diff \(v["max_diff"]!), PSNR \(ps)")
        }
        if declinedProg > 0 { print("Metal declined by design (progressive or arithmetic): \(declinedProg)") }
        return summary
    }
    var perDir: [String: Any] = [:]
    for d in dirs.map(lbl) { perDir[d] = summarize(records.filter { $0["dir"] as? String == d }, title: "public-bench \(d)", table: true) }
    // the total: printed only for several directories (for one it repeats the directory's summary)
    var summary = dirs.count > 1 ? summarize(records, title: "public-bench, all \(dirs.count) directories", table: false)
                                 : perDir[lbl(dirs[0])] as! [String: Any]
    summary["per_directory"] = perDir
    summary["skipped"] = skipped
    summary["invalid_cases"] = invalidCases
    // VideoToolbox Y-plane outliers: max diff above 1 (elsewhere it is IDCT rounding, max 1)
    let outliers = records.compactMap { r -> [String: Any]? in
        guard let y = (r["videotoolbox"] as? [String: Any])?["y_plane_control"] as? [String: Any] else { return nil }
        let md = y["max_diff"] as? Int ?? 0
        guard md > 1 || y["error"] != nil else { return nil }
        return ["file": "\(r["dir"] as? String ?? "")/\(fileName(r))", "width": r["width"] ?? NSNull(), "height": r["height"] ?? NSNull(),
                "subsampling": r["subsampling"] ?? NSNull(), "pixel_format": y["pixel_format"] ?? NSNull(), "max_diff": md,
                "differing_bytes": y["differing_bytes"] ?? NSNull(), "frac_differ": y["frac_differ"] ?? NSNull(),
                "plane0": y["plane0"] ?? NSNull(), "error": y["error"] ?? NSNull()]
    }
    summary["videotoolbox_y_plane_outliers"] = outliers
    print("\nVideoToolbox Y-plane outliers (max diff above 1):" + (outliers.isEmpty ? " none" : ""))
    for o in outliers {
        print("  \(o["file"]!) \(o["width"]!)x\(o["height"]!) \(o["subsampling"]!) \(o["pixel_format"]!): max \(o["max_diff"]!), \(o["differing_bytes"]!) values (\(String(format: "%.4g", ((o["frac_differ"] as? Double) ?? 0) * 100))%) differ; plane 0 \(o["plane0"]!)")
    }
    print("\nload \(cond["load_average"] ?? "?") -> \(cond["load_average_end"] ?? "?")")
    print("invalid cases (a call failed): \(invalidCases.isEmpty ? "none" : invalidCases.joined(separator: "; "))")
    print("skipped files: \(skipped.isEmpty ? "none" : skipped.map { "\($0["file"]!) (\($0["reason"]!))" }.joined(separator: ", "))")
    let nonProg = records.filter { ($0["metal_decode"] as? [String: Any])?["declined_by_design"] as? Bool != true }.count
    let encTried = records.filter { ($0["encode"] as? [String: Any])?["identical"] != nil }.count
    print("Metal exactness: decode \(nonProg - decodeBad)/\(nonProg) byte-identical (\(records.count - nonProg) declined by design: progressive or arithmetic), encode \(encTried - encodeBad)/\(encTried) byte-identical (\(records.count - encTried) skipped)")

    // JSON: on any error, print it and dump the results to stdout so they are not lost
    let chip = (cond["chip"] as? String ?? "?").replacingOccurrences(of: "Apple ", with: "").lowercased().replacingOccurrences(of: " ", with: "")
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = .current; stamp.dateFormat = "yyyy-MM-dd-HHmm"
    let path = out ?? "results/public/\(chip)-gpu\(cond["gpu_cores"] ?? 0)-\(stamp.string(from: Date())).json"
    let doc: [String: Any] = ["conditions": cond, "records": records, "summary": summary]
    var js: Data? = nil
    do {
        js = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        try js!.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(records.count) records)")
    } catch {
        print("could not write \(path): \(error)\nthe results follow on stdout:")
        if let js, let s = String(data: js, encoding: .utf8) { print(s) } else { print(doc) }
    }
    if decodeBad > 0 || encodeBad > 0 { return 1 }
    return skipped.isEmpty ? 0 : 2
}
