import Foundation
@_spi(Testing) import ExactJPEG
import Metal

// ejm perf-small [rounds]: the small-export encode speed-ups, measured step by step. Configurations are interleaved
// in short rounds (each round runs every configuration for ~0.25 s) and the medians across rounds are reported, so a
// background disturbance hits all configurations alike. Every output is compared with libjpeg-turbo's bytes.
struct PerfConfig { let name: String; let images: Int; let run: () -> (gpuPerImage: Double, ok: Bool) }

func measureInterleaved(_ configs: [PerfConfig], rounds: Int, slice: Double = 0.25) -> [(String, Double, Double, Double, Bool)] {
    var ips = [[Double]](repeating: [], count: configs.count), gpu = ips, wall = ips
    var ok = [Bool](repeating: true, count: configs.count)
    for _ in 0..<rounds {
        for (k, c) in configs.enumerated() {
            var n = 0, g: [Double] = []
            let t0 = now()
            while now() - t0 < slice { let r = c.run(); n += c.images; g.append(r.gpuPerImage); ok[k] = ok[k] && r.ok }
            let dt = now() - t0
            ips[k].append(Double(n) / dt); wall[k].append(dt / Double(n)); gpu[k].append(median(g))
        }
    }
    return configs.indices.map { (configs[$0].name, median(ips[$0]), median(wall[$0]), median(gpu[$0]), ok[$0]) }
}

func printPerf(_ rows: [(String, Double, Double, Double, Bool)]) {
    for (name, ips, wall, gpu, ok) in rows {
        print(String(format: "  %-34@ %7.0f images/s   wall %.3f ms/image, GPU %.3f ms/image   %@", name as NSString, ips,
                     wall * 1000, gpu * 1000, ok ? "byte-identical" : "DIFFERENT"))
    }
}

func runPerfSmall(rounds: Int = 8) {
    benchProfile()
    let dev = MetalContext.shared.device
    print("load: \(Bench.shell("sysctl -n vm.loadavg")); \(rounds) interleaved rounds, medians")
    for (w, h, q, ss, si) in [(1200, 800, 87, Subsampling.s420, 2), (1500, 1000, 90, .s444, 0)] {
        let a = Synth.make(width: w, height: h, seed: 21)
        let ref = Turbo.encode(a, w, h, quality: q, samp: si)
        let buf = sharedBuffer(a, dev)
        print("\n== \(w)x\(h) q\(q) \(["4:4:4", "4:2:2", "4:2:0"][si])")
        let job = EncodeJob(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
        var configs: [PerfConfig] = []
        for (n, fusedOn) in [(1, false), (16, false), (1, true), (4, true), (16, true), (32, true)] {
            let enc = Encoder()
            enc.fusedMaxBlocks = fusedOn ? 2_000_000 : 0     // explicit: the device default may be either
            let jobs = Array(repeating: job, count: n)
            configs.append(PerfConfig(name: "batch \(n)\(fusedOn ? ", single-pass" : ", two-pass")", images: n) {
                let out = try! enc.encodeBatch(jobs)
                return (enc.gpuSeconds / Double(n), out[0] == ref && out[n - 1] == ref)
            })
        }
        // GPU time of each stage prefix (stage names in Encoder.stages), batch 16
        let names = ["fill+dct", "dummy dc", "count", "scan up", "scan mid", "scan down", "write", "stuff count", "scan up", "scan mid", "scan down", "stuff scatter"]
        var prof: [PerfConfig] = []
        for k in 1...names.count {
            let e = Encoder(); e.profileStages = k
            let jobs = Array(repeating: job, count: 16)
            prof.append(PerfConfig(name: "stages 1-\(k) (to \(names[k - 1]))", images: 16) {
                _ = try! e.encodeBatch(jobs); return (e.gpuSeconds / 16, true) })
        }
        if ProcessInfo.processInfo.environment["EJM_PROFILE"] == "1" { printPerf(measureInterleaved(prof, rounds: 4)) }
        let warm = Encoder()
        warmUp { _ = try! warm.encodeBatch([job]) }
        printPerf(measureInterleaved(configs, rounds: rounds))
    }
}

/// single-image encode at the larger sizes, two-pass vs single-pass (interleaved medians)
func runPerfLarge(rounds: Int) {
    benchProfile()
    let dev = MetalContext.shared.device
    for (w, h, q, ss, si) in [(3840, 2560, 95, Subsampling.s444, 0), (6720, 4480, 95, .s422, 1)] {
        let a = Synth.make(width: w, height: h, seed: 21)
        let ref = Turbo.encode(a, w, h, quality: q, samp: si)
        let job = EncodeJob(buffer: sharedBuffer(a, dev), width: w, height: h, quality: q, subsampling: ss)
        print("\n== \(w)x\(h) q\(q)")
        var configs: [PerfConfig] = []
        for fused in [false, true] {
            let e = Encoder(); e.fusedMaxBlocks = fused ? 2_000_000 : 0
            configs.append(PerfConfig(name: fused ? "single-pass" : "two-pass", images: 1) {
                let o = try! e.encodeBatch([job]); return (e.gpuSeconds, o[0] == ref) })
        }
        printPerf(measureInterleaved(configs, rounds: rounds, slice: 0.4))
    }
}

/// why two concurrent decoders were slower than one: per-decode wall and GPU time with 1 and 2 decoder threads
func runDecodeConcurrency(rounds: Int) {
    benchProfile()
    let img = Synth.make(width: 6720, height: 4480, seed: 11)
    let jpeg = Turbo.encode(img, 6720, 4480, quality: 95, samp: 1)
    for threads in [1, 2, 1, 2] {
        let decs = (0..<threads).map { _ in Decoder() }
        for d in decs { _ = d.decode(jpeg) }
        let gpu = (0..<threads).map { _ in Slot([Double]()) }, prep = (0..<threads).map { _ in Slot([Double]()) }
        let wait = (0..<threads).map { _ in Slot([Double]()) }
        let n = 24 * rounds
        let next = ManagedAtomicCounter()
        let shared = Unchecked(decs)
        let t0 = now()
        DispatchQueue.concurrentPerform(iterations: threads) { k in
            let d = shared.value[k]
            while next.increment() <= n {
                _ = d.decode(jpeg)
                gpu[k].value.append(d.gpuSeconds); prep[k].value.append(d.hostPrepSeconds); wait[k].value.append(d.waitSeconds)
            }
        }
        let dt = now() - t0
        let g = gpu.flatMap { $0.value }, p = prep.flatMap { $0.value }, w = wait.flatMap { $0.value }
        print(String(format: "  %d decoder(s): %6.1f images/s; per decode: GPU %.2f ms, host prep %.2f ms, commit->done %.2f ms",
                     threads, Double(n) / dt, median(g) * 1000, median(p) * 1000, median(w) * 1000))
    }
}
