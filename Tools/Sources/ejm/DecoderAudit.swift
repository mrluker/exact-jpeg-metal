import Foundation
import Metal
@_spi(Testing) import ExactJPEG

// Decoder checks from the 2026-11-18 audit, run by `ejm api-check` (each one also by name):
//   trailing-ff        a JPEG cut right after a 0xFF byte (no byte after it, no EOI): libjpeg-turbo's memory source
//                      reads that 0xFF as the start of a marker and fills the rest of the scan with zero bits; the
//                      decoder must give its pixels exactly or decline, never accept different pixels
//   dc-reason          a scan whose DC values leave int16 is declined with the reason "DC value outside int16" (it
//                      was reported only as the coefficient range before)
//   quant16            a 16-bit quantisation table with a value above 32767 is declined ("quantisation value above
//                      32767"): libjpeg-turbo keeps the table as int16, where its C and SIMD IDCTs can differ (32768
//                      times a -1 coefficient); a 16-bit table with values up to 32767 decodes exactly
//   layout-identity    the decoder's layout cache tells headers apart by their bytes, not only by a hash: with a
//                      forced key collision (Decoder.layoutKeyOverride) different headers still decode exactly
//   output-buffer      an `output` buffer with .private or .managed storage, or from another device (when there is
//                      one), is declined ("output buffer must be .storageModeShared on the decoder's device"), in
//                      decode(bytes:) and decode(buffer:); a shared one still decodes exactly
//   offset-limit       with maxPixels raised, a header claiming 65500x65500 is declined ("image too large: ...") before
//                      any allocation, so no kernel offset (32-bit) can wrap; 16384x16384 is not refused for that
//   alloc-order        every cheap check runs before any buffer is allocated (Decoder.allocatedBytes): a 654-byte
//                      file claiming 16384x16384 (decode(bytes:), decode(buffer:), decode(path:)), a decode over
//                      maxGPUBytes, a file over 256 MB through decode(path:) (declined before it is read)
//   alloc-failure      allocations that fail (Decoder.failAllocations: input, output, scratch) decline with a reason,
//                      leave the caller's output untouched, and the decoder works again afterwards
//   path-edges         decode(path:) on a fresh decoder: an empty and a 3-byte file decline ("not a JPEG"), a JPEG
//                      whose header is longer than the 64 KB read first (APP segments) decodes exactly
nonisolated(unsafe) let decoderAuditChecks: [(name: String, run: (Tally) -> Void)] = [
    ("trailing-ff", checkTrailingFF),
    ("dc-reason", checkDCReason),
    ("quant16", checkQuant16),
    ("layout-identity", checkLayoutIdentity),
    ("output-buffer", checkOutputBuffer),
    ("offset-limit", checkOffsetLimit),
    ("alloc-order", checkAllocOrder),
    ("alloc-failure", checkAllocFailure),
    ("path-edges", checkPathEdges),
]

private func sameBytes(_ img: GPUImage?, _ ref: [UInt8]) -> Bool {
    guard let img else { return false }
    let b = img.bytes
    return b.count == ref.count && ref.withUnsafeBytes { memcmp($0.baseAddress!, b.baseAddress!, ref.count) == 0 }
}

private func scanStart(_ d: Data) -> Int { try! d.withUnsafeBytes { try parseJPEGHeader($0) }.scanStart }

private func checkTrailingFF(_ t: Tally) {
    let dec = Decoder()
    let files: [(String, Data)] = [
        ("640x480 4:2:0", Turbo.encode(corpusContent(640, 480, "smooth", 31), 640, 480, quality: 90, samp: 2)),
        ("203x97 4:4:4 noise", Turbo.encode(corpusContent(203, 97, "noise", 32), 203, 97, quality: 95, samp: 0)),
        ("203x97 4:2:2 rst3", Turbo.encode(corpusContent(203, 97, "edges", 33), 203, 97, quality: 85, samp: 1, restartMCUs: 3)),
        ("120x80 gray", Turbo.encode(corpusContent(120, 80, "edges", 34).enumerated().filter { $0.offset % 3 == 0 }.map(\.element),
                                     120, 80, gray: true, quality: 90, samp: 0)),
    ]
    var exact = 0, declined = 0, wrong = 0, tried = 0
    for (name, base) in files {
        let s0 = scanStart(base), end = base.count - 2          // libjpeg-turbo writes EOI last
        // cut points: the last 64 bytes of the scan and 32 spread over it; the byte there becomes 0xFF, the last
        var cuts = Array(max(s0 + 1, end - 64)..<end)
        for j in 1..<32 { cuts.append(s0 + (end - s0) * j / 32) }
        for p in Set(cuts).sorted() {
            var d = Data(base[0..<p]); d.append(0xFF)
            tried += 1
            let img = dec.decode(d)
            guard let ref = Turbo.decode(d) else {
                t.check(img == nil, "\(name), cut at \(p) after 0xFF: libjpeg-turbo fails, the decoder accepted")
                if img == nil { declined += 1 } else { wrong += 1 }
                continue
            }
            if img == nil { declined += 1 }
            else if sameBytes(img, ref.px) { exact += 1 }
            else { wrong += 1; t.check(false, "\(name), cut at \(p) after 0xFF: accepted with pixels that differ from libjpeg-turbo (warned \(ref.warned))") }
        }
        // the whole scan and then a lone 0xFF (EOI cut after its first byte): libjpeg-turbo decodes it, so must we
        let d = Data(base[0..<end]) + Data([0xFF])
        let img = dec.decode(d)
        t.check(sameBytes(img, Turbo.decode(d)!.px), "\(name), whole scan then a lone 0xFF: \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
    }
    // files whose last data byte is 0xFF (the scan ends FF 00, then EOI): cut right after that 0xFF. Its bits are
    // the last code bits; libjpeg-turbo reads zeros there instead, so a decoder that keeps the 0xFF as data finishes
    // every block with different pixels
    var found = 0, seed: UInt32 = 0
    let kinds = ["noise", "smooth", "edges"]
    while found < 12 && seed < 20000 {
        seed += 1
        let w = 8 + Int(seed % 37), h = 8 + Int(seed % 23), samp = Int(seed % 3)
        let base = Turbo.encode(corpusContent(w, h, kinds[Int(seed % 3)], seed), w, h, quality: 50 + Int(seed % 50), samp: samp)
        let n = base.count
        guard base[n - 4] == 0xFF, base[n - 3] == 0, base[n - 2] == 0xFF, base[n - 1] == 0xD9 else { continue }
        found += 1
        let d = Data(base[0..<(n - 3)])
        tried += 1
        let img = dec.decode(d)
        guard let ref = Turbo.decode(d) else {
            t.check(img == nil, "\(w)x\(h) seed \(seed), last data byte 0xFF, cut after it: libjpeg-turbo fails, the decoder accepted")
            if img == nil { declined += 1 } else { wrong += 1 }
            continue
        }
        if img == nil { declined += 1 }
        else if sameBytes(img, ref.px) { exact += 1 }
        else { wrong += 1; t.check(false, "\(w)x\(h) seed \(seed), last data byte 0xFF, cut after it: accepted with pixels that differ from libjpeg-turbo (warned \(ref.warned))") }
    }
    t.check(found == 12, "found only \(found) files whose data ends with a stuffed 0xFF")
    print("  \(tried) files cut after a 0xFF (\(found) of them right after the last data byte): \(exact) exact, \(declined) declined, \(wrong) accepted with different pixels")
}

/// A gray 8x160 JPEG (libjpeg-turbo's q100 header: every quantiser 1, the standard tables) whose scan has 20 blocks,
/// each a DC difference of +2047 (category 11: code 111111110, then 11 one bits) and EOB (1010): FF 7F FA per
/// block, stuffed FF 00 7F FA. The DC reaches 40940, outside int16, from the 17th block on.
func dcOverflowJPEG() -> Data {
    let base = Turbo.encode([UInt8](repeating: 128, count: 8 * 160), 8, 160, gray: true, quality: 100, samp: 0)
    var d = Data(base[0..<scanStart(base)])
    for _ in 0..<20 { d += Data([0xFF, 0x00, 0x7F, 0xFA]) }
    return d + Data([0xFF, 0xD9])
}

private func checkDCReason(_ t: Tally) {
    let dec = Decoder()
    let d = dcOverflowJPEG()
    let img = dec.decode(d, format: .gray)
    // (blocks 3 to 16 have DC values in int16 that the IDCT's first pass cannot hold: that reason joins it)
    t.check(img == nil && dec.reason?.contains("DC value outside int16") == true, "DC overflow: \(img == nil ? "declined: \(dec.reason ?? "?")" : "accepted")")
    // the same scan cut to 16 blocks: the DC (at most 32752) stays in int16, the IDCT's first pass does not (DC
    // times 4), so the reason is the coefficient range, not the DC
    var hdr = [UInt8](d[0..<(d.count - 2 - 16)]) + [0xFF, 0xD9]
    if let i = (2..<(hdr.count - 9)).first(where: { hdr[$0] == 0xFF && hdr[$0 + 1] == 0xC0 }) { hdr[i + 5] = 0; hdr[i + 6] = 128 }  // height 128
    let img2 = dec.decode(Data(hdr), format: .gray)
    t.check(img2 == nil && dec.reason == "coefficients outside the range where all libjpeg-turbo IDCTs agree",
            "16 blocks, DC within int16: \(img2 == nil ? "declined: \(dec.reason ?? "?")" : "accepted")")
}

/// A gray 8x8 JPEG with libjpeg-turbo's q100 header, its DQT rewritten as a 16-bit table (every value 1 except
/// zig-zag position 1 = q1), and one block: DC difference 0 (code 00), AC run 0 size 1 value -1 at position 1 (code
/// 00, bit 0), EOB (1010): 0000 0101 0 + one-bit padding = 05 7F.
func quant16JPEG(_ q1: Int) -> Data {
    let base = [UInt8](Turbo.encode([UInt8](repeating: 128, count: 64), 8, 8, gray: true, quality: 100, samp: 0))
    let s0 = scanStart(Data(base))
    let i = (2..<s0).first { base[$0] == 0xFF && base[$0 + 1] == 0xDB }!
    precondition(base[i + 2] == 0 && base[i + 3] == 67 && base[i + 4] == 0, "expected one 8-bit table 0")
    var q = [UInt8]()
    for k in 0..<64 { let v = k == 1 ? q1 : 1; q += [UInt8(v >> 8), UInt8(v & 255)] }
    let dqt: [UInt8] = [0xFF, 0xDB, 0, 131, 0x10] + q
    return Data(base[0..<i] + dqt + base[(i + 69)..<s0] + [0x05, 0x7F, 0xFF, 0xD9])
}

private func checkQuant16(_ t: Tally) {
    let dec = Decoder()
    for q1 in [32768, 40000, 65535] {
        let d = quant16JPEG(q1)
        let img = dec.decode(d, format: .gray)
        t.check(img == nil && dec.reason == "quantisation value above 32767",
                "16-bit table with \(q1): \(img == nil ? "declined: \(dec.reason ?? "?")" : "accepted")")
    }
    for q1 in [300, 1000] {
        let d = quant16JPEG(q1)
        let img = dec.decode(d, format: .gray)
        t.check(sameBytes(img, turboDecode(d, .gray)!), "16-bit table with \(q1): \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs from libjpeg-turbo")")
    }
}

private func checkLayoutIdentity(_ t: Tally) {
    let files: [(String, Data)] = [
        ("640x480 4:2:0", Turbo.encode(corpusContent(640, 480, "smooth", 51), 640, 480, quality: 90, samp: 2)),
        ("203x97 4:4:4", Turbo.encode(corpusContent(203, 97, "edges", 52), 203, 97, quality: 85, samp: 0)),
        ("203x97 4:2:2 rst3", Turbo.encode(corpusContent(203, 97, "edges", 53), 203, 97, quality: 85, samp: 1, restartMCUs: 3)),
        ("640x480 4:2:0 q50", Turbo.encode(corpusContent(640, 480, "smooth", 51), 640, 480, quality: 50, samp: 2)),
    ]
    let dec = Decoder()
    dec.layoutKeyOverride = "collision"
    for round in 0..<2 {
        for (name, d) in files {
            let img = dec.decode(d)
            t.check(sameBytes(img, turboDecode(d, .rgb)!), "forced layout key collision, round \(round), \(name): \(img == nil ? "declined: \(dec.reason ?? "?")" : "bytes differ")")
        }
    }
}

private func checkOutputBuffer(_ t: Tally) {
    let d = Turbo.encode(corpusContent(203, 97, "smooth", 61), 203, 97, quality: 90, samp: 2)
    let ref = turboDecode(d, .rgb)!
    let dec = Decoder()
    let dev = dec.ctx.device
    let want = "output buffer must be .storageModeShared on the decoder's device"
    var bad: [(String, MTLBuffer)] = [("private", dev.makeBuffer(length: ref.count, options: .storageModePrivate)!)]
    #if os(macOS)
    bad.append(("managed", dev.makeBuffer(length: ref.count, options: .storageModeManaged)!))
    if let other = MTLCopyAllDevices().first(where: { $0.registryID != dev.registryID }) {
        bad.append(("another device", other.makeBuffer(length: ref.count, options: .storageModeShared)!))
    }
    #endif
    let src = d.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    for (name, ob) in bad {
        let a = d.withUnsafeBytes { dec.decode(bytes: $0, output: ob) }
        t.check(a == nil && dec.reason == want, "decode(bytes:output:) into a \(name) buffer: \(a == nil ? dec.reason ?? "?" : "accepted")")
        let b = dec.decode(buffer: src, length: d.count, output: ob)
        t.check(b == nil && dec.reason == want, "decode(buffer:output:) into a \(name) buffer: \(b == nil ? dec.reason ?? "?" : "accepted")")
    }
    print("  rejected output buffers: \(bad.map(\.0).joined(separator: ", "))")
    let ok = dev.makeBuffer(length: ref.count, options: .storageModeShared)!
    t.check(sameBytes(d.withUnsafeBytes { dec.decode(bytes: $0, output: ok) }, ref), "decode(bytes:output:) into a shared buffer")
}

/// d (a libjpeg-turbo baseline JPEG) with the frame's height and width replaced
func claimSize(_ d: Data, _ w: Int, _ h: Int) -> Data {
    var b = [UInt8](d)
    let i = (2..<(b.count - 9)).first { b[$0] == 0xFF && b[$0 + 1] == 0xC0 }!
    b[i + 5] = UInt8(h >> 8); b[i + 6] = UInt8(h & 255); b[i + 7] = UInt8(w >> 8); b[i + 8] = UInt8(w & 255)
    return Data(b)
}

private func checkOffsetLimit(_ t: Tally) {
    let small444 = Turbo.encode(corpusContent(16, 16, "smooth", 71), 16, 16, quality: 90, samp: 0)
    let gray = Turbo.encode([UInt8](repeating: 100, count: 256), 16, 16, gray: true, quality: 90, samp: 0)
    let dec = Decoder()
    dec.maxPixels = Int.max
    let dev = dec.ctx.device
    for (name, d, fmt) in [("65500x65500 4:4:4", claimSize(small444, 65500, 65500), PixelFormat.rgb),
                           ("65500x65500 gray to .gray", claimSize(gray, 65500, 65500), .gray),
                           ("46341x46341 gray to .gray", claimSize(gray, 46341, 46341), .gray),
                           ("30000x30000 4:4:4 to .rgba", claimSize(small444, 30000, 30000), .rgba)] {
        let src = d.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        let a0 = dec.allocatedBytes
        let img = dec.decode(buffer: src, length: d.count, format: fmt)
        t.check(img == nil && dec.reason?.hasPrefix("image too large") == true, "\(name), maxPixels = Int.max: \(img == nil ? "declined: \(dec.reason ?? "?")" : "accepted")")
        t.check(dec.allocatedBytes == a0, "\(name): \(dec.allocatedBytes - a0) bytes allocated before declining")
    }
    // under the limit: declined for its short data, not its size
    let d = claimSize(small444, 16384, 16384)
    let img = dec.decode(d)
    t.check(img == nil && dec.reason == "entropy-coded data too short for the image size", "16384x16384 4:4:4: \(img == nil ? dec.reason ?? "?" : "accepted")")
}

private func checkAllocOrder(_ t: Tally) {
    let tiny = claimSize(Turbo.encode(corpusContent(8, 8, "smooth", 72), 8, 8, quality: 90, samp: 0), 16384, 16384)
    let want = "entropy-coded data too short for the image size"
    do {
        let dec = Decoder()
        let a = tiny.withUnsafeBytes { dec.decode(bytes: $0) }
        t.check(a == nil && dec.reason == want && dec.allocatedBytes == 0,
                "\(tiny.count)-byte file claiming 16384x16384, decode(bytes:): \(a == nil ? dec.reason ?? "?" : "accepted"), \(dec.allocatedBytes) bytes allocated")
        let src = tiny.withUnsafeBytes { dec.ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        let b = dec.decode(buffer: src, length: tiny.count)
        t.check(b == nil && dec.reason == want && dec.allocatedBytes == 0,
                "same file, decode(buffer:): \(b == nil ? dec.reason ?? "?" : "accepted"), \(dec.allocatedBytes) bytes allocated")
        let path = NSTemporaryDirectory() + "ejm-audit-\(getpid()).jpg"
        try! tiny.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let c = dec.decode(path: path)
        t.check(c == nil && dec.reason == want && dec.allocatedBytes == 0,
                "same file, decode(path:): \(c == nil ? dec.reason ?? "?" : "accepted"), \(dec.allocatedBytes) bytes allocated")
    }
    do {
        // over the GPU budget: declined before the output (or anything else) is allocated
        let d = Turbo.encode(corpusContent(640, 480, "smooth", 73), 640, 480, quality: 90, samp: 2)
        let dec = Decoder()
        dec.maxGPUBytes = 1 << 20
        let img = dec.decode(d)
        t.check(img == nil && dec.reason?.contains("more than allowed") == true && dec.allocatedBytes == 0,
                "640x480 with maxGPUBytes 1 MB: \(img == nil ? dec.reason ?? "?" : "accepted"), \(dec.allocatedBytes) bytes allocated")
        dec.maxGPUBytes = nil
        t.check(sameBytes(dec.decode(d), turboDecode(d, .rgb)!), "640x480 after maxGPUBytes is reset")
    }
    do {
        // a file over 256 MB (sparse: a small JPEG, then zeros): decode(path:) declines before reading it
        let d = Turbo.encode(corpusContent(64, 48, "smooth", 74), 64, 48, quality: 90, samp: 2)
        let path = NSTemporaryDirectory() + "ejm-audit-big-\(getpid()).jpg"
        FileManager.default.createFile(atPath: path, contents: d)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fh = FileHandle(forWritingAtPath: path)!
        try! fh.truncate(atOffset: UInt64((1 << 28) + (2 << 20)))
        try! fh.close()
        let dec = Decoder()
        let t0 = now()
        let img = dec.decode(path: path)
        let ms = (now() - t0) * 1000
        t.check(img == nil && dec.reason == "entropy-coded data larger than 256 MB" && dec.allocatedBytes == 0,
                "258 MB file, decode(path:): \(img == nil ? dec.reason ?? "?" : "accepted"), \(dec.allocatedBytes) bytes allocated, \(fmt(ms, 1)) ms")
        print("  258 MB file through decode(path:): declined in \(fmt(ms, 1)) ms, \(dec.allocatedBytes) bytes allocated")
    }
}

private func checkAllocFailure(_ t: Tally) {
    let small = Turbo.encode(corpusContent(64, 48, "smooth", 75), 64, 48, quality: 90, samp: 2)
    let big = Turbo.encode(corpusContent(1201, 803, "smooth", 76), 1201, 803, quality: 90, samp: 1)
    let refBig = turboDecode(big, .rgb)!
    // a fresh decoder: the input buffer fails first (decode(bytes:)), the output and scratch with decode(buffer:)
    for entry in ["bytes", "buffer", "path"] {
        let dec = Decoder()
        dec.failAllocations = true
        let ob = dec.ctx.device.makeBuffer(length: refBig.count, options: .storageModeShared)!
        memset(ob.contents(), 0xA5, refBig.count)
        let src = big.withUnsafeBytes { dec.ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        let path = NSTemporaryDirectory() + "ejm-audit-fail-\(getpid()).jpg"
        try! big.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let img: GPUImage?
        switch entry {
        case "bytes": img = big.withUnsafeBytes { dec.decode(bytes: $0, output: ob) }
        case "buffer": img = dec.decode(buffer: src, length: big.count, output: ob)
        default: img = dec.decode(path: path)
        }
        let untouched = UnsafeRawBufferPointer(start: ob.contents(), count: refBig.count).allSatisfy { $0 == 0xA5 }
        t.check(img == nil && dec.reason?.hasPrefix("cannot allocate") == true && untouched,
                "allocations failing, decode(\(entry):): \(img == nil ? dec.reason ?? "?" : "accepted"), output untouched \(untouched)")
        let own = dec.decode(buffer: src, length: big.count)
        t.check(own == nil && dec.reason?.hasPrefix("cannot allocate") == true, "allocations failing, own output: \(own == nil ? dec.reason ?? "?" : "accepted")")
        dec.failAllocations = false
        t.check(sameBytes(dec.decode(big), refBig), "after allocations work again, decode(\(entry):) path decoder")
    }
    // a decoder whose buffers fit a small image: the larger one needs a bigger scratch arena, which fails
    let dec = Decoder()
    t.check(sameBytes(dec.decode(small), turboDecode(small, .rgb)!), "small image")
    dec.failAllocations = true
    let ob = dec.ctx.device.makeBuffer(length: refBig.count, options: .storageModeShared)!
    let src = big.withUnsafeBytes { dec.ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    let img = dec.decode(buffer: src, length: big.count, output: ob)
    t.check(img == nil && dec.reason?.hasPrefix("cannot allocate") == true, "scratch allocation failing: \(img == nil ? dec.reason ?? "?" : "accepted")")
    dec.failAllocations = false
    t.check(sameBytes(dec.decode(buffer: src, length: big.count, output: ob), refBig), "after the scratch allocation works again")
}

private func checkPathEdges(_ t: Tally) {
    let path = NSTemporaryDirectory() + "ejm-audit-edge-\(getpid()).jpg"
    defer { try? FileManager.default.removeItem(atPath: path) }
    for (name, d) in [("empty file", Data()), ("3-byte file", Data([0xFF, 0xD8, 0xFF]))] {
        try! d.write(to: URL(fileURLWithPath: path))
        let dec = Decoder()
        let img = dec.decode(path: path)
        t.check(img == nil && dec.reason == "not a JPEG", "\(name), decode(path:): \(img == nil ? dec.reason ?? "?" : "accepted")")
    }
    // 2 + 3 COM segments of 30000 bytes after SOI: the scan starts past 90 KB
    let base = Turbo.encode(corpusContent(203, 97, "smooth", 81), 203, 97, quality: 90, samp: 2)
    var d = Data(base[0..<2])
    for _ in 0..<3 { d += Data([0xFF, 0xFE, UInt8(30002 >> 8), UInt8(30002 & 255)]) + Data(repeating: 0x41, count: 30000) }
    d += base[2...]
    try! d.write(to: URL(fileURLWithPath: path))
    let dec = Decoder()
    let img = dec.decode(path: path)
    t.check(sameBytes(img, turboDecode(d, .rgb)!), "header of \(scanStart(d)) bytes, decode(path:): \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
    let again = dec.decode(path: path)          // now the input buffer holds it: the direct read
    t.check(sameBytes(again, turboDecode(d, .rgb)!), "the same file again: \(again == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
}
