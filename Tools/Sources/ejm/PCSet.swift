import Foundation
import ExactJPEG
import TurboRef
import ImageIO
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import CryptoKit

// ejm pc-set <pc-set dir> [--out <path>] [--quick]
// The sister PC library's public-set benchmark (its bench/public_set.py) on this Mac, so that the two result files
// compare row for row. <pc-set dir> holds imagecompression_info/*.ppm (14), libjpeg_turbo_3dtest/*.ppm (3) and
// jpegs/<image>__<setting>.jpg (102, made by Pillow 13.0.0 with libjpeg-turbo 3.2.0) with jpegs/SHA256SUMS. Every
// JPEG is checked against SHA256SUMS (a mismatch or a missing file is reported and skipped, exit 2). Per JPEG: the
// Metal decode against libjpeg-turbo (TurboRef islow, fancy upsampling, RGB), decodeAndPack then decode(packed:),
// the Metal encode of the source PPM against the Pillow file (four settings), ImageIO and VideoToolbox against the
// same reference, and the median ms of every decoder. Exit 1 if a Metal decode, packed decode or encode that should
// be identical is not (an encode counts as failed when it differs from libjpeg-turbo's own encode of the same
// pixels; a difference from Pillow's file alone is reported and investigated, not failed).

private struct PCSetting {
    let name: String, quality: Int, sub: Subsampling?, turboSamp: Int?, encode: Bool, pillow: String
}

private let pcSettings: [PCSetting] = [
    PCSetting(name: "q95_420", quality: 95, sub: .s420, turboSamp: 2, encode: true, pillow: "quality=95, subsampling=2 (4:2:0)"),
    PCSetting(name: "q95_422", quality: 95, sub: .s422, turboSamp: 1, encode: true, pillow: "quality=95, subsampling=1 (4:2:2)"),
    PCSetting(name: "q95_444", quality: 95, sub: .s444, turboSamp: 0, encode: true, pillow: "quality=95, subsampling=0 (4:4:4)"),
    PCSetting(name: "q95_gray", quality: 95, sub: nil, turboSamp: nil, encode: false, pillow: "converted to L, quality=95, no subsampling argument"),
    PCSetting(name: "q90_420", quality: 90, sub: .s420, turboSamp: 2, encode: true, pillow: "quality=90, subsampling=2 (4:2:0)"),
    PCSetting(name: "q95_420_opt", quality: 95, sub: .s420, turboSamp: 2, encode: false, pillow: "quality=95, subsampling=2 (4:2:0), optimize=True"),
]

/// subsampling groups of the per-decoder least-squares fit
private let pcGroups: [(name: String, settings: Set<String>)] = [
    ("4:2:0", ["q95_420", "q90_420", "q95_420_opt"]), ("4:2:2", ["q95_422"]), ("4:4:4", ["q95_444"]),
]

private let pcDecoders = ["this library", "libjpeg-turbo, one thread", "Apple ImageIO", "VideoToolbox (Apple hardware JPEG)"]
/// an optional as a JSON value (nil: null)
private func orNull(_ x: Any?) -> Any { x ?? NSNull() }

private let pcOthers = ["Apple ImageIO", "VideoToolbox (Apple hardware JPEG)"]

/// A binary PPM (P6, maxval 255) as RGB
private func readPPM(_ d: Data) -> (rgb: [UInt8], w: Int, h: Int)? {
    let p = [UInt8](d)
    var i = 0
    func token() -> Int? {
        while i < p.count {
            if p[i] == UInt8(ascii: "#") { while i < p.count && p[i] != 10 && p[i] != 13 { i += 1 } }
            else if p[i] == 32 || (9...13).contains(p[i]) { i += 1 }
            else { break }
        }
        var v = 0, n = 0
        while i < p.count, (48...57).contains(p[i]) { v = v * 10 + Int(p[i] - 48); i += 1; n += 1 }
        return n > 0 ? v : nil
    }
    guard p.count > 2, p[0] == UInt8(ascii: "P"), p[1] == UInt8(ascii: "6") else { return nil }
    i = 2
    guard let w = token(), let h = token(), let mx = token(), mx == 255, w > 0, h > 0, i < p.count else { return nil }
    i += 1                                   // the single whitespace byte after maxval
    guard p.count - i >= w * h * 3 else { return nil }
    return (Array(p[i..<(i + w * h * 3)]), w, h)
}

/// a CGImage's pixels as RGB; 8-bit gray (a gray JPEG) is expanded to R = G = B, as libjpeg-turbo's JCS_RGB output
private func pcImageRGB(_ img: CGImage) -> [UInt8]? {
    if let cs = img.colorSpace, cs.model == .monochrome, img.bitsPerComponent == 8, img.bitsPerPixel == 8,
       let data = img.dataProvider?.data {
        let w = img.width, h = img.height, bpr = img.bytesPerRow, q = CFDataGetBytePtr(data)!
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { let v = q[y * bpr + x], k = 3 * (y * w + x); rgb[k] = v; rgb[k + 1] = v; rgb[k + 2] = v } }
        return rgb
    }
    return cgImageRawRGB(img)
}

/// the PC's identity record of `a` against `ref` (both RGB): {"same": true} or max diff, the share of pixels with
/// any channel differing (5 dp) and PSNR over all values (2 dp)
private func pcIdentity(_ a: UnsafeRawBufferPointer, _ ref: [UInt8]) -> [String: Any] {
    guard a.count == ref.count else { return ["error": "size \(a.count) bytes, reference \(ref.count)"] }
    var maxd = 0, se = 0.0, pxDiff = 0
    ref.withUnsafeBufferPointer { r in
        let n = r.count / 3
        for p in 0..<n {
            let d0 = abs(Int(a[3 * p]) - Int(r[3 * p])), d1 = abs(Int(a[3 * p + 1]) - Int(r[3 * p + 1])), d2 = abs(Int(a[3 * p + 2]) - Int(r[3 * p + 2]))
            if d0 | d1 | d2 != 0 {
                pxDiff += 1
                maxd = max(maxd, d0, d1, d2)
                se += Double(d0 * d0 + d1 * d1 + d2 * d2)
            }
        }
    }
    if pxDiff == 0 { return ["same": true] }
    let psnr = 10 * log10(255.0 * 255.0 / (se / Double(ref.count)))
    return ["same": false, "max_diff": maxd, "pixels_differ": jnum(Double(pxDiff) / Double(ref.count / 3), 1e5), "psnr": jnum(psnr, 100)]
}

/// `warm` seconds and at least `minWarm` calls back to back, then `iters` calls, each waited for; median ms, nil if
/// any call failed
private func pcTime(iters: Int, warm: Double, minWarm: Int = 2, _ work: () -> Bool) -> (ms: Double?, failures: Int) {
    var fails = 0, n = 0
    let t0 = mono()
    while n < minWarm || mono() - t0 < warm { if !work() { fails += 1 }; n += 1; if fails > 3 { break } }
    var ts: [Double] = []
    for _ in 0..<iters {
        let a = mono(); let ok = work(); let d = mono() - a
        if ok { ts.append(d) } else { fails += 1 }
    }
    return (fails == 0 && !ts.isEmpty ? median(ts) * 1000 : nil, fails)
}

/// the marker segments of a JPEG up to its first SOS, as (name, start, end) byte ranges
private func pcSegments(_ d: [UInt8]) -> [(String, Int, Int)] {
    var out: [(String, Int, Int)] = [("SOI", 0, 2)]
    var i = 2
    while i + 3 < d.count, d[i] == 0xFF {
        let m = d[i + 1]
        let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
        var name: String
        switch m {
        case 0xE0...0xEF: name = "APP\(m - 0xE0)"
        case 0xDB: name = "DQT"
        case 0xC4: name = "DHT"
        case 0xC0: name = "SOF0"
        case 0xC1: name = "SOF1"
        case 0xDD: name = "DRI"
        case 0xFE: name = "COM"
        case 0xDA: name = "SOS"
        default: name = "marker 0x\(String(m, radix: 16))"
        }
        if m == 0xE0, len >= 7, i + 9 <= d.count, String(bytes: d[(i + 4)..<(i + 8)], encoding: .ascii) == "JFIF" { name = "APP0 (JFIF)" }
        out.append((name, i, i + 2 + len))
        if m == 0xDA { out.append(("entropy-coded data", i + 2 + len, d.count)); break }
        i += 2 + len
    }
    return out
}

/// where two files first differ: offset, both lengths, the segment holding the offset in each, and the bytes there
private func pcFirstDiff(_ a: Data, _ b: Data) -> [String: Any] {
    let x = [UInt8](a), y = [UInt8](b)
    var k = 0
    while k < x.count && k < y.count && x[k] == y[k] { k += 1 }
    func seg(_ s: [(String, Int, Int)]) -> String { s.first { k >= $0.1 && k < $0.2 }?.0 ?? "past the end" }
    func hex(_ p: [UInt8]) -> String { p[min(k, p.count)..<min(k + 16, p.count)].map { String(format: "%02x", $0) }.joined(separator: " ") }
    return ["first_differing_offset": k, "metal_bytes": x.count, "pillow_bytes": y.count,
            "metal_segment": seg(pcSegments(x)), "pillow_segment": seg(pcSegments(y)),
            "metal_bytes_at_offset": hex(x), "pillow_bytes_at_offset": hex(y)]
}

/// ms = a + b*MP + c*codedMB by least squares, with the standard errors of a, b, c (nil below 4 points or singular)
private func pcFit(_ pts: [(mp: Double, mb: Double, ms: Double)]) -> [String: Any] {
    let n = pts.count
    guard n >= 4 else { return ["n": n] }
    var A = [[Double]](repeating: [0, 0, 0], count: 3), r = [0.0, 0, 0]
    for p in pts {
        let x = [1, p.mp, p.mb]
        for i in 0..<3 { r[i] += x[i] * p.ms; for j in 0..<3 { A[i][j] += x[i] * x[j] } }
    }
    // inverse of the 3x3 normal matrix
    let a = A
    let det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
    guard abs(det) > 1e-12 else { return ["n": n, "error": "singular"] }
    var inv = [[Double]](repeating: [0, 0, 0], count: 3)
    for i in 0..<3 { for j in 0..<3 {
        let r0 = [0, 1, 2].filter { $0 != j }, c0 = [0, 1, 2].filter { $0 != i }
        let m = a[r0[0]][c0[0]] * a[r0[1]][c0[1]] - a[r0[0]][c0[1]] * a[r0[1]][c0[0]]
        inv[i][j] = ((i + j) % 2 == 0 ? m : -m) / det
    } }
    let beta = (0..<3).map { i in (0..<3).reduce(0.0) { $0 + inv[i][$1] * r[$1] } }
    let ssr = pts.reduce(0.0) { $0 + pow($1.ms - (beta[0] + beta[1] * $1.mp + beta[2] * $1.mb), 2) }
    let s2 = ssr / Double(n - 3)
    let se = (0..<3).map { sqrt(max(inv[$0][$0] * s2, 0)) }
    return ["n": n, "a_ms": jnum(beta[0]), "b_ms_per_mp": jnum(beta[1]), "c_ms_per_coded_mb": jnum(beta[2]),
            "se_a": jnum(se[0]), "se_b": jnum(se[1]), "se_c": jnum(se[2])]
}

func runPCSet(_ argv: [String]) -> Int32 {
    var quick = false, out: String? = nil, pos: [String] = []
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--quick": quick = true
        case "--out": i += 1; guard i < argv.count else { print("--out needs a path"); return 2 }; out = argv[i]
        case let a where a.hasPrefix("--"): print("unknown flag \(a)"); return 2
        default: pos.append(argv[i])
        }
        i += 1
    }
    guard pos.count == 1 else { print("usage: ejm pc-set <pc-set dir> [--out <path>] [--quick]"); return 2 }
    let root = URL(fileURLWithPath: pos[0]).standardizedFileURL.path
    let rootLabel = (root as NSString).lastPathComponent
    let iters = quick ? 3 : 9, warm = quick ? 0.1 : 0.3
    let fm = FileManager.default

    // sources: rgb8bit first, then the 3 vgl frames, each sorted by name
    var sources: [(name: String, dir: String, path: String)] = []
    for sub in ["imagecompression_info", "libjpeg_turbo_3dtest"] {
        let names = ((try? fm.contentsOfDirectory(atPath: root + "/" + sub)) ?? []).filter { $0.hasSuffix(".ppm") }.sorted()
        for n in names { sources.append(((n as NSString).deletingPathExtension, sub, root + "/" + sub + "/" + n)) }
    }
    guard !sources.isEmpty else { print("no .ppm files under \(rootLabel)/imagecompression_info or \(rootLabel)/libjpeg_turbo_3dtest"); return 2 }
    guard let sums = try? String(contentsOfFile: root + "/jpegs/SHA256SUMS", encoding: .utf8) else { print("no jpegs/SHA256SUMS in \(rootLabel)"); return 2 }
    var expected: [String: String] = [:]
    for line in sums.split(whereSeparator: \.isNewline) {
        let p = line.split(separator: " ", maxSplits: 1)
        guard p.count == 2 else { continue }
        var name = p[1].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("*") { name.removeFirst() }
        expected[name] = String(p[0]).lowercased()
    }

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    benchProfile()
    let cond = Bench.conditions()
    func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown"
        }
    }
    let loadStart = cond["load_average"] as? String ?? "?", thermalStart = thermal()
    print("pc-set \(rootLabel): reference \(Turbo.version); \(quick ? "QUICK (smoke test, not results): " : "")\(iters) timed calls after \(warm) s; load \(loadStart), thermal \(thermalStart)")

    let dec = Decoder(), pdec = Decoder(), enc = Encoder()
    var rows: [[String: Any]] = [], skipped: [[String: Any]] = [], fileList: [[String: Any]] = []
    var bad: [String] = []
    for src in sources {
        var ppm: (rgb: [UInt8], w: Int, h: Int)? = nil
        var ppmError: String? = nil
        var ppmSkipped = false               // an unusable PPM is listed in `skipped` once per image
        if pcSettings.contains(where: \.encode) {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: src.path)) { ppm = readPPM(d); if ppm == nil { ppmError = "not an 8-bit binary PPM" } }
            else { ppmError = "unreadable" }
        }
        for s in pcSettings {
            let fname = "\(src.name)__\(s.name).jpg"
            let path = root + "/jpegs/" + fname
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                print("\(fname): MISSING; skipped"); skipped.append(["file": fname, "reason": "missing"]); continue
            }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let want = expected[fname] else {
                print("\(fname): not in SHA256SUMS; skipped"); skipped.append(["file": fname, "reason": "not in SHA256SUMS"]); continue
            }
            guard want == sha else {
                print("\(fname): SHA-256 MISMATCH (\(sha), expected \(want)); skipped")
                skipped.append(["file": fname, "reason": "sha256 mismatch", "sha256": sha, "expected": want]); continue
            }
            fileList.append(["file": fname, "sha256": sha, "bytes": data.count, "source": "\(src.dir)/\(src.name).ppm"])
            guard let ref = Turbo.decode(data), !ref.warned else {
                print("\(fname): libjpeg-turbo cannot decode it cleanly; skipped"); skipped.append(["file": fname, "reason": "libjpeg-turbo decode error or warning"]); continue
            }
            let w = ref.w, h = ref.h, px = w * h
            let hdr = data.withUnsafeBytes { try? parseJPEGHeader($0) }
            var r: [String: Any] = ["image": src.name, "setting": s.name, "megapixels": jnum(Double(px) / 1e6, 100)]
            let codedBytes = hdr.map { data.count - $0.scanStart - 2 }
            r["bytes_per_pixel"] = codedBytes.map { jnum(Double($0) / Double(px), 1e4) } ?? NSNull()
            if let hd = hdr {
                // coded 8x8 blocks: whole MCUs for an interleaved frame, the component's own blocks for one component
                if hd.ncomp == 1 { r["blocks"] = ((w + 7) / 8) * ((h + 7) / 8) }
                else {
                    let mx = (w + 8 * hd.hmax - 1) / (8 * hd.hmax), my = (h + 8 * hd.vmax - 1) / (8 * hd.vmax)
                    r["blocks"] = mx * my * hd.samp.reduce(0) { $0 + $1.h * $1.v }
                }
            } else { r["blocks"] = NSNull() }

            // Metal decode
            let decline = data.withUnsafeBytes { dec.declineReason(bytes: $0) }
            r["route"] = decline.map { "declined: \($0)" } ?? "gpu"
            var line = "\(fname): \(fmt(Double(px) / 1e6, 1)) MP"
            if let img = dec.decode(data) {
                let same = ref.px.withUnsafeBytes { $0.elementsEqual(img.bytes) }
                r["gpu_decoded"] = true; r["passes"] = dec.passes; r["same_pixels"] = same
                if !same { bad.append("\(fname) decode") }
                line += ", decode \(same ? "same" : "DIFFERENT"), passes \(dec.passes)"
            } else {
                r["gpu_decoded"] = false; r["passes"] = 0; r["same_pixels"] = false
                bad.append("\(fname) decode declined (\(dec.reason ?? "?"))")
                line += ", decode DECLINED (\(dec.reason ?? "?"))"
            }
            // packed: decodeAndPack, then decode(packed:)
            if let (_, pk) = pdec.decodeAndPack(data), let pk {
                let im = pdec.decode(packed: pk)
                let same = im.map { m in ref.px.withUnsafeBytes { $0.elementsEqual(m.bytes) } } ?? false
                r["from_packed_same"] = same
                if !same { bad.append("\(fname) packed") }
                line += ", packed \(same ? "same" : "DIFFERENT")"
            } else {
                r["from_packed_same"] = false; bad.append("\(fname) packed (no packed copy: \(pdec.reason ?? "coefficients do not fit"))")
                line += ", packed FAILED"
            }

            // encode of the source PPM at the setting, against the Pillow file
            if s.encode, let sub = s.sub, let ts = s.turboSamp {
                if let p = ppm, p.w == w, p.h == h {
                    do {
                        let got = try p.rgb.withUnsafeBytes { try enc.encode(bytes: $0, width: w, height: h, quality: s.quality, subsampling: sub) }
                        let same = got == data
                        let turbo = Turbo.encode(p.rgb, w, h, quality: s.quality, samp: ts)
                        r["encode_same_bytes"] = same
                        var ed: [String: Any] = ["same_as_libjpeg_turbo_encode": got == turbo, "libjpeg_turbo_same_as_pillow": turbo == data]
                        if !same { for (k, v) in pcFirstDiff(got, data) { ed[k] = v } }
                        r["encode_detail"] = ed
                        if got != turbo { bad.append("\(fname) encode (differs from libjpeg-turbo)") }
                        line += ", encode \(same ? "same bytes" : "differs from Pillow at \(ed["first_differing_offset"]!) (\(ed["pillow_segment"]!)); libjpeg-turbo \(got == turbo ? "same" : "DIFFERENT")")"
                    } catch {
                        r["encode_same_bytes"] = false; r["encode_detail"] = ["error": "\(error)"]
                        bad.append("\(fname) encode failed: \(error)"); line += ", encode FAILED"
                    }
                } else {
                    r["encode_same_bytes"] = NSNull()
                    r["encode_detail"] = ["error": ppmError ?? "source \(ppm.map { "\($0.w)x\($0.h)" } ?? "?") does not match \(w)x\(h)"]
                    if !ppmSkipped { skipped.append(["file": "\(src.dir)/\(src.name).ppm", "reason": ppmError ?? "size mismatch"]); ppmSkipped = true }
                    line += ", encode SKIPPED"
                }
            }

            // others: ImageIO (hardware key true) and VideoToolbox BGRA, against the reference
            var others: [String: Any] = [:]
            var lastImg: CGImage? = nil
            if let img = imageIODecodeKey(data, hardware: true) {
                lastImg = img
                others["Apple ImageIO"] = pcImageRGB(img).map { rgb in rgb.withUnsafeBytes { pcIdentity($0, ref.px) } }
                    ?? ["error": "no RGB pixels: \(img.bitsPerComponent)-bit, \(img.bitsPerPixel) bits per pixel"]
            } else { others["Apple ImageIO"] = ["error": "decode failed"] }
            var st: OSStatus = 0
            let vt = VTHardwareJPEGDecoder(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA, requireHW: true, status: &st)
            if let vt {
                if let sb = vt.sample(data), let pb = vt.decode(sb) {
                    others["VideoToolbox (Apple hardware JPEG)"] = bgraPixelBufferRGB(pb).withUnsafeBytes { pcIdentity($0, ref.px) }
                } else { others["VideoToolbox (Apple hardware JPEG)"] = ["error": "decode failed, status \(vt.lastStatus)"] }
            } else { others["VideoToolbox (Apple hardware JPEG)"] = ["error": "no hardware session, status \(st)"] }
            r["others"] = others
            _ = lastImg

            // timing, every decoder from the bytes in memory
            var ms: [String: Any] = [:]
            ms["this library"] = (r["gpu_decoded"] as? Bool == true) ? (pcTime(iters: iters, warm: warm) { dec.decode(data) != nil }.ms.map { jnum($0) } ?? NSNull()) : NSNull()
            do {
                var buf = [UInt8](repeating: 0, count: px * 3)
                ms["libjpeg-turbo, one thread"] = pcTime(iters: iters, warm: warm) { buf.withUnsafeMutableBufferPointer { Turbo.decodeInto(data, $0.baseAddress!) } == 0 }.ms.map { jnum($0) } ?? NSNull()
            }
            ms["Apple ImageIO"] = (others["Apple ImageIO"] as? [String: Any])?["error"] == nil
                ? (pcTime(iters: iters, warm: warm) { imageIODecodeKey(data, hardware: true) != nil }.ms.map { jnum($0) } ?? NSNull()) : NSNull()
            if let vt, (others["VideoToolbox (Apple hardware JPEG)"] as? [String: Any])?["error"] == nil {
                ms["VideoToolbox (Apple hardware JPEG)"] = pcTime(iters: iters, warm: warm) { vt.sample(data).flatMap { vt.decode($0) } != nil }.ms.map { jnum($0) } ?? NSNull()
            } else { ms["VideoToolbox (Apple hardware JPEG)"] = NSNull() }
            r["ms"] = ms
            func o(_ k: String) -> String {
                guard let d = others[k] as? [String: Any] else { return "?" }
                if d["error"] != nil { return "error" }
                return d["same"] as? Bool == true ? "same" : "max \(d["max_diff"] ?? "?")"
            }
            func m(_ k: String) -> String { (ms[k] as? Double).map { fmt($0) } ?? "-" }
            line += "; ms Metal \(m("this library")), turbo \(m("libjpeg-turbo, one thread")), ImageIO \(m("Apple ImageIO")) (\(o("Apple ImageIO"))), VT \(m("VideoToolbox (Apple hardware JPEG)")) (\(o("VideoToolbox (Apple hardware JPEG)")))"
            print(line)
            r["_mp_exact"] = Double(px) / 1e6     // the fit's filter and regressor (megapixels is rounded)
            r["_coded_mb"] = codedBytes.map { Double($0) / 1e6 } ?? NSNull()
            rows.append(r)
        }
    }
    let loadEnd = Bench.shell("sysctl -n vm.loadavg | tr -d '{}' | xargs"), thermalEnd = thermal()

    // summary
    var summary: [String: Any] = ["jpegs": rows.count]
    summary["on_the_gpu_route"] = rows.filter { $0["route"] as? String == "gpu" }.count
    summary["decoded_on_the_gpu"] = rows.filter { $0["gpu_decoded"] as? Bool == true }.count
    summary["pixels_identical"] = rows.filter { $0["same_pixels"] as? Bool == true }.count
    var passes: [String: Int] = [:]
    for r in rows where r["gpu_decoded"] as? Bool == true { passes["\(r["passes"] ?? 0)", default: 0] += 1 }
    summary["passes"] = passes
    let encRows = rows.filter { $0["encode_same_bytes"] is Bool }
    summary["encodes_compared"] = encRows.count
    summary["encodes_byte_identical"] = encRows.filter { $0["encode_same_bytes"] as? Bool == true }.count
    summary["encodes_same_as_libjpeg_turbo"] = rows.filter { ($0["encode_detail"] as? [String: Any])?["same_as_libjpeg_turbo_encode"] as? Bool == true }.count
    summary["from_packed_identical"] = rows.filter { $0["from_packed_same"] as? Bool == true }.count
    let bpps = rows.compactMap { $0["bytes_per_pixel"] as? Double }
    summary["bytes_per_pixel"] = [orNull(bpps.min()), orNull(bpps.max())]
    var fits: [String: Any] = [:]
    for g in pcGroups {
        var per: [String: Any] = [:]
        for d in pcDecoders {
            let pts = rows.compactMap { r -> (mp: Double, mb: Double, ms: Double)? in
                guard g.settings.contains(r["setting"] as? String ?? ""), let mp = r["_mp_exact"] as? Double, mp >= 3,
                      let mb = r["_coded_mb"] as? Double, let y = (r["ms"] as? [String: Any])?[d] as? Double else { return nil }
                return (mp, mb, y)
            }
            per[d] = pcFit(pts)
        }
        fits[g.name] = per
    }
    summary["ms_per_coded_mb"] = ["model": "least squares ms = a + b*MP + c*codedMB over JPEGs of 3 MP and up; codedMB = (file length - scan start - 2) / 1e6; se_*: standard errors",
                                  "groups": ["4:2:0": "q95_420, q90_420, q95_420_opt", "4:2:2": "q95_422", "4:4:4": "q95_444"], "fits": fits]
    var othersSum: [String: Any] = [:]
    for k in pcOthers {
        let recs = rows.map { ($0["setting"] as? String ?? "", ($0["others"] as? [String: Any])?[k] as? [String: Any] ?? ["error": "missing"]) }
        func count(_ rs: [(String, [String: Any])]) -> [String: Int] {
            ["identical": rs.filter { $0.1["same"] as? Bool == true }.count, "differ": rs.filter { $0.1["same"] as? Bool == false }.count,
             "failed": rs.filter { $0.1["error"] != nil }.count]
        }
        var e: [String: Any] = count(recs)
        let diff = recs.filter { $0.1["same"] as? Bool == false }.map { $0.1 }
        e["max_diff"] = diff.compactMap { $0["max_diff"] as? Int }.max() ?? 0
        let pd = diff.compactMap { $0["pixels_differ"] as? Double }, ps = diff.compactMap { $0["psnr"] as? Double }
        e["pixels_differ"] = [orNull(pd.min()), orNull(pd.max())]
        e["psnr"] = [orNull(ps.min()), orNull(ps.max())]
        var bys: [String: Any] = [:]
        for s in pcSettings { bys[s.name] = count(recs.filter { $0.0 == s.name }) }
        e["by_setting"] = bys
        othersSum[k] = e
    }
    summary["others"] = othersSum
    for k in rows.indices { rows[k]["_coded_mb"] = nil; rows[k]["_mp_exact"] = nil }

    // the Pillow differences, grouped by where they start
    var encDiff: [String: Int] = [:]
    for r in rows { if let ed = r["encode_detail"] as? [String: Any], let seg = ed["pillow_segment"] as? String { encDiff[seg, default: 0] += 1 } }
    if !encDiff.isEmpty { summary["encode_differences_start_in"] = encDiff }

    let chip = (cond["chip"] as? String ?? "?").replacingOccurrences(of: "Apple ", with: "").lowercased().replacingOccurrences(of: " ", with: "")
    let iso = ISO8601DateFormatter(); iso.timeZone = .current
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let commit = Bench.shell("git rev-parse --short HEAD 2>/dev/null")
    let dirty = !Bench.shell("git status --porcelain --untracked-files=no 2>/dev/null").isEmpty
    let doc: [String: Any] = [
        "measured": iso.string(from: Date()),
        "quick": quick,
        "gpu": ["chip": cond["chip"] ?? "?", "cores": cond["gpu_cores"] ?? 0],
        "versions": ["libjpeg-turbo runtime": orNull(Turbo.runtimeVersion), "macOS": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                     "ejm commit": orNull(commit.isEmpty ? nil : (dirty ? commit + " (uncommitted changes)" : commit))],
        "archives": [
            ["name": "rgb8bit.zip", "bytes": 346126330, "sha256": "16c273504425923259b1ddf8e39dfa9cb27585d249f6263cfc6bea39cfafa660",
             "url": "https://imagecompression.info/test_images/rgb8bit.zip", "images": "imagecompression_info/*.ppm"],
            ["name": "3dtestimages.tar.bz2", "bytes": 764181, "sha256": "60e5cac0da25712a9b49da60212f14266d07c586dfb5d6c968e34fec6937b667",
             "url": "https://libjpeg-turbo.org/pmwiki/uploads/About/3dtestimages.tar.bz2", "images": "libjpeg_turbo_3dtest/*.ppm"],
        ],
        "generator": "Pillow 13.0.0, libjpeg-turbo 3.2.0",
        "reference": "libjpeg-turbo 3.2.0 TurboRef islow fancy; the PC uses simplejpeg 1.9.0 / libjpeg-turbo 3.1.2",
        "gray": "q95_gray JPEGs are compared as RGB: the reference is libjpeg-turbo's JCS_RGB output of the gray file (R = G = B = Y), the Metal Decoder decodes them to PixelFormat.rgb, ImageIO's 8-bit gray CGImage is expanded to R = G = B, VideoToolbox's BGRA is read as RGB",
        "settings": pcSettings.map { ["name": $0.name, "quality": $0.quality, "pillow": $0.pillow, "encode_compared": $0.encode] as [String: Any] },
        "other_decoders": ["Apple ImageIO": "CGImageSourceCreateImageAtIndex with kCGImageSourceUseHardwareAcceleration true and kCGImageSourceShouldCacheImmediately; the CGImage's own bytes as RGB",
                           "VideoToolbox (Apple hardware JPEG)": "VTDecompressionSession, hardware decoder required, 32BGRA output read as RGB (includes VideoToolbox's YCbCr to RGB conversion); its timed call makes the sample buffer from the bytes and decodes it"],
        "timing": quick ? "QUICK smoke run: at least 2 calls and 0.1 s back to back, then the median of 3 calls, each waited for, from bytes in memory, CLOCK_UPTIME_RAW"
                        : "at least 2 calls and 0.3 s back to back, then the median of 9 calls, each waited for, from bytes in memory, CLOCK_UPTIME_RAW; null when a call failed",
        "timing_notes": ["VideoToolbox: each timed call builds the CMSampleBuffer from the bytes and decodes it (a decode from bytes in memory); the session is made once per JPEG, outside the timed calls",
                         "this library: one Decoder is reused across calls (its header and layout cache warm), as the PC reuses its library state"],
        "encode": "Metal Encoder of the source PPM's RGB at the setting's quality and subsampling against the Pillow file (encode_same_bytes); encode_detail compares it with libjpeg-turbo's own encode of the same pixels and, when it differs from Pillow's file, gives the first differing offset and the segment there",
        "pc_set_dir": rootLabel,
        "inputs": fileList,
        "skipped": skipped,
        "files": rows,
        "summary": summary,
        "conditions": ["load_average_before": loadStart, "load_average_after": loadEnd, "thermal_state_before": thermalStart, "thermal_state_after": thermalEnd],
    ]

    print("\n== pc-set summary\(quick ? " (QUICK: smoke test, not results)" : ""): \(rows.count) JPEGs, \(summary["on_the_gpu_route"]!) on the GPU route, \(summary["decoded_on_the_gpu"]!) decoded on the GPU")
    print("pixels identical \(summary["pixels_identical"]!)/\(rows.count); from packed identical \(summary["from_packed_identical"]!)/\(rows.count); passes \(passes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
    print("encodes byte-identical to Pillow \(summary["encodes_byte_identical"]!)/\(encRows.count); same as libjpeg-turbo's encode \(summary["encodes_same_as_libjpeg_turbo"]!)/\(encRows.count)\(encDiff.isEmpty ? "" : "; Pillow differences start in \(encDiff)")")
    print("bytes per pixel \(bpps.min().map { fmt($0, 4) } ?? "?")...\(bpps.max().map { fmt($0, 4) } ?? "?")")
    for k in pcOthers {
        let e = othersSum[k] as! [String: Any]
        print("\(k): identical \(e["identical"]!), differ \(e["differ"]!), failed \(e["failed"]!), max diff \(e["max_diff"]!), PSNR \(e["psnr"]!)")
    }
    for g in pcGroups {
        let per = fits[g.name] as! [String: Any]
        for d in pcDecoders {
            let f = per[d] as! [String: Any]
            print("fit \(g.name) \(d): ms = \(f["a_ms"] ?? "?") + \(f["b_ms_per_mp"] ?? "?") x MP + \(f["c_ms_per_coded_mb"] ?? "?") x coded MB (n \(f["n"]!), se c \(f["se_c"] ?? "?"))")
        }
    }
    print("load \(loadStart) -> \(loadEnd); thermal \(thermalStart) -> \(thermalEnd)")
    print("skipped: \(skipped.isEmpty ? "none" : skipped.map { "\($0["file"]!) (\($0["reason"]!))" }.joined(separator: ", "))")
    if !bad.isEmpty { print("NOT IDENTICAL: \(bad.joined(separator: "; "))") }

    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = .current; stamp.dateFormat = "yyyy-MM-dd-HHmm"
    let path = out ?? "results/public/\(chip)-gpu\(cond["gpu_cores"] ?? 0)-\(stamp.string(from: Date()))-pc-set.json"
    var writeFailed = false
    do {
        let js = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        try js.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rows.count) rows)")
    } catch {
        writeFailed = true
        print("could not write \(path): \(error)\nthe results follow on stdout:")
        if let js = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]), let s = String(data: js, encoding: .utf8) { print(s) }
        else { print(doc) }
    }
    if !bad.isEmpty { return 1 }
    if writeFailed { return 3 }
    return skipped.isEmpty ? 0 : 2
}
