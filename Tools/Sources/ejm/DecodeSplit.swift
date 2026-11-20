import Foundation
import ExactJPEG
import Metal

// ejm decode-split [seconds] [rounds] [--quick] [--out path]
// Decode throughput with the work split between the GPU and the CPU, measured as the sister PC library measures it:
// 2 GPU decoder threads plus N libjpeg-turbo threads pull images from one shared queue, and the images per second
// are compared with the best of GPU only and CPU only (libjpeg-turbo on every core), every bar from one run.
//
// Sizes: 1600x1200, 3000x2000, 4032x3024, 6000x4000 and 6720x4480 at q90 4:2:0, and 6720x4480 q95 4:2:2. Each size
// has a pool of distinct synthetic camera-like JPEGs (Synth.make, seeds 300 + k), taken round-robin from the queue
// so no decoder sees the same image twice in a row. Variants, each `seconds` (default 2) after `warmupSeconds` of the
// same variant, every variant once per round over `rounds` interleaved rounds (default 3), the order rotated each
// round; the median over rounds is reported. Rate: decodes completed by the deadline over the window length (later
// ones are checked but not counted, and their wait is not in the denominator). Pool: 16 JPEGs per size.
//   gpu        2 GPU decoder threads (2 in flight)
//   cpu        libjpeg-turbo (TurboRef tr_decode: islow, fancy upsampling, RGB) on all P+E cores, one image per thread
//   split-N    2 GPU decoder threads plus N libjpeg-turbo threads, N = cores - 1 and cores - 2; the gain,
//              split / max(gpu, cpu), always uses N = cores - 1, declared in advance
// Exactness: every decoded image, in every variant and warm-up, is compared byte for byte with libjpeg-turbo's
// decode of that JPEG (computed once per pool image); the compare is inside the timed loop for both sides alike.
// Any mismatch or failed decode exits 1. Threads are plain Threads at user-interactive QoS (concurrentPerform would
// not run more iterations than cores at once). --quick (a smoke test, not results): 4 JPEGs per size, 0.5 s per
// variant, 0.25 s warm-ups, 1 round.

private struct SplitSize { let w: Int; let h: Int; let q: Int; let samp: Int
    var sub: String { ["4:4:4", "4:2:2", "4:2:0"][samp] }
    var label: String { "\(w)x\(h) q\(q) \(sub)" }
    var mp: Double { Double(w * h) / 1e6 }
}
private let splitSizes = [SplitSize(w: 1600, h: 1200, q: 90, samp: 2), SplitSize(w: 3000, h: 2000, q: 90, samp: 2),
                          SplitSize(w: 4032, h: 3024, q: 90, samp: 2), SplitSize(w: 6000, h: 4000, q: 90, samp: 2),
                          SplitSize(w: 6720, h: 4480, q: 90, samp: 2), SplitSize(w: 6720, h: 4480, q: 95, samp: 1)]

/// per-thread tallies, written by one thread and read after all have joined
/// `timed`: decodes that completed by the deadline (the ones the rate counts); `images`: all decodes, for exactness
private final class SplitTally: @unchecked Sendable { var images = 0, timed = 0, identical = 0, mismatched = 0, failed = 0 }

/// Run `n` threads at user-interactive QoS and wait for all of them.
private func onThreads(_ n: Int, _ body: @escaping @Sendable (Int) -> Void) {
    let g = DispatchGroup()
    for k in 0..<n {
        g.enter()
        let t = Thread { body(k); g.leave() }
        t.qualityOfService = .userInteractive
        t.start()
    }
    g.wait()
}

private func orNull(_ x: Any?) -> Any { x ?? NSNull() }

private func thermalName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown"
    }
}

func runDecodeSplit(_ argv: [String]) -> Int32 {
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
    let usage = "usage: ejm decode-split [seconds] [rounds] [--quick] [--out <path>]"
    guard pos.count <= 2 else { print(usage); return 2 }
    var seconds = quick ? 0.5 : 2.0, rounds = quick ? 1 : 3
    if pos.count > 0 { guard let s = Double(pos[0]), s > 0 else { print(usage); return 2 }; seconds = s }
    if pos.count > 1 { guard let r = Int(pos[1]), r > 0 else { print(usage); return 2 }; rounds = r }
    let warm = quick ? 0.25 : warmupSeconds
    let poolSize = quick ? 4 : 16
    let tStart = now()

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    benchProfile()
    let topo = cpuTopology()
    let cores = topo.total
    let gpuThreads = 2
    let splitNs = [cores - 1, cores - 2].filter { $0 > 0 }
    var cond = Bench.conditions()
    let loadStart = cond["load_average"] as? String ?? "?", thermalStart = thermalName()
    print("decode-split: \(quick ? "QUICK (smoke test, not results): " : "")\(fmt(seconds, 2)) s per variant after \(fmt(warm, 2)) s warm-up, \(rounds) round(s), \(poolSize) JPEGs per size")
    print("\(cond["chip"] ?? "?"), \(cond["gpu_cores"] ?? "?")-core GPU, CPU \(cores) cores (\(topo.performance) performance + \(topo.efficiency) efficiency); reference \(Turbo.version); load \(loadStart), thermal \(thermalStart)")

    struct Variant { let name: String; let gpu: Int; let cpu: Int }
    let variants = [Variant(name: "gpu", gpu: gpuThreads, cpu: 0), Variant(name: "cpu", gpu: 0, cpu: cores)]
        + splitNs.map { Variant(name: "split-\($0)", gpu: gpuThreads, cpu: $0) }

    var sizeDocs: [[String: Any]] = []
    var totals = (images: 0, identical: 0, mismatched: 0, failed: 0)
    var bad: [String] = []
    var summaryLines: [String] = []
    for sz in splitSizes {
        // the pool and its references
        var pool: [Data] = [], refs: [[UInt8]] = []
        for k in 0..<poolSize {
            let img = Synth.make(width: sz.w, height: sz.h, seed: UInt32(300 + k))
            let j = Turbo.encode(img, sz.w, sz.h, quality: sz.q, samp: sz.samp)
            guard let r = Turbo.decode(j), !r.warned else { print("\(sz.label): libjpeg-turbo could not decode pool image \(k)"); return 1 }
            pool.append(j); refs.append(r.px)
        }
        let px = sz.w * sz.h * 3
        let meanBytes = pool.reduce(0) { $0 + $1.count } / pool.count
        print("\n== \(sz.label) (\(fmt(sz.mp, 1)) MP, \(pool.count) JPEGs, mean \(fmt(Double(meanBytes) / 1e6, 2)) MB)")
        let decs = (0..<gpuThreads).map { _ in Decoder() }
        let bufs = (0..<cores).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: px) }
        defer { bufs.forEach { $0.deallocate() } }
        let shared = Unchecked((pool, refs, decs, bufs))
        // first use of each decoder on every pool image, outside any timing (and checked)
        for d in decs { for (j, data) in pool.enumerated() {
            guard let g = d.decode(data) else { totals.failed += 1; bad.append("\(sz.label) pool \(j): GPU decode failed (\(d.reason ?? "?"))"); continue }
            totals.images += 1
            if g.bytes.count == px && refs[j].withUnsafeBytes({ memcmp($0.baseAddress!, g.bytes.baseAddress!, px) == 0 }) { totals.identical += 1 }
            else { totals.mismatched += 1; bad.append("\(sz.label) pool \(j): GPU decode differs from libjpeg-turbo") }
        } }

        /// one run of a variant for `secs`: (images per second, GPU images, CPU images, tallies)
        func run(_ v: Variant, _ secs: Double) -> (ips: Double, gpu: Int, cpu: Int, tallies: [SplitTally]) {
            let queue = ManagedAtomicCounter()
            let tallies = (0..<(v.gpu + v.cpu)).map { _ in SplitTally() }
            let tl = Unchecked(tallies)
            let t0 = now()
            onThreads(v.gpu + v.cpu) { k in
                let (pool, refs, decs, bufs) = shared.value
                let t = tl.value[k]
                while now() - t0 < secs {
                    let j = (queue.increment() - 1) % pool.count
                    let ref = refs[j]
                    if k < v.gpu {
                        guard let g = decs[k].decode(pool[j]) else { t.failed += 1; continue }
                        t.images += 1
                        if now() - t0 <= secs { t.timed += 1 }
                        let same = g.bytes.count == px && ref.withUnsafeBytes { memcmp($0.baseAddress!, g.bytes.baseAddress!, px) == 0 }
                        if same { t.identical += 1 } else { t.mismatched += 1 }
                    } else {
                        let b = bufs[k - v.gpu]
                        let r = Turbo.decodeInto(pool[j], b)
                        if r < 0 { t.failed += 1; continue }
                        t.images += 1
                        if now() - t0 <= secs { t.timed += 1 }
                        let same = ref.withUnsafeBytes { memcmp($0.baseAddress!, b, px) == 0 }
                        if same { t.identical += 1 } else { t.mismatched += 1 }
                    }
                }
            }
            // the threads have joined (stragglers finished and were checked), but the rate counts only the decodes
            // that completed within the window, over the window's length
            let g = tallies.prefix(v.gpu).reduce(0) { $0 + $1.timed }, c = tallies.dropFirst(v.gpu).reduce(0) { $0 + $1.timed }
            return (Double(g + c) / secs, g, c, tallies)
        }

        var perRound: [String: [[String: Any]]] = [:], rates: [String: [Double]] = [:]
        var exact = (images: 0, identical: 0, mismatched: 0, failed: 0)
        func tally(_ ts: [SplitTally], _ what: String) {
            for t in ts {
                exact.images += t.images; exact.identical += t.identical; exact.mismatched += t.mismatched; exact.failed += t.failed
            }
            let mm = ts.reduce(0) { $0 + $1.mismatched }, fl = ts.reduce(0) { $0 + $1.failed }
            if mm + fl > 0 { bad.append("\(sz.label) \(what): \(mm) decodes differ from libjpeg-turbo, \(fl) failed") }
        }
        for round in 0..<rounds {
            let load = Bench.shell("sysctl -n vm.loadavg | tr -d '{}' | xargs")
            var line = "  round \(round + 1) (load \(load)):"
            for vi in 0..<variants.count {
                let v = variants[(vi + round) % variants.count]
                tally(run(v, warm).tallies, "\(v.name) warm-up")
                let r = run(v, seconds)
                tally(r.tallies, v.name)
                rates[v.name, default: []].append(r.ips)
                perRound[v.name, default: []].append(["round": round + 1, "images_per_s": jnum(r.ips), "gpu_images": r.gpu, "cpu_images": r.cpu, "load_average": load])
                line += " \(v.name) \(fmt(r.ips, 1))/s" + (v.gpu > 0 && v.cpu > 0 ? " (GPU \(r.gpu), CPU \(r.cpu))" : "")
            }
            print(line)
        }
        totals.images += exact.images; totals.identical += exact.identical; totals.mismatched += exact.mismatched; totals.failed += exact.failed
        let med = Dictionary(uniqueKeysWithValues: variants.map { ($0.name, median(rates[$0.name]!)) })
        let bestSingle = max(med["gpu"]!, med["cpu"]!)
        var vdocs: [[String: Any]] = []
        for v in variants {
            var d: [String: Any] = ["name": v.name, "gpu_threads": v.gpu, "cpu_threads": v.cpu, "images_per_s": jnum(med[v.name]!), "rounds": perRound[v.name]!]
            if v.gpu > 0 && v.cpu > 0 {
                // the counts of the round whose rate is the median
                let rs = perRound[v.name]!, rr = rates[v.name]!
                let mi = rr.indices.sorted { rr[$0] < rr[$1] }[rr.count / 2]
                d["gpu_images"] = rs[mi]["gpu_images"]; d["cpu_images"] = rs[mi]["cpu_images"]
                d["gain_vs_best_single"] = jnum(med[v.name]! / bestSingle)
            }
            vdocs.append(d)
        }
        // the gain uses one split declared in advance, 2 GPU threads + (cores - 1) libjpeg-turbo threads; the
        // cores - 2 split is reported but never chosen
        let headN = cores - 1
        let best: Int? = splitNs.contains(headN) ? headN : nil
        let gain = best.map { med["split-\($0)"]! / bestSingle }
        var sdoc: [String: Any] = ["label": sz.label, "width": sz.w, "height": sz.h, "megapixels": jnum(sz.mp), "quality": sz.q, "subsampling": sz.sub,
                                   "pool": pool.count, "mean_bytes": meanBytes, "variants": vdocs,
                                   "best_single": med["gpu"]! >= med["cpu"]! ? "gpu" : "cpu",
                                   "exact": ["images": exact.images, "identical": exact.identical, "mismatched": exact.mismatched, "failed": exact.failed]]
        if let best, let gain { sdoc["gain_split"] = "split-\(best)"; sdoc["gain"] = jnum(gain) }
        sizeDocs.append(sdoc)
        var s = String(format: "%@ (%.1f MP): GPU x2 %.1f/s, CPU x%d %.1f/s", sz.label as NSString, sz.mp, med["gpu"]!, cores, med["cpu"]!)
        for n in splitNs {
            let d = vdocs.first { $0["name"] as? String == "split-\(n)" }!
            s += String(format: ", 2+%d %.1f/s (GPU %d, CPU %d)", n, med["split-\(n)"]!, d["gpu_images"] as! Int, d["cpu_images"] as! Int)
        }
        if let gain, let best { s += String(format: "; gain %.2fx (2+%d, the pre-declared split, over the best single path, %@)", gain, best, med["gpu"]! >= med["cpu"]! ? "GPU only" : "CPU only") }
        s += "; exact \(exact.identical)/\(exact.images)" + (exact.failed > 0 ? ", \(exact.failed) failed" : "")
        summaryLines.append(s)
    }

    let loadEnd = Bench.shell("sysctl -n vm.loadavg | tr -d '{}' | xargs"), thermalEnd = thermalName()
    let elapsed = now() - tStart
    print("\n== decode-split summary\(quick ? " (QUICK: smoke test, not results)" : "")")
    summaryLines.forEach { print($0) }
    print("exactness: \(totals.identical)/\(totals.images) decodes byte-identical to libjpeg-turbo, \(totals.mismatched) differ, \(totals.failed) failed")
    print("load \(loadStart) -> \(loadEnd); thermal \(thermalStart) -> \(thermalEnd); \(fmt(elapsed, 0)) s")
    if !bad.isEmpty { print("NOT IDENTICAL: \(bad.joined(separator: "; "))") }

    // conditions as the bench records have them, without the keys that describe other benchmarks
    cond["corpus"] = "Synth.make camera-like images, seeds 300 + k, \(poolSize) per size, encoded by libjpeg-turbo"
    cond.removeValue(forKey: "gpu_warmup"); cond.removeValue(forKey: "cpu_timing")
    cond["load_average_before"] = loadStart; cond["load_average_after"] = loadEnd
    cond["thermal_state_before"] = thermalStart; cond["thermal_state_after"] = thermalEnd
    cond["cpu_performance_cores"] = topo.performance; cond["cpu_efficiency_cores"] = topo.efficiency
    let chip = (cond["chip"] as? String ?? "?").replacingOccurrences(of: "Apple ", with: "").lowercased().replacingOccurrences(of: " ", with: "")
    let iso = ISO8601DateFormatter(); iso.timeZone = .current
    let commit = Bench.shell("git rev-parse --short HEAD 2>/dev/null")
    let dirty = !Bench.shell("git status --porcelain --untracked-files=no 2>/dev/null").isEmpty
    let doc: [String: Any] = [
        "kind": "decode-split",
        "measured": iso.string(from: Date()),
        "quick": quick,
        "passed": bad.isEmpty,
        "gpu": ["chip": cond["chip"] ?? "?", "cores": cond["gpu_cores"] ?? 0],
        "cpu": ["cores": cores, "performance": topo.performance, "efficiency": topo.efficiency],
        "versions": ["libjpeg-turbo runtime": orNull(Turbo.runtimeVersion), "libjpeg-turbo headers": Turbo.headerVersion,
                     "ejm commit": orNull(commit.isEmpty ? nil : (dirty ? commit + " (uncommitted changes)" : commit))],
        "method": [
            "seconds_per_variant": seconds, "warmup_seconds": warm, "rounds": rounds, "pool_per_size": poolSize, "gpu_threads": gpuThreads,
            "variants": "gpu: 2 GPU decoder threads; cpu: libjpeg-turbo on all \(cores) cores, one image per thread; split-N: 2 GPU decoder threads plus N libjpeg-turbo threads; all threads of a variant pull from one shared queue over the size's pool, round-robin",
            "rate": "decodes that completed by the deadline (a GPU decode when decode returned, a libjpeg-turbo decode when tr_decode returned) divided by the window length (deadline minus start); decodes finishing after the deadline are not counted and the wait for them is not in the denominator (they are still checked, and every thread is joined before the next variant); median over rounds, variant order rotated each round",
            "reference": "libjpeg-turbo TurboRef tr_decode (islow, fancy upsampling, RGB)",
            "exactness": "every decoded image, warm-ups included, compared byte for byte with libjpeg-turbo's decode of that JPEG inside the timed loop",
            "gain": "split-(cores - 1), declared in advance, / max(gpu, cpu), from the medians of the same run; split-(cores - 2) is reported alongside and never used for the gain",
            "headline_split": "split-\(cores - 1)",
        ],
        "sizes": sizeDocs,
        "exact": ["images": totals.images, "identical": totals.identical, "mismatched": totals.mismatched, "failed": totals.failed],
        "elapsed_seconds": jnum(elapsed),
        "conditions": cond,
    ]
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = .current; stamp.dateFormat = "yyyy-MM-dd-HHmm"
    let path = out ?? "results/bench/\(chip)-gpu\(cond["gpu_cores"] ?? 0)-\(stamp.string(from: Date()))-decode-split.json"
    var writeFailed = false
    do {
        let js = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        try js.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        writeFailed = true
        print("could not write \(path): \(error)")
        if let js = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]), let s = String(data: js, encoding: .utf8) { print(s) }
    }
    if !bad.isEmpty { return 1 }
    return writeFailed ? 3 : 0
}
