import Foundation
import Metal
@_spi(Testing) import ExactJPEG

// Per-stage GPU time of a decode, shared by `ejm decode-profile` and the iOS check app (--decode-profile).
// Method: Decoder.profileStopAfter = k encodes only the first k dispatches; the GPU time of prefix k minus that of
// prefix k - 1 is dispatch k's cost, including its barrier. Prefixes are interleaved in rounds (every prefix once per
// round, `reps` calls each) so a clock change hits them alike; per prefix the median over all calls is used (the
// minimum is recorded too). One decoder thread only: with two, command buffers overlap on the GPU and a command
// buffer's GPU time no longer measures its own work.
// Also: the per-dispatch cost of empty dispatches (serial and concurrent encoders) and each kernel's threadgroup memory.

struct StageCost { let stage: String; var dispatches: Int; var ms: Double }

func profileMedian(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

/// GPU ms of each prefix 0...n of the decode of `jpeg` (n = its number of dispatches), the dispatch names, and the
/// full decode's host timings and pass count.
func profileDecode(_ jpeg: Data, rounds: Int, reps: Int) -> (names: [String], prefixMs: [Double], info: [String: Any]) {
    // (prefixMs: the median per prefix; info["prefix_min_ms"]: the minimums)
    let dec = Decoder()
    dec.profileRecord = true
    guard dec.decode(jpeg) != nil else { return ([], [], ["error": dec.reason ?? "?"]) }
    let names = dec.profileDispatches, passes = dec.passes
    var host: [String: [Double]] = ["prep": [], "encode": [], "wait": [], "gpu": [], "wall": []]
    for _ in 0..<20 {
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = dec.decode(jpeg)
        host["wall"]!.append(CFAbsoluteTimeGetCurrent() - t0)
        host["prep"]!.append(dec.hostPrepSeconds); host["encode"]!.append(dec.hostEncodeSeconds)
        host["wait"]!.append(dec.waitSeconds); host["gpu"]!.append(dec.gpuSeconds)
    }
    dec.profileRecord = false
    var samples = [[Double]](repeating: [], count: names.count + 1)
    for _ in 0..<rounds {
        for k in 0...names.count {
            dec.profileStopAfter = k == names.count ? Int.max : k
            for _ in 0..<reps { _ = dec.decode(jpeg); samples[k].append(dec.gpuSeconds * 1000) }
        }
    }
    var info: [String: Any] = ["passes_needed": passes, "dispatches": names.count, "prefix_min_ms": samples.map { $0.min() ?? .nan }]
    for (k, v) in host { info["host_\(k)_ms"] = profileMedian(v) * 1000 }
    return (names, samples.map(profileMedian), info)
}

/// per-stage sums of the prefix differences (stage = the part of the dispatch name before ':')
func stageCosts(_ names: [String], _ prefix: [Double]) -> [StageCost] {
    var out: [StageCost] = [StageCost(stage: "empty command buffer", dispatches: 0, ms: prefix.first ?? .nan)]
    for (k, n) in names.enumerated() {
        let st = String(n.split(separator: ":").first ?? "")
        let d = prefix[k + 1] - prefix[k]
        if out.last!.stage == st { out[out.count - 1].dispatches += 1; out[out.count - 1].ms += d }
        else { out.append(StageCost(stage: st, dispatches: 1, ms: d)) }
    }
    return out
}

/// GPU ms per dispatch of n trivial dispatches (one 32-thread threadgroup writing nothing), serial and concurrent
func emptyDispatchCost(_ ctx: MetalContext = .shared) -> [String: Any] {
    let p = ctx.pipeline("fill_u32")
    let b = ctx.device.makeBuffer(length: 4096, options: .storageModeShared)!
    func run(_ n: Int, _ type: MTLDispatchType) -> Double {
        var g: [Double] = []
        for _ in 0..<15 {
            let cb = ctx.queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder(dispatchType: type)!
            e.setComputePipelineState(p)
            var v: UInt32 = 0, z: UInt32 = 0
            e.setBuffer(b, offset: 0, index: 0); e.setBytes(&v, length: 4, index: 1); e.setBytes(&z, length: 4, index: 2)
            for _ in 0..<n { e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1)) }
            e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            g.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        return profileMedian(g)
    }
    var r: [String: Any] = [:]
    for (name, t) in [("serial", MTLDispatchType.serial), ("concurrent", .concurrent)] {
        let lo = run(1, t), hi = run(65, t)
        r["\(name)_1_ms"] = lo; r["\(name)_65_ms"] = hi; r["\(name)_per_dispatch_us"] = (hi - lo) / 64 * 1000
    }
    return r
}

/// static threadgroup memory of the decoder's kernels (bytes; sync_pass and decode_write add the Huffman tables)
func decodeKernelMemory(_ ctx: MetalContext = .shared) -> [String: Any] {
    var r: [String: Any] = ["max_threadgroup_memory": ctx.device.maxThreadgroupMemoryLength]
    for k in ["unstuff_count", "unstuff_scatter", "scan_up", "scan_mid", "scan_down", "fix_segs", "seg_chunks", "make_chunks",
              "sync_pass", "first_blocks", "decode_write", "idct_islow", "color"] {
        let p = ctx.pipeline(k)
        r[k] = ["static_tg_bytes": p.staticThreadgroupMemoryLength, "max_threads": p.maxTotalThreadsPerThreadgroup,
                "simd_width": p.threadExecutionWidth]
    }
    return r
}

/// the whole profile of one file as printable lines and a JSON-able dictionary
func decodeProfileReport(label: String, jpeg: Data, rounds: Int, reps: Int) -> (lines: [String], json: [String: Any]) {
    let (names, prefix, info) = profileDecode(jpeg, rounds: rounds, reps: reps)
    guard !names.isEmpty else { return (["\(label): \(info["error"] ?? "?")"], ["case": label, "error": info["error"] ?? "?"]) }
    let st = stageCosts(names, prefix)
    var lines = [String(format: "profile %@: full decode GPU %.3f ms (prefix median %.3f), wall %.3f; host prep %.3f, encode %.3f, commit->done %.3f ms; %d dispatches; sync passes needed %d of %d encoded",
                        label, info["host_gpu_ms"] as! Double, prefix.last!, info["host_wall_ms"] as! Double, info["host_prep_ms"] as! Double,
                        info["host_encode_ms"] as! Double, info["host_wait_ms"] as! Double, names.count, info["passes_needed"] as! Int,
                        names.filter { $0.hasSuffix(":sync_pass") }.count)]
    for s in st { lines.append("  " + s.stage.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: " %2d dispatch(es) %8.3f ms", s.dispatches, s.ms)) }
    var js: [String: Any] = info
    js["case"] = label; js["bytes"] = jpeg.count; js["dispatch_names"] = names; js["prefix_gpu_ms"] = prefix
    js["stages"] = st.map { ["stage": $0.stage, "dispatches": $0.dispatches, "ms": $0.ms] }
    return (lines, js)
}

// GPU clock experiments (facts about the device's clock management, not library changes). A one-threadgroup ALU loop
// ("spin", 32 threads, fixed iteration count) is a clock meter: its GPU time is inversely proportional to the clock.
// Decodes are timed: sequential (one decoder, commit and wait); two decoders on two threads (always one command
// buffer queued); sequential while a second queue keeps the spin kernel running (2 in flight) on one GPU core.
final class ClockKeeper: @unchecked Sendable {      // running / times are touched by its own thread only while running
    let ctx: MetalContext, queue: MTLCommandQueue, pso: MTLComputePipelineState, buf: MTLBuffer
    var running = false
    let done = DispatchSemaphore(value: 0)
    init(_ ctx: MetalContext = .shared) {
        self.ctx = ctx
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void spin(device uint* o [[buffer(0)]], constant uint& n [[buffer(1)]], uint t [[thread_position_in_grid]]) {
            uint x = t;
            for (uint i = 0; i < n; i++) x = x * 1664525u + 1013904223u;
            if (x == 7u) o[0] = x;
        }
        """
        let lib = try! ctx.device.makeLibrary(source: src, options: nil)
        pso = try! ctx.device.makeComputePipelineState(function: lib.makeFunction(name: "spin")!)
        queue = ctx.device.makeCommandQueue()!
        buf = ctx.device.makeBuffer(length: 64, options: .storageModeShared)!
    }
    func makeCB(_ n: UInt32) -> MTLCommandBuffer {
        let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        var n = n
        e.setComputePipelineState(pso); e.setBuffer(buf, offset: 0, index: 0); e.setBytes(&n, length: 4, index: 1)
        e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        e.endEncoding()
        return cb
    }
    /// GPU ms of one spin command buffer, committed alone and waited for
    func once(_ n: UInt32) -> Double { let cb = makeCB(n); cb.commit(); cb.waitUntilCompleted(); return (cb.gpuEndTime - cb.gpuStartTime) * 1000 }
    /// keep two spin command buffers in flight until stop(); returns the GPU ms of each
    var times: [Double] = []
    func start(_ n: UInt32) {
        running = true; times = []
        Thread.detachNewThread { [self] in
            let sem = DispatchSemaphore(value: 2), lock = NSLock()
            while running {
                sem.wait()
                let cb = makeCB(n)
                cb.addCompletedHandler { c in lock.lock(); self.times.append((c.gpuEndTime - c.gpuStartTime) * 1000); lock.unlock(); sem.signal() }
                cb.commit()
            }
            sem.wait(); sem.wait(); sem.signal(); sem.signal()      // (a semaphore must not be freed below its start value)
            done.signal()
        }
    }
    func stop() -> [Double] { running = false; done.wait(); return times }
}

/// two decoders and their GPU times, each used by one thread only
final class TwoDecoders: @unchecked Sendable {
    final class Times { var v: [Double] = [] }
    var decs = [Decoder(), Decoder()]          // var: the iOS timing reuses its timed decoder as decs[0]
    let gpu = [Times(), Times()]
}

func clockExperiments(_ jpeg: Data, label: String) -> (lines: [String], json: [String: Any]) {
    let k = ClockKeeper()
    let n: UInt32 = 50_000
    _ = k.once(n)
    // clock meter: alone after 50 ms idle, and in a continuous stream
    var idle: [Double] = []
    for _ in 0..<7 { Thread.sleep(forTimeInterval: 0.05); idle.append(k.once(n)) }
    k.start(n); Thread.sleep(forTimeInterval: 1.0); let streamT = k.stop()
    let stream = Array(streamT.suffix(20))
    var lines = [String(format: "clock meter (spin, 1 threadgroup): alone after 50 ms idle %.3f ms, in a continuous stream %.3f ms (ratio %.2f)",
                        profileMedian(idle), profileMedian(stream), profileMedian(idle) / profileMedian(stream))]
    var js: [String: Any] = ["case": label, "spin_idle_ms": profileMedian(idle), "spin_stream_ms": profileMedian(stream)]
    let dec = Decoder()
    func seq(_ count: Int) -> (gpu: Double, wall: Double) {
        var g: [Double] = [], w: [Double] = []
        for _ in 0..<count { let t0 = CFAbsoluteTimeGetCurrent(); _ = dec.decode(jpeg); w.append(CFAbsoluteTimeGetCurrent() - t0); g.append(dec.gpuSeconds) }
        return (profileMedian(g) * 1000, profileMedian(w) * 1000)
    }
    for _ in 0..<2 {
        _ = seq(10)
        let a = seq(30)
        // two decoders on two threads
        let two = TwoDecoders()
        for d in two.decs { _ = d.decode(jpeg) }
        let t0 = CFAbsoluteTimeGetCurrent()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            for _ in 0..<30 { _ = two.decs[i].decode(jpeg); two.gpu[i].v.append(two.decs[i].gpuSeconds) }
        }
        let g2 = two.gpu.map(\.v)
        let per2 = (CFAbsoluteTimeGetCurrent() - t0) / 60 * 1000
        // sequential with the spin kernel kept running on a second queue
        k.start(n); Thread.sleep(forTimeInterval: 0.3)
        let b = seq(30)
        let kt = k.stop()
        lines.append(String(format: "clock %@: sequential GPU %.3f ms, wall %.3f; two decoders on two threads: %.3f ms wall per image, GPU %.3f per decode; sequential with the spin kernel kept running: GPU %.3f, wall %.3f (spin %.3f ms)",
                            label, a.gpu, a.wall, per2, profileMedian(g2[0] + g2[1]) * 1000, b.gpu, b.wall, profileMedian(Array(kt.suffix(20)))))
        js["sequential_gpu_ms"] = a.gpu; js["sequential_wall_ms"] = a.wall; js["two_threads_wall_per_image_ms"] = per2
        js["two_threads_gpu_ms"] = profileMedian(g2[0] + g2[1]) * 1000; js["with_spin_gpu_ms"] = b.gpu; js["with_spin_wall_ms"] = b.wall
    }
    return (lines, js)
}

/// GPU time of decodes over time after the GPU has idled: does it leave its slow state, and what makes it.
/// Each scenario starts after `idle` seconds without GPU work, then decodes `jpeg` for `seconds`; the result is the
/// median GPU (and wall) ms per 0.25 s bucket.
func clockTrajectories(_ jpeg: Data, big: Data?, idle: Double = 3, seconds: Double = 3) -> (lines: [String], json: [String: Any]) {
    let k = ClockKeeper()
    _ = k.once(1000)
    var lines: [String] = [], js: [String: Any] = [:]
    func series(_ name: String, threads: Int, pre: () -> Void) {
        Thread.sleep(forTimeInterval: idle)
        pre()
        let two = TwoDecoders()
        let t0 = CFAbsoluteTimeGetCurrent()
        final class Log: @unchecked Sendable { var v: [[(Double, Double, Double)]] = [[], []] }   // (t, gpu, wall) per thread
        let log = Log()
        DispatchQueue.concurrentPerform(iterations: threads) { i in
            var mine: [(Double, Double, Double)] = []
            while CFAbsoluteTimeGetCurrent() - t0 < seconds {
                let a = CFAbsoluteTimeGetCurrent()
                _ = two.decs[i].decode(jpeg)
                mine.append((a - t0, two.decs[i].gpuSeconds * 1000, (CFAbsoluteTimeGetCurrent() - a) * 1000))
            }
            log.v[i] = mine
        }
        let all = (log.v[0] + log.v[1]).sorted { $0.0 < $1.0 }
        var buckets: [String] = [], bj: [[String: Double]] = []
        var b = 0.0
        while b < seconds {
            let s = all.filter { $0.0 >= b && $0.0 < b + 0.25 }
            if !s.isEmpty {
                let g = profileMedian(s.map(\.1)), w = profileMedian(s.map(\.2))
                buckets.append(String(format: "%.2f/%.1f", g, w)); bj.append(["t": b, "gpu_ms": g, "wall_ms": w, "n": Double(s.count)])
            }
            b += 0.25
        }
        lines.append("trajectory \(name) (GPU/wall ms per 0.25 s, \(all.count) decodes): " + buckets.joined(separator: " "))
        js[name] = bj
    }
    series("sequential from idle", threads: 1) {}
    series("two decoder threads from idle", threads: 2) {}
    series("sequential after one 6720x4480 decode", threads: 1) { if let big { _ = Decoder().decode(big) } }
    series("sequential after 0.2 s of the spin stream", threads: 1) { k.start(50_000); Thread.sleep(forTimeInterval: 0.2); _ = k.stop() }
    // once fast: how long an idle gap keeps the fast state
    for gap in [0.01, 0.05, 0.2, 1.0] {
        let d = Decoder()
        let t0 = CFAbsoluteTimeGetCurrent()
        k.start(50_000); Thread.sleep(forTimeInterval: 0.5); _ = k.stop()
        var g: [Double] = []
        while CFAbsoluteTimeGetCurrent() - t0 < 1.0 { _ = d.decode(jpeg) }
        for _ in 0..<5 { Thread.sleep(forTimeInterval: gap); _ = d.decode(jpeg); g.append(d.gpuSeconds * 1000) }
        lines.append(String(format: "after the fast state, %.0f ms idle then one decode: GPU %.3f ms (median of 5)", gap * 1000, profileMedian(g)))
        js["gap_\(Int(gap * 1000))ms_gpu_ms"] = profileMedian(g)
    }
    return (lines, js)
}

/// chunkBits A/B on one file: configurations interleaved in `rounds` rounds, one decoder thread (commit and wait per
/// image) and two decoder threads (one command buffer always queued). Each slice first checks one output byte for
/// byte against `want` (the verified default decode, outside the timing), then decodes for `slice` seconds and
/// times only the second half, so the GPU's clock state has settled for that pattern. Returns per configuration
/// the median over rounds of the wall ms per image and the median GPU ms per decode.
func chunkAB(_ jpeg: Data, want: [UInt8], bits: [Int], rounds: Int = 4, slice: Double = 1.6) -> (lines: [String], json: [[String: Any]], ok: Bool) {
    final class Cfg: @unchecked Sendable {      // each decoder is used by one thread; the rest under `lock`
        let decs: [Decoder]; var wall: [Double] = [], gpu: [Double] = [], ok = true, n = 0
        init(_ b: Int) { decs = [Decoder(), Decoder()]; for d in decs { d.chunkBits = b } }
    }
    let cfgs = bits.map(Cfg.init)
    var lines: [String] = [], js: [[String: Any]] = [], allOK = true
    for threads in [1, 2] {
        for c in cfgs { c.wall = []; c.gpu = [] }
        for _ in 0..<rounds {
            for c in cfgs {
                for d in c.decs { c.ok = c.ok && (d.decode(jpeg).map { $0.bytes.count == want.count && memcmp($0.bytes.baseAddress!, want, want.count) == 0 } ?? false) }
                c.n = 0
                let lock = NSLock()
                let t0 = CFAbsoluteTimeGetCurrent(), half = slice / 2
                DispatchQueue.concurrentPerform(iterations: threads) { i in
                    var g: [Double] = [], k = 0, good = true
                    while CFAbsoluteTimeGetCurrent() - t0 < slice {
                        let counted = CFAbsoluteTimeGetCurrent() - t0 >= half
                        if c.decs[i].decode(jpeg) == nil { good = false; break }
                        if counted { g.append(c.decs[i].gpuSeconds * 1000); k += 1 }
                    }
                    lock.lock(); c.n += k; c.gpu += g; c.ok = c.ok && good; lock.unlock()
                }
                c.wall.append((CFAbsoluteTimeGetCurrent() - t0 - half) / Double(max(c.n, 1)) * 1000)
            }
        }
        for (b, c) in zip(bits, cfgs) {
            let w = profileMedian(c.wall), g = profileMedian(c.gpu)
            lines.append(String(format: "  chunkBits %5d, %d thread(s): %.3f ms wall per image, GPU %.3f ms per decode, %@", b, threads, w, g, c.ok ? "identical" : "DIFFERENT"))
            js.append(["chunk_bits": b, "threads": threads, "wall_per_image_ms": w, "gpu_ms": g, "identical": c.ok, "wall_rounds_ms": c.wall])
            allOK = allOK && c.ok
        }
    }
    return (lines, js, allOK)
}
