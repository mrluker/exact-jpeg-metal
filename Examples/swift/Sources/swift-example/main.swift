// Swift example: decode a JPEG file on the GPU (exact libjpeg-turbo output), re-encode it, then encode pixels
// made in memory and decode them back.
//   ./scripts/swift-example.sh            builds and runs it on a synthetic JPEG
//   swift-example in.jpg out.jpg
import Foundation
import ExactJPEG

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: swift-example in.jpg out.jpg"); exit(2) }

// 1. Decode a file. nil means declined: dec.reason says why, and the caller decodes on the CPU instead.
let dec = Decoder()                                  // one per thread
guard let img = dec.decode(path: args[1], format: .rgb) else {
    print("declined: \(dec.reason ?? "?")")
    exit(1)
}
print("decoded \(img.width)x\(img.height), \(img.channels) channels")

// 2. Encode the decoded pixels straight from the decoder's MTLBuffer (no copy). img stays valid until the
//    next decode on `dec`.
let enc = Encoder()                                  // one per thread
let jpeg = try enc.encode(buffer: img.buffer, offset: img.offset, width: img.width, height: img.height,
                          channels: img.channels, quality: 90, subsampling: .s420)
try jpeg.write(to: URL(fileURLWithPath: args[2]))
print("encoded \(jpeg.count) bytes to \(args[2])")

// 3. Encode pixels from ordinary memory (RGB, 3 bytes per pixel), then decode them back.
let w = 320, h = 200
var px = [UInt8](repeating: 0, count: w * h * 3)
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 3
    px[i] = UInt8(x * 255 / (w - 1)); px[i + 1] = UInt8(y * 255 / (h - 1)); px[i + 2] = 128
} }
let small = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: w, height: h, quality: 85, subsampling: .s444) }
guard let back = dec.decode(small, format: .rgb) else { print("declined: \(dec.reason ?? "?")"); exit(1) }
print("gradient: \(small.count) bytes, decoded back to \(back.width)x\(back.height)")
