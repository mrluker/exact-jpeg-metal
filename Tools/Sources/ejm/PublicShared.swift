import Foundation
import ImageIO
import CoreGraphics

// Timing and pixel-identity helpers of `ejm public-bench` (PublicBench.swift), shared with the iOS check app's
// --public mode (Examples/ios-check/App/PublicMode.swift; project.yml lists this file). Foundation, ImageIO and
// CoreGraphics only: no libjpeg-turbo, no Metal. Both targets define fmt(_:_:) and median(_:).

/// monotonic seconds (CLOCK_UPTIME_RAW; CFAbsoluteTimeGetCurrent follows wall-clock adjustments)
@inline(__always) func mono() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 }

/// JSON cannot hold infinity or NaN (PSNR of identical images): those become null.
func jnum(_ x: Double, _ digits: Double = 1000) -> Any { x.isFinite ? (x * digits).rounded() / digits : NSNull() }

/// A timed case: per-call seconds of the successful calls and the number of failed calls (warm-up included).
struct Timed {
    var times: [Double] = [], failures = 0
    var valid: Bool { failures == 0 && !times.isEmpty }
    var medianMs: Double { times.isEmpty ? .nan : median(times) * 1000 }
    /// median ms, or "invalid (n failed)"
    var text: String { valid ? fmt(medianMs) : "invalid (\(failures) failed)" }
    func json(_ key: String = "ms") -> [String: Any] {
        [key: valid ? jnum(medianMs) : NSNull(), "failures": failures, "valid": valid, "timed_calls": times.count]
    }
}

/// `warm` seconds of `work`, then `iters` timed calls; `work` returns false on failure
func pbTimes(_ iters: Int, warm: Double, _ work: () -> Bool) -> Timed {
    var r = Timed()
    let t0 = mono()
    while mono() - t0 < warm { if !work() { r.failures += 1 } }
    for _ in 0..<iters {
        let a = mono()
        let ok = work()
        let d = mono() - a
        if ok { r.times.append(d) } else { r.failures += 1 }
    }
    return r
}

/// ImageIO decode with kCGImageSourceUseHardwareAcceleration set explicitly to `hardware`
func imageIODecodeKey(_ d: Data, hardware: Bool) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let o: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true, "kCGImageSourceUseHardwareAcceleration" as CFString: hardware]
    return CGImageSourceCreateImageAtIndex(src, 0, o as CFDictionary)
}

/// Where R, G and B sit in each pixel of a CGImage's own bytes: 8-bit RGB / RGBA orders, or 8-bit gray (with or
/// without alpha), whose one value is R, G and B alike (as libjpeg-turbo's RGB decode of a gray JPEG). nil for other
/// layouts (16-bit, CMYK, ...).
private func cgImageLayout(_ img: CGImage) -> (bpp: Int, idx: (Int, Int, Int))? {
    guard img.bitsPerComponent == 8 else { return nil }
    let bpp = img.bitsPerPixel / 8
    let alpha = img.alphaInfo, little = img.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
    let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
    switch img.colorSpace?.model ?? .rgb {
    case .rgb:
        if bpp == 3 { return (3, (0, 1, 2)) }
        if bpp == 4 { return (4, little ? (alphaFirst ? (2, 1, 0) : (3, 2, 1)) : (alphaFirst ? (1, 2, 3) : (0, 1, 2))) }
    case .monochrome:
        if bpp == 1 { return (1, (0, 0, 0)) }
        if bpp == 2 { let g = alpha == .none ? 0 : (alphaFirst ? 1 : 0); return (2, (g, g, g)) }
    default: break
    }
    return nil
}

/// The CGImage's own bytes as RGB (no drawing, no colour conversion; from research/hw-hybrid's cgRawRGB); gray
/// expanded to R = G = B. nil for other layouts (16-bit, CMYK, ...).
func cgImageRawRGB(_ img: CGImage) -> [UInt8]? {
    guard let (bpp, idx) = cgImageLayout(img), let data = img.dataProvider?.data else { return nil }
    let w = img.width, h = img.height, bpr = img.bytesPerRow
    let p = CFDataGetBytePtr(data)!
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    rgb.withUnsafeMutableBufferPointer { o in
        for y in 0..<h {
            let row = p + y * bpr
            for x in 0..<w { let q = row + x * bpp, i = (y * w + x) * 3; o[i] = q[idx.0]; o[i + 1] = q[idx.1]; o[i + 2] = q[idx.2] }
        }
    }
    return rgb
}

/// identity(_:_:) of a CGImage's pixels (as cgImageRawRGB gives them) against `ref`, read in place: no RGB copy.
/// nil for the layouts cgImageRawRGB declines.
func cgImageIdentity(_ img: CGImage, _ ref: [UInt8]) -> [String: Any]? {
    guard let (bpp, idx) = cgImageLayout(img), let data = img.dataProvider?.data else { return nil }
    let w = img.width, h = img.height, bpr = img.bytesPerRow
    guard w * h * 3 == ref.count else { return ["error": "size \(w * h * 3) bytes, reference \(ref.count)"] }
    let p = CFDataGetBytePtr(data)!
    var hist = [Int](repeating: 0, count: 256)
    var se = 0.0
    ref.withUnsafeBufferPointer { r in
        hist.withUnsafeMutableBufferPointer { hb in
            for y in 0..<h {
                let row = p + y * bpr
                for x in 0..<w {
                    let q = row + x * bpp, i = (y * w + x) * 3
                    let d0 = abs(Int(q[idx.0]) - Int(r[i])), d1 = abs(Int(q[idx.1]) - Int(r[i + 1])), d2 = abs(Int(q[idx.2]) - Int(r[i + 2]))
                    hb[d0] += 1; hb[d1] += 1; hb[d2] += 1
                    se += Double(d0 * d0 + d1 * d1 + d2 * d2)
                }
            }
        }
    }
    let n = ref.count, differing = n - hist[0]
    let psnr = se == 0 ? Double.infinity : 10 * log10(255.0 * 255.0 / (se / Double(n)))
    return ["identical": differing == 0, "max_diff": hist.lastIndex { $0 > 0 } ?? 0, "differing_bytes": differing,
            "frac_differ": Double(differing) / Double(n), "psnr_db": jnum(psnr, 100)]
}

/// identity of `a` against `ref`: identical, max diff, number and fraction of differing values, PSNR
func identity(_ a: UnsafeRawBufferPointer, _ ref: [UInt8]) -> [String: Any] {
    guard a.count == ref.count else { return ["error": "size \(a.count) bytes, reference \(ref.count)"] }
    let s = diffStats(a, ref)
    let differing = Int((s.fracNonzero * Double(ref.count)).rounded())
    return ["identical": differing == 0, "max_diff": s.maxd, "differing_bytes": differing, "frac_differ": s.fracNonzero,
            "psnr_db": jnum(s.psnr, 100)]
}

func identityText(_ r: [String: Any]?) -> String {
    guard let r else { return "n/a" }
    if let e = r["error"] { return "ERROR: \(e)" }
    if r["identical"] as? Bool == true { return "identical" }
    let p = (r["psnr_db"] as? Double).map { fmt($0, 1) + " dB" } ?? "?"
    return "max \(r["max_diff"] ?? "?"), \(r["differing_bytes"] ?? "?") values (\(String(format: "%.4g", ((r["frac_differ"] as? Double) ?? 0) * 100))%) differ, PSNR \(p)"
}

struct DiffStats { var maxd = 0; var p999 = 0; var meanAbs = 0.0; var fracNonzero = 0.0; var psnr = 0.0 }

func diffStats(_ a: UnsafeRawBufferPointer, _ b: [UInt8]) -> DiffStats {
    var hist = [Int](repeating: 0, count: 256)
    var se = 0.0, sa = 0.0
    for i in 0..<b.count {
        let d = abs(Int(a[i]) - Int(b[i]))
        hist[d] += 1
        se += Double(d * d); sa += Double(d)
    }
    var s = DiffStats()
    let n = b.count
    s.maxd = hist.lastIndex { $0 > 0 } ?? 0
    var acc = 0
    for k in 0..<256 { acc += hist[k]; if Double(acc) >= 0.999 * Double(n) { s.p999 = k; break } }
    s.meanAbs = sa / Double(n)
    s.fracNonzero = Double(n - hist[0]) / Double(n)
    s.psnr = se == 0 ? .infinity : 10 * log10(255.0 * 255.0 / (se / Double(n)))
    return s
}
