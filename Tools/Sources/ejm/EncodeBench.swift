import Foundation
import ExactJPEG
import ImageIO
import Metal
import UniformTypeIdentifiers

func sharedBuffer(_ px: [UInt8], _ dev: MTLDevice) -> MTLBuffer {
    px.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
}

/// Encoder exactness: Metal output bytes == libjpeg-turbo output bytes (whole file).
@discardableResult func runEncodeCorpus() -> Bool {
    print("reference: \(Turbo.version)")
    let enc = Encoder()
    let dev = enc.ctx.device
    var ok = 0, bad = 0
    let sizes = [(1, 1), (1, 17), (17, 1), (2, 3), (7, 9), (8, 8), (9, 2), (16, 16), (15, 33), (31, 64), (97, 203), (480, 640), (1080, 1920), (2560, 3840)]
    var seed: UInt32 = 100
    for (h, w) in sizes {
        for kind in (h * w < 300000 ? ["smooth", "edges", "noise"] : ["smooth"]) {
            seed &+= 1
            let a = corpusContent(w, h, kind, seed)
            let buf = sharedBuffer(a, dev)
            for (si, ss) in [Subsampling.s444, .s422, .s420].enumerated() {
                for q in [1, 25, 50, 75, 87, 90, 95, 100] {
                    let got: Data
                    do { got = try enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss) } catch {
                        print("  THREW \(h)x\(w) \(ss) q\(q): \(type(of: error))"); fflush(stdout)
                        if let e = error as? InvalidInput { print("    \(e.description)") }
                        bad += 1; continue
                    }
                    let ref = Turbo.encode(a, w, h, quality: q, samp: si)
                    if got == ref { ok += 1 } else {
                        bad += 1
                        let n = min(got.count, ref.count)
                        let first = (0..<n).first { got[$0] != ref[$0] } ?? n
                        if bad <= 20 { print("  DIFFERENT \(h)x\(w) \(kind) \(ss) q\(q): sizes \(got.count) vs \(ref.count), first diff at byte \(first)") }
                    }
                }
            }
        }
    }
    // RGBA input with padded rows gives the same bytes
    let a = corpusContent(203, 97, "smooth", 5)
    var rgba = [UInt8](repeating: 0, count: 97 * 1000)
    for y in 0..<97 { for x in 0..<203 { for c in 0..<3 { rgba[y * 1000 + x * 4 + c] = a[(y * 203 + x) * 3 + c] } } }
    let g = try! enc.encode(buffer: sharedBuffer(rgba, dev), width: 203, height: 97, channels: 4, rowBytes: 1000, quality: 90, subsampling: .s420)
    if g == Turbo.encode(a, 203, 97, quality: 90, samp: 2) { ok += 1 } else { bad += 1; print("  DIFFERENT rgba padded") }
    // an EXIF block of 4 lengths moves the scan to each byte offset mod 4 in the output buffer (word stores in
    // stuff_scatter): the scan must be the same bytes as libjpeg-turbo's after the header
    let ne = corpusContent(640, 480, "noise", 9)
    let nref = Turbo.encode(ne, 640, 480, quality: 95, samp: 0)
    let h0 = try! jpegHeader(width: 640, height: 480, quality: 95, subsampling: .s444).count
    for extra in 0..<4 {
        let exif = Data(repeating: 0x45, count: 10 + extra)
        let got = try! enc.encode(buffer: sharedBuffer(ne, dev), width: 640, height: 480, quality: 95, subsampling: .s444, exif: exif)
        let want = try! jpegHeader(width: 640, height: 480, quality: 95, subsampling: .s444, exif: exif) + nref[h0...]
        if got == want { ok += 1 } else { bad += 1; print("  DIFFERENT with a \(10 + extra)-byte EXIF block") }
    }
    print("encoder: identical files \(ok), different \(bad)")
    Exact.v["encode"] = ["files": ok + bad, "identical": ok, "different": bad]
    return bad == 0
}

/// ImageIO JPEG encode of an RGB image (Apple's encoder; may use the hardware JPEG block).
func imageIOEncode(_ img: CGImage, quality: Double) -> Data {
    let d = NSMutableData()
    let dst = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dst)
    return d as Data
}

func cgImage(rgb: [UInt8], _ w: Int, _ h: Int) -> CGImage {
    let provider = CGDataProvider(data: Data(rgb) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func runEncodeBench(iters: Int) {
    benchProfile()
    print("reference: \(Turbo.version); corpus: ejm synthetic v1, Synth.make(w x h, seed 21)")
    let enc = Encoder()
    let dev = enc.ctx.device
    // the pipeline exports (the old listing set, the camera size, the service set), from a synthetic photo at each size
    for (label, w, h, q, ss, si) in [("3840x2560 q95 4:4:4 (banner)", 3840, 2560, 95, Subsampling.s444, 0),
                                       ("1500x1000 q90 4:4:4", 1500, 1000, 90, .s444, 0),
                                       ("1200x800 q87 4:2:0", 1200, 800, 87, .s420, 2),
                                       ("6720x4480 q95 4:2:2", 6720, 4480, 95, .s422, 1),
                                       // the service output set (3840 long-edge master + 2048 listing copy), any shape
                                       ("2048x1365 q90 4:4:4 (listing)", 2048, 1365, 90, .s444, 0),
                                       ("1365x2048 q90 4:4:4 (listing, portrait)", 1365, 2048, 90, .s444, 0),
                                       ("2560x3840 q95 4:4:4 (master, portrait)", 2560, 3840, 95, .s444, 0),
                                       ("3840x2880 q95 4:4:4 (master, 4:3)", 3840, 2880, 95, .s444, 0)] {
        let a = Synth.make(width: w, height: h, seed: 21)
        let buf = sharedBuffer(a, dev)
        let ref = Turbo.encode(a, w, h, quality: q, samp: si)
        let got = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
        print("\n== \(label): \(ref.count / 1024) KB, Metal \(got == ref ? "byte-identical" : "DIFFERENT") to libjpeg-turbo")
        var wall: [Double] = [], gpu: [Double] = []
        warmUp { _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss) }
        for k in 0..<(iters + discardIterations) {
            let t = now(); _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
            if k >= discardIterations { wall.append(now() - t); gpu.append(enc.gpuSeconds) }
        }
        // cold: the first call after 5 s of GPU idle (clocks down), recorded separately for the small export. Taken
        // after the timed loop: before it, the loop's first calls ran on clocks still rising (M4, 2026-11-17).
        var cold: (Double, Double)? = nil
        if w == 1200 {
            Thread.sleep(forTimeInterval: 5)
            let t = now(); _ = try! enc.encode(buffer: buf, width: w, height: h, quality: q, subsampling: ss)
            cold = (now() - t, enc.gpuSeconds)
        }
        if let cold { print("  first call after 5 s idle: wall \(fmt(cold.0 * 1000)) ms, GPU \(fmt(cold.1 * 1000)) ms") }
        print("  Metal exact: wall \(fmt(median(wall) * 1000)) ms, GPU \(fmt(median(gpu) * 1000)) ms (retries \(enc.retries))")
        let base: [String: Any] = ["op": "encode", "case": label, "width": w, "height": h, "quality": q,
                                   "subsampling": ["4:4:4", "4:2:2", "4:2:0"][si], "bytes": ref.count, "iters": iters]
        Bench.add(base, impl: "metal", wall: median(wall), gpu: median(gpu), extra: ["exact": got == ref])
        if let cold { Bench.add(base, impl: "metal", wall: cold.0, gpu: cold.1, extra: ["api": "first call after 5 s idle (one call)"]) }
        let cpu = cpuTimes(iters) { _ = Turbo.encode(a, w, h, quality: q, samp: si) }
        print("  libjpeg-turbo (NEON, 1 thread): \(fmt(median(cpu) * 1000)) ms")
        Bench.add(base, impl: "libjpeg-turbo", wall: median(cpu))
        let cg = cgImage(rgb: a, w, h)
        var iio: [Double] = []
        var d = Data()
        // ImageIO quality is 0..1 and does not map to libjpeg's quality scale; pick the value whose size is closest
        var bestQ = 0.9, bestGap = Int.max
        for iq in stride(from: 0.70, through: 1.0, by: 0.02) {
            let s = imageIOEncode(cg, quality: iq).count
            if abs(s - ref.count) < bestGap { bestGap = abs(s - ref.count); bestQ = iq }
        }
        for _ in 0..<max(3, iters / 4) { let t = now(); d = imageIOEncode(cg, quality: bestQ); iio.append(now() - t) }
        let back = Turbo.decode(d)!.px, refBack = Turbo.decode(ref)!.px
        let vsSrc = back.withUnsafeBytes { diffStats($0, a) }
        let refSrc = refBack.withUnsafeBytes { diffStats($0, a) }
        print("  ImageIO encode (quality \(fmt(bestQ, 2)), \(d.count / 1024) KB): \(fmt(median(iio) * 1000)) ms; decoded vs source PSNR \(fmt(vsSrc.psnr, 1)) dB max \(vsSrc.maxd) (libjpeg-turbo q\(q): \(fmt(refSrc.psnr, 1)) dB max \(refSrc.maxd))")
        Bench.add(base, impl: "imageio", wall: median(iio), extra: ["imageio_quality": bestQ, "imageio_bytes": d.count,
                  "psnr_vs_source_db": vsSrc.psnr, "libjpeg_psnr_vs_source_db": refSrc.psnr])
    }
}
