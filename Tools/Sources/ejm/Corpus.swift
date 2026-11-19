import Foundation
import ExactJPEG
import CryptoKit
import TurboRef

/// A deterministic synthetic corpus written by libjpeg-turbo (the same idea as exact-gpu-jpeg's tests/corpus.py):
/// every subsampling, sizes from 1x1 up, qualities 1-100, optimised tables, restart intervals, progressive files
/// (which must be declined).
struct CorpusItem { let name: String; let data: Data; let expectGPU: Bool }

func makeCorpus() -> [CorpusItem] {
    let sizes = [(1, 1), (1, 17), (17, 1), (2, 3), (7, 9), (8, 8), (9, 2), (16, 16), (15, 33), (31, 64), (97, 203),
                 (480, 640), (1080, 1920)]
    let qualities = [1, 5, 25, 50, 75, 90, 95, 100]
    let subs = ["444", "422", "420", "440", "411", "gray"]
    var out: [CorpusItem] = []
    var seed: UInt32 = 7
    for (si, (h, w)) in sizes.enumerated() {
        let kinds = h * w < 300000 ? ["smooth", "edges", "noise"] : ["smooth"]
        for kind in kinds {
            seed &+= 1
            let a = corpusContent(w, h, kind, seed)
            for (k, sub) in subs.enumerated() {
                let q = qualities[(si + k + kind.count) % qualities.count]
                let gray = sub == "gray"
                let src = gray ? stride(from: 0, to: a.count, by: 3).map { a[$0] } : a
                out.append(CorpusItem(name: "tj_\(h)x\(w)_\(kind)_\(sub)_q\(q)",
                                      data: Turbo.encode(src, w, h, gray: gray, quality: q, samp: k < 5 ? k : 0), expectGPU: true))
            }
        }
    }
    for (h, w) in [(1, 1), (9, 2), (16, 16), (15, 33), (97, 203), (480, 640)] {
        seed &+= 1
        let a = corpusContent(w, h, "smooth", seed)
        for s in 0..<3 {
            out.append(CorpusItem(name: "tj_\(h)x\(w)_s\(s)_opt", data: Turbo.encode(a, w, h, quality: 85, samp: s, optimize: true), expectGPU: true))
            out.append(CorpusItem(name: "tj_\(h)x\(w)_s\(s)_rst1", data: Turbo.encode(a, w, h, quality: 85, samp: s, restartMCUs: 1), expectGPU: true))
            out.append(CorpusItem(name: "tj_\(h)x\(w)_s\(s)_rst7", data: Turbo.encode(a, w, h, quality: 60, samp: s, restartMCUs: 7), expectGPU: true))
            out.append(CorpusItem(name: "tj_\(h)x\(w)_s\(s)_rstrow", data: Turbo.encode(a, w, h, quality: 95, samp: s, restartRows: 1, optimize: true), expectGPU: true))
            out.append(CorpusItem(name: "tj_\(h)x\(w)_s\(s)_prog", data: Turbo.encode(a, w, h, quality: 85, samp: s, progressive: true), expectGPU: false))
        }
        let g = stride(from: 0, to: a.count, by: 3).map { a[$0] }
        out.append(CorpusItem(name: "tj_\(h)x\(w)_gray_rst3", data: Turbo.encode(g, w, h, gray: true, quality: 80, samp: 0, restartMCUs: 3), expectGPU: true))
    }
    // a full-size camera-like file per subsampling
    let big = Synth.make(width: 6720, height: 4480, seed: 3)
    for s in 0..<3 {
        out.append(CorpusItem(name: "tj_6720x4480_s\(s)_q95", data: Turbo.encode(big, 6720, 4480, quality: 95, samp: s), expectGPU: true))
    }
    return out
}

@discardableResult func runCorpus() -> Bool {
    print("reference: \(Turbo.version)")
    let t0 = now()
    let corpus = makeCorpus()
    print("corpus: \(corpus.count) files (\(fmt(now() - t0, 1)) s to generate)")
    let dec = Decoder()
    var ok = 0, declined = 0, wrong = 0, unexpected = 0, refFailed = 0
    var declinedNames: [String] = []
    for item in corpus {
        for format in [PixelFormat.rgb, .gray] {
            let img = dec.decode(item.data, format: format)
            if !item.expectGPU {
                if img == nil { declined += 1; declinedNames.append("\(item.name) \(format)") } else { unexpected += 1; print("  should have declined: \(item.name)") }
                continue
            }
            guard let img else {
                unexpected += 1
                declinedNames.append("\(item.name) \(format)")
                print("  declined \(item.name) \(format): \(dec.reason ?? "?")")
                continue
            }
            guard let ref = Turbo.decode(item.data, gray: format == .gray), !ref.warned else { refFailed += 1; print("  REFERENCE FAILED \(item.name) \(format): libjpeg-turbo could not decode it cleanly"); continue }
            let got = img.bytes
            var diffs = 0, maxd = 0, firstAt = -1
            for i in 0..<ref.px.count {
                let d = abs(Int(got[i]) - Int(ref.px[i]))
                if d != 0 { diffs += 1; maxd = max(maxd, d); if firstAt < 0 { firstAt = i } }
            }
            if diffs == 0 && got.count == ref.px.count { ok += 1 } else {
                wrong += 1
                print("  DIFFERENT \(item.name) \(format): \(diffs) bytes differ, max \(maxd), first at \(firstAt)")
            }
        }
    }
    // one line naming the declined set, so runs at other settings can be compared (scripts/test.sh)
    let names = declinedNames.sorted().joined(separator: "\n")
    print("declined set: \(declinedNames.count) decodes, sha256 \(SHA256.hash(data: Data(names.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())")
    if refFailed > 0 { print("FAIL: libjpeg-turbo failed or warned on \(refFailed) corpus decodes (no reference)") }
    print("exact: \(ok), declined as expected: \(declined), wrong: \(wrong), unexpected decline/accept: \(unexpected)")
    Exact.v["decode"] = ["files": corpus.count, "decodes_exact": ok, "declined_as_expected": declined, "wrong": wrong, "unexpected": unexpected,
                         "reference_failures": refFailed]
    return wrong == 0 && unexpected == 0 && refFailed == 0
}

/// The timing inputs of the iOS check app (Examples/ios-check): libjpeg-turbo encodes of Synth images, with the
/// hashes the app checks its GPU results against (the phone has no libjpeg-turbo).
let benchDecodeCases: [(label: String, w: Int, h: Int, seed: UInt32, q: Int, samp: Int)] =
    [("6720x4480 q95 4:2:2", 6720, 4480, 11, 95, 1), ("6720x4480 q90 4:2:0", 6720, 4480, 11, 90, 2),
     ("6720x4480 q95 4:4:4", 6720, 4480, 11, 95, 0)]
    + [(64, 64), (256, 256), (488, 480), (640, 480), (1024, 768), (1600, 1200), (2048, 1536), (3264, 2448), (4032, 3024)].map { ("\($0.0)x\($0.1) q90 4:2:0", $0.0, $0.1, 21, 90, 2) }
let benchEncodeCases: [(label: String, w: Int, h: Int, seed: UInt32, q: Int, samp: Int)] =
    [("3840x2560 q95 4:4:4", 3840, 2560, 21, 95, 0), ("2048x1365 q90 4:4:4", 2048, 1365, 21, 90, 0),
     ("1500x1000 q90 4:4:4", 1500, 1000, 21, 90, 0), ("1200x800 q87 4:2:0", 1200, 800, 21, 87, 2)]
    + [(64, 64), (256, 256), (488, 480), (640, 480), (1024, 768), (1600, 1200)].map { ("\($0.0)x\($0.1) q90 4:2:0", $0.0, $0.1, 21, 90, 2) }

/// ejm export-corpus <dir>: the decoder corpus as <dir>/<name>.jpg (the files `ejm corpus` decodes), plus the
/// timing inputs in <dir>/bench/ and their hashes in <dir>/bench/bench.json. Every corpus file is checked against
/// the manifest's `jpeg` hash, so the export is the committed exactness target. Prints the total size.
func runExportCorpus(dir: String, manifest: String = "testdata/manifest-libjpeg-turbo-3.2.0.json") -> Bool {
    let fm = FileManager.default
    try! fm.createDirectory(atPath: dir + "/bench", withIntermediateDirectories: true)
    let man = (try? Data(contentsOf: URL(fileURLWithPath: manifest))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let want = Dictionary(((man?["decode"] as? [[String: Any]]) ?? []).map { ($0["name"] as! String, $0["jpeg"] as! String) }) { a, _ in a }
    var total = 0, large = 0, nLarge = 0, differ = 0
    let corpus = makeCorpus()
    for it in corpus {
        try! it.data.write(to: URL(fileURLWithPath: "\(dir)/\(it.name).jpg"))
        total += it.data.count
        if it.name.hasPrefix("tj_6720x4480") { large += it.data.count; nLarge += 1 }
        if want[it.name] != sha(it.data) { differ += 1; print("  differs from the manifest: \(it.name)") }
    }
    var dec: [[String: Any]] = [], enc: [[String: Any]] = [], benchBytes = 0
    for c in benchDecodeCases {
        let src = Synth.make(width: c.w, height: c.h, seed: c.seed)
        let d = Turbo.encode(src, c.w, c.h, quality: c.q, samp: c.samp)
        let file = "dec_\(c.w)x\(c.h)_q\(c.q)_s\(c.samp).jpg"
        try! d.write(to: URL(fileURLWithPath: "\(dir)/bench/\(file)"))
        benchBytes += d.count
        dec.append(["label": c.label, "file": file, "width": c.w, "height": c.h, "quality": c.q, "samp": c.samp,
                    "jpeg": sha(d), "rgb": sha(Turbo.decode(d)!.px)])
    }
    for c in benchEncodeCases {
        let src = Synth.make(width: c.w, height: c.h, seed: c.seed)
        enc.append(["label": c.label, "width": c.w, "height": c.h, "seed": Int(c.seed), "quality": c.q, "samp": c.samp,
                    "source": sha(src), "jpeg": sha(Turbo.encode(src, c.w, c.h, quality: c.q, samp: c.samp))])
    }
    let js = try! JSONSerialization.data(withJSONObject: ["reference": Turbo.version, "decode": dec, "encode": enc],
                                         options: [.prettyPrinted, .sortedKeys])
    try! js.write(to: URL(fileURLWithPath: dir + "/bench/bench.json"))
    func mb(_ n: Int) -> String { fmt(Double(n) / 1e6, 1) }
    print("wrote \(corpus.count) corpus files to \(dir): \(mb(total)) MB (the \(nLarge) 6720x4480 files: \(mb(large)) MB); \(differ) differ from the manifest")
    print("wrote \(dec.count) timing inputs to \(dir)/bench: \(mb(benchBytes)) MB, hashes in bench/bench.json")
    let refsOK = exportDeviceRefs(dir: dir, corpus: corpus)
    return differ == 0 && !want.isEmpty && refsOK
}

/// <dir>/refs.json: libjpeg-turbo's own output for the iOS check's cases that the manifest has no hash for, so the
/// device compares with libjpeg-turbo's bytes rather than with the library's own:
///   formats  per GPU-decodable corpus file, SHA-256 of libjpeg-turbo's decode to .bgr, .rgba and .bgra
///            (tr_decode_fmt: JCS_EXT_BGR, JCS_EXT_RGBA, JCS_EXT_BGRA)
///   exif     encodes of enc_480x640_smooth_s0_q95 with an EXIF block of 10-13 bytes of 0x45 (tr_encode_meta)
///   icc      encodes of enc_97x203_smooth_s0_q90's source with ICC profiles (and one EXIF + ICC) at 4:4:4 and
///            4:2:0, q90; the profile and EXIF bytes are <dir>/icc/*.bin (tr_encode_meta: jpeg_write_icc_profile)
func exportDeviceRefs(dir: String, corpus: [CorpusItem]) -> Bool {
    let fm = FileManager.default
    // the device checks its bytes against these hashes: only libjpeg-turbo 3.2.0's (as manifest write); a refs.json
    // left from an earlier export goes too, so that no stale one is bundled
    guard Turbo.runtimeVersion == Turbo.target else {
        try? fm.removeItem(atPath: dir + "/refs.json")
        print("refs.json: refused, the loaded libjpeg-turbo is \(Turbo.runtimeVersion ?? "of unknown version") (\(Turbo.runtimePath)), the device check's target is \(Turbo.target)")
        return false
    }
    try! fm.createDirectory(atPath: dir + "/icc", withIntermediateDirectories: true)
    var formats: [String: [String: String]] = [:], bad = 0
    for it in corpus where it.expectGPU {
        var e: [String: String] = [:]
        for (f, key) in [(PixelFormat.bgr, "bgr"), (.rgba, "rgba"), (.bgra, "bgra")] {
            guard let px = turboDecode(it.data, f) else { bad += 1; print("  libjpeg-turbo failed: \(it.name) \(key)"); continue }
            e[key] = sha(px)
        }
        formats[it.name] = e
    }
    func meta(_ px: [UInt8], _ w: Int, _ h: Int, _ q: Int, _ samp: Int, _ exif: Data?, _ icc: Data?) -> Data? {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var len = 0
        func opt<R>(_ d: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
            guard let d else { return body(nil, 0) }
            return d.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count) }
        }
        let r = px.withUnsafeBufferPointer { p in opt(exif) { e, el in opt(icc) { i, il in tr_encode_meta(p.baseAddress, Int32(w), Int32(h), Int32(q), Int32(samp), e, el, i, il, &out, &len) } } }
        guard r == 0 else { return nil }
        defer { tr_free(out) }
        return Data(bytes: out!, count: len)
    }
    let cases = encodeCases()
    var exif: [[String: Any]] = [], icc: [[String: Any]] = []
    if let c = cases.first(where: { $0.name == "enc_480x640_smooth_s0_q95" }) {
        for n in 10...13 {
            guard let d = meta(c.src, c.w, c.h, 95, 0, Data(repeating: 0x45, count: n), nil) else { bad += 1; continue }
            exif.append(["case": c.name, "length": n, "byte": 0x45, "quality": 95, "samp": 0, "jpeg": sha(d)])
        }
    } else { bad += 1 }
    if let c = cases.first(where: { $0.name == "enc_97x203_smooth_s0_q90" }) {
        var rng = Rng(s: 99)
        func blob(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }) }
        let ex = Data("Exif\0\0".utf8) + blob(1000)
        try! ex.write(to: URL(fileURLWithPath: "\(dir)/icc/exif_1006.bin"))
        for (n, withExif) in [(560, false), (65519, false), (65520, false), (200_000, false), (70000, true)] {
            let prof = blob(n), file = "icc/icc_\(n).bin"
            try! prof.write(to: URL(fileURLWithPath: "\(dir)/\(file)"))
            for samp in [0, 2] {
                guard let d = meta(c.src, c.w, c.h, 90, samp, withExif ? ex : nil, prof) else { bad += 1; continue }
                var e: [String: Any] = ["case": c.name, "icc_file": file, "quality": 90, "samp": samp, "jpeg": sha(d)]
                if withExif { e["exif_file"] = "icc/exif_1006.bin" }
                icc.append(e)
            }
        }
    } else { bad += 1 }
    let js = try! JSONSerialization.data(withJSONObject: ["reference": Turbo.version, "formats": formats, "exif": exif, "icc": icc],
                                         options: [.prettyPrinted, .sortedKeys])
    try! js.write(to: URL(fileURLWithPath: dir + "/refs.json"))
    // the same comparisons the device makes, here on this Mac's GPU: a reference this library does not reproduce on
    // the Mac is an export problem (or a library bug), not a device one
    let dec = Decoder(), enc = Encoder()
    var macOK = 0, macBad = 0
    for it in corpus where it.expectGPU {
        for (f, key) in [(PixelFormat.bgr, "bgr"), (.rgba, "rgba"), (.bgra, "bgra")] {
            if let img = dec.decode(it.data, format: f), sha(img.bytes) == formats[it.name]?[key] { macOK += 1 } else { macBad += 1; print("  this Mac's GPU differs: \(it.name) \(key)") }
        }
    }
    for e in exif + icc {
        let c = cases.first { $0.name == e["case"] as? String }!
        let ex: Data? = (e["length"] as? Int).map { Data(repeating: 0x45, count: $0) } ?? (e["exif_file"] as? String).map { try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")) }
        let ic: Data? = (e["icc_file"] as? String).map { try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")) }
        let got = try? c.src.withUnsafeBytes { try enc.encode(bytes: $0, width: c.w, height: c.h, quality: e["quality"] as! Int,
                                                              subsampling: [Subsampling.s444, .s422, .s420][e["samp"] as! Int], icc: ic, exif: ex) }
        if let got, sha(got) == e["jpeg"] as? String { macOK += 1 } else { macBad += 1; print("  this Mac's GPU differs: \(e["case"] ?? "?") \(e["icc_file"] ?? e["length"] ?? "")") }
    }
    print("wrote \(dir)/refs.json: \(formats.count) files x 3 formats, \(exif.count) EXIF and \(icc.count) ICC encodes (libjpeg-turbo's output); \(bad) failures; this Mac's GPU: \(macOK) identical, \(macBad) different")
    return bad == 0 && macBad == 0
}

/// api-check device-refs: refs.json (exportDeviceRefs, in a child: ejm export-refs-child) is written by libjpeg-turbo
/// 3.2.0 only; with another version (EJM_TEST_TURBO_RUNTIME=3.2.1, unknown) it is refused and a refs.json already
/// there is removed, so run-device.sh never bundles one from another version
func checkDeviceRefs(_ t: Tally) {
    let fm = FileManager.default
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    for (k, rt) in ["3.2.1", "", nil].enumerated() {
        let dir = NSTemporaryDirectory() + "ejm-refs-\(getpid())-\(k)"
        try? fm.removeItem(atPath: dir)
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        try! #"{"reference": "libjpeg-turbo 3.2.1"}"#.write(toFile: dir + "/refs.json", atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["export-refs-child", dir]
        var env = ProcessInfo.processInfo.environment
        env["EJM_TEST_TURBO_RUNTIME"] = rt
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe
        try! p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        let ref = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/refs.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reference"] as? String
        let name = rt.map { $0.isEmpty ? "an unknown runtime" : "runtime \($0)" } ?? "the real runtime (\(Turbo.version))"
        if rt == nil && Turbo.runtimeVersion == Turbo.target {
            t.check(p.terminationStatus == 0 && ref == "libjpeg-turbo \(Turbo.target)", "\(name): refs.json written, reference \(ref ?? "none"): \(out)")
        } else {
            t.check(p.terminationStatus != 0 && ref == nil, "\(name): refused, no refs.json left (reference \(ref ?? "none")): \(out)")
        }
    }
    // ejm export-public: one small JPEG in a public-bench-style directory, into an earlier export holding a stale
    // public-refs.json
    for (k, rt) in ["3.2.1", "", nil].enumerated() {
        let base = NSTemporaryDirectory() + "ejm-pubrefs-\(getpid())-\(k)", inDir = base + "/set", outDir = base + "/out"
        try? fm.removeItem(atPath: base)
        try! fm.createDirectory(atPath: inDir, withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        let jpeg = Turbo.encode(Synth.make(width: 64, height: 48, seed: 3), 64, 48, quality: 90, samp: 2)
        try! jpeg.write(to: URL(fileURLWithPath: inDir + "/small.jpg"))
        try! "\(sha(jpeg))  small.jpg\n".write(toFile: inDir + "/SHA256SUMS", atomically: true, encoding: .utf8)
        try! #"{"reference": "libjpeg-turbo 3.2.1"}"#.write(toFile: outDir + "/public-refs.json", atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["export-public", outDir, inDir]
        var env = ProcessInfo.processInfo.environment
        env["EJM_TEST_TURBO_RUNTIME"] = rt
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe
        try! p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        p.waitUntilExit()
        let raw = try? Data(contentsOf: URL(fileURLWithPath: outDir + "/public-refs.json"))
        let doc = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let ref = doc?["reference"] as? String
        let name = rt.map { $0.isEmpty ? "an unknown runtime" : "runtime \($0)" } ?? "the real runtime (\(Turbo.version))"
        if rt == nil && Turbo.runtimeVersion == Turbo.target {
            let files = doc?["files"] as? [[String: Any]] ?? []
            let noPath = raw.map { !String(decoding: $0, as: UTF8.self).contains(base) } ?? false
            t.check(p.terminationStatus == 0 && ref == "libjpeg-turbo \(Turbo.target)" && files.count == 1 && noPath
                    && fm.fileExists(atPath: outDir + "/set/small.jpg"),
                    "\(name): public-refs.json written, reference \(ref ?? "none"), \(files.count) file, no absolute path \(noPath): \(out)")
        } else {
            t.check(p.terminationStatus != 0 && ref == nil, "\(name): export-public refused, no public-refs.json left (reference \(ref ?? "none")): \(out)")
        }
    }
}
