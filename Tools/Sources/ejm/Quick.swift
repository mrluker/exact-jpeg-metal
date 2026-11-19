import Foundation
import ExactJPEG

/// ejm quick [iters]: Metal-only medians for A/B work on the codec kernels (no libjpeg-turbo or ImageIO timing, so a
/// run takes seconds): 6720x4480 decode (the three subsamplings of `ejm decode`, from memory and from a file) and the
/// 3840x2560 q95 / 2048x1365 q90 4:4:4 encodes of `ejm encode`. Every case is checked byte for byte against
/// libjpeg-turbo first; the same synthetic images and seeds as the full benchmarks.
func runQuick(iters: Int) {
    let dec = Decoder()
    let img = Synth.make(width: 6720, height: 4480, seed: 11)
    let tmp = NSTemporaryDirectory() + "ejm-quick-\(getpid()).jpg"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    for (label, q, s) in [("decode 6720x4480 q95 4:2:2", 95, 1), ("decode 6720x4480 q90 4:2:0", 90, 2), ("decode 6720x4480 q95 4:4:4", 95, 0)] {
        let data = Turbo.encode(img, 6720, 4480, quality: q, samp: s)
        let ref = Turbo.decode(data)!
        guard let first = dec.decode(data) else { print("\(label): declined (\(dec.reason ?? "?"))"); continue }
        let exact = ref.px.withUnsafeBytes { $0.elementsEqual(first.bytes) }
        var wall: [Double] = [], gpu: [Double] = []
        warmUp { _ = dec.decode(data) }
        for k in 0..<(iters + discardIterations) {
            let t = now(); _ = dec.decode(data)
            if k >= discardIterations { wall.append(now() - t); gpu.append(dec.gpuSeconds) }
        }
        try! data.write(to: URL(fileURLWithPath: tmp))
        var pw: [Double] = []
        for k in 0..<(iters + discardIterations) {
            let t = now(); _ = dec.decode(path: tmp)
            if k >= discardIterations { pw.append(now() - t) }
        }
        print("\(label) (\(data.count / 1024) KB): \(exact ? "exact" : "DIFFERENT"), wall \(fmt(median(wall) * 1000, 3)) ms, GPU \(fmt(median(gpu) * 1000, 3)) ms, from file wall \(fmt(median(pw) * 1000, 3)) ms, passes \(dec.passes)")
    }
    let enc = Encoder()
    for (label, w, h, q) in [("encode 3840x2560 q95 4:4:4", 3840, 2560, 95), ("encode 2048x1365 q90 4:4:4", 2048, 1365, 90)] {
        let a = Synth.make(width: w, height: h, seed: 21)
        let buf = sharedBuffer(a, enc.ctx.device)
        let ref = Turbo.encode(a, w, h, quality: q, samp: 0)
        let got = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: .s444)
        var wall: [Double] = [], gpu: [Double] = []
        warmUp { _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: .s444) }
        for k in 0..<(iters + discardIterations) {
            let t = now(); _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: .s444)
            if k >= discardIterations { wall.append(now() - t); gpu.append(enc.gpuSeconds) }
        }
        print("\(label) (\(ref.count / 1024) KB): \(got == ref ? "exact" : "DIFFERENT"), wall \(fmt(median(wall) * 1000, 3)) ms, GPU \(fmt(median(gpu) * 1000, 3)) ms")
    }
}
