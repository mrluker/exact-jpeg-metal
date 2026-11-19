import Foundation
import Metal
import CryptoKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import UIKit
import ExactJPEG

// The checks of `ejm corpus`, `ejm encode-corpus` and the libjpeg-turbo-free part of `ejm api-check`, plus the
// timings of `ejm decode` / `ejm encode` / small images, on an iOS device. There is no libjpeg-turbo here: every
// result is compared with SHA-256 hashes of libjpeg-turbo 3.2.0's output, from the committed manifest
// (testdata/manifest-libjpeg-turbo-3.2.0.json) and from Corpus/bench/bench.json (written by `ejm export-corpus`).

func sha(_ p: UnsafeRawBufferPointer) -> String { SHA256.hash(data: p).map { String(format: "%02x", $0) }.joined() }
func sha(_ d: Data) -> String { d.withUnsafeBytes { sha($0) } }
func sha(_ b: [UInt8]) -> String { b.withUnsafeBytes { sha($0) } }
func now() -> Double { CFAbsoluteTimeGetCurrent() }
func fmt(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

func thermalName(_ t: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
    switch t { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown" }
}

func sysctlString(_ name: String) -> String {
    var n = 0
    guard sysctlbyname(name, nil, &n, nil, 0) == 0, n > 0 else { return "?" }
    var b = [CChar](repeating: 0, count: n)
    guard sysctlbyname(name, &b, &n, nil, 0) == 0 else { return "?" }
    return String(cString: b)
}

func modelIdentifier() -> String {
    var u = utsname(); uname(&u)
    return withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// this process's memory footprint and what iOS still allows it, in MB
func memMB() -> String {
    var info = task_vm_info_data_t()
    var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
    let fp = r == KERN_SUCCESS ? Int(info.phys_footprint) / 1_000_000 : -1
    return "footprint \(fp) MB, available \(os_proc_available_memory() / 1_000_000) MB"
}

/// images counted and an all-exact flag, shared by two timing threads
/// two encoders for the two-thread encode timing (one per thread; the first is the timed one)
final class TwoEncoders: @unchecked Sendable {
    final class Times { var v: [Double] = [] }
    var encs = [Encoder(), Encoder()]
    let gpu = [Times(), Times()]
}

final class Slot2: @unchecked Sendable {
    private let lock = NSLock(); private(set) var n = 0, ok = true
    func add(_ k: Int, _ good: Bool) { lock.lock(); n += k; ok = ok && good; lock.unlock() }
}

func sharedBuffer(_ px: [UInt8], _ dev: MTLDevice) -> MTLBuffer {
    px.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 1), options: .storageModeShared)! }
}

final class Runner {
    let timingOnly: Bool
    let profileOnly = ProcessInfo.processInfo.arguments.contains("--decode-profile")
    let abOnly = ProcessInfo.processInfo.arguments.contains("--decode-ab")
    let loadOnly = ProcessInfo.processInfo.arguments.contains("--load-routing")
    let publicOnly = ProcessInfo.processInfo.arguments.contains("--public")
    let report: (String?, String?) -> Void
    var results: [String: Any] = [:]
    var failures: [String] = []
    let bundle = Bundle.main.resourceURL!
    let warmupSeconds = 1.0, discard = 3, iters = 10

    init(timingOnly: Bool, report: @escaping (String?, String?) -> Void) { self.timingOnly = timingOnly; self.report = report }

    func say(_ s: String) { print(s); report(s, nil) }
    func status(_ s: String) { report(nil, s) }
    func fail(_ s: String) { failures.append(s); say("  MISMATCH \(s)") }

    func run() -> String {
        let t0 = now()
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: Date()) }()
        results["started"] = ISO8601DateFormatter().string(from: Date())
        results["mode"] = publicOnly ? "public" : loadOnly ? "load-routing" : abOnly ? "decode-ab" : profileOnly ? "decode-profile" : timingOnly ? "timing-only" : "full"
        device()
        if publicOnly {
            status("public"); autoreleasepool { publicBench() }
        } else if loadOnly {
            status("load routing"); autoreleasepool { loadRouting() }
        } else if abOnly {
            status("decode A/B"); autoreleasepool { decodeAB() }
        } else if profileOnly {
            status("decode profile"); autoreleasepool { decodeProfile() }
        } else if !timingOnly {
            // the hashes the formats and EXIF/ICC checks compare with must be libjpeg-turbo 3.2.0's (run-device.sh
            // and ejm export-corpus refuse others; this catches a refs.json bundled some other way)
            let ref = refs?["reference"] as? String ?? "missing"
            if ref != "libjpeg-turbo 3.2.0" { fail("Corpus/refs.json reference is \(ref), not libjpeg-turbo 3.2.0 (re-run ejm export-corpus)") }
            // autoreleasepool per phase: this thread has no run loop, so Metal's autoreleased objects (command
            // buffers and what they hold) would otherwise pile up across phases (the first full run was killed by
            // the memory limit in the timing section)
            status("decoder corpus"); autoreleasepool { decodeCorpus() }; say("memory after decoder corpus: \(memMB())")
            status("encoder corpus"); autoreleasepool { encodeCorpus() }; say("memory after encoder corpus: \(memMB())")
            status("API checks"); autoreleasepool { apiChecks() }; say("memory after API checks: \(memMB())")
        }
        if !profileOnly && !abOnly && !loadOnly && !publicOnly { status("timing"); autoreleasepool { timing() } }
        var d = results["device"] as! [String: Any]
        d["thermal_end"] = thermalName()
        results["device"] = d
        results["failures"] = failures
        results["seconds"] = now() - t0
        let file = "results-\(stamp)\(publicOnly ? "-public" : loadOnly ? "-loadrouting" : abOnly ? "-ab" : profileOnly ? "-profile" : timingOnly ? "-timing" : "").json"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let js = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try! js.write(to: docs.appendingPathComponent(file))
        say("failures: \(failures.count)")
        say("total \(fmt(now() - t0, 1)) s; thermal at end: \(thermalName())")
        say("RESULTS_FILE \(file)")
        return file
    }

    // MARK: device

    func device() {
        let dev = MetalContext.shared.device
        let pi = ProcessInfo.processInfo
        var d: [String: Any] = [
            "model_identifier": modelIdentifier(), "mtl_device": dev.name,
            "supports_apple7": dev.supportsFamily(.apple7), "supports_apple8": dev.supportsFamily(.apple8),
            "supports_apple9": dev.supportsFamily(.apple9),
            "recommended_max_working_set_size": dev.recommendedMaxWorkingSetSize,
            "max_threadgroup_memory_length": dev.maxThreadgroupMemoryLength, "max_buffer_length": dev.maxBufferLength,
            "ios_version": UIDevice.current.systemVersion, "ios_build": sysctlString("kern.osversion"),
            "thermal_start": thermalName(), "processor_count": pi.processorCount,
            "active_processor_count": pi.activeProcessorCount, "physical_memory": pi.physicalMemory,
            "low_power_mode": pi.isLowPowerModeEnabled,
            "metal_compile_ms": MetalContext.shared.compileSeconds * 1000,
            "cpu_reference": "libjpeg-turbo is not available on iOS: the CPU comparison is ImageIO (Apple's codec); exactness is checked against SHA-256 hashes of libjpeg-turbo 3.2.0 output",
        ]
        let t = now(); MetalContext.shared.warmUp(); d["warmup_pipelines_ms"] = (now() - t) * 1000
        results["device"] = d
        for k in d.keys.sorted() { say("device \(k): \(d[k]!)") }
        profile()
    }

    // MARK: device profile

    /// DeviceProfile: layer 1 (from the reported properties) and the routing numbers, estimated and then measured
    /// (the background measurement the first read starts; waited for here so it does not overlap the timings).
    /// The cache is cleared first so every run measures.
    func profile() {
        DeviceProfile.clearCache()
        let p = DeviceProfile.current
        let layer1 = p.dictionary
        say("profile layer 1: \(p.summary)")
        let t = now()
        let m = p.measuredRouting(timeout: 30)
        let waited = (now() - t) * 1000
        say("profile routing (\(p.routingSource.rawValue), waited \(fmt(waited, 1)) ms): \(p.summary)")
        if let m { say("profile measurement cost: \(fmt(m.measurementMs, 1)) ms wall, \(fmt(m.measurementGPUMs, 1)) ms GPU") }
        else { say("profile: no measurement (\(p.measurementFailureReason ?? "deferred: hot or Low Power Mode, or timed out")): \(p.summary)") }
        func crossover(_ op: DeviceProfile.Operation) -> Double {
            let r = p.routing
            let cpu = op == .decode ? DeviceProfile.defaultCPUDecodeMsPerMP : DeviceProfile.defaultCPUEncodeMsPerMP
            let fixed = op == .decode ? r.decodeFixedMs : r.encodeFixedMs, slope = op == .decode ? r.decodeMsPerMP : r.encodeMsPerMP
            return cpu > slope ? fixed / (cpu - slope) : 0
        }
        results["device_profile"] = ["layer1": layer1, "measured": p.dictionary, "waited_ms": waited,
                                     "decode_crossover_mp_default_cpu": crossover(.decode), "encode_crossover_mp_default_cpu": crossover(.encode)]
    }

    // MARK: decoder corpus

    func loadJSON(_ url: URL) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    lazy var manifest: [String: Any] = loadJSON(bundle.appendingPathComponent("manifest-libjpeg-turbo-3.2.0.json"))
    var decEntries: [[String: Any]] { manifest["decode"] as! [[String: Any]] }
    var corpusData: [String: Data] = [:]    // verified bundled files, by name

    func corpusFile(_ name: String) -> Data? { try? Data(contentsOf: bundle.appendingPathComponent("Corpus/\(name).jpg")) }

    /// libjpeg-turbo's own output for cases the manifest has no hash for (.bgr/.rgba/.bgra decodes, EXIF and ICC
    /// encodes), written by `ejm export-corpus` on the Mac (Corpus/refs.json; Corpus.swift exportDeviceRefs)
    lazy var refs: [String: Any]? = (try? Data(contentsOf: bundle.appendingPathComponent("Corpus/refs.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    var refFormats: [String: [String: String]] { refs?["formats"] as? [String: [String: String]] ?? [:] }

    func decodeCorpus() {
        say("== decoder corpus: \(decEntries.count) manifest files (reference \(manifest["reference"] ?? "?"))")
        let dec = Decoder()
        var ok = 0, declined = 0, wrong = 0, unexpected = 0, bundleBad = 0, missing = 0
        var fmtOK = 0, fmtBad = 0
        let t0 = now()
        for (k, e) in decEntries.enumerated() {
            let name = e["name"] as! String
            if k % 20 == 0 { status("decoder corpus \(k)/\(decEntries.count)") }
            guard let data = corpusFile(name) else { missing += 1; fail("\(name): not bundled"); continue }
            guard sha(data) == e["jpeg"] as? String else { bundleBad += 1; fail("\(name): bundled file differs from the manifest's jpeg hash"); continue }
            corpusData[name] = data
            let expect = e["gpu_expected"] as! Bool
            for (fmt, key) in [(PixelFormat.rgb, "rgb"), (.gray, "gray")] {
                let img = dec.decode(data, format: fmt)
                if !expect {
                    if img == nil { declined += 1 } else { unexpected += 1; fail("\(name) \(key): should have declined") }
                    continue
                }
                guard let img else { unexpected += 1; fail("\(name) \(key): declined (\(dec.reason ?? "?"))"); continue }
                guard sha(img.bytes) == e[key] as? String else { wrong += 1; fail("\(name) \(key): DIFFERENT from libjpeg-turbo 3.2.0"); continue }
                ok += 1
                // api-check `formats` / `gray-rgba`: .bgr, .rgba, .bgra equal libjpeg-turbo's decode to that format
                // (hashes from refs.json; a missing hash is a failure)
                if fmt == .rgb {
                    for (f, fk) in [(PixelFormat.bgr, "bgr"), (.rgba, "rgba"), (.bgra, "bgra")] {
                        guard let want = refFormats[name]?[fk] else { fmtBad += 1; fail("\(name) \(fk): no libjpeg-turbo hash in Corpus/refs.json"); continue }
                        if let o = dec.decode(data, format: f), sha(o.bytes) == want { fmtOK += 1 } else {
                            fmtBad += 1; fail("\(name) \(fk): DIFFERENT from libjpeg-turbo's decode to \(fk) (\(dec.reason ?? "decoded"))")
                        }
                    }
                }
            }
        }
        say("decoder: exact \(ok), wrong \(wrong), declined as expected \(declined), unexpected decline/accept \(unexpected); bundled-file hash mismatches \(bundleBad), missing \(missing) (\(fmt(now() - t0, 1)) s)")
        say("formats (.bgr/.rgba/.bgra vs libjpeg-turbo's decodes, refs.json from \(refs?["reference"] ?? "MISSING")): \(fmtOK) identical, \(fmtBad) different")
        results["decode"] = ["files": decEntries.count, "decodes_exact": ok, "wrong": wrong, "declined_as_expected": declined,
                             "unexpected": unexpected, "bundled_hash_mismatch": bundleBad, "missing": missing, "seconds": now() - t0]
        results["api_formats"] = ["identical": fmtOK, "different": fmtBad,
                                  "reference": refs?["reference"] ?? "missing",
                                  "what": "every GPU-decodable corpus file decoded to .bgr, .rgba, .bgra equals libjpeg-turbo's decode to that format (SHA-256 from Corpus/refs.json, ejm export-corpus); gray files included"]
    }

    // MARK: encoder corpus

    func encodeCorpus() {
        let enc = Encoder(), dev = enc.ctx.device
        let cases = encodeCases()
        let entries = manifest["encode"] as! [[String: Any]]
        say("== encoder corpus: \(cases.count) cases, manifest \(entries.count)")
        guard cases.count == entries.count else { fail("encoder case count \(cases.count) != manifest \(entries.count)"); return }
        var ok = 0, bad = 0, srcOK = 0, srcBad = 0
        var buf: (key: String, b: MTLBuffer)? = nil
        let t0 = now()
        for (k, (c, e)) in zip(cases, entries).enumerated() {
            if k % 24 == 0 { status("encoder corpus \(k)/\(cases.count)") }
            guard c.name == e["name"] as? String else { fail("case \(k): name \(c.name) != manifest \(e["name"] ?? "?")"); bad += 1; continue }
            if let s = e["source"] as? String {
                if sha(c.src) == s { srcOK += 1 } else { srcBad += 1; fail("\(c.name): synthetic source differs from the manifest (generator drift)") }
            }
            let key = "\(c.w)x\(c.h)/\(c.src.count)/\(c.name.split(separator: "_")[2])"
            if buf?.key != key { buf = (key, sharedBuffer(c.src, dev)) }
            let ss: Subsampling = [.s444, .s422, .s420][c.samp]
            do {
                let got = try enc.encode(buffer: buf!.b, width: c.w, height: c.h, quality: c.q, subsampling: ss)
                if sha(got) == e["jpeg"] as? String { ok += 1 } else { bad += 1; fail("\(c.name): encode DIFFERENT from libjpeg-turbo 3.2.0 (\(got.count) bytes)") }
            } catch { bad += 1; fail("\(c.name): threw \(error)") }
        }
        let manifestCases = ok + bad
        // RGBA input with padded rows gives the bytes of the manifest's RGB case
        if let e = entries.first(where: { $0["name"] as? String == "enc_97x203_smooth_s2_q90" }),
           let c = cases.first(where: { $0.name == "enc_97x203_smooth_s2_q90" }) {
            var rgba = [UInt8](repeating: 0, count: c.h * 1000)
            for y in 0..<c.h { for x in 0..<c.w { for ch in 0..<3 { rgba[y * 1000 + x * 4 + ch] = c.src[(y * c.w + x) * 3 + ch] } } }
            let g = try? enc.encode(buffer: sharedBuffer(rgba, dev), width: c.w, height: c.h, channels: 4, rowBytes: 1000, quality: 90, subsampling: .s420)
            if let g, sha(g) == e["jpeg"] as? String { ok += 1 } else { bad += 1; fail("RGBA padded rows (enc_97x203_smooth_s2_q90): DIFFERENT") }
        }
        // EXIF blocks of 4 lengths move the scan to each byte offset mod 4; ICC profiles of one to several chunks,
        // and EXIF + ICC: whole files against libjpeg-turbo's (tr_encode_meta) hashes in refs.json
        var metaCases = 0
        let exifRefs = refs?["exif"] as? [[String: Any]] ?? [], iccRefs = refs?["icc"] as? [[String: Any]] ?? []
        if exifRefs.count != 4 || iccRefs.count != 10 { bad += 1; fail("refs.json: \(exifRefs.count) EXIF and \(iccRefs.count) ICC references, expected 4 and 10 (re-run ejm export-corpus)") }
        for e in exifRefs + iccRefs {
            metaCases += 1
            guard let cn = e["case"] as? String, let c = cases.first(where: { $0.name == cn }), let q = e["quality"] as? Int, let samp = e["samp"] as? Int,
                  let want = e["jpeg"] as? String else { bad += 1; fail("refs.json: malformed entry \(e)"); continue }
            var exif: Data? = nil, icc: Data? = nil
            if let n = e["length"] as? Int, let b = e["byte"] as? Int { exif = Data(repeating: UInt8(b), count: n) }
            if let f = e["exif_file"] as? String { exif = try? Data(contentsOf: bundle.appendingPathComponent("Corpus/\(f)")); if exif == nil { bad += 1; fail("\(f): not bundled"); continue } }
            if let f = e["icc_file"] as? String { icc = try? Data(contentsOf: bundle.appendingPathComponent("Corpus/\(f)")); if icc == nil { bad += 1; fail("\(f): not bundled"); continue } }
            let ss: Subsampling = [.s444, .s422, .s420][samp]
            let what = "\(cn) q\(q) \(ss)\(exif.map { " EXIF \($0.count) B" } ?? "")\(icc.map { " ICC \($0.count) B" } ?? "")"
            let got = try? enc.encode(buffer: sharedBuffer(c.src, dev), width: c.w, height: c.h, quality: q, subsampling: ss, icc: icc, exif: exif)
            if let got, sha(got) == want { ok += 1 } else { bad += 1; fail("\(what): DIFFERENT from libjpeg-turbo (\(got?.count ?? -1) bytes)") }
        }
        say("encoder: identical \(ok), different \(bad) (\(manifestCases) manifest cases, RGBA padded rows, \(metaCases) EXIF/ICC cases from refs.json); sources match \(srcOK), differ \(srcBad) (\(fmt(now() - t0, 1)) s)")
        results["encode"] = ["cases": ok + bad, "manifest_cases": manifestCases, "identical": ok, "different": bad,
                             "sources_match": srcOK, "sources_differ": srcBad, "seconds": now() - t0,
                             "extra_cases": "RGBA with padded rows (vs the manifest hash of enc_97x203_smooth_s2_q90); EXIF of 10-13 bytes and ICC (one to four chunks, and EXIF + ICC) at 4:4:4 and 4:2:0 (vs libjpeg-turbo's hashes in Corpus/refs.json)",
                             "meta_cases": metaCases, "refs_reference": refs?["reference"] ?? "missing"]
    }

    // MARK: API checks without libjpeg-turbo

    func entry(_ name: String) -> [String: Any]? { decEntries.first { $0["name"] as? String == name } }

    func apiChecks() {
        say("== API checks (the libjpeg-turbo-free part of ejm api-check, against manifest hashes)")
        var out: [String: Any] = [:]
        var tally: [String: (Int, Int)] = [:]
        func check(_ group: String, _ cond: Bool, _ what: @autoclosure () -> String) {
            var t = tally[group] ?? (0, 0)
            if cond { t.0 += 1 } else { t.1 += 1; fail("api \(group): \(what())") }
            tally[group] = t
        }
        let dec = Decoder(), dev = dec.ctx.device
        let usable = decEntries.filter { ($0["gpu_expected"] as! Bool) && corpusData[$0["name"] as! String] != nil }

        // output: decode(bytes:output:) and decode(buffer:length:output:) into caller buffers; one byte short declines
        for e in usable where !(e["name"] as! String).hasPrefix("tj_6720x4480") {
            let name = e["name"] as! String, data = corpusData[name]!
            guard let h = try? data.withUnsafeBytes({ try parseJPEGHeader($0) }) else { check("output", false, "\(name): header"); continue }
            for (fmt, key) in [(PixelFormat.rgb, "rgb"), (.gray, "gray")] {
                let need = h.width * h.height * fmt.channels
                for extra in [0, 4096] {
                    let ob = dev.makeBuffer(length: need + extra, options: .storageModeShared)!
                    let img = data.withUnsafeBytes { dec.decode(bytes: $0, format: fmt, output: ob) }
                    check("output", img != nil && img!.buffer === ob && img!.offset == 0 && sha(img!.bytes) == e[key] as? String, "decode(bytes:output:) \(name) \(key) +\(extra)")
                }
                let ib = data.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count + 100, options: .storageModeShared)! }
                let ob = dev.makeBuffer(length: need, options: .storageModeShared)!
                let img = dec.decode(buffer: ib, length: data.count, format: fmt, output: ob)
                check("output", img != nil && img!.buffer === ob && sha(img!.bytes) == e[key] as? String, "decode(buffer:length:output:) \(name) \(key)")
                if need > 1 {
                    let small = dev.makeBuffer(length: need - 1, options: .storageModeShared)!
                    let r = data.withUnsafeBytes { dec.decode(bytes: $0, format: fmt, output: small) }
                    check("output", r == nil && dec.reason == "output buffer too small", "output one byte short, \(name) \(key): \(dec.reason ?? "accepted")")
                }
            }
        }

        // tuning and eager-range: non-default eagerPasses, chunkBits, checkpoints give the manifest bytes
        let tuneNames = ["tj_480x640_s2_rst7", "tj_480x640_gray_rst3", "tj_97x203_s1_rst1", "tj_480x640_s0_rstrow", "tj_480x640_s2_opt"]
        let tune = tuneNames.compactMap { n in entry(n).flatMap { e in corpusData[n].map { (n, $0, e["rgb"] as! String) } } }
        check("tuning", tune.count == tuneNames.count, "tuning files missing: \(tune.map(\.0))")
        for g in [1, 2, 4, 16, 64, 0, -1, 65, 1000] {
            let d = Decoder(); d.eagerPasses = g
            check("eager-range", (1...64).contains(d.eagerPasses), "eagerPasses = \(g) reads back \(d.eagerPasses)")
            for (n, data, want) in tune {
                let img = d.decode(data)
                check(g >= 1 && g <= 64 ? "tuning" : "eager-range", img.map { sha($0.bytes) } == want && (1...64).contains(d.passes), "eagerPasses \(g), \(n): \(img == nil ? "declined \(d.reason ?? "?")" : "differs")")
            }
        }
        for bits in [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536] {
            for cp in [nil, 1, 2, 3, 7, 15, 31] as [Int?] {
                let d = Decoder(); d.chunkBits = bits; d.checkpoints = cp
                for (n, data, want) in tune {
                    let img = d.decode(data)
                    check("tuning", img.map { sha($0.bytes) } == want, "chunkBits \(bits) checkpoints \(cp.map(String.init) ?? "nil") \(n): \(img == nil ? "declined \(d.reason ?? "?")" : "differs")")
                }
            }
        }

        // decline-untouched (Swift output: only; the C API is not in this app)
        var declinedInputs: [(String, Data)] = decEntries.filter { !($0["gpu_expected"] as! Bool) }.compactMap { e in
            corpusData[e["name"] as! String].map { (e["name"] as! String, $0) } }
        if let base = corpusData["tj_480x640_smooth_420_q50"] ?? usable.first(where: { ($0["name"] as! String).hasPrefix("tj_480x640_smooth_420") }).flatMap({ corpusData[$0["name"] as! String] }) {
            for m: UInt8 in [0xD8, 0xC4] { var d = base; d[d.count - 1] = m; declinedInputs.append(("trailer FF\(String(m, radix: 16, uppercase: true))", d)) }
            let s0 = try! base.withUnsafeBytes { try parseJPEGHeader($0) }.scanStart
            var rng: UInt64 = 12345, corrupt = 0
            func next() -> UInt64 { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng }
            for _ in 0..<400 where corrupt < 6 {
                var d = base
                let at = s0 + Int(next() % UInt64(d.count - s0 - 64))
                for k in 0..<3 { d[at + k] = UInt8(truncatingIfNeeded: next()) }
                if dec.decode(d) == nil, let r = dec.reason, !r.contains("after the scan") { declinedInputs.append(("corrupt at \(at): \(r)", d)); corrupt += 1 }
            }
        } else { check("decline-untouched", false, "no 480x640 4:2:0 base file") }
        if let r = corpusData["tj_480x640_s2_rst7"], let i = (r.startIndex..<(r.count - 1)).first(where: { r[$0] == 0xFF && r[$0 + 1] == 0xD3 }) {
            var d = r; d[i + 1] = 0xD5; declinedInputs.append(("RST3 renumbered", d))
        }
        for (name, d) in declinedInputs {
            guard let h = try? d.withUnsafeBytes({ try parseJPEGHeader($0) }) else { continue }
            for fmt in [PixelFormat.rgb, .rgba, .gray] {
                let need = max(h.width * h.height * fmt.channels, 1)
                let ob = dev.makeBuffer(length: need, options: .storageModeShared)!
                memset(ob.contents(), 0xA5, need)
                let img = d.withUnsafeBytes { dec.decode(bytes: $0, format: fmt, output: ob) }
                let ub = UnsafeRawBufferPointer(start: ob.contents(), count: need)
                check("decline-untouched", img == nil && ub.allSatisfy { $0 == 0xA5 }, "\(name) \(fmt): declined \(img == nil), output touched \(!ub.allSatisfy { $0 == 0xA5 })")
            }
        }
        // trailers the decoder accepts (pixels of the base file) and rejects
        if let e = usable.first(where: { ($0["name"] as! String).hasPrefix("tj_97x203_smooth_422") }), let base = corpusData[e["name"] as! String] {
            let body = base.prefix(base.count - 2), want = e["rgb"] as! String
            let accepted: [(String, Data)] = [
                ("EOI then junk", base + Data([1, 2, 3, 0xFF, 0xC4])), ("fill bytes before EOI", body + Data([0xFF, 0xFF, 0xFF, 0xD9])),
                ("COM after the scan", body + Data([0xFF, 0xFE, 0, 5, 65, 66, 67, 0xFF, 0xD9])),
                ("APP15 after the scan", body + Data([0xFF, 0xEF, 0, 2, 0xFF, 0xD9])), ("no EOI", Data(body)),
            ]
            for (n, d) in accepted { let img = dec.decode(d); check("decline-untouched", img.map { sha($0.bytes) } == want, "\(n): \(img == nil ? "declined \(dec.reason ?? "?")" : "differs")") }
            let rejected: [(String, Data)] = [
                ("APP segment running past the end", body + Data([0xFF, 0xE1, 0, 50, 1])), ("truncated APP marker", body + Data([0xFF, 0xE1, 0])),
                ("APP length 1", body + Data([0xFF, 0xE1, 0, 1, 0xFF, 0xD9])), ("SOF marker after EOI-less scan", body + Data([0xFF, 0xC0, 0, 2])),
            ]
            for (n, d) in rejected { let img = dec.decode(d); check("decline-untouched", img == nil && dec.reason?.contains("after the scan") == true, "\(n): \(img == nil ? dec.reason ?? "?" : "accepted")") }
        }

        // header-limits
        func throwsInvalid(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch is InvalidInput { return true } catch { return false } }
        let maxICC = 255 * 65519
        check("header-limits", throwsInvalid { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, exif: Data(count: 65534)) }, "65534-byte EXIF accepted")
        check("header-limits", throwsInvalid { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, icc: Data(count: maxICC + 1)) }, "oversized ICC accepted")
        check("header-limits", !throwsInvalid { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, icc: Data(count: maxICC), exif: Data(count: 65533)) }, "largest allowed blocks rejected")
        let enc = Encoder(), px = [UInt8](repeating: 128, count: 8 * 8 * 3)
        for (icc, exif) in [(nil, Data(count: 65534)), (Data(count: maxICC + 1), nil)] as [(Data?, Data?)] {
            check("header-limits", throwsInvalid { _ = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8, icc: icc, exif: exif) } }, "Encoder.encode accepted an oversized block")
        }

        // warmup: after warmUp(), decodes in every format and encodes build no new pipeline states
        let ctx = try! MetalContext()
        ctx.warmUp()
        let n0 = ctx.pipelineCount
        let d2 = Decoder(ctx: ctx), e2 = Encoder(ctx: ctx)
        for n in tuneNames + ["tj_97x203_smooth_411_q90", "tj_97x203_edges_440_q1"] { if let data = corpusData[n] { for f in [PixelFormat.rgb, .bgr, .gray, .rgba, .bgra] { _ = d2.decode(data, format: f) } } }
        for e in usable.prefix(60) { if let data = corpusData[e["name"] as! String] { _ = d2.decode(data) } }
        let sp = corpusContent(321, 123, "smooth", 3)
        for ss in [Subsampling.s444, .s422, .s420] {
            _ = try? sp.withUnsafeBytes { try e2.encode(bytes: $0, width: 321, height: 123, subsampling: ss) }
            _ = try? e2.encodeBatch([EncodeJob(buffer: sharedBuffer(sp, ctx.device), width: 321, height: 123, subsampling: ss)])
        }
        e2.fusedMaxBlocks = 0
        _ = try? sp.withUnsafeBytes { try e2.encode(bytes: $0, width: 321, height: 123) }
        check("warmup", ctx.pipelineCount == n0, "warmUp built \(n0) pipelines; decoding and encoding then built \(ctx.pipelineCount - n0) more")

        for (g, t) in tally.sorted(by: { $0.key < $1.key }) {
            say("api \(g): \(t.0) passed, \(t.1) failed"); out[g] = ["passed": t.0, "failed": t.1]
        }
        out["formats"] = results["api_formats"]
        out["skipped"] = ["c-api: the C API (ExactJPEGC) is not linked into the app",
                          "warmup source check: reads the .metal sources from the repository; the pipeline-count part ran"]
        out["notes"] = "eager-range, tuning, output, decline-untouched (Swift output: only), header-limits and warmup run against manifest hashes or the declined/accepted contract; formats and icc (in the encoder corpus) against libjpeg-turbo hashes from Corpus/refs.json; trailer and corruption cases are derived from corpus files"
        results["api"] = out
        results.removeValue(forKey: "api_formats")
    }

    // MARK: decode profile

    /// per-stage GPU time of the decode of three bench inputs (DecodeProfile.swift), 3 interleaved rounds; each
    /// file's full decode is first checked against its libjpeg-turbo hash
    func decodeProfile() {
        let bench = loadJSON(bundle.appendingPathComponent("Corpus/bench/bench.json"))
        let lp = ProcessInfo.processInfo.isLowPowerModeEnabled
        say("== decode profile; Low Power Mode \(lp), thermal \(thermalName())")
        let empty = emptyDispatchCost(), mem = decodeKernelMemory()
        say("profile empty dispatches: \(empty)")
        say("profile threadgroup memory: \(mem)")
        var rows: [[String: Any]] = []
        for c in bench["decode"] as! [[String: Any]] {
            let label = c["label"] as! String, file = c["file"] as! String
            guard ["640x480 q90 4:2:0", "1600x1200 q90 4:2:0", "2048x1536 q90 4:2:0", "6720x4480 q90 4:2:0"].contains(label) else { continue }
            status("decode profile \(label)")
            let th = waitCool("profile \(label)")
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Corpus/bench/\(file)")), sha(data) == c["jpeg"] as? String else {
                fail("profile input \(file): missing or differs from bench.json"); continue
            }
            // autoreleasepool: this thread has no run loop, and the Metal objects of a 6720x4480 profile otherwise
            // stay alive into the next file (the app was killed for memory once)
            let ok = autoreleasepool { () -> Bool in
                let dec = Decoder()
                guard let img = dec.decode(data), sha(img.bytes) == c["rgb"] as? String else { fail("profile \(label): not exact (\(dec.reason ?? "differs"))"); return false }
                warm { _ = dec.decode(data) }
                return true
            }
            guard ok else { continue }
            var (lines, js) = autoreleasepool { decodeProfileReport(label: label, jpeg: data, rounds: 3, reps: 7) }
            js["thermal_before"] = th; js["thermal_after"] = thermalName(); js["low_power_mode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
            lines.forEach(say)
            let (cl, cj) = autoreleasepool { clockExperiments(data, label: label) }
            cl.forEach(say)
            js["clock"] = cj
            rows.append(js)
        }
        // the GPU clock over time from idle (DecodeProfile.swift clockTrajectories), 1600x1200 and 640x480
        var traj: [String: Any] = [:]
        let byLabel = Dictionary(uniqueKeysWithValues: (bench["decode"] as! [[String: Any]]).map { ($0["label"] as! String, $0["file"] as! String) })
        let big = byLabel["6720x4480 q90 4:2:0"].flatMap { try? Data(contentsOf: bundle.appendingPathComponent("Corpus/bench/\($0)")) }
        for label in ["1600x1200 q90 4:2:0", "640x480 q90 4:2:0"] {
            guard let f = byLabel[label], let data = try? Data(contentsOf: bundle.appendingPathComponent("Corpus/bench/\(f)")) else { continue }
            status("clock trajectories \(label)")
            say("== clock trajectories \(label); thermal \(thermalName()), Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
            let (tl, tj) = autoreleasepool { clockTrajectories(data, big: big) }
            tl.forEach(say)
            traj[label] = tj
        }
        results["clock_trajectories"] = traj
        results["decode_profile"] = ["rows": rows, "empty_dispatches": empty, "threadgroup_memory": mem, "low_power_mode_before": lp,
                                     "low_power_mode_after": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                     "method": "Decoder.profileStopAfter = k encodes the first k dispatches; GPU time of prefix k minus prefix k - 1 = dispatch k; prefixes interleaved in 3 rounds of 7 calls each; median per prefix (runs 1-3 of 2026-11-17 used the minimum)"]
    }

    /// chunkBits 4096 / 2048 on the bench inputs up to 1600x1200, one and two decoder threads (DecodeProfile.swift chunkAB)
    func decodeAB() {
        let bench = loadJSON(bundle.appendingPathComponent("Corpus/bench/bench.json"))
        say("== decode A/B (chunkBits); Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled), thermal \(thermalName())")
        var rows: [[String: Any]] = []
        for c in bench["decode"] as! [[String: Any]] {
            let label = c["label"] as! String, file = c["file"] as! String
            guard ["64x64 q90 4:2:0", "256x256 q90 4:2:0", "488x480 q90 4:2:0", "640x480 q90 4:2:0", "1024x768 q90 4:2:0", "1600x1200 q90 4:2:0"].contains(label) else { continue }
            status("decode A/B \(label)")
            let th = waitCool("A/B \(label)")
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Corpus/bench/\(file)")), sha(data) == c["jpeg"] as? String,
                  let img = Decoder().decode(data), sha(img.bytes) == c["rgb"] as? String else { fail("A/B \(label): input or default decode not exact"); continue }
            let want = Array(img.bytes)
            say("ab \(label); thermal \(th)")
            let (l, j, ok) = chunkAB(data, want: want, bits: [4096, 2048])
            l.forEach(say)
            if !ok { fail("A/B \(label): a chunkBits setting gave DIFFERENT bytes") }
            rows.append(["case": label, "thermal_before": th, "thermal_after": thermalName(), "configs": j])
        }
        results["decode_ab"] = ["rows": rows, "low_power_mode_after": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                "method": "configurations interleaved, 4 rounds of a 1.6 s slice each (only the second half timed), 1 and 2 decoder threads; wall per image = timed time / images; one output per decoder per slice compared byte for byte with the hash-verified default decode"]
    }

    // MARK: timing

    func waitCool(_ label: String) -> String {
        var t = ProcessInfo.processInfo.thermalState
        let t0 = now()
        while (t == .serious || t == .critical) && now() - t0 < 600 {
            status("thermal \(thermalName(t)): pausing before \(label)")
            say("  thermal \(thermalName(t)), pausing 15 s before \(label)")
            Thread.sleep(forTimeInterval: 15)
            t = ProcessInfo.processInfo.thermalState
        }
        return thermalName(t)
    }

    func warm(_ work: () -> Void) { let t0 = now(); while now() - t0 < warmupSeconds { work() } }

    func timed(_ work: () -> Double?) -> (wall: [Double], gpu: [Double]) {
        var w: [Double] = [], g: [Double] = []
        for k in 0..<(iters + discard) {
            let t = now(); let gp = work(); let dt = now() - t
            if k >= discard { w.append(dt); if let gp { g.append(gp) } }
        }
        return (w, g)
    }

    func cgImageRGB(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        rgba.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.interpolationQuality = .none
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2] }
        return rgb
    }

    func diff(_ a: UnsafeRawBufferPointer, _ b: [UInt8]) -> [String: Any] {
        guard a.count == b.count else { return ["error": "size \(a.count) vs \(b.count)"] }
        var maxd = 0, nz = 0, se = 0.0
        for i in 0..<b.count { let d = abs(Int(a[i]) - Int(b[i])); if d > 0 { nz += 1; maxd = max(maxd, d); se += Double(d * d) } }
        let psnr = se == 0 ? 999.0 : 10 * log10(255.0 * 255.0 / (se / Double(b.count)))
        return ["max_diff": maxd, "frac_values_differ": Double(nz) / Double(b.count), "psnr_db": psnr]
    }

    func imageIODecode(_ d: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func imageIOEncode(_ img: CGImage, quality: Double) -> Data {
        let d = NSMutableData()
        let dst = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dst)
        return d as Data
    }

    func cgImage(rgb: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: Data(rgb) as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func ms(_ x: Double) -> Double { (x * 1e6).rounded() / 1000 }

    func timing() {
        corpusData.removeAll()      // the verified corpus files are not needed for timing
        let bench = loadJSON(bundle.appendingPathComponent("Corpus/bench/bench.json"))
        var rows: [[String: Any]] = []
        let thermalBefore = thermalName(), lowPowerBefore = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPowerBefore { say("WARNING: Low Power Mode is on: these timings are not representative") }
        say("timing start: \(memMB())")
        say("== timing: median of \(iters) after \(warmupSeconds) s warm-up and \(discard) discarded calls; thermal \(thermalBefore)")
        let dec = Decoder()
        for c in bench["decode"] as! [[String: Any]] {
            let label = c["label"] as! String, file = c["file"] as! String
            status("timing decode \(label)")
            let th = waitCool("decode \(label)")
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Corpus/bench/\(file)")), sha(data) == c["jpeg"] as? String else {
                fail("timing input \(file): missing or differs from bench.json"); continue
            }
            guard let first = dec.decode(data) else { fail("decode \(label): declined (\(dec.reason ?? "?"))"); continue }
            let exact = sha(first.bytes) == c["rgb"] as? String
            if !exact { fail("decode \(label): DIFFERENT from libjpeg-turbo 3.2.0") }
            let gpuRef = Array(first.bytes)
            warm { _ = dec.decode(data) }
            let t = timed { _ = dec.decode(data); return dec.gpuSeconds }
            // two decoders on two threads (one command buffer always queued, which keeps an iPhone's GPU clock up):
            // images per second over 1.5 s after 0.5 s; the first counted decode of each thread compared with gpuRef.
            // The second decoder is freed before ImageIO runs (three 6720x4480 decoders plus ImageIO's images went
            // past the app's memory limit).
            let (per2, gpu2) = autoreleasepool { () -> (Double, Double) in
                let two = TwoDecoders()
                two.decs[0] = dec
                let ok2 = Slot2()
                let t2 = now()
                DispatchQueue.concurrentPerform(iterations: 2) { i in
                    var n = 0, good = true
                    while now() - t2 < 2.0 {
                        let img = two.decs[i].decode(data)
                        if now() - t2 >= 0.5 { n += 1; good = good && img != nil && (n != 1 || memcmp(img!.bytes.baseAddress!, gpuRef, gpuRef.count) == 0) }
                        if now() - t2 >= 0.5 { two.gpu[i].v.append(two.decs[i].gpuSeconds) }
                    }
                    ok2.add(n, good)
                }
                if !ok2.ok { fail("decode \(label), two threads: DIFFERENT or declined") }
                return (1.5 / Double(max(ok2.n, 1)), median(two.gpu[0].v + two.gpu[1].v))
            }
            // ImageIO (Apple's decoder) on the same file
            var io: [Double] = []
            var last: CGImage? = nil
            // autoreleasepool: ImageIO's images are autoreleased, and this thread has no run loop to drain them
            warm { autoreleasepool { last = imageIODecode(data) } }
            for _ in 0..<iters { autoreleasepool { let t0 = now(); last = imageIODecode(data); io.append(now() - t0) } }
            let vs: [String: Any] = autoreleasepool { last.map { img in cgImageRGB(img).withUnsafeBytes { diff($0, gpuRef) } } ?? ["error": "ImageIO failed"] }
            last = nil
            // ImageIO on two threads, images per second over 1.5 s after 0.5 s (the CPU counterpart of the two-decoder figure)
            let io2 = Slot2()
            let ti = now()
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                var n = 0, good = true
                while now() - ti < 2.0 { autoreleasepool { let img = imageIODecode(data); good = good && img != nil; if now() - ti >= 0.5 { n += 1 } } }
                io2.add(n, good)
            }
            let ioPer2 = 1.5 / Double(max(io2.n, 1))
            let row: [String: Any] = ["op": "decode", "case": label, "bytes": data.count, "exact": exact, "thermal": th,
                                      "metal_wall_ms": ms(median(t.wall)), "metal_gpu_ms": ms(median(t.gpu)), "metal_wall_min_ms": ms(t.wall.min()!),
                                      "imageio_ms": ms(median(io)), "imageio_vs_libjpeg_turbo": vs, "passes": dec.passes,
                                      "metal_two_threads_ms_per_image": ms(per2), "metal_two_threads_gpu_ms": ms(gpu2),
                                      "imageio_two_threads_ms_per_image": ms(ioPer2)]
            rows.append(row)
            say("decode \(label) (\(data.count / 1024) KB): \(exact ? "exact" : "DIFFERENT"), Metal wall \(fmt(median(t.wall) * 1000, 3)) ms, GPU \(fmt(median(t.gpu) * 1000, 3)) ms; two decoder threads \(fmt(per2 * 1000, 3)) ms per image (GPU \(fmt(gpu2 * 1000, 3))); ImageIO \(fmt(median(io) * 1000, 3)) ms, two threads \(fmt(ioPer2 * 1000, 3)) ms per image (vs libjpeg-turbo max \(vs["max_diff"] ?? "?"), PSNR \(fmt(vs["psnr_db"] as? Double ?? 0, 1)) dB); thermal \(th)")
        }
        let enc = Encoder()
        for c in bench["encode"] as! [[String: Any]] {
            let label = c["label"] as! String, w = c["width"] as! Int, h = c["height"] as! Int, q = c["quality"] as! Int, s = c["samp"] as! Int
            status("timing encode \(label)")
            let th = waitCool("encode \(label)")
            let a = Synth.make(width: w, height: h, seed: UInt32(c["seed"] as! Int))
            if sha(a) != c["source"] as? String { fail("encode \(label): synthetic source differs from bench.json") }
            let buf = sharedBuffer(a, enc.ctx.device), ss: Subsampling = [.s444, .s422, .s420][s]
            let got = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
            let exact = sha(got) == c["jpeg"] as? String
            if !exact { fail("encode \(label): DIFFERENT from libjpeg-turbo 3.2.0") }
            warm { _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss) }
            let t = timed { _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss); return enc.gpuSeconds }
            // two encoders on two threads (one command buffer always queued, the sustained case): images per second
            // over 1.5 s after 0.5 s; each thread's first counted output compared with the verified one
            let (encPer2, encGpu2) = autoreleasepool { () -> (Double, Double) in
                let two = TwoEncoders()
                two.encs[0] = enc
                let ok2 = Slot2()
                let t2 = now()
                DispatchQueue.concurrentPerform(iterations: 2) { i in
                    var n = 0, good = true
                    while now() - t2 < 2.0 {
                        let j = try? two.encs[i].encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
                        if now() - t2 >= 0.5 { n += 1; good = good && j != nil && (n != 1 || j! == got); two.gpu[i].v.append(two.encs[i].gpuSeconds) }
                    }
                    ok2.add(n, good)
                }
                if !ok2.ok { fail("encode \(label), two threads: DIFFERENT or failed") }
                return (1.5 / Double(max(ok2.n, 1)), median(two.gpu[0].v + two.gpu[1].v))
            }
            // ImageIO: its quality scale differs from libjpeg's; use the setting whose size is closest
            let cg = cgImage(rgb: a, w, h)
            var bestQ = 0.9, gap = Int.max
            for iq in stride(from: 0.70, through: 1.0, by: 0.02) { let n = autoreleasepool { imageIOEncode(cg, quality: iq).count }; if abs(n - got.count) < gap { gap = abs(n - got.count); bestQ = iq } }
            var io: [Double] = [], d = Data()
            warm { autoreleasepool { d = imageIOEncode(cg, quality: bestQ) } }
            for _ in 0..<iters { autoreleasepool { let t0 = now(); d = imageIOEncode(cg, quality: bestQ); io.append(now() - t0) } }
            // ImageIO on two threads, images per second over 1.5 s after 0.5 s (the CPU counterpart of the two-encoder figure)
            let ioe2 = Slot2()
            let tie = now()
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                var n = 0
                while now() - tie < 2.0 { autoreleasepool { _ = imageIOEncode(cg, quality: bestQ); if now() - tie >= 0.5 { n += 1 } } }
                ioe2.add(n, true)
            }
            let ioEncPer2 = 1.5 / Double(max(ioe2.n, 1))
            func back(_ j: Data) -> [String: Any] {
                if let img = dec.decode(j) { return diff(img.bytes, a) }
                if let r = autoreleasepool(invoking: { imageIODecode(j).map { cgImageRGB($0) } }) { return r.withUnsafeBytes { diff($0, a) } }
                return ["error": "cannot decode"]
            }
            let ioQ = back(d), refQ = back(got)
            let row: [String: Any] = ["op": "encode", "case": label, "bytes": got.count, "exact": exact, "thermal": th,
                                      "metal_wall_ms": ms(median(t.wall)), "metal_gpu_ms": ms(median(t.gpu)), "metal_wall_min_ms": ms(t.wall.min()!),
                                      "retries": enc.retries, "metal_two_threads_ms_per_image": ms(encPer2), "metal_two_threads_gpu_ms": ms(encGpu2), "imageio_ms": ms(median(io)), "imageio_two_threads_ms_per_image": ms(ioEncPer2), "imageio_quality": bestQ, "imageio_bytes": d.count,
                                      "imageio_psnr_vs_source_db": ioQ["psnr_db"] ?? 0, "libjpeg_turbo_psnr_vs_source_db": refQ["psnr_db"] ?? 0]
            rows.append(row)
            say("encode \(label) (\(got.count / 1024) KB): \(exact ? "exact" : "DIFFERENT"), Metal wall \(fmt(median(t.wall) * 1000, 3)) ms, GPU \(fmt(median(t.gpu) * 1000, 3)) ms; two encoder threads \(fmt(encPer2 * 1000, 3)) ms per image (GPU \(fmt(encGpu2 * 1000, 3))); ImageIO q\(fmt(bestQ, 2)) \(fmt(median(io) * 1000, 3)) ms, two threads \(fmt(ioEncPer2 * 1000, 3)) ms per image (\(d.count / 1024) KB, PSNR \(fmt(ioQ["psnr_db"] as? Double ?? 0, 1)) vs \(fmt(refQ["psnr_db"] as? Double ?? 0, 1)) dB); thermal \(th)")
        }
        // single-pass (fused) against two-pass encode, interleaved: 7 rounds of 15 calls per configuration
        var paths: [[String: Any]] = []
        let pathCases: [(String, Int)] = [("1200x800 q87 4:2:0", 1), ("1500x1000 q90 4:4:4", 1), ("2048x1365 q90 4:4:4", 1),
                                          ("3840x2560 q95 4:4:4", 1), ("1200x800 q87 4:2:0", 16)]
        for (label, batch) in pathCases {
            guard let c = (bench["encode"] as! [[String: Any]]).first(where: { $0["label"] as? String == label }) else { fail("path case \(label) missing"); continue }
            let w = c["width"] as! Int, h = c["height"] as! Int, q = c["quality"] as! Int, s = c["samp"] as! Int
            status("timing fused vs two-pass \(label) batch \(batch)")
            let th = waitCool("fused vs two-pass \(label)")
            let a = Synth.make(width: w, height: h, seed: UInt32(c["seed"] as! Int))
            let job = EncodeJob(buffer: sharedBuffer(a, MetalContext.shared.device), width: w, height: h, quality: q, subsampling: [.s444, .s422, .s420][s])
            let jobs = Array(repeating: job, count: batch)
            let want = c["jpeg"] as? String
            // explicit single-pass cap (the library's 2M blocks or 1/16 of the working set): the default Encoder()
            // follows DeviceProfile.encoderPath, two-pass on Apple9 and later
            let fused = Encoder(), two = Encoder(); two.fusedMaxBlocks = 0
            fused.fusedMaxBlocks = min(2_000_000, Int(MetalContext.shared.device.recommendedMaxWorkingSetSize / 16 / 128))
            var ok = [true, true], wall: [[Double]] = [[], []], gpu: [[Double]] = [[], []]
            let encs = [fused, two]
            // the first output of each encoder is checked against the hash; later ones are compared with it byte for
            // byte (a memcmp: hashing every output left the GPU idle ~10 ms between calls at 3840x2560, which let
            // its clock drop and inflated these timings by about 60% in the first runs)
            var firstOut: [Data?] = [nil, nil]
            func call(_ k: Int) -> Double {
                let out = try! encs[k].encodeBatch(jobs)
                let g = encs[k].gpuSeconds
                if firstOut[k] == nil { firstOut[k] = out[0]; if sha(out[0]) != want { ok[k] = false } }
                if !out.allSatisfy({ $0 == firstOut[k]! }) { ok[k] = false }
                return g
            }
            warm { _ = call(0); _ = call(1) }
            for _ in 0..<7 { for k in 0..<2 { for _ in 0..<15 { let t0 = now(); let g = call(k); wall[k].append(now() - t0); gpu[k].append(g) } } }
            for k in 0..<2 where !ok[k] { fail("\(k == 0 ? "fused" : "two-pass") \(label) batch \(batch): DIFFERENT from libjpeg-turbo 3.2.0") }
            let row: [String: Any] = ["case": label, "batch": batch, "thermal": th, "exact_fused": ok[0], "exact_two_pass": ok[1],
                                      "fused_wall_ms": ms(median(wall[0])), "fused_gpu_ms": ms(median(gpu[0])),
                                      "two_pass_wall_ms": ms(median(wall[1])), "two_pass_gpu_ms": ms(median(gpu[1])),
                                      "fused_fallbacks": fused.fusedFallbacks, "fused_max_blocks": fused.fusedMaxBlocks]
            paths.append(row)
            say("encode path \(label) batch \(batch): fused wall \(fmt(median(wall[0]) * 1000, 3)) GPU \(fmt(median(gpu[0]) * 1000, 3)) ms; two-pass wall \(fmt(median(wall[1]) * 1000, 3)) GPU \(fmt(median(gpu[1]) * 1000, 3)) ms (per call of \(batch) images); \(ok[0] && ok[1] ? "exact" : "DIFFERENT"); thermal \(th)")
        }
        results["encode_paths"] = ["rows": paths, "method": "default Encoder() (single-pass when it fits) against fusedMaxBlocks = 0 (two-pass), encodeBatch of 1 or 16 jobs, 1 s warm-up of both, then 7 interleaved rounds of 15 calls each; medians over all 105 calls; GPU time per call (whole batch); the first output of each encoder checked against the libjpeg-turbo hash in bench.json, every later output compared byte for byte with it"]

        let lowPowerAfter = ProcessInfo.processInfo.isLowPowerModeEnabled
        results["timing"] = ["thermal_before": thermalBefore, "thermal_after": thermalName(), "rows": rows,
                             "low_power_mode_before": lowPowerBefore, "low_power_mode_after": lowPowerAfter,
                             "representative": !lowPowerBefore && !lowPowerAfter,
                             "method": "median of \(iters) calls after \(warmupSeconds) s of the same work and \(discard) discarded calls; wall from the caller's view, GPU from command buffer GPU start/end; inputs from Corpus/bench (libjpeg-turbo 3.2.0 encodes of Synth images) checked against bench.json hashes",
                             "cpu_comparison": "ImageIO (libjpeg-turbo is not available on iOS)"]
        say("timing thermal: before \(thermalBefore), after \(thermalName()); Low Power Mode before \(lowPowerBefore), after \(lowPowerAfter)")
    }
}
