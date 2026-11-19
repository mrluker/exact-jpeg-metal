import Foundation
import ExactJPEG
import ImageIO
import CoreGraphics

/// ImageIO decode to RGBA8 (Apple's decoder; on Apple silicon it may use the hardware JPEG block).
func imageIODecode(_ d: Data, into ctxBuf: UnsafeMutableRawPointer?, hardware: Bool) -> (CGImage, [UInt8])? {
    let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let src = CGImageSourceCreateWithData(d as CFData, opts as CFDictionary) else { return nil }
    var o: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    if hardware { o["kCGImageSourceUseHardwareAcceleration" as CFString] = true }
    guard let img = CGImageSourceCreateImageAtIndex(src, 0, o as CFDictionary) else { return nil }
    return (img, [])
}

/// Render a CGImage into RGB bytes (sRGB, no colour management beyond what the image carries).
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

func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }

func runDecodeBench(iters: Int) {
    benchProfile()
    print("reference: \(Turbo.version); corpus: ejm synthetic v1, Synth.make(6720x4480, seed 11), encoded by the reference")
    let img = Synth.make(width: 6720, height: 4480, seed: 11)
    let dec = Decoder()
    print("Metal kernels compiled in \(fmt(dec.ctx.compileSeconds * 1000, 0)) ms on \(dec.ctx.device.name)")
    for (label, q, s) in [("camera-like q95 4:2:2", 95, 1), ("q90 4:2:0", 90, 2), ("q95 4:4:4", 95, 0)] {
        let data = Turbo.encode(img, 6720, 4480, quality: q, samp: s)
        print("\n== \(label): \(data.count / 1024) KB")
        let ref = Turbo.decode(data)!
        // Metal exact
        guard let first = dec.decode(data) else { print("  Metal declined: \(dec.reason ?? "?")"); continue }
        let st = diffStats(first.bytes, ref.px)
        print("  Metal exact vs libjpeg-turbo: max diff \(st.maxd) (\(st.fracNonzero == 0 ? "byte-identical" : "NOT identical"))")
        var wall: [Double] = [], gpu: [Double] = [], prep: [Double] = [], encd: [Double] = [], wait: [Double] = []
        warmUp { _ = dec.decode(data) }
        for k in 0..<(iters + discardIterations) {
            let t = now()
            _ = dec.decode(data)
            if k < discardIterations { continue }
            wall.append(now() - t); gpu.append(dec.gpuSeconds)
            prep.append(dec.hostPrepSeconds); encd.append(dec.hostEncodeSeconds); wait.append(dec.waitSeconds)
        }
        print("  host: prep \(fmt(median(prep) * 1000, 3)) ms, encode commands \(fmt(median(encd) * 1000, 3)) ms, commit->done \(fmt(median(wait) * 1000, 3)) ms (GPU busy \(fmt(median(gpu) * 1000, 3)))")
        print("  Metal exact: wall \(fmt(median(wall) * 1000)) ms, GPU \(fmt(median(gpu) * 1000)) ms (median of \(iters)), sync passes \(dec.passes)")
        let base: [String: Any] = ["op": "decode", "case": label, "width": 6720, "height": 4480, "quality": q,
                                   "subsampling": ["4:4:4", "4:2:2", "4:2:0"][s], "bytes": data.count, "iters": iters]
        Bench.add(base, impl: "metal", wall: median(wall), gpu: median(gpu), extra: ["exact": st.fracNonzero == 0])
        // libjpeg-turbo, one thread
        var buf = [UInt8](repeating: 0, count: 6720 * 4480 * 3)
        let cpu = cpuTimes(iters) { _ = buf.withUnsafeMutableBufferPointer { Turbo.decodeInto(data, $0.baseAddress!) } }
        print("  libjpeg-turbo (NEON, 1 thread): \(fmt(median(cpu) * 1000)) ms")
        Bench.add(base, impl: "libjpeg-turbo", wall: median(cpu))
        // ImageIO
        var iio: [Double] = []
        var lastImg: CGImage? = nil
        for _ in 0..<max(3, iters / 4) {
            let t = now()
            lastImg = imageIODecode(data, into: nil, hardware: true)?.0
            iio.append(now() - t)
        }
        if let li = lastImg {
            let px = cgImageRGB(li)
            let d = px.withUnsafeBytes { diffStats($0, ref.px) }
            print("  ImageIO decode: \(fmt(median(iio) * 1000)) ms; vs libjpeg-turbo: max \(d.maxd), p99.9 \(d.p999), mean |d| \(fmt(d.meanAbs, 3)), \(fmt(d.fracNonzero * 100, 1))% values differ, PSNR \(fmt(d.psnr, 1)) dB")
            Bench.add(base, impl: "imageio", wall: median(iio), extra: ["max_diff": d.maxd, "p999_diff": d.p999, "psnr_db": d.psnr])
        }
    }
}

/// Benchmark and check every JPEG in a directory (e.g. real photos kept outside git): exactness against
/// libjpeg-turbo, Metal vs libjpeg-turbo time. Prints counts and medians only, no file names.
func runDecodeFiles(dir: String, iters: Int) -> Bool {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { ["jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    let dec = Decoder()
    var exact = 0, declined = 0, wrong = 0
    var gpu: [Double] = [], wall: [Double] = [], cpu: [Double] = [], mb: [Double] = []
    for f in files {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + f)) else { continue }
        guard let img = dec.decode(d) else { declined += 1; print("  declined: \(dec.reason ?? "?")"); continue }
        guard let ref = Turbo.decode(d), ref.px.withUnsafeBytes({ $0.elementsEqual(img.bytes) }) else { wrong += 1; continue }
        exact += 1
        mb.append(Double(d.count) / 1e6)
        var w: [Double] = [], g: [Double] = []
        for _ in 0..<iters { let t = now(); _ = dec.decode(d); w.append(now() - t); g.append(dec.gpuSeconds) }
        wall.append(median(w)); gpu.append(median(g))
        var buf = [UInt8](repeating: 0, count: ref.px.count)
        let t = now(); _ = buf.withUnsafeMutableBufferPointer { Turbo.decodeInto(d, $0.baseAddress!) }; cpu.append(now() - t)
    }
    print("corpus: \(dir) (\(files.count) files, median \(fmt(mb.isEmpty ? 0 : median(mb), 1)) MB)")
    print("exact \(exact), declined \(declined), DIFFERENT \(wrong)")
    if !wall.isEmpty {
        print("median per file: Metal wall \(fmt(median(wall) * 1000)) ms, GPU \(fmt(median(gpu) * 1000)) ms; libjpeg-turbo 1 thread \(fmt(median(cpu) * 1000)) ms")
    }
    return wrong == 0
}
