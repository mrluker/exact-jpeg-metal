import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
// VT hardware decode of a JPEG to 444f (or 420f), dump plane 0 (Y) as PGM. args: in.jpg out.pgm fmt(444|420) w h
let a = CommandLine.arguments
let d = try! Data(contentsOf: URL(fileURLWithPath: a[1]))
let w = Int(a[4])!, h = Int(a[5])!
let pf: OSType = a[3] == "444" ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
var f: CMVideoFormatDescription?
CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: Int32(w), height: Int32(h), extensions: nil, formatDescriptionOut: &f)
var s: VTDecompressionSession?
let spec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pf, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
print("create", VTDecompressionSessionCreate(allocator: nil, formatDescription: f!, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s))
var bb: CMBlockBuffer?
CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: d.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: d.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
d.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: d.count) }
var sb: CMSampleBuffer?; var n = d.count
CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: f, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &n, sampleBufferOut: &sb)
var out: CVPixelBuffer?
let st = VTDecompressionSessionDecodeFrame(s!, sampleBuffer: sb!, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in out = img; print("frame status", status) }
VTDecompressionSessionWaitForAsynchronousFrames(s!)
print("decode", st)
let pb = out!
CVPixelBufferLockBaseAddress(pb, .readOnly)
let pw = CVPixelBufferGetWidthOfPlane(pb, 0), ph = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
print("plane0", pw, ph, bpr)
var o = Data("P5\n\(pw) \(ph)\n255\n".utf8)
for y in 0..<ph { o.append(base + y * bpr, count: pw) }
try! o.write(to: URL(fileURLWithPath: a[2]))
