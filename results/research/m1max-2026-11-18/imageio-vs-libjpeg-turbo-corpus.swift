import Foundation
import ImageIO
import CoreGraphics
// For each JPEG: ImageIO decode (default options) vs libjpeg-turbo djpeg (PPM/PGM). Prints name, kind, max diff, frac differing, PSNR.
func ppm(_ path: String) -> (w: Int, h: Int, c: Int, px: [UInt8])? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    let b = [UInt8](d); var i = 0; var tok: [String] = []
    while tok.count < 4 {
        while b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        if b[i] == 0x23 { while b[i] != 0x0A { i += 1 }; continue }
        var t = ""; while !(b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) { t.append(Character(UnicodeScalar(b[i]))); i += 1 }
        tok.append(t)
    }
    i += 1
    let c = tok[0] == "P6" ? 3 : 1
    return (Int(tok[1])!, Int(tok[2])!, c, Array(b[i...]))
}
for path in CommandLine.arguments.dropFirst(2) {
    let name = (path as NSString).lastPathComponent
    let ref = CommandLine.arguments[1] + "/" + name + ".pnm"
    guard let r = ppm(ref) else { print("\(name) noref"); continue }
    guard let d = FileManager.default.contents(atPath: path), let src = CGImageSourceCreateWithData(d as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("\(name) imageio-failed"); continue }
    let w = img.width, h = img.height
    guard w == r.w, h == r.h else { print("\(name) size-mismatch"); continue }
    // raw decoded bytes, no colour management: draw only if the layout is not plain 8-bit RGB(X)/gray
    var got = [UInt8](repeating: 0, count: w * h * r.c)
    let raw = img.dataProvider!.data! as Data, bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
    if img.bitsPerComponent != 8 { print("\(name) bpc\(img.bitsPerComponent)"); continue }
    raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for y in 0..<h { for x in 0..<w { for k in 0..<r.c { got[(y * w + x) * r.c + k] = p[y * bpr + x * bpp + k] } } }
    }
    if bpp != r.c && !(bpp == 4 && r.c == 3) { print("\(name) layout bpp\(bpp) c\(r.c)"); continue }
    var mx = 0, nd = 0; var se = 0.0
    for i in 0..<got.count { let dd = abs(Int(got[i]) - Int(r.px[i])); if dd > 0 { nd += 1; mx = max(mx, dd); se += Double(dd * dd) } }
    let psnr = se == 0 ? 999 : 10 * log10(255.0 * 255.0 / (se / Double(got.count)))
    print(String(format: "%@ c%d max %d differ %.4f psnr %.2f", name, r.c, mx, Double(nd) / Double(got.count), psnr))
}
