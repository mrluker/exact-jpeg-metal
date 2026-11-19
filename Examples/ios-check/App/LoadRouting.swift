import Foundation
import Metal
import CoreGraphics
@_spi(Testing) import ExactJPEG

// --load-routing: the load-aware routing of DeviceProfile on iOS.
//  1. wiring: no device-wide GPU read on iOS (DeviceActivity gives nil, no background reads start); simulated calls
//     become load samples as `ejm api-check` expects; real decodes, encodes and timed CPU jobs add samples, none
//     while load correction is off
//  2. acceptance cells, as the M4 routing acceptance: 640x480, 1600x1200 and 4032x3024, decode and encode; each rep
//     asks the profile for its advice, then times both truths live (GPU: this library; CPU: ImageIO inside
//     beginCPUWork()/end, so the CPU side feeds the load correction as an app's would). Conditions: idle or 4
//     in-process spinner threads, load correction off or on (alternated), the load correction reset before each
//  3. Low Power Mode and the thermal state before and after each condition

/// busy-loop threads at default QoS, started and stopped around one condition
final class Spinners: @unchecked Sendable {
    private let lock = NSLock()
    private var stopFlag = false
    private let done = DispatchGroup()
    private(set) var sink: UInt64 = 0

    init(count: Int) {
        for k in 0..<count {
            done.enter()
            let t = Thread { [self] in
                var x: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(k)
                while true {
                    for _ in 0..<200_000 { x ^= x << 13; x ^= x >> 7; x ^= x << 17 }
                    lock.lock(); let stop = stopFlag; sink ^= x; lock.unlock()
                    if stop { break }
                }
                done.leave()
            }
            t.qualityOfService = .default
            t.name = "spinner \(k)"
            t.start()
        }
    }

    func stop() {
        lock.lock(); stopFlag = true; lock.unlock()
        done.wait()
    }
}

extension Runner {
    func loadRouting() {
        say("== load routing; Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled), thermal \(thermalName())")
        var out: [String: Any] = [:]
        out["wiring"] = loadRoutingWiring()
        out["cells"] = loadRoutingCells()
        out["load_correction_enabled_at_end"] = DeviceProfile.loadCorrectionEnabled
        results["load_routing"] = out
    }

    // MARK: wiring

    func loadRoutingWiring() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ what: String) {
            rows.append(["check": name, "passed": ok, "detail": what])
            say("load wiring \(name): \(ok ? "PASS" : "FAIL") (\(what))")
            if !ok { fail("load routing wiring \(name): \(what)") }
        }
        DeviceProfile.loadCorrectionEnabled = true
        let p = DeviceProfile.current
        // the library's background calibration (started with MetalContext) is tracked work: a simulated call that
        // overlaps it adds no sample, so let it finish before the checks below
        _ = p.measuredRouting(timeout: 30)

        // iOS: no device-wide GPU counter, so the reads give nil and no background read starts
        _ = DeviceProfileTesting.stopDeviceActivityPolling()
        DeviceProfileTesting.resetDeviceActivity()
        let w = DeviceProfile.currentWarmth
        let pollingAfterWarmth = DeviceProfileTesting.deviceActivityPolling
        let d = p.routingDecision(width: 1600, height: 1200, operation: .decode)
        let pollingAfterAdvice = DeviceProfileTesting.deviceActivityPolling
        let readNow = DeviceProfileTesting.deviceActivityReadNow()
        let readLater = DeviceProfileTesting.deviceActivityReadNow(thenAfter: 0.5)
        Thread.sleep(forTimeInterval: 0.3)
        let pollingLater = DeviceProfileTesting.deviceActivityPolling
        check("device-gpu-read-nil", w.deviceGPUPercent == nil && d.warmth?.deviceGPUPercent == nil && readNow == nil && readLater == nil,
              "currentWarmth.deviceGPUPercent \(w.deviceGPUPercent.map(String.init) ?? "nil"), routingDecision warmth \(d.warmth?.deviceGPUPercent.map(String.init) ?? "nil"), deviceActivityReadNow \(readNow.map(String.init) ?? "nil") / after 0.5 s \(readLater.map(String.init) ?? "nil")")
        check("device-reads-not-polling", !pollingAfterWarmth && !pollingAfterAdvice && !pollingLater,
              "deviceActivityPolling after a warmth query \(pollingAfterWarmth), after routing advice \(pollingAfterAdvice), 0.3 s later \(pollingLater)")

        // simulated calls, as ejm api-check: a call alone is one sample; with tracked work, setup work or another
        // call overlapping it, none
        let savedClock = DeviceProfileTesting.warmthClock, savedGPU = DeviceProfileTesting.gpuActivity
        DeviceProfileTesting.warmthClock = nil; DeviceProfileTesting.gpuActivity = nil
        DeviceProfileTesting.resetLoadCorrection()
        let dev = MetalContext.shared.device
        let s0 = DeviceProfileTesting.loadSampleCount
        let alone = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5)
        let tracked = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5, trackedInside: true)
        let setup = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5, setupInside: true)
        let overlapping = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5, overlappingCall: true)
        let after = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5)
        let s1 = DeviceProfileTesting.loadSampleCount
        check("simulated-calls", alone == 1 && tracked == 0 && setup == 0 && overlapping == 0 && after == 1 && s1 - s0 == 2,
              "alone \(alone), tracked inside \(tracked), setup inside \(setup), overlapping \(overlapping), alone again \(after); loadSampleCount \(s0) -> \(s1)")

        // real calls: a decode and an encode one sample each; a new decoder's first call (setup) and the library's
        // own calibration none; a timed CPU job one; with load correction off, none
        DeviceProfileTesting.resetLoadCorrection()
        _ = p.measuredRouting(timeout: 30)
        let px = [UInt8](repeating: 100, count: 1024 * 768 * 3)
        let enc = Encoder(), dec = Decoder()
        let jpg = (try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }) ?? Data()
        _ = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }
        _ = dec.decode(jpg)                                           // setup: buffers sized
        let n0 = DeviceProfileTesting.loadSampleCount
        let decoded = dec.decode(jpg) != nil
        let n1 = DeviceProfileTesting.loadSampleCount
        _ = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }
        let n2 = DeviceProfileTesting.loadSampleCount
        _ = Decoder().decode(jpg)                                     // a new decoder's first call allocates: setup
        let n3 = DeviceProfileTesting.loadSampleCount
        _ = DeviceProfileTesting.measure(MetalContext.shared)         // the library's own calibration calls
        let n4 = DeviceProfileTesting.loadSampleCount
        let job = p.beginCPUWork()
        autoreleasepool { _ = imageIODecode(jpg) }
        job.end(width: 1024, height: 768, operation: .decode)
        let n5 = DeviceProfileTesting.loadSampleCount
        check("real-calls", decoded && n1 - n0 == 1 && n2 - n1 == 1 && n3 == n2 && n4 == n3 && n5 - n4 == 1,
              "decode \(n1 - n0), encode \(n2 - n1), new decoder's first call \(n3 - n2), calibration \(n4 - n3), timed ImageIO decode \(n5 - n4) samples")
        DeviceProfile.loadCorrectionEnabled = false
        let m0 = DeviceProfileTesting.loadSampleCount
        _ = dec.decode(jpg)
        _ = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }
        p.beginCPUWork().end(width: 1024, height: 768, operation: .decode)
        let m1 = DeviceProfileTesting.loadSampleCount
        let fOff = p.loadFactors(width: 1024, height: 768, operation: .decode, gpuSet: .warm, cpuWarm: true)
        DeviceProfile.loadCorrectionEnabled = true
        check("off-no-samples", m1 == m0 && fOff == DeviceProfile.LoadFactors(gpu: 1, cpu: 1),
              "load correction off: a decode, an encode and a CPU job added \(m1 - m0) samples; factors \(fOff)")
        DeviceProfileTesting.resetLoadCorrection()
        DeviceProfileTesting.warmthClock = savedClock; DeviceProfileTesting.gpuActivity = savedGPU
        return rows
    }

    // MARK: acceptance cells

    /// one size: the GPU decoder and encoder (set up before any condition), the JPEG to decode, the source pixels
    /// for the encode (a shared buffer for the GPU, a CGImage for ImageIO)
    final class LRCase {
        let w: Int, h: Int
        let dec = Decoder(), enc = Encoder()
        let jpeg: Data, buf: MTLBuffer, cg: CGImage
        init(w: Int, h: Int, jpeg: Data, buf: MTLBuffer, cg: CGImage) { self.w = w; self.h = h; self.jpeg = jpeg; self.buf = buf; self.cg = cg }
    }

    func loadRoutingCells() -> [String: Any] {
        let sizes = [(640, 480), (1600, 1200), (4032, 3024)]
        let reps = 5, rounds = 2, spinnerCount = 4, gap = 0.35, wrongMargin = 1.25, ioQuality = 0.9
        let p = DeviceProfile.current
        var cases: [LRCase] = []
        for (k, (w, h)) in sizes.enumerated() {
            status("load routing: inputs \(w)x\(h)")
            let px = Synth.make(width: w, height: h, seed: UInt32(700 + k))
            let buf = sharedBuffer(px, MetalContext.shared.device)
            guard let jpeg = try? Encoder().encode(buffer: buf, width: w, height: h, quality: 90, subsampling: .s420) else {
                fail("load routing: encode of the \(w)x\(h) input failed"); continue
            }
            let c = LRCase(w: w, h: h, jpeg: jpeg, buf: buf, cg: cgImage(rgb: px, w, h))
            // setup before any condition: buffers sized, pipelines built, ImageIO loaded (no sample is a setup call)
            for _ in 0..<2 {
                _ = c.dec.decode(jpeg)
                _ = try? c.enc.encode(buffer: buf, width: w, height: h, quality: 90, subsampling: .s420)
                autoreleasepool { _ = imageIODecode(jpeg); _ = imageIOEncode(c.cg, quality: ioQuality) }
            }
            cases.append(c)
        }
        // conditions alternate load correction off and on, idle and with spinners, over `rounds` rounds
        var conditions: [(spin: Bool, on: Bool)] = []
        // round 1 runs off then on, round 2 on then off, so neither setting always runs second (warmer)
        for r in 0..<rounds { for spin in [false, true] { for on in (r % 2 == 0 ? [false, true] : [true, false]) { conditions.append((spin, on)) } } }
        var rows: [[String: Any]] = []
        for (ci, cond) in conditions.enumerated() {
            let name = "\(cond.spin ? "\(spinnerCount) spinners" : "idle"), load correction \(cond.on ? "on" : "off")"
            status("load routing \(ci + 1)/\(conditions.count): \(name)")
            let th = waitCool("load routing \(name)")
            let pi = ProcessInfo.processInfo
            let before: [String: Any] = ["low_power_mode": pi.isLowPowerModeEnabled, "thermal": thermalName()]
            DeviceProfileTesting.resetLoadCorrection()
            DeviceProfile.loadCorrectionEnabled = cond.on
            let spinners = cond.spin ? Spinners(count: spinnerCount) : nil
            if spinners != nil { Thread.sleep(forTimeInterval: 1.0) }
            let t0 = now()
            // per cell (size x operation): reps
            var cellReps: [[[String: Any]]] = Array(repeating: [], count: cases.count * 2)
            for r in 0..<reps {
                for (k, c) in cases.enumerated() {
                    for (oi, op) in [DeviceProfile.Operation.decode, .encode].enumerated() {
                        autoreleasepool { cellReps[k * 2 + oi].append(loadRoutingRep(p, c, op, gpuFirst: (r + k + oi) % 2 == 0, gap: gap, ioQuality: ioQuality)) }
                    }
                }
            }
            spinners?.stop()
            let after: [String: Any] = ["low_power_mode": pi.isLowPowerModeEnabled, "thermal": thermalName()]
            var cells: [[String: Any]] = []
            var lostTotal = 0.0, wrongTotal = 0
            for (k, c) in cases.enumerated() {
                for (oi, op) in ["decode", "encode"].enumerated() {
                    let rs = cellReps[k * 2 + oi]
                    let g = rs.map { $0["gpu_ms"] as! Double }, cp = rs.map { $0["cpu_ms"] as! Double }
                    let pickedCPU = rs.filter { $0["picked"] as! String == "cpu" }.count
                    var lost = 0.0, wrong = 0
                    for x in rs {
                        let gm = x["gpu_ms"] as! Double, cm = x["cpu_ms"] as! Double
                        let (picked, other) = x["picked"] as! String == "cpu" ? (cm, gm) : (gm, cm)
                        if picked > other * wrongMargin { wrong += 1; lost += picked - other }
                    }
                    lostTotal += lost; wrongTotal += wrong
                    cells.append(["case": "\(c.w)x\(c.h)", "op": op, "picked_gpu": rs.count - pickedCPU, "picked_cpu": pickedCPU,
                                  "gpu_ms_median": median(g), "cpu_ms_median": median(cp), "wrong_reps": wrong, "lost_ms": lost, "reps": rs])
                    say("lr \(name) \(c.w)x\(c.h) \(op): picked GPU \(rs.count - pickedCPU) CPU \(pickedCPU); GPU \(fmt(median(g), 2)) ms, CPU \(fmt(median(cp), 2)) ms (medians); wrong \(wrong), lost \(fmt(lost, 2)) ms")
                }
            }
            say("lr \(name): lost \(fmt(lostTotal, 2)) ms over \(wrongTotal) wrong reps of \(cases.count * 2 * reps); \(fmt(now() - t0, 1)) s; Low Power Mode \(before["low_power_mode"]!) -> \(after["low_power_mode"]!), thermal \(before["thermal"]!) -> \(after["thermal"]!)")
            rows.append(["condition": name, "spinners": cond.spin ? spinnerCount : 0, "load_correction": cond.on, "round": ci / 4 + 1,
                         "thermal_after_wait": th, "before": before, "after": after, "lost_ms": lostTotal, "wrong_reps": wrongTotal,
                         "seconds": now() - t0, "cells": cells])
        }
        DeviceProfileTesting.resetLoadCorrection()
        DeviceProfile.loadCorrectionEnabled = true
        return ["conditions": rows,
                "method": "sizes \(sizes.map { "\($0.0)x\($0.1)" }.joined(separator: ", ")), decode and encode (q90 4:2:0 Synth images; encode from a shared MTLBuffer); \(reps) reps per cell, cells interleaved within a rep; each rep waits \(gap) s, asks DeviceProfile.current.routingDecision (default rates, detected warmth), then times the GPU (Decoder/Encoder) and the CPU (ImageIO, quality \(ioQuality), inside beginCPUWork()/end with the default rate), each after a \(gap) s gap, order alternating; a rep is wrong when the picked side took more than \(wrongMargin)x the other, lost ms = picked minus other; conditions idle or \(spinnerCount) in-process busy-loop threads at default QoS (started 1 s before, stopped after), load correction off/on alternated via DeviceProfile.loadCorrectionEnabled, DeviceProfileTesting.resetLoadCorrection() before each, \(rounds) rounds"]
    }

    /// one rep: the advice, then both truths timed (GPU wall; CPU wall inside beginCPUWork()/end)
    func loadRoutingRep(_ p: DeviceProfile, _ c: LRCase, _ op: DeviceProfile.Operation, gpuFirst: Bool, gap: Double, ioQuality: Double) -> [String: Any] {
        Thread.sleep(forTimeInterval: gap)
        let d = p.routingDecision(width: c.w, height: c.h, operation: op)
        var gpuMs = Double.nan, cpuMs = Double.nan, ok = true
        func gpu() {
            let t = now()
            if op == .decode { ok = c.dec.decode(c.jpeg) != nil && ok }
            else { ok = (try? c.enc.encode(buffer: c.buf, width: c.w, height: c.h, quality: 90, subsampling: .s420)) != nil && ok }
            gpuMs = (now() - t) * 1000
        }
        func cpu() {
            let job = p.beginCPUWork()
            let t = now()
            if op == .decode { ok = imageIODecode(c.jpeg) != nil && ok } else { ok = !imageIOEncode(c.cg, quality: ioQuality).isEmpty && ok }
            cpuMs = (now() - t) * 1000
            job.end(width: c.w, height: c.h, operation: op)
        }
        if gpuFirst { gpu(); Thread.sleep(forTimeInterval: gap); cpu() } else { cpu(); Thread.sleep(forTimeInterval: gap); gpu() }
        if !ok { fail("load routing \(c.w)x\(c.h) \(op): a GPU or ImageIO call failed") }
        return ["picked": d.prefersCPU ? "cpu" : "gpu", "gpu_ms": gpuMs, "cpu_ms": cpuMs, "gpu_first": gpuFirst,
                "predicted_gpu_ms": d.predictedGPUms, "predicted_cpu_ms": d.predictedCPUms, "gpu_set": d.gpuSet.rawValue,
                "cpu_cold": d.cpuCold, "factor_gpu": d.loadFactors.gpu, "factor_cpu": d.loadFactors.cpu]
    }
}
