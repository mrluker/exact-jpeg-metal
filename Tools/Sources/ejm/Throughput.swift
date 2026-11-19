import Foundation
import ExactJPEG
import ImageIO
import CoreGraphics
import Metal

// Batch throughput (images per second) for the same corpus as the single-image benchmarks: how many images a
// machine gets through when it has a whole batch, not how fast one image goes. libjpeg-turbo cannot split one
// image across cores, so its all-core number runs one image per core at a time.
//
// Variants per task: libjpeg-turbo on 1 core and on all cores (one image per core), Metal exact with 1 and 2
// concurrent decoders/encoders (each with its own buffers and command buffers, sharing the GPU), ImageIO on 1
// thread and on all cores. The same image is processed `count` times per variant (the work per image does not
// depend on having seen it before); the GPU is warmed first.

func cpuTopology() -> (total: Int, performance: Int, efficiency: Int) {
    func n(_ k: String) -> Int { Int(Bench.shell("sysctl -n \(k) 2>/dev/null")) ?? 0 }
    return (ProcessInfo.processInfo.activeProcessorCount, n("hw.perflevel0.physicalcpu"), n("hw.perflevel1.physicalcpu"))
}

/// Run `count` jobs over `threads` threads (each thread gets its own state from `make`), return images per second.
/// `make` runs before the clock starts, and should do one untimed job so first-use allocations are not timed.
func throughput<S>(count: Int, threads: Int, make: () -> S, job: (inout S) -> Void) -> Double {
    // runs for at least `minSeconds` (and at least `count` jobs), so short jobs are not timed over a few milliseconds
    var states = (0..<threads).map { _ in make() }
    let done = ManagedAtomicCounter()
    let minSeconds = 1.5
    let t0 = now()
    withoutActuallyEscaping(job) { job in
        states.withUnsafeMutableBufferPointer { st in
            let base = Unchecked(st.baseAddress!), job = Unchecked(job)
            DispatchQueue.concurrentPerform(iterations: threads) { k in
                while now() - t0 < minSeconds || done.value < count { job.value(&base.value[k]); _ = done.increment() }
            }
        }
    }
    return Double(done.value) / (now() - t0)
}

/// A mutable value written by one concurrentPerform iteration and read after concurrentPerform returns.
final class Slot<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

final class ManagedAtomicCounter: @unchecked Sendable {
    private var v = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; v += 1; return v }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
}

func runThroughputBench(count: Int) {
    benchProfile()
    let topo = cpuTopology()
    print("\n== batch throughput (images per second), each variant at least 1.5 s; CPU: \(topo.total) cores (\(topo.performance) performance + \(topo.efficiency) efficiency)")
    let cores = topo.total
    func record(_ op: String, _ label: String, _ w: Int, _ h: Int, _ q: Int, _ ss: String, _ impl: String, _ threads: Int, _ ips: Double) {
        Bench.records.append(["op": "throughput-" + op, "case": label, "width": w, "height": h, "quality": q, "subsampling": ss,
                              "impl": impl, "threads": threads, "images_per_s": (ips * 100).rounded() / 100, "count": count])
        print(String(format: "  %-44@ %7.2f images/s", "\(impl) x\(threads)" as NSString, ips))
    }

    // decode 6720x4480 q95 4:2:2
    let img = Synth.make(width: 6720, height: 4480, seed: 11)
    let jpeg = Turbo.encode(img, 6720, 4480, quality: 95, samp: 1)
    print("decode 6720x4480 q95 4:2:2 (\(jpeg.count / 1024) KB)")
    let px = 6720 * 4480 * 3
    let warmDec = Decoder()
    warmUp { _ = warmDec.decode(jpeg) }
    for t in [1, 2] {
        record("decode", "decode 6720x4480 q95 4:2:2", 6720, 4480, 95, "4:2:2", "metal", t,
               throughput(count: count, threads: t, make: { let d = Decoder(); _ = d.decode(jpeg); return d }, job: { d in _ = d.decode(jpeg) }))
    }
    for t in [1, cores] {
        record("decode", "decode 6720x4480 q95 4:2:2", 6720, 4480, 95, "4:2:2", "libjpeg-turbo", t,
               throughput(count: count, threads: t, make: { [UInt8](repeating: 0, count: px) },
                          job: { b in _ = b.withUnsafeMutableBufferPointer { Turbo.decodeInto(jpeg, $0.baseAddress!) } }))
    }
    for t in [1, cores] {
        record("decode", "decode 6720x4480 q95 4:2:2", 6720, 4480, 95, "4:2:2", "imageio", t,
               throughput(count: count, threads: t, make: { () }, job: { _ in
                   _ = imageIODecode(jpeg, into: nil, hardware: true)   // kCGImageSourceShouldCacheImmediately: decoded here
               }))
    }

    // the three exports
    for (w, h, q, ss, si) in [(3840, 2560, 95, Subsampling.s444, 0), (1500, 1000, 90, .s444, 0), (1200, 800, 87, .s420, 2)] {
        let a = Synth.make(width: w, height: h, seed: 21)
        let sub = ["4:4:4", "4:2:2", "4:2:0"][si]
        let label = "encode \(w)x\(h) q\(q) \(sub)"
        print(label)
        let dev = MetalContext.shared.device
        let buf = sharedBuffer(a, dev)
        let warmEnc = Encoder()
        warmUp { _ = try! warmEnc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss) }
        let n = count * (w * h > 4_000_000 ? 1 : 4)       // small images: more of them, for a stable rate
        for t in [1, 2] {
            record("encode", label, w, h, q, sub, "metal", t,
                   throughput(count: n, threads: t, make: { let e = Encoder(); _ = try! e.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss); return e },
                              job: { e in _ = try! e.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss) }))
        }
        // batches of 16 images per submission (encodeBatch), one thread
        let job = EncodeJob(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
        let batch = Array(repeating: job, count: 16)
        let nb = max(n / 16, 2)
        let batchRate = 16 * throughput(count: nb, threads: 1, make: { let e = Encoder(); _ = try! e.encodeBatch(batch); return e },
                                        job: { e in _ = try! e.encodeBatch(batch) })
        record("encode", label, w, h, q, sub, "metal-batch16", 1, batchRate)
        for t in [1, cores] {
            record("encode", label, w, h, q, sub, "libjpeg-turbo", t,
                   throughput(count: n, threads: t, make: { () }, job: { _ in _ = Turbo.encode(a, w, h, quality: q, samp: si) }))
        }
        // hybrid: one thread feeds the GPU with batches of 16 while the other cores run libjpeg-turbo, all pulling from
        // one shared queue, so both sides finish together; the bytes are identical whichever side encodes an image
        let hn = max(200, Int(2.5 * batchRate))                // about 1.5-2 s of work
        let queue = ManagedAtomicCounter()
        let gpuEnc = Encoder()
        _ = try! gpuEnc.encodeBatch(batch)
        let gpuDone = Slot(0), cpuDone = (0..<(cores - 1)).map { _ in Slot(0) }
        let allExact = Slot(true)
        let shared = Unchecked((gpuEnc, batch))
        let ref = Turbo.encode(a, w, h, quality: q, samp: si)
        let th0 = now()
        DispatchQueue.concurrentPerform(iterations: cores) { k in
            if k == 0 {
                while true {
                    var take = 0
                    while take < 16 && queue.increment() <= hn { take += 1 }
                    if take == 0 { break }
                    let (gpuEnc, batch) = shared.value
                    let out = try! gpuEnc.encodeBatch(Array(batch.prefix(take)))
                    if out[0] != ref { allExact.value = false }
                    gpuDone.value += take
                    if take < 16 { break }
                }
            } else {
                while queue.increment() <= hn { _ = Turbo.encode(a, w, h, quality: q, samp: si); cpuDone[k - 1].value += 1 }
            }
        }
        let hips = Double(hn) / (now() - th0)
        record("encode", label, w, h, q, sub, "hybrid", cores, hips)
        print(String(format: "    hybrid split: GPU %d images, CPU %d images (%d threads), %@", gpuDone.value, cpuDone.reduce(0) { $0 + $1.value }, cores - 1,
                     allExact.value ? "GPU outputs byte-identical" : "GPU output DIFFERENT"))
        let cg = cgImage(rgb: a, w, h)
        for t in [1, cores] {
            record("encode", label, w, h, q, sub, "imageio", t,
                   throughput(count: n, threads: t, make: { () }, job: { _ in _ = imageIOEncode(cg, quality: 0.9) }))
        }
    }
    Bench.extraConditions["cpu_performance_cores"] = topo.performance
    Bench.extraConditions["cpu_efficiency_cores"] = topo.efficiency
    Bench.extraConditions["throughput_images_per_variant"] = count
}
