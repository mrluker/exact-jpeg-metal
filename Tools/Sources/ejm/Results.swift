import Foundation
import Metal
import ExactJPEG

/// Benchmark records and machine conditions, written as JSON so charts can be regenerated from committed results.
enum Bench {
    nonisolated(unsafe) static var records: [[String: Any]] = []
    nonisolated(unsafe) static var extraConditions: [String: Any] = [:]

    static func add(_ base: [String: Any], impl: String, wall: Double, gpu: Double? = nil, extra: [String: Any] = [:]) {
        var r = base
        r["impl"] = impl
        r["wall_ms"] = (wall * 1e5).rounded() / 100
        if let gpu { r["gpu_ms"] = (gpu * 1e5).rounded() / 100 }
        for (k, v) in extra { r[k] = v }
        records.append(r)
    }

    static func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// chip, GPU core count, memory, macOS, power source, date, reference library
    static func conditions() -> [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let mem = ProcessInfo.processInfo.physicalMemory
        let cores = shell("system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Total Number of Cores/{print $2; exit}'")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        iso.timeZone = .current             // local, like the time in the file name (ISO8601DateFormatter defaults to UTC)
        var c: [String: Any] = [
            "chip": shell("sysctl -n machdep.cpu.brand_string"),
            "model": shell("sysctl -n hw.model"),
            "model_name": shell("system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}'"),
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "?",
            "gpu_cores": Int(cores) ?? 0,
            "cpu_cores": ProcessInfo.processInfo.processorCount,
            "memory_gb": Int(mem >> 30),
            "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "power": shell("pmset -g batt | head -1 | sed -E \"s/.*'(.*)'.*/\\1/\""),
            "date": iso.string(from: Date()),
            "load_average": shell("sysctl -n vm.loadavg | tr -d '{}' | xargs"),
            "reference": Turbo.version,
            "corpus": "ejm synthetic v1 (Synth.make, decode seed 11, encode seed 21)",
            "gpu_warmup": "\(warmupSeconds) s of the same GPU work before each timed case, first \(discardIterations) timed iterations discarded",
            "cpu_timing": "libjpeg-turbo 1-thread cases: \(warmupSeconds) s of the same work first, then max(5, iters / 2) timed calls, thread at user-interactive QoS",
        ]
        c["device_profile"] = DeviceProfile.current.dictionary
        for (k, v) in extraConditions { c[k] = v }
        return c
    }

    static func write(_ path: String, extra: [String: Any] = [:]) {
        var out: [String: Any] = ["conditions": conditions(), "records": records]
        for (k, v) in extra { out[k] = v }
        let js = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! js.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(records.count) records)")
    }
}

/// results/bench/<chip>-gpu<cores>-<yyyy-MM-dd-HHmm>.json, local time: decode and encode benchmarks with conditions
func runBenchJSON(iters: Int, dir: String) {
    runDecodeBench(iters: iters)
    runEncodeBench(iters: iters)
    runThroughputBench(count: 24)
    let c = Bench.conditions()
    let chip = (c["chip"] as! String).replacingOccurrences(of: "Apple ", with: "").lowercased().replacingOccurrences(of: " ", with: "")
    // date and time from one clock (local, as scripts/bench.sh names work/bench-<host>-<date>); a UTC date with a
    // local time named an M4 run of 22:42 CST on 2026-11-17 "2026-11-18-2242"
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = .current; stamp.dateFormat = "yyyy-MM-dd-HHmm"
    Bench.write("\(dir)/\(chip)-gpu\(c["gpu_cores"]!)-\(stamp.string(from: Date())).json")
}

enum Exact { nonisolated(unsafe) static var v: [String: Any] = [:] }

/// The exactness record (results/exactness.json) from one scripts/test.sh work directory, never assembled by hand:
///   ejm exactness work/test-<date> results/exactness.json
/// It refuses to write unless the run passed: <dir>/run.json (test.sh writes it after every step passed: run id,
/// commit, validation pattern), the counts the corpus, encoder corpus, manifest and decline-corpus steps recorded in
/// <dir>/record/ (their --record=) with passed = true, and the decoder fuzz, shader-validated fuzz and encoder fuzz
/// summaries with no findings. The shader validation report count is read from the run's validated logs with
/// run.json's pattern, and the two deliberate-fault control logs must each contain a report. run.json must also say
/// libjpeg-turbo 3.2.0 was loaded (another version, or none recorded, only with allowRuntime: --allow-runtime), fuzz
/// lengths of at least test.sh's defaults (testShDefaults; no override) and no uncommitted changes (else only with
/// allowDirty: --allow-dirty). An override used is listed in the record's "overrides".
func runExactnessReport(dir: String, out: String, allowRuntime: Bool = false, allowDirty: Bool = false) -> Bool {
    var problems: [String] = [], overrides: [String] = []
    func load(_ rel: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(rel)")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { problems.append("\(rel): missing or unreadable"); return nil }
        return o
    }
    func text(_ rel: String) -> String? {
        guard let t = try? String(contentsOfFile: "\(dir)/\(rel)", encoding: .utf8) else { problems.append("\(rel): missing"); return nil }
        return t
    }
    let run = load("run.json")
    if let run, run["status"] as? String != "passed" { problems.append("run.json: status \(run["status"] ?? "?"), not passed") }
    if let run {
        let rt = run["libjpeg_turbo_runtime"] as? String ?? ""
        if rt != "3.2.0" {
            let shown = rt.isEmpty ? "unknown" : rt
            if allowRuntime { overrides.append("--allow-runtime: libjpeg_turbo_runtime \(shown), not 3.2.0") }
            else { problems.append("run.json: libjpeg_turbo_runtime \(shown), not 3.2.0 (--allow-runtime to record it anyway)") }
        }
        switch testShDefaults() {
        case .failure(let why): problems.append(why.description)
        case .success(let mins):
            for (key, min) in mins {
                let n = run[key] as? Int
                if n == nil || n! < min { problems.append("run.json: \(key) \(n.map(String.init) ?? "missing"), below test.sh's \(min)") }
            }
        }
        switch run["uncommitted_changes"] as? Bool {
        case false?: break
        case true? where allowDirty: overrides.append("--allow-dirty: the run had uncommitted changes")
        case true?: problems.append("run.json: uncommitted_changes true (--allow-dirty to record it anyway)")
        case nil: problems.append("run.json: uncommitted_changes missing")
        }
    }
    var r: [String: Any] = [:]
    for (key, file) in [("decode", "corpus"), ("encode", "encode-corpus"), ("manifest", "manifest"), ("decline_corpus", "decline-corpus")] {
        guard let rec = load("record/\(file).json") else { continue }
        if rec["passed"] as? Bool != true { problems.append("record/\(file).json: the step did not pass") }
        guard let v = rec[key] else { problems.append("record/\(file).json: no \(key) counts"); continue }
        r[key] = v
    }
    for (key, file) in [("fuzz", "fuzz/summary.json"), ("fuzz_shader_validation", "fuzz-sv/summary.json"), ("encode_fuzz", "encode-fuzz/summary.json")] {
        guard let sm = load(file) else { continue }
        let f = sm["findings"]
        let none = (f as? [String: Any])?.isEmpty ?? ((f as? Int) == 0)
        if !none { problems.append("\(file): findings \(f ?? "?")") }
        if (sm["counts"] as? [String: Any])?.isEmpty ?? true { problems.append("\(file): no counts") }
        r[key] = sm
    }
    let pattern = run?["sv_pattern"] as? String ?? ""
    if pattern.isEmpty { problems.append("run.json: no sv_pattern") }
    let re = try? NSRegularExpression(pattern: pattern)
    func reports(_ t: String) -> Int {
        guard let re else { return 0 }
        return t.split(separator: "\n", omittingEmptySubsequences: false).filter { l in
            let s = String(l); return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }.count
    }
    var svCounts: [String: Int] = [:]
    for log in (run?["sv_logs"] as? [String]) ?? [] { if let t = text(log) { svCounts[log] = reports(t) } }
    if svCounts.isEmpty { problems.append("run.json: no validated logs listed") }
    var controls: [String: Int] = [:]
    for log in (run?["sv_controls"] as? [String]) ?? [] {
        if let t = text(log) { controls[log] = reports(t); if controls[log]! == 0 { problems.append("\(log): the deliberate fault was not reported") } }
    }
    if controls.isEmpty { problems.append("run.json: no control logs listed") }
    let total = svCounts.values.reduce(0, +)
    if total != 0 { problems.append("shader validation reports: \(total)") }
    guard problems.isEmpty else {
        print("exactness record NOT written (\(dir)):"); problems.forEach { print("  \($0)") }
        return false
    }
    r["shader_validation_reports"] = total
    r["shader_validation"] = ["pattern": pattern, "reports_per_log": svCounts, "control_reports": controls]
    r["test_run"] = run
    r["overrides"] = overrides
    overrides.forEach { print("WARNING: \($0)") }
    r["conditions"] = Bench.conditions()
    let js = try! JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
    try! FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! js.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) from \(dir) (run \(run?["run_id"] ?? "?"), commit \(run?["commit"] ?? "?"))")
    return true
}

/// The fuzz lengths of a full scripts/test.sh run, the minimums `ejm exactness` accepts, read from test.sh's line
/// `FUZZ_DEFAULT=50000; SV_DEFAULT=5000; ENC_FUZZ_DEFAULT=5000` (so the numbers live in one place): scripts/test.sh
/// from the current directory, else next to this executable's repository (Tools/.build/<config>/ejm).
func testShDefaults() -> Result<[(String, Int)], ExactnessError> {
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let candidates = ["scripts/test.sh", exe.deletingLastPathComponent().appendingPathComponent("../../../scripts/test.sh").standardized.path]
    guard let text = candidates.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first else {
        return .failure(ExactnessError("scripts/test.sh not found (run from the repository root): the fuzz minimums are read from it"))
    }
    let re = try! NSRegularExpression(pattern: #"^FUZZ_DEFAULT=(\d+); SV_DEFAULT=(\d+); ENC_FUZZ_DEFAULT=(\d+)$"#, options: .anchorsMatchLines)
    guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
        return .failure(ExactnessError("scripts/test.sh has no FUZZ_DEFAULT=...; SV_DEFAULT=...; ENC_FUZZ_DEFAULT=... line"))
    }
    let v = (1...3).map { Int(text[Range(m.range(at: $0), in: text)!])! }
    return .success([("fuzz_iterations", v[0]), ("sv_fuzz_iterations", v[1]), ("encode_fuzz_iterations", v[2])])
}
struct ExactnessError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

/// GPU clock state matters for short calls (DVFS): before each timed Metal case, keep the GPU busy with the same
/// work for `warmupSeconds`, then discard the first `discard` timed iterations. Recorded in the conditions.
let warmupSeconds = 1.0, discardIterations = 3

func warmUp(_ work: () -> Void) {
    let t0 = now()
    while now() - t0 < warmupSeconds { work() }
}

/// Median-ready timings of a single-thread CPU call. Without a warm-up the first calls after an idle wait ran on a
/// low clock (or an efficiency core): on an M4, 1200x800 encode read 3.86 ms here against 1.49 ms when run alone
/// (2026-11-17). So: user-interactive QoS (prefers performance cores), `warmupSeconds` of the same work, then
/// max(5, iters / 2) timed calls.
func cpuTimes(_ iters: Int, _ work: () -> Void) -> [Double] {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    warmUp(work)
    var t: [Double] = []
    for _ in 0..<max(5, iters / 2) { let t0 = now(); work(); t.append(now() - t0) }
    return t
}

/// api-check exactness-record: `ejm exactness` on a made-up passing run directory, then with each requirement
/// broken in turn (in child processes, so the real command line is what is tested): the libjpeg-turbo runtime must
/// be 3.2.0 (another, empty or missing refused unless --allow-runtime, which the record then names), the three fuzz
/// lengths at least test.sh's defaults (no flag), and no uncommitted changes (unless --allow-dirty, recorded)
func checkExactnessRecord(_ t: Tally) {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "ejm-exactness-\(getpid())"
    defer { try? fm.removeItem(atPath: root) }
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let goodRun: [String: Any] = ["status": "passed", "run_id": "test-fake", "commit": "0000000", "uncommitted_changes": false,
        "date": "2026-11-19T00:00:00-0600", "libjpeg_turbo_runtime": "3.2.0", "fuzz_iterations": 50000,
        "sv_fuzz_iterations": 5000, "encode_fuzz_iterations": 5000, "sv_pattern": "Invalid store",
        "sv_logs": ["sv.log"], "sv_controls": ["control.log"]]
    func write(_ obj: Any, _ path: String) {
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
    }
    var k = 0
    /// a run directory with run.json changed by edit; ejm exactness on it with flags: (exit 0, output, record)
    func run(_ edit: (inout [String: Any]) -> Void, _ flags: [String] = []) -> (ok: Bool, out: String, rec: [String: Any]?) {
        k += 1
        let dir = "\(root)/run\(k)"
        var r = goodRun; edit(&r)
        write(r, "\(dir)/run.json")
        for (key, file) in [("decode", "corpus"), ("encode", "encode-corpus"), ("manifest", "manifest"), ("decline_corpus", "decline-corpus")] {
            write(["passed": true, key: ["n": 1]], "\(dir)/record/\(file).json")
        }
        for f in ["fuzz", "fuzz-sv", "encode-fuzz"] { write(["findings": [String: Any](), "counts": ["exact": 1]], "\(dir)/\(f)/summary.json") }
        try! "clean\n".write(toFile: "\(dir)/sv.log", atomically: true, encoding: .utf8)
        try! "Invalid store at offset 0\n".write(toFile: "\(dir)/control.log", atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["exactness", dir, "\(dir)/exactness.json"] + flags
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return (false, "cannot start: \(error)", nil) }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let rec = (try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/exactness.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (p.terminationStatus == 0, out, rec)
    }
    func overrides(_ rec: [String: Any]?) -> [String] { rec?["overrides"] as? [String] ?? ["(none listed)"] }
    let good = run { _ in }
    t.check(good.ok && good.rec != nil && overrides(good.rec).isEmpty, "a passing run is recorded with no overrides: \(good.out) \(overrides(good.rec))")
    func refused(_ what: String, _ want: String, _ flags: [String] = [], _ edit: (inout [String: Any]) -> Void) {
        let r = run(edit, flags)
        t.check(!r.ok && r.rec == nil && r.out.contains(want), "\(what) is refused (\(want)): exit ok \(r.ok), \(r.out.split(separator: "\n").dropFirst().joined(separator: "; "))")
        if !r.ok { print("  refused \(what):\(r.out.split(separator: "\n").dropFirst().joined(separator: ";"))") }
    }
    refused("runtime 3.2.1", "libjpeg_turbo_runtime") { $0["libjpeg_turbo_runtime"] = "3.2.1" }
    refused("an empty runtime", "libjpeg_turbo_runtime") { $0["libjpeg_turbo_runtime"] = "" }
    refused("no runtime", "libjpeg_turbo_runtime") { $0["libjpeg_turbo_runtime"] = nil }
    refused("fuzz 49999", "fuzz_iterations", ["--allow-runtime", "--allow-dirty"]) { $0["fuzz_iterations"] = 49999 }
    refused("shader-validated fuzz 4999", "sv_fuzz_iterations", ["--allow-runtime", "--allow-dirty"]) { $0["sv_fuzz_iterations"] = 4999 }
    refused("encoder fuzz 4999", "encode_fuzz_iterations", ["--allow-runtime", "--allow-dirty"]) { $0["encode_fuzz_iterations"] = 4999 }
    refused("no fuzz count", "fuzz_iterations") { $0["fuzz_iterations"] = nil }
    refused("uncommitted changes", "uncommitted_changes") { $0["uncommitted_changes"] = true }
    refused("no uncommitted_changes", "uncommitted_changes") { $0["uncommitted_changes"] = nil }
    let rt = run({ $0["libjpeg_turbo_runtime"] = "3.2.1" }, ["--allow-runtime"])
    t.check(rt.ok && overrides(rt.rec).contains { $0.contains("--allow-runtime") && $0.contains("3.2.1") },
            "runtime 3.2.1 with --allow-runtime is recorded with the override: \(overrides(rt.rec))")
    let dirty = run({ $0["uncommitted_changes"] = true }, ["--allow-dirty"])
    t.check(dirty.ok && overrides(dirty.rec).contains { $0.contains("--allow-dirty") },
            "uncommitted changes with --allow-dirty are recorded with the override: \(overrides(dirty.rec))")
    let bad = run({ _ in }, ["--allow-everything"])
    t.check(!bad.ok && bad.rec == nil, "an unknown flag is refused: \(bad.out)")
}
