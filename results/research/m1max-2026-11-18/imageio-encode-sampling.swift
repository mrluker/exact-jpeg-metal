import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
// ImageIO encode of a w x h RGB test image at each quality; print the SOF component sampling factors
func sof(_ d: Data) -> String {
    let b = [UInt8](d); var i = 2
    while i + 4 < b.count {
        guard b[i] == 0xFF else { i += 1; continue }
        let m = b[i + 1], len = Int(b[i + 2]) << 8 | Int(b[i + 3])
        if (0xC0...0xC2).contains(m) {
            let n = Int(b[i + 9]); var s: [String] = []
            for c in 0..<n { let f = b[i + 11 + 3 * c]; s.append("\(f >> 4)x\(f & 15)") }
            return s.joined(separator: ",")
        }
        i += 2 + len
    }
    return "?"
}
let w = 512, h = 512
var px = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h { for x in 0..<w { let o = (y * w + x) * 4; px[o] = UInt8((x * 7 + y) & 255); px[o+1] = UInt8((y * 5) & 255); px[o+2] = UInt8((x ^ y) & 255); px[o+3] = 255 } }
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let img = ctx.makeImage()!
for q in [0.5, 0.7, 0.8, 0.82, 0.9, 0.95, 0.98, 1.0] {
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    CGImageDestinationFinalize(dst)
    print("q\(q): \(out.length) bytes, SOF sampling \(sof(out as Data))")
}
