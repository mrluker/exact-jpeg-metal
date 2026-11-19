import Foundation

// Pure-Swift generators of the synthetic test data (no libjpeg-turbo, no Metal): compiled into ejm and, by path,
// into the iOS check app (Examples/ios-check/project.yml), so both make bit-identical sources. The manifest's
// `source` hashes catch any drift.

/// Deterministic, photo-like synthetic RGB images (no real photos in the repo): soft gradients, large
/// soft-edged shapes (walls, furniture), band-limited noise at several scales, sharp lines (frames), fine
/// texture patches and mild sensor noise. seed picks the scene.
enum Synth {
    @inline(__always) static func hash(_ x: Int32, _ y: Int32, _ s: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6B343 ^ UInt32(bitPattern: y) &* 0xD8163841 ^ s &* 0xCB1AB31F
        h ^= h >> 13; h &*= 0x5BD1E995; h ^= h >> 15
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }
    @inline(__always) static func vnoise(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
        let xi = Int32(floor(x)), yi = Int32(floor(y))
        var fx = x - Float(xi), fy = y - Float(yi)
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi, s), b = hash(xi + 1, yi, s), c = hash(xi, yi + 1, s), d = hash(xi + 1, yi + 1, s)
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }

    struct Shape { var cx, cy, rx, ry, soft: Float; var col: SIMD3<Float>; var rect: Bool }

    static func make(width W: Int, height H: Int, seed: UInt32, noise: Float = 2.0) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: W * H * 3)
        var rng = seed &* 2654435761 | 1
        func rnd() -> Float { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return Float(rng & 0xFFFFFF) / Float(0xFFFFFF) }
        let fw = Float(W), fh = Float(H)
        var shapes: [Shape] = []
        for _ in 0..<40 {
            shapes.append(Shape(cx: rnd() * fw, cy: rnd() * fh, rx: (0.03 + 0.25 * rnd()) * fw, ry: (0.03 + 0.25 * rnd()) * fh,
                                soft: 1 + 40 * rnd() * rnd(), col: SIMD3(rnd(), rnd(), rnd()) * 230 + 10, rect: rnd() < 0.6))
        }
        let top = SIMD3<Float>(rnd(), rnd(), rnd()) * 120 + 120, bottom = SIMD3<Float>(rnd(), rnd(), rnd()) * 160 + 40
        let lines = (0..<30).map { _ in (rnd() < 0.5, rnd(), 1 + 6 * rnd(), rnd() * 255) }
        let tex = (0..<6).map { _ in (rnd() * fw, rnd() * fh, (0.05 + 0.1 * rnd()) * fw) }
        out.withUnsafeMutableBufferPointer { o in
            let base = Unchecked(o.baseAddress!), shapes = shapes
            DispatchQueue.concurrentPerform(iterations: H) { y in
                let p = base.value
                let fy = Float(y)
                for x in 0..<W {
                    let fx = Float(x)
                    let t = fy / fh
                    var c = top * (1 - t) + bottom * t
                    for s in shapes {
                        let dx = abs(fx - s.cx) / s.rx, dy = abs(fy - s.cy) / s.ry
                        let d = s.rect ? max(dx, dy) : (dx * dx + dy * dy).squareRoot()
                        let edge = (1 - d) * min(s.rx, s.ry) / s.soft
                        let a = min(max(edge, 0), 1)
                        if a > 0 { c = c * (1 - a * 0.85) + s.col * (a * 0.85) }
                    }
                    var n: Float = 0
                    var amp: Float = 28, sc: Float = 1 / 600
                    for o in 0..<5 { n += amp * (vnoise(fx * sc, fy * sc, seed &+ UInt32(o)) - 0.5); amp *= 0.5; sc *= 2.3 }
                    c += SIMD3(n, n * 0.9, n * 0.8)
                    for (vert, pos, wd, v) in lines {
                        let q = vert ? fx - pos * fw : fy - pos * fh
                        if abs(q) < wd { c = c * 0.3 + SIMD3(repeating: v) * 0.7 }
                    }
                    for (tx, ty, r) in tex where abs(fx - tx) < r && abs(fy - ty) < r {
                        let v = hash(Int32(x / 2), Int32(y / 3), seed) * 60 - 30
                        c += SIMD3(repeating: v)
                    }
                    let g = noise * (hash(Int32(x), Int32(y), seed &+ 99) + hash(Int32(x), Int32(y), seed &+ 77) - 1) * 1.7
                    c += SIMD3(g, g, g)
                    let i = (y * W + x) * 3
                    p[i] = UInt8(min(max(c.x, 0), 255)); p[i + 1] = UInt8(min(max(c.y, 0), 255)); p[i + 2] = UInt8(min(max(c.z, 0), 255))
                }
            }
        }
        return out
    }
}

/// Hands a non-Sendable value (a pointer, a closure, a decoder) to DispatchQueue.concurrentPerform. The callers only
/// touch disjoint elements, or one object, from each iteration, so sharing it is safe.
struct Unchecked<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

func corpusContent(_ w: Int, _ h: Int, _ kind: String, _ seed: UInt32) -> [UInt8] {
    switch kind {
    case "smooth": return Synth.make(width: w, height: h, seed: seed, noise: 6)
    case "edges":
        var a = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 3
            var c: (UInt8, UInt8, UInt8) = ((x / 5 + y / 7) % 2 == 1) ? (255, 255, 255) : (0, 0, 0)
            if x % 9 == 0 { c = (255, 0, 0) }
            if y % 11 == 0 { c = (0, 0, 255) }
            a[i] = c.0; a[i + 1] = c.1; a[i + 2] = c.2
        } }
        return a
    default:
        var r = seed | 1
        return (0..<(w * h * 3)).map { _ in r ^= r << 13; r ^= r >> 17; r ^= r << 5; return UInt8(truncatingIfNeeded: r) }
    }
}

struct EncCase { let name: String; let w: Int; let h: Int; let src: [UInt8]; let q: Int; let samp: Int }

/// the encoder cases of `ejm encode-corpus`, in the same order and with the same seeds
func encodeCases() -> [EncCase] {
    var out: [EncCase] = []
    let sizes = [(1, 1), (1, 17), (17, 1), (2, 3), (7, 9), (8, 8), (9, 2), (16, 16), (15, 33), (31, 64), (97, 203), (480, 640), (1080, 1920), (2560, 3840)]
    var seed: UInt32 = 100
    for (h, w) in sizes {
        for kind in (h * w < 300000 ? ["smooth", "edges", "noise"] : ["smooth"]) {
            seed &+= 1
            let a = corpusContent(w, h, kind, seed)
            for si in 0..<3 { for q in [1, 25, 50, 75, 87, 90, 95, 100] {
                out.append(EncCase(name: "enc_\(h)x\(w)_\(kind)_s\(si)_q\(q)", w: w, h: h, src: a, q: q, samp: si))
            } }
        }
    }
    return out
}
