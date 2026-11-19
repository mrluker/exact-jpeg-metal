import Foundation
import ExactJPEG
import TurboRef

// Mutation fuzzer for the decoder. Everything is generated locally; nothing is downloaded.
//
//   ejm fuzz <out_dir> [iters] [seed]
//
// Seeds: small synthetic JPEGs written by libjpeg-turbo (every subsampling, gray, optimised tables, restart
// intervals). Mutations: bit flips, byte changes, truncation anywhere and at every marker boundary, inserted and
// deleted bytes, inserted / removed / renumbered restart markers, stray 0xFF, corrupted DQT/DHT/SOF/SOS/DRI fields,
// absurd and zero dimensions, bad component counts and sampling factors, bad segment lengths, duplicated / dropped
// / reordered segments, random scan data, spliced scans.
//
// Findings (input saved to <out_dir>/findings):
//   mismatch        the GPU returned an image that differs from libjpeg-turbo's, or libjpeg-turbo failed on it
//   warning         identical pixels, but libjpeg-turbo warned about something other than the benign cases
//                   (extraneous bytes before a marker, missing EOI after a complete scan, unknown JFIF version)
//   nondeterministic two decodes of the same input differ (or one declines)
//   leak            after a bad input, a known-good file no longer decodes byte-exactly
//   gpu_error       a command buffer reported an error (run with MTL_SHADER_VALIDATION=1 to catch out-of-bounds access)
//   internal        the decoder declined with an "internal:" reason (the GPU and host trailer checks disagreed)
//   hang            no progress for 60 s (the process exits; the input is <out_dir>/current.jpg)
//   crash           the process died: the input is <out_dir>/current.jpg
// Summary: <out_dir>/summary.json. The run also fails when under 10% of the mutated files decode exactly (an
// all-decline regression would otherwise pass with no finding).

struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) < p * 1_000_000 }
}

/// marker segments: (offset of 0xFF, marker, end offset); the scan data runs from the SOS end to the next marker
func segments(_ d: [UInt8]) -> (segs: [(at: Int, m: UInt8, end: Int)], scan: Range<Int>?) {
    var segs: [(Int, UInt8, Int)] = []
    var i = 2
    let n = d.count
    while i + 3 < n, d[i] == 0xFF {
        let m = d[i + 1]
        let L = Int(d[i + 2]) << 8 | Int(d[i + 3])
        let end = min(i + 2 + L, n)
        segs.append((i, m, end))
        if m == 0xDA {
            var j = end
            while j + 1 < n && !(d[j] == 0xFF && d[j + 1] != 0 && (d[j + 1] & 0xF8) != 0xD0) { j += 1 }
            return (segs.map { ($0.0, $0.1, $0.2) }, end..<max(end, j))
        }
        i = end
    }
    return (segs.map { ($0.0, $0.1, $0.2) }, nil)
}

func mutate(_ src: [UInt8], _ other: [UInt8], _ r: inout Rng) -> ([UInt8], String) {
    var d = src
    let (segs, scan) = segments(d)
    func seg(_ m: UInt8) -> (at: Int, m: UInt8, end: Int)? { let c = segs.filter { $0.m == m }; return c.isEmpty ? nil : c[r.int(c.count)] }
    let k = r.int(16)
    switch k {
    case 0:
        for _ in 0..<(1 + r.int(8)) { let i = r.int(d.count); d[i] ^= UInt8(1 << r.int(8)) }
        return (d, "bitflip")
    case 1:
        for _ in 0..<(1 + r.int(4)) { d[r.int(d.count)] = UInt8(r.int(256)) }
        return (d, "bytes")
    case 2: return (Array(d[0..<r.int(d.count)]), "truncate")
    case 3:
        var cuts = segs.flatMap { [$0.at, $0.at + 1, $0.at + 2, $0.at + 4, $0.end - 1, $0.end] }
        if let s = scan { cuts += [s.lowerBound + 1, s.lowerBound + s.count / 2, s.upperBound - 1, s.upperBound] }
        let c = cuts.filter { $0 > 0 && $0 < d.count }
        return (c.isEmpty ? d : Array(d[0..<c[r.int(c.count)]]), "truncate-structural")
    case 4:
        let i = r.int(d.count)
        d.insert(contentsOf: (0..<(1 + r.int(16))).map { _ in UInt8(r.int(256)) }, at: i)
        return (d, "insert")
    case 5:
        let i = r.int(d.count), n = min(1 + r.int(32), d.count - i)
        d.removeSubrange(i..<(i + n))
        return (d, "delete")
    case 6:
        guard let s = scan, s.count > 4 else { return (d, "rst-none") }
        let ops = r.int(3)
        if ops == 0 {                                        // insert an RST marker
            d.insert(contentsOf: [0xFF, UInt8(0xD0 + r.int(8))], at: s.lowerBound + r.int(s.count))
            return (d, "rst-insert")
        }
        var rst: [Int] = []
        var j = s.lowerBound
        while j + 1 < s.upperBound { if d[j] == 0xFF && (d[j + 1] & 0xF8) == 0xD0 { rst.append(j) }; j += 1 }
        guard !rst.isEmpty else { d.insert(contentsOf: [0xFF, 0xD0], at: s.lowerBound + r.int(s.count)); return (d, "rst-insert") }
        let at = rst[r.int(rst.count)]
        if ops == 1 { d.removeSubrange(at..<(at + 2)); return (d, "rst-remove") }
        d[at + 1] = UInt8(0xD0 + r.int(8))
        return (d, "rst-renumber")
    case 7:
        guard let s = scan, s.count > 2 else { return (d, "ff-none") }
        let i = s.lowerBound + r.int(s.count)
        if r.chance(0.5) { d.insert(contentsOf: [0xFF, UInt8(1 + r.int(255))], at: i) } else { d.insert(0xFF, at: i) }
        return (d, "stray-ff")
    case 8:
        let kinds: [UInt8] = [0xDB, 0xC4, 0xC0, 0xDA, 0xDD]
        guard let sg = seg(kinds[r.int(kinds.count)]), sg.end - sg.at > 4 else { return (d, "field-none") }
        for _ in 0..<(1 + r.int(3)) {
            let i = sg.at + 4 + r.int(sg.end - sg.at - 4)
            d[i] = r.chance(0.3) ? [0, 1, 0xFF, 0x7F, 0x80, 0x0F, 0x10, 0x11][r.int(8)] : UInt8(r.int(256))
        }
        return (d, "field")
    case 9:
        guard let sg = seg(0xC0) ?? seg(0xC1), sg.end - sg.at >= 9 else { return (d, "dims-none") }
        let vals = [0, 1, 2, 7, 8, 9, 15, 16, 17, 255, 256, 4097, 65499, 65500, 65501, 65535, r.int(65536)]
        let v = vals[r.int(vals.count)]
        let at = sg.at + 5 + (r.chance(0.5) ? 0 : 2)
        d[at] = UInt8(v >> 8); d[at + 1] = UInt8(v & 255)
        return (d, "dims")
    case 10:
        guard let sg = seg(0xC0) ?? seg(0xC1), sg.end - sg.at >= 10 else { return (d, "comps-none") }
        if r.chance(0.4) { d[sg.at + 9] = UInt8([0, 1, 2, 3, 4, 255][r.int(6)]); return (d, "ncomp") }
        let nc = Int(d[sg.at + 9])
        guard nc > 0, sg.at + 10 + 3 * nc <= d.count else { return (d, "comps-none") }
        let c = r.int(nc)
        d[sg.at + 11 + 3 * c] = UInt8([0x00, 0x11, 0x12, 0x21, 0x22, 0x44, 0x13, 0x31, 0x41, 0x14, 0x55, 0xFF][r.int(12)])
        return (d, "sampling")
    case 11:
        guard !segs.isEmpty else { return (d, "len-none") }
        let sg = segs[r.int(segs.count)]
        let v = [0, 1, 2, 3, 0xFFFF, r.int(65536), sg.end - sg.at - 2 + 1, sg.end - sg.at - 2 - 1][r.int(8)]
        d[sg.at + 2] = UInt8((v >> 8) & 255); d[sg.at + 3] = UInt8(v & 255)
        return (d, "seglen")
    case 12:
        guard segs.count > 1 else { return (d, "dup-none") }
        let sg = segs[r.int(segs.count - 1)]
        let bytes = Array(d[sg.at..<sg.end])
        let op = r.int(3)
        if op == 0 { d.insert(contentsOf: bytes, at: sg.end); return (d, "dup-seg") }
        if op == 1 { d.removeSubrange(sg.at..<sg.end); return (d, "drop-seg") }
        let other = segs[r.int(segs.count - 1)]
        if other.at == sg.at { return (d, "reorder-none") }
        d.removeSubrange(sg.at..<sg.end)
        let to = other.at < sg.at ? other.at : other.at - bytes.count
        d.insert(contentsOf: bytes, at: max(2, min(to, d.count)))
        return (d, "reorder-seg")
    case 13:
        guard let s = scan, s.count > 8 else { return (d, "rand-none") }
        let a = s.lowerBound + r.int(s.count), n = min(1 + r.int(256), s.upperBound - a)
        for i in a..<(a + n) { d[i] = UInt8(r.int(256)) }
        return (d, "random-scan")
    case 14:
        let (_, os) = segments(other)
        guard let s = scan, let o = os else { return (d, "splice-none") }
        d.replaceSubrange(s, with: other[o])
        return (d, "splice-scan")
    default:
        // a different file's header with this file's scan, or trailing garbage after EOI
        if r.chance(0.5) { d += (0..<(1 + r.int(64))).map { _ in UInt8(r.int(256)) }; return (d, "trailing") }
        d.insert(contentsOf: [0xFF, 0xFE, 0x00, 0x04, 0x41, 0x42], at: d.count - min(2, d.count))
        return (d, "trailing-com")
    }
}

func fuzzSeeds() -> [(String, [UInt8])] {
    var seeds: [(String, [UInt8])] = []
    var s: UInt32 = 900
    for (h, w) in [(8, 8), (16, 24), (33, 17), (1, 1), (5, 70), (64, 64), (120, 90)] {
        s &+= 1
        let a = corpusContent(w, h, "smooth", s)
        let g = stride(from: 0, to: a.count, by: 3).map { a[$0] }
        for samp in 0..<5 { seeds.append(("\(h)x\(w)_s\(samp)", [UInt8](Turbo.encode(a, w, h, quality: 75, samp: samp)))) }
        seeds.append(("\(h)x\(w)_gray", [UInt8](Turbo.encode(g, w, h, gray: true, quality: 75, samp: 0))))
        seeds.append(("\(h)x\(w)_opt", [UInt8](Turbo.encode(a, w, h, quality: 90, samp: 2, optimize: true))))
        seeds.append(("\(h)x\(w)_rst1", [UInt8](Turbo.encode(a, w, h, quality: 50, samp: 1, restartMCUs: 1))))
        seeds.append(("\(h)x\(w)_rst3", [UInt8](Turbo.encode(a, w, h, quality: 100, samp: 0, restartMCUs: 3))))
        seeds.append(("\(h)x\(w)_q1", [UInt8](Turbo.encode(a, w, h, quality: 1, samp: 2))))
    }
    let a = corpusContent(640, 480, "smooth", 77)
    seeds.append(("480x640_s1", [UInt8](Turbo.encode(a, 640, 480, quality: 95, samp: 1))))
    seeds.append(("480x640_rstrow", [UInt8](Turbo.encode(a, 640, 480, quality: 85, samp: 2, restartRows: 1))))
    return seeds
}

final class Progress: @unchecked Sendable { var stamp = now(); var iter = 0 }

@discardableResult func runFuzz(outDir: String, iters: Int, seed: UInt64) -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outDir + "/findings", withIntermediateDirectories: true)
    let seeds = fuzzSeeds()
    var r = Rng(s: seed | 1)
    let dec = Decoder()
    dec.maxPixels = 1 << 22
    let good = seeds.first { $0.0 == "480x640_s1" }!.1
    let goodRef = Turbo.decode(Data(good))!.px
    var warnings: [String: Int] = [:]
    var counts: [String: Int] = [:], declines: [String: Int] = [:], findings: [String: Int] = [:], mutations: [String: Int] = [:]
    let prog = Progress()
    let watchdog = Thread {
        while true {
            Thread.sleep(forTimeInterval: 5)
            if now() - prog.stamp > 60 { print("HANG at iteration \(prog.iter); input in \(outDir)/current.jpg"); fflush(stdout); exit(3) }
        }
    }
    watchdog.start()
    func finding(_ kind: String, _ d: [UInt8], _ note: String) {
        findings[kind, default: 0] += 1
        if findings[kind]! <= 20 {
            try? Data(d).write(to: URL(fileURLWithPath: "\(outDir)/findings/\(kind)_\(findings[kind]!).jpg"))
            print("  FINDING \(kind): \(note)"); fflush(stdout)
        }
    }
    let t0 = now()
    for it in 0..<iters {
        prog.iter = it; prog.stamp = now()
        let (sname, src) = seeds[r.int(seeds.count)]
        var (d, what) = mutate(src, seeds[r.int(seeds.count)].1, &r)
        if r.chance(0.25) { let (d2, w2) = mutate(d.count > 4 ? d : src, src, &r); d = d2; what += "+" + w2 }
        mutations[what.split(separator: "+").first.map(String.init) ?? what, default: 0] += 1
        try? Data(d).write(to: URL(fileURLWithPath: outDir + "/current.jpg"))
        let format: PixelFormat = r.chance(0.2) ? .gray : .rgb
        let data = Data(d)
        let img = dec.decode(data, format: format)
        if let reason = dec.reason, reason.hasPrefix("GPU error") { finding("gpu_error", d, "\(sname) \(what): \(reason)") }
        if let reason = dec.reason, reason.hasPrefix("internal:") { finding("internal", d, "\(sname) \(what): \(reason)") }
        if let img {
            let px = [UInt8](img.bytes)
            if let ref = Turbo.decode(data, gray: format == .gray), ref.w == img.width, ref.h == img.height {
                let code = tr_last_warning()
                if ref.px != px { finding("mismatch", d, "\(sname) \(what): pixels differ (libjpeg-turbo warning \(code))") }
                else if ref.warned {
                    // identical pixels; libjpeg-turbo only warned. Record which warning (extraneous bytes before a
                    // marker does not change the image; anything else is flagged)
                    let msg = String(cString: tr_message(code))
                    warnings[msg, default: 0] += 1
                    // benign: libjpeg-turbo discards extraneous bytes before a marker, reports a missing EOI after a
                    // complete scan, or an unknown JFIF version; none changes the pixels (checked above)
                    let benign = ["extraneous bytes", "Premature end of JPEG file", "unknown JFIF revision"].contains { msg.contains($0) }
                    if benign { counts["decoded_exact_with_benign_warning", default: 0] += 1 }
                    else { finding("warning", d, "\(sname) \(what): libjpeg-turbo warned '\(msg)' but GPU accepted (pixels identical)") }
                }
                else { counts["decoded_exact", default: 0] += 1 }
            } else {
                finding("mismatch", d, "\(sname) \(what): libjpeg-turbo cannot decode it or size differs, GPU accepted")
            }
            if r.chance(0.1) {
                let again = dec.decode(data, format: format)
                if again == nil || [UInt8](again!.bytes) != px { finding("nondeterministic", d, "\(sname) \(what)") }
            }
        } else {
            counts["declined", default: 0] += 1
            let key = (dec.reason ?? "?").replacingOccurrences(of: #"\d+"#, with: "N", options: .regularExpression)
            declines[key, default: 0] += 1
            if r.chance(0.05) {
                if dec.decode(data, format: format) != nil { finding("nondeterministic", d, "\(sname) \(what): declined once, accepted next") }
            }
        }
        if it % 50 == 49 {
            guard let g = dec.decode(Data(good)), [UInt8](g.bytes) == goodRef else { finding("leak", d, "after \(sname) \(what)"); continue }
        }
        if it % 5000 == 4999 { print("  \(it + 1) iterations, \(fmt(now() - t0, 0)) s, findings \(findings)"); fflush(stdout) }
    }
    let summary: [String: Any] = [
        "iterations": iters, "seed": seed, "seconds": now() - t0, "seed_files": seeds.count,
        "counts": counts, "accepted_with_libjpeg_warning": warnings, "findings": findings, "mutations": mutations,
        "top_decline_reasons": Dictionary(uniqueKeysWithValues: declines.sorted { $0.value > $1.value }.prefix(15).map { ($0.key, $0.value) }),
        "reference": Turbo.version, "device": dec.ctx.device.name,
        "shader_validation": ProcessInfo.processInfo.environment["MTL_SHADER_VALIDATION"] ?? "0",
    ]
    let js = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try? js.write(to: URL(fileURLWithPath: outDir + "/summary.json"))
    try? fm.removeItem(atPath: outDir + "/current.jpg")
    print(String(data: js, encoding: .utf8)!)
    // an all-decline regression would leave no finding: about 20% of the mutated files decode exactly (25% with the
    // benign-warning ones; 2026-11-18, 200000 iterations), so require at least 10% decoded exactly (without a warning)
    let exact = counts["decoded_exact"] ?? 0, minExact = max(1, iters / 10)
    print("fuzz: \(iters) iterations, decoded exactly \(exact) (minimum \(minExact)), with a benign warning \(counts["decoded_exact_with_benign_warning"] ?? 0), declined \(counts["declined"] ?? 0), findings \(findings.values.reduce(0, +))")
    if exact < minExact { print("FAIL: only \(exact) of \(iters) mutated files decoded exactly (minimum \(minExact)): the decoder declines too much") }
    return findings.isEmpty && exact >= minExact
}
