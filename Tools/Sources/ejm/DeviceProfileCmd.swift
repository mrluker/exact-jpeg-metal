import Foundation
import Metal
@_spi(Testing) import ExactJPEG

/// For benchmarks: read the profile, wait for its routing measurement (so it does not overlap the timing), print it.
@discardableResult func benchProfile() -> DeviceProfile {
    let p = DeviceProfile.current
    _ = p.measuredRouting(timeout: 10)
    print("device profile: \(p.summary)")
    return p
}

// ejm profile [--measure N | --rules]
//   (no argument)  the device profile: layer 1, then the routing numbers (waits for the background measurement or
//                  reads the cache) and what they advise at a few sizes
//   --measure N    run the routing measurement N times in this process (no cache), each on a fresh MetalContext
//                  after the first, and print each result, its isolated call times, the CPU proxy's fit and the
//                  measurement's own cost
//   --assume-idle  as with no argument, but the busy gate's utilization and load sample is injected as idle (for a
//                  machine that is always busy); waiting for this process's own GPU work to pause still applies
//   --rules        the layer-1 rules applied to an M1 Max, an M4 and an iPhone 13's reported properties
func runProfileCommand(_ mode: String) {
    if mode == "--rules" {
        for (name, fam, cores, ws, cpu) in [("M1 Max (Apple7, 32 cores, 55.7 GB working set)", DeviceProfile.Family.apple7, Optional(32), UInt64(55_662_788_608), 8),
                                            ("M4 (Apple9, 8 cores, 12124 MB working set)", .apple9, 8, 12124 << 20, 4),
                                            ("iPhone 13 (Apple8, cores not readable, 2.86 GB working set)", .apple8, nil, 2_863_311_530, 6)] {
            let p = DeviceProfileTesting.derive(name: name, family: fam, gpuCores: cores, workingSet: ws, cpuCores: cpu)
            print("\(name):\n  \(p.summary)")
            printCrossovers(p, indent: "  ")
        }
        return
    }
    if mode == "--measure" {
        let n = Int(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "5") ?? 5
        print("load: \(Bench.shell("sysctl -n vm.loadavg"))")
        for k in 0..<n {
            let ctx = k == 0 ? MetalContext.shared : try! MetalContext()
            if k > 0 { _ = ctx.selfCheck() }
            let t0 = now()
            let o = DeviceProfileTesting.measureDetailed(ctx)
            print("  run \(k + 1) (\(fmt((now() - t0) * 1000, 0)) ms wall, \(fmt(o.gpuMs, 1)) ms GPU, CPU proxy \(fmt(o.cpuChunksMs.reduce(0, +), 1)) ms):")
            print("    isolated 256x256 calls, ms: decode \(o.decodeMs.map { fmt($0, 2) }.joined(separator: ", ")); encode \(o.encodeMs.map { fmt($0, 2) }.joined(separator: ", "))")
            print("    isolated 1600x1200 calls, ms: decode \(o.decodeLargeMs.map { fmt($0, 2) } ?? "-"), encode \(o.encodeLargeMs.map { fmt($0, 2) } ?? "-")")
            print("    sporadic (cold GPU): " + (o.sporadic.map { $0.costDescription + String(format: ", cold start %.2f ms", $0.coldStartMs) }
                                         ?? "not used: \(o.reason ?? "?")"))
            let c = o.cpuChunksMs, n = c.count
            if n > 0 {
                let q = max(n / 8, 1)
                print("    CPU proxy: \(n) chunks; first \(c.prefix(q).map { fmt($0, 3) }.joined(separator: ", ")) ms; last \(c.suffix(q).map { fmt($0, 3) }.joined(separator: ", ")) ms")
            }
            print("    CPU cold model: " + (o.cpu.map { String(format: "ratio %.2f, ramp %.1f ms (proxy %.1f ms CPU)", $0.ratio, $0.rampMs, $0.measurementMs) }
                                           ?? "not used: \(o.cpuReason ?? "?")"))
        }
        return
    }
    // the real busy-gate sample, taken before the first read starts the measurement (sampleNow briefly swaps the
    // sampler, which must not race the background gate). Device Utilization % is a decaying average, so it still
    // shows this process's own recent work (the self-check): sample 1 s after it, or say it includes it.
    let gateNow = DeviceProfileTesting.sampleNow(MetalContext.shared.device, quiet: 1.0).summary
    let ownQuiet = DeviceProfileTesting.ownGPUQuietSeconds
    if mode == "--assume-idle" {          // inject an idle busy-gate sample (this process's own work still counts)
        DeviceProfileTesting.idleSampler = { DeviceProfile.IdleSample(gpuUtilization: [0, 0], loadAverage: 0, cpuCores: ProcessInfo.processInfo.activeProcessorCount) }
    }
    let p = DeviceProfile.current
    print("layer 1: \(p.summary)")
    // a snapshot only: the first utilization read after a quiet stretch can still report the earlier value, so the
    // sample the measurement's gate actually used is printed after it
    print(ownQuiet >= 1.0 ? "busy gate snapshot now (1 s or more after this process's last GPU work): \(gateNow)"
                          : "busy gate snapshot now (includes this process's own GPU work of the last \(fmt(ownQuiet, 2)) s): \(gateNow)")
    print("cache: \(DeviceProfileTesting.cacheEnabled ? DeviceProfileTesting.cacheFile(p)?.path ?? "none" : "disabled (EJM_PROFILE_CACHE=0)")")
    let t0 = now()
    let m = p.measuredRouting(timeout: 30)
    print("routing (\(p.routingSource.rawValue), after \(fmt((now() - t0) * 1000, 1)) ms): \(p.summary)")
    print("busy gate sample the measurement used: \(p.sporadicRouting.idleSample?.summary ?? "none (not measured: estimate or cache without a sample)")")
    let r = p.sporadicRouting, u = p.sustainedRouting, w = p.warmRouting, c = p.cpuColdModel
    print("  GPU cold (sporadic, \(r.measured ? "measured" : "estimate")): " + r.costDescription + String(format: ", cold start %.2f ms", r.coldStartMs))
    print(String(format: "  GPU warm (recent work): decode %.3f ms + %.3f ms/MP, encode %.3f ms + %.3f ms/MP",
                 w.decodeFixedMs, w.decodeMsPerMP, w.encodeFixedMs, w.encodeMsPerMP))
    print(String(format: "  GPU sustained (estimate): decode %.3f ms + %.3f ms/MP, encode %.3f ms + %.3f ms/MP",
                 u.decodeFixedMs, u.decodeMsPerMP, u.encodeFixedMs, u.encodeMsPerMP))
    print(String(format: "  CPU warm (default rates): decode %.2f ms/MP, encode %.2f ms/MP; CPU cold model (%@): ratio %.2f, ramp %.1f ms",
                 DeviceProfile.defaultCPUDecodeMsPerMP, DeviceProfile.defaultCPUEncodeMsPerMP, (c.measured ? "measured" : "default") as NSString, c.ratio, c.rampMs)
          + (DeviceProfileTesting.cpuFailureReason(p).map { " (proxy not used: \($0))" } ?? ""))
    if let m { print(String(format: "measurement cost: %.1f ms wall (mostly idle gaps), %.1f ms GPU", m.measurementMs, m.measurementGPUMs)
                     + (c.measured ? String(format: ", %.1f ms CPU proxy", c.measurementMs) : "")) }
    else if let why = DeviceProfileTesting.failureReason(p) { print("not measured: \(why)") }
    print("warmth now: \(DeviceProfile.currentWarmth)")
    printCrossovers(p, indent: "")
}

/// the CPU/GPU crossover at the default CPU rates, for each GPU set against the warm and the cold CPU
private func printCrossovers(_ p: DeviceProfile, indent: String) {
    for op in [DeviceProfile.Operation.decode, .encode] {
        let parts = [("GPU cold", p.sporadicRouting), ("GPU warm", p.warmRouting), ("GPU sustained", p.sustainedRouting)].map { name, r in
            "\(name): CPU warm \(crossover(r, op, p.cpuColdModel, cpuWarm: true)), CPU cold \(crossover(r, op, p.cpuColdModel, cpuWarm: false))"
        }
        print("\(indent)\(op) crossover: " + parts.joined(separator: "; "))
    }
}

/// the image size above which the GPU set `r` beats the CPU at the default rate (warm, or cold through `m`)
func crossover(_ r: DeviceProfile.Routing, _ op: DeviceProfile.Operation, _ m: DeviceProfile.CPUColdModel, cpuWarm: Bool) -> String {
    guard let mp = crossoverMP(r, op, m, cpuWarm: cpuWarm, rate: op == .decode ? DeviceProfile.defaultCPUDecodeMsPerMP : DeviceProfile.defaultCPUEncodeMsPerMP) else {
        return "CPU faster to 100 MP"
    }
    let side = Int((mp * 1e6).squareRoot())
    return String(format: "%.3f MP (about %dx%d)", mp, side, side)
}

/// the smallest size (MP, 0.001 MP steps to 100 MP) from which prefersCPU advises the GPU (the CPU must be predicted
/// cpuPreferenceMargin faster to be advised); nil: none
func crossoverMP(_ r: DeviceProfile.Routing, _ op: DeviceProfile.Operation, _ m: DeviceProfile.CPUColdModel, cpuWarm: Bool, rate: Double) -> Double? {
    var mp = 0.001
    while mp <= 100 {
        let w = rate * mp, cpu = cpuWarm ? w : m.coldMs(warmMs: w)
        if r.gpuMs(megapixels: mp, operation: op) <= cpu * (1 + DeviceProfile.cpuPreferenceMargin) { return mp }
        mp += mp < 10 ? 0.001 : 0.1
    }
    return nil
}

// ejm profile-child <mode>:<dir>: run by `ejm api-check device-profile` in a child process, so the profile is read
// for the first time with the cache directory and environment the mode needs. One "OK ..." or "FAIL ..." per line.
//   nocache:<dir>     EJM_PROFILE_CACHE=0; <dir> holds a valid seeded file: not read, not rewritten, nothing added
//   cache:<dir>       <dir> holds a valid seeded file: used, no measurement
//   corrupt:<dir>     <dir> holds a corrupt file: ignored, measured, rewritten valid
//   stale:<dir>       <dir> holds an entry last measured 25 h ago: used at once, re-measured in the background,
//                     merged field by field by minimum, merge count and date updated, source then measured
//   recent:<dir>      <dir> holds an entry measured 1 h ago: used, not re-measured
//   busy:<dir>        a busy device (injected): deferred, estimate kept, nothing written, retried only after 10
//                     minutes (injected clock), measured once idle with the sample in the cache and summary
//   busystale:<dir>   a 25-hour-old entry on a busy device: used, the re-measure deferred, the entry unchanged
//   implausible:<dir> cold fixed costs over 20x the sustained ones: nothing cached, estimate kept, reason in summary
//   cpuonly:<dir>     the same GPU timings, but a CPU proxy run that fits: the CPU model is used and saved on its own
//   unwritable:<dir>  <dir> cannot be created: measured anyway, no crash
// Every mode injects its measurement timings (plausible ones unless named), so children do no timing GPU work.
// Every other mode injects an idle device, so the gate never depends on this machine's load.
func runProfileChild(_ arg: String) -> Bool {
    let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { print("FAIL bad argument \(arg)"); return false }
    let (mode, dir) = (parts[0], URL(fileURLWithPath: parts[1]))
    DeviceProfileTesting.cacheDirectory = dir
    // an idle device, whatever this machine is doing (the busy modes inject a busy one)
    DeviceProfileTesting.idleSampler = mode.hasPrefix("busy") ? { busySample } : { idleSample }
    // deterministic timings (no GPU work in the measurement): plausible ones, or the mode's own
    DeviceProfileTesting.timingOverride = timings(mode)
    let T = Date(timeIntervalSince1970: 1_900_000_000)
    if mode == "busy" { DeviceProfileTesting.clock = { T } }    // the first read defers at T
    var ok = true
    func check(_ c: Bool, _ what: String) { print("\(c ? "OK" : "FAIL") \(mode): \(what)"); if !c { ok = false } }
    let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    let seededFile = DeviceProfileTesting.cacheFile(MetalContext.shared.profile)
    let seededBytes = seededFile.flatMap { try? Data(contentsOf: $0) }
    let p = DeviceProfile.current
    let r = p.measuredRouting(timeout: 30)
    let after = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    switch mode {
    case "nocache":
        check(!DeviceProfileTesting.cacheEnabled, "EJM_PROFILE_CACHE=0 seen")
        check(p.routingSource == .measured && r != nil && r != seeded, "seeded file not read (source \(p.routingSource.rawValue))")
        check(before == after && seededFile.flatMap { try? Data(contentsOf: $0) } == seededBytes, "nothing written")
    case "cache":
        check(p.routingSource == .cache && r == seeded, "seeded file used (source \(p.routingSource.rawValue))")
    case "corrupt":
        check(p.routingSource == .measured && r != nil, "corrupt file ignored, measured (source \(p.routingSource.rawValue))")
        check(DeviceProfileTesting.loadCache(p) == r, "rewritten with the measurement")
    case "stale":       // seeded 25 h ago: cache at once, then a background re-measure merges by minimum
        check(p.routingSource == .cache && r == staleSeed, "stale entry used first (source \(p.routingSource.rawValue))")
        check(DeviceProfileTesting.waitForRemeasure(p, timeout: 30), "re-measure finished")
        let e = DeviceProfileTesting.entry(p)
        check(p.routingSource == .measured, "source measured after the re-measure (\(p.routingSource.rawValue))")
        check(e?.merges == 4 && (e?.lastMeasured).map { abs($0.timeIntervalSinceNow) < 120 } == true, "merge count 3 -> \(e?.merges ?? -1), date updated")
        if let m = e?.routing {
            check(m == p.routing && m.decodeFixedMs == staleSeed.decodeFixedMs && m.encodeMsPerMP == staleSeed.encodeMsPerMP
                  && m.decodeMsPerMP < staleSeed.decodeMsPerMP && m.encodeFixedMs < staleSeed.encodeFixedMs && m.coldStartMs < staleSeed.coldStartMs,
                  "field-by-field minimum kept (seeded 0.001 kept, seeded 500 replaced)")
        } else { check(false, "merged entry missing") }
    case "recent":      // seeded 1 h ago: used, no re-measure
        check(DeviceProfileTesting.waitForRemeasure(p, timeout: 5), "no re-measure running")
        let e = DeviceProfileTesting.entry(p)
        check(p.routingSource == .cache && r == staleSeed && e?.merges == 3, "recent entry used, not re-measured (source \(p.routingSource.rawValue), merges \(e?.merges ?? -1))")
    case "busy":        // a busy device: deferred, retried at most every 10 minutes, measured once idle
        check(r == nil && p.routingSource == .estimate && DeviceProfileTesting.gateChecks(p) == 1, "busy: deferred, estimate kept (source \(p.routingSource.rawValue))")
        check(after.isEmpty || after == before, "busy: nothing written")
        check(p.summary.contains("measurement deferred, busy (GPU 62%/58%"), "busy shown in summary: \(p.summary)")
        DeviceProfileTesting.clock = { T + 300 }          // 5 minutes after the deferral: no new attempt
        _ = DeviceProfile.current.measuredRouting(timeout: 1)
        let g1 = DeviceProfileTesting.gateChecks(p)
        DeviceProfileTesting.clock = { T + 601 }          // past 10 minutes: one new attempt, deferred again
        _ = DeviceProfile.current.measuredRouting(timeout: 5)
        let g2 = DeviceProfileTesting.gateChecks(p)
        DeviceProfileTesting.clock = { T + 901 }          // 5 minutes after that one: none
        _ = DeviceProfile.current.measuredRouting(timeout: 1)
        let g3 = DeviceProfileTesting.gateChecks(p)
        check(g1 == 1 && g2 == 2 && g3 == 2, "busy: retried after 10 minutes only (gate checks \(g1), \(g2), \(g3))")
        DeviceProfileTesting.idleSampler = { idleSample }
        DeviceProfileTesting.clock = { T + 1300 }
        let m = DeviceProfile.current.measuredRouting(timeout: 30)
        check(m != nil && p.routingSource == .measured && DeviceProfileTesting.gateChecks(p) == 3, "idle again: measured (source \(p.routingSource.rawValue))")
        let e = DeviceProfileTesting.entry(p)
        check(e?.routing.idleSample == idleSample && p.summary.contains("measured idle (GPU 3%/4%, load 1.00 of 10 cores)"),
              "idle sample recorded in the cache and the summary: \(p.summary)")
    case "busystale":   // a 25-hour-old entry on a busy device: used, re-measure deferred, entry unchanged
        check(p.routingSource == .cache && r == staleSeed, "busy stale entry used (source \(p.routingSource.rawValue))")
        check(DeviceProfileTesting.waitForRemeasure(p, timeout: 10), "deferred re-measure over")
        let e = DeviceProfileTesting.entry(p)
        check(p.routingSource == .cache && e?.merges == 3 && e?.routing == staleSeed && DeviceProfileTesting.gateChecks(p) == 1,
              "busy: no re-measure recorded (merges \(e?.merges ?? -1), gate checks \(DeviceProfileTesting.gateChecks(p)))")
    case "implausible":    // cold costs implausible: nothing cached, estimate kept, reason in the summary
        check(r == nil && p.routingSource == .estimate && DeviceProfileTesting.entry(p) == nil && after == before
              && p.sporadicRouting == p.estimatedSporadicRouting, "nothing cached (source \(p.routingSource.rawValue))")
        check(p.summary.contains("measurement not used: implausible: cold decode fixed cost"), "reason in the summary: \(p.summary)")
    case "cpuonly":        // GPU part not used, CPU fit kept and saved on its own
        let c = p.cpuColdModel
        check(r == nil && p.routingSource == .estimate && DeviceProfileTesting.entry(p) == nil, "GPU part not cached (source \(p.routingSource.rawValue))")
        check(c.measured && abs(c.ratio - 4) < 0.2 && DeviceProfileTesting.loadCPUOnlyCache(p) == c,
              "CPU model kept and saved on its own: ratio \(fmt(c.ratio)), ramp \(fmt(c.rampMs, 1))")
    case "unwritable":
        check(p.routingSource == .measured && r != nil, "measured without a cache (source \(p.routingSource.rawValue))")
    case "loadoff":     // EJM_LOAD_CORRECTION=0: off, no samples from real calls, no device read
        check(!DeviceProfile.loadCorrectionEnabled, "EJM_LOAD_CORRECTION=0 seen")
        let px = [UInt8](repeating: 128, count: 640 * 480 * 3)
        let enc = Encoder(), dec = Decoder()
        var jpg = Data()
        for _ in 0..<3 { jpg = (try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 640, height: 480, quality: 90) }) ?? Data() }
        for _ in 0..<3 { _ = dec.decode(jpg) }
        p.beginCPUWork().end(width: 640, height: 480, operation: .decode)
        check(DeviceProfileTesting.loadSampleCount == 0, "no load samples from 3 encodes, 3 decodes and a CPU job (\(DeviceProfileTesting.loadSampleCount))")
        let f = p.loadFactors(width: 640, height: 480, operation: .decode, gpuSet: .warm, cpuWarm: true)
        check(f == DeviceProfile.LoadFactors(gpu: 1, cpu: 1), "factors 1: \(f)")
        Thread.sleep(forTimeInterval: 0.6)
        check(DeviceProfile.currentWarmth.deviceGPUPercent == nil, "no device read")
    default: check(false, "unknown mode")
    }
    // the library still decodes and encodes
    let px = SelfCheckTesting.pixels(width: 64, height: 48, channels: 3, rowBytes: 192)
    let j = try? px.withUnsafeBytes { try Encoder().encode(bytes: $0, width: 64, height: 48) }
    check(j.flatMap { Decoder().decode($0) } != nil, "encode and decode work")
    return ok
}

/// injected measurement timings: the wall ms of 5 isolated 256x256 decodes and encodes, plausible against any
/// Mac's estimate (sustained fixed costs 1.33 and 0.29 ms; cold medians 5 and 1 ms); implausible: 40 ms decode,
/// over 20x 1.33; cpuonly: the same, with a CPU proxy run of the default model
func timings(_ mode: String) -> DeviceProfileTesting.MeasurementTimings {
    mode == "implausible" ? .init(decode: [40, 40, 40, 40, 40], encode: [1, 1, 1, 1, 1])
        : mode == "cpuonly" ? .init(decode: [40, 40, 40, 40, 40], encode: [1, 1, 1, 1, 1],
                                    cpuChunks: DeviceProfileTesting.simulateCPUProxy(DeviceProfile.defaultCPUColdModel, chunkMs: 0.1))
        : .init(decode: [6, 5, 5, 5, 5], encode: [1, 1, 1, 1, 1])
}

/// injected busy samples: an idle device and a busy one (GPU 62% then 58%)
let idleSample = DeviceProfile.IdleSample(gpuUtilization: [3, 4], loadAverage: 1.0, cpuCores: 10)
let busySample = DeviceProfile.IdleSample(gpuUtilization: [62, 58], loadAverage: 3.0, cpuCores: 10)

/// a stale entry's numbers: some far better than any real measurement (0.001, must be kept), some far worse (500,
/// must be replaced)
let staleSeed = DeviceProfile.Routing(decodeFixedMs: 0.001, decodeMsPerMP: 500, encodeFixedMs: 500, encodeMsPerMP: 0.001,
                                      coldStartMs: 500, measured: true, measurementMs: 42, measurementGPUMs: 21)

/// the distinctive routing numbers the api-check seeds into cache files
let seeded = DeviceProfile.Routing(decodeFixedMs: 1.25, decodeMsPerMP: 0.5, encodeFixedMs: 0.75, encodeMsPerMP: 0.25,
                                   coldStartMs: 5, measured: true, measurementMs: 42, measurementGPUMs: 21)
