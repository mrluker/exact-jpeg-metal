import Foundation
import ExactJPEG
import Metal

// ejm inflight [seconds] [rounds]: how many images in flight a GPU takes before throughput stops rising, the data
// behind DeviceProfile.suggestedInFlight. 1, 2, 3, 4, 6 and 8 threads (or a comma-separated list), each with its own Decoder or Encoder, run
// 6720x4480 q95 4:2:2 decodes and 3840x2560 q95 4:4:4 encodes, single-pass and two-pass, for `seconds` (default 2) per point. The points are
// interleaved over `rounds` rounds (default 3), every point once per round, so a burst of outside load hits them
// alike; the medians over rounds are reported with the load average of each round. The first output of every
// thread is compared with libjpeg-turbo's bytes.
func runInFlight(seconds: Double, rounds: Int, threads: [Int] = [1, 2, 3, 4, 6, 8]) {
    let dev = MetalContext.shared.device
    benchProfile()
    let img = Synth.make(width: 6720, height: 4480, seed: 11)
    let jpeg = Turbo.encode(img, 6720, 4480, quality: 95, samp: 1)
    let decRef = Turbo.decode(jpeg)!.px
    let a = Synth.make(width: 3840, height: 2560, seed: 21)
    let encRef = Turbo.encode(a, 3840, 2560, quality: 95, samp: 0)
    let buf = sharedBuffer(a, dev)
    var rates = [String: [Double]]()
    var exact = true
    func point(_ op: String, _ n: Int) -> Double {
        let ok = Slot(true)
        let r: Double
        if op == "decode" {
            r = throughputFor(seconds: seconds, threads: n, make: {
                let d = Decoder()
                let first = d.decode(jpeg)
                if !(first.map { b in decRef.withUnsafeBytes { $0.elementsEqual(b.bytes) } } ?? false) { ok.value = false }
                return d
            }, job: { d in _ = d.decode(jpeg) })
        } else {
            r = throughputFor(seconds: seconds, threads: n, make: {
                let e = Encoder()
                e.fusedMaxBlocks = op == "encode-fused" ? 2_000_000 : 0
                if (try? e.encode(buffer: buf, width: 3840, height: 2560, quality: 95, subsampling: .s444)) != encRef { ok.value = false }
                return e
            }, job: { e in _ = try! e.encode(buffer: buf, width: 3840, height: 2560, quality: 95, subsampling: .s444) })
        }
        if !ok.value { exact = false }
        return r
    }
    var loads: [String] = []
    for round in 1...rounds {
        let load = Bench.shell("sysctl -n vm.loadavg | tr -d '{}' | xargs")
        loads.append(load)
        print("round \(round), load \(load)")
        for op in ["decode", "encode-fused", "encode-two-pass"] {
            for n in threads {
                let r = point(op, n)
                rates["\(op) \(n)", default: []].append(r)
                print(String(format: "  %@ x%d: %6.1f images/s", op as NSString, n, r))
            }
        }
    }
    print("\nmedians over \(rounds) rounds (\(fmt(seconds, 1)) s per point), loads: \(loads.joined(separator: "; "))")
    print("threads | decode 6720x4480 q95 4:2:2 | encode 3840x2560 q95 4:4:4 single-pass | the same, two-pass")
    for n in threads {
        print(String(format: "  x%d    | %6.1f images/s | %6.1f images/s | %6.1f images/s", n, median(rates["decode \(n)"]!),
                     median(rates["encode-fused \(n)"]!), median(rates["encode-two-pass \(n)"]!)))
    }
    print(exact ? "every thread's first output byte-identical to libjpeg-turbo" : "OUTPUT DIFFERENT from libjpeg-turbo")
}

/// `threads` threads, each with its own state from `make` (built before the clock starts), run `job` for `seconds`.
func throughputFor<S>(seconds: Double, threads: Int, make: () -> S, job: (inout S) -> Void) -> Double {
    var states = (0..<threads).map { _ in make() }
    let done = ManagedAtomicCounter()
    let t0 = now()
    withoutActuallyEscaping(job) { job in
        states.withUnsafeMutableBufferPointer { st in
            let base = Unchecked(st.baseAddress!), job = Unchecked(job)
            DispatchQueue.concurrentPerform(iterations: threads) { k in
                while now() - t0 < seconds { job.value(&base.value[k]); _ = done.increment() }
            }
        }
    }
    return Double(done.value) / (now() - t0)
}
