import Foundation
import Metal
import CryptoKit
@_spi(Testing) import ExactJPEG

// ejm packed-check [vectors|forged|corpus ...] [trials]: the opt-in packed path (Decoder.decodeAndPack,
// Decoder.decode(packed:)).
//   vectors  the format's test vectors: the packer gives each body hash, the GPU unpack of that body the arrays hash
//   forged   forged index words on in-memory payloads: the unpack kernel's flag is raised exactly when a word fails
//            a memory-safety check, guard bands around every buffer stay unchanged, and decode(packed:) falls
//            back to pixels identical to the normal decode (run under Metal shader validation by test.sh); an
//            `output` buffer with .private or .managed storage is declined as by decode(bytes:output:)
//   corpus   every corpus file the normal decoder accepts, through the packed path: identical to the normal
//            decode and to libjpeg-turbo
// ejm packed-bench [rounds]: pack cost, memory and repeat decode time, packed against normal, 6720x4480 cases.

private final class PTally {
    var ok = 0, bad = 0
    func check(_ cond: Bool, _ what: @autoclosure () -> String) {
        if cond { ok += 1 } else { bad += 1; print("  FAIL: \(what())") }
    }
}

// ---- test vectors ----

struct PackVector { let seed: UInt64; let blocks: Int; let wide: Bool; let wideBlocks: Int; let bodyBytes: Int; let arrays: String; let body: String }
let packVectors: [PackVector] = [
    PackVector(seed: 1, blocks: 64, wide: false, wideBlocks: 8, bodyBytes: 1832,
               arrays: "41c119404c6401a4a512901b14839de86b507cd7f9a81ea90c35802f18a77f86",
               body: "3fc65fcfba9b23f77e70aa124ab8ee5058c24c5d9ecd7b78828da61968571b4d"),
    PackVector(seed: 2, blocks: 4096, wide: false, wideBlocks: 546, bodyBytes: 125136,
               arrays: "45ad154bf136b45ab6bcc3b0c18e7c50bb74b6f804dbe71f27050d7dadf4c57c",
               body: "315b1c9cebb033d829b4a1571543f216f38bbb6e3251950cafae1e95fec4f943"),
    PackVector(seed: 3, blocks: 65536, wide: false, wideBlocks: 8135, bodyBytes: 2017814,
               arrays: "1a6f44b7dff81b600294341c8a7207d9b88833a6ae7e36cc1e10c3c210299264",
               body: "f3bdd6c80f3e49b3094f270caefb0c6fb1a0f165feab9b94d3da7d2dd30f07b5"),
    PackVector(seed: 4, blocks: 4096, wide: true, wideBlocks: 521, bodyBytes: 124686,
               arrays: "c1639c9406f3a92ef55696b6e7bcb3049fa61d9d0f243f0dd403c00ca53c9f17",
               body: "d0ff39ff9f9bcb04cfe281ac0d7ebb757ce7b90f4e9ea4201c333e0dd6678ab2"),
]

struct XorShift64 { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s } }

struct CoefArrays { var coef: [Int16]; var dc: [Int32]; var nq: [UInt8] }

func vectorArrays(_ v: PackVector) -> CoefArrays {
    var g = XorShift64(s: v.seed)
    let B = v.blocks
    var a = CoefArrays(coef: [Int16](repeating: 0, count: B * 64), dc: [Int32](repeating: 0, count: B), nq: [UInt8](repeating: 0, count: B))
    for b in 0..<B {
        let r = g.next()
        a.dc[b] = v.wide ? Int32(r % 65536) - 32768 : Int32(r % 2047) - 1023
        let k = (r >> 16) % 8
        let count = k == 0 ? 0 : k == 1 ? 63 : 1 + Int((r >> 24) % 24)
        let limit: UInt64 = k == 2 ? (v.wide ? 32767 : 1023) : k == 3 ? 127 : 7
        for j in 0..<count {
            let r2 = g.next()
            let pos = k == 1 ? 1 + j : 1 + Int(r2 % 63)
            let mag = Int16(1 + (r2 >> 8) % limit)
            a.coef[b * 64 + pos] = (r2 >> 40) & 1 != 0 ? -mag : mag
        }
        var hi = -1
        for p in 0..<64 where a.coef[b * 64 + p] != 0 { hi = p }
        a.nq[b] = hi < 0 ? 0 : UInt8(hi / 16 + 1)
    }
    return a
}

/// coef bytes (int16 LE), then nq, then dc (int32 LE)
func arraysHash(coef: UnsafeRawBufferPointer, nq: UnsafeRawBufferPointer, dc: UnsafeRawBufferPointer) -> String {
    var h = SHA256()
    h.update(bufferPointer: coef); h.update(bufferPointer: nq); h.update(bufferPointer: dc)
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

func bodyBytes(_ idx: [UInt32], _ data: [UInt8]) -> [UInt8] {
    var b = [UInt8](); b.reserveCapacity(idx.count * 4 + data.count)
    for w in idx { b += [UInt8(w & 255), UInt8((w >> 8) & 255), UInt8((w >> 16) & 255), UInt8(w >> 24)] }
    return b + data
}

/// One dispatch of Decode.metal packed_unpack (arguments as Decoder.run binds them) on (buffer, offset) pairs.
func dispatchUnpack(_ ctx: MetalContext, idx: (MTLBuffer, Int), data: (MTLBuffer, Int), coef: (MTLBuffer, Int),
                    dc: (MTLBuffer, Int), nq: (MTLBuffer, Int), flag: (MTLBuffer, Int), nblk: Int, dlen: Int) -> Error? {
    let desc = MTLCommandBufferDescriptor(); desc.errorOptions = .encoderExecutionStatus
    let cb = ctx.queue.makeCommandBuffer(descriptor: desc)!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(ctx.pipeline("packed_unpack"))
    e.setBuffer(idx.0, offset: idx.1, index: 0); e.setBuffer(data.0, offset: data.1, index: 1)
    e.setBuffer(coef.0, offset: coef.1, index: 2); e.setBuffer(dc.0, offset: dc.1, index: 3); e.setBuffer(nq.0, offset: nq.1, index: 4)
    var pa = (UInt32(nblk), UInt32(dlen)); e.setBytes(&pa, length: 8, index: 5)
    e.setBuffer(flag.0, offset: flag.1, index: 6)
    e.dispatchThreadgroups(MTLSize(width: max((4 * nblk + 255) / 256, 1), height: 1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return cb.error
}

private func checkVectors(_ t: PTally) {
    let ctx = MetalContext.shared
    for v in packVectors {
        let a = vectorArrays(v)
        let ah = a.coef.withUnsafeBytes { c in a.nq.withUnsafeBytes { q in a.dc.withUnsafeBytes { d in arraysHash(coef: c, nq: q, dc: d) } } }
        t.check(ah == v.arrays, "seed \(v.seed): generated arrays hash \(ah), expected \(v.arrays) (generator port)")
        guard let p = PackedTesting.pack(coef: a.coef, dc: a.dc, nq: a.nq) else { t.check(false, "seed \(v.seed): packer declined"); continue }
        let body = bodyBytes(p.index, p.data)
        let wide = p.index.filter { $0 >> 31 != 0 }.count
        let bh = sha(body)
        t.check(bh == v.body && body.count == v.bodyBytes && wide == v.wideBlocks,
                "seed \(v.seed): body \(body.count) B, \(wide) wide, sha256 \(bh); expected \(v.bodyBytes) B, \(v.wideBlocks) wide, \(v.body)")
        // GPU unpack of that body into zeroed arrays
        let B = v.blocks, dev = ctx.device
        let ib = p.index.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        let db = dev.makeBuffer(length: p.data.count + PackedTesting.tail, options: .storageModeShared)!
        p.data.withUnsafeBytes { db.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let cb = dev.makeBuffer(length: B * 128, options: .storageModeShared)!, dcb = dev.makeBuffer(length: B * 4, options: .storageModeShared)!
        let qb = dev.makeBuffer(length: B, options: .storageModeShared)!, fb = dev.makeBuffer(length: 4, options: .storageModeShared)!
        for b in [cb, dcb, qb, fb] { memset(b.contents(), 0, b.length) }
        let err = dispatchUnpack(ctx, idx: (ib, 0), data: (db, 0), coef: (cb, 0), dc: (dcb, 0), nq: (qb, 0), flag: (fb, 0), nblk: B, dlen: p.data.count)
        let gh = arraysHash(coef: UnsafeRawBufferPointer(start: cb.contents(), count: B * 128), nq: UnsafeRawBufferPointer(start: qb.contents(), count: B),
                            dc: UnsafeRawBufferPointer(start: dcb.contents(), count: B * 4))
        let flag = fb.contents().load(as: Int32.self)
        t.check(err == nil && flag == 0 && gh == v.arrays, "seed \(v.seed): GPU unpack arrays \(gh), flag \(flag), error \(String(describing: err)); expected \(v.arrays)")
        print("  seed \(v.seed), \(B) blocks, \(v.wide ? "wide" : "normal"): \(wide) wide blocks, body \(body.count) B \(bh == v.body ? "matches" : "DIFFERS"); GPU unpack arrays \(gh == v.arrays ? "match" : "DIFFER")")
    }
}

// ---- forged index words ----

/// An in-memory payload: index words, data (without the tail), dlen, and the arrays it came from.
struct Payload { let name: String; let idx: [UInt32]; let data: [UInt8]; let arrays: CoefArrays? }

/// a buffer with guard bands of known bytes before and after its content; content starts at `at`
final class Guarded {
    static let band = 4096
    let buf: MTLBuffer, at: Int, len: Int
    init(_ dev: MTLDevice, _ len: Int, guarded: Bool) {
        self.len = len; at = guarded ? Guarded.band : 0
        buf = dev.makeBuffer(length: max(len + 2 * at, 4), options: .storageModeShared)!
    }
    var content: UnsafeMutableRawPointer { buf.contents() + at }
    static func fillByte(_ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: 0xA5 ^ (i &* 31) ^ (i >> 8)) }
    func fillGuards() {
        guard at > 0 else { return }
        let p = buf.contents().assumingMemoryBound(to: UInt8.self)
        for i in 0..<at { p[i] = Guarded.fillByte(i); p[at + len + i] = Guarded.fillByte(i + 7) }
    }
    /// guard bytes that differ from the fill
    func changedGuards() -> Int {
        guard at > 0 else { return 0 }
        let p = buf.contents().assumingMemoryBound(to: UInt8.self)
        var n = 0
        for i in 0..<at { if p[i] != Guarded.fillByte(i) { n += 1 }; if p[at + len + i] != Guarded.fillByte(i + 7) { n += 1 } }
        return n
    }
}

/// what the kernel's checks reject
func violates(_ w: UInt32, dlen: Int) -> Bool { Int(w & 0x0fff_ffff) > dlen || w & 1 != 0 || (w >> 28) & 7 > 4 }

/// a forged word of kind k for a block whose real word is w
func forgeWord(_ k: Int, _ w: UInt32, dlen: Int, _ g: inout XorShift64) -> UInt32 {
    let r = g.next()
    let hi = w & 0xf000_0000, off = w & 0x0fff_ffff
    switch k {
    case 0:                                      // offset past dlen (even or odd), up to the field's maximum
        let past = UInt32(min(dlen + 1 + Int(r % UInt64(max(0x0fff_ffff - dlen, 1))), 0x0fff_ffff))
        return hi | past
    case 1: return hi | (off ^ 1)                              // odd offset (the real one plus or minus 1)
    case 2: return (w & 0x8fff_ffff) | UInt32(5 + r % 3) << 28 // n = 5, 6, 7
    case 3: return UInt32(truncatingIfNeeded: r >> 7)          // fully random
    case 4:                                      // valid edge: offset dlen (reads only the zero tail), any n <= 4
        return UInt32(dlen) | UInt32(r % 5) << 28 | (r & 32 != 0 ? 1 << 31 : 0)
    default:                                     // valid: another block's even offset, n <= 4, any wide bit
        let o = (UInt32(truncatingIfNeeded: r >> 3) % UInt32(max(dlen, 2))) & ~1
        return o | UInt32(r % 5) << 28 | (r & 64 != 0 ? 1 << 31 : 0)
    }
}

struct ForgedTally { var trials = 0, violating = 0, flagged = 0, flagWrong = 0, guardChanged = 0, gpuErrors = 0, badBlockWrites = 0
                     var decodes = 0, fellBack = 0, fallbackWrong = 0, fallbackMissing = 0, validDecodes = 0, outTailChanged = 0 }

/// Kernel-level trial on one payload: forge `count` words, run packed_unpack on guarded (or exact-size) buffers.
private func forgedKernelTrial(_ ctx: MetalContext, _ p: Payload, _ g: inout XorShift64, _ T: inout ForgedTally, guarded: Bool) {
    let dev = ctx.device, B = p.idx.count, dlen = p.data.count
    var idx = p.idx
    let count = 1 + Int(g.next() % 8)
    var forgedAt: [Int] = []
    for _ in 0..<count {
        let b = Int(g.next() % UInt64(B)), kind = Int(g.next() % 6)
        idx[b] = forgeWord(kind, p.idx[b], dlen: dlen, &g)
        forgedAt.append(b)
    }
    let anyBad = idx.contains { violates($0, dlen: dlen) }
    let ib = Guarded(dev, 4 * B, guarded: guarded), db = Guarded(dev, dlen + PackedTesting.tail, guarded: guarded)
    let cb = Guarded(dev, 128 * B, guarded: guarded), dcb = Guarded(dev, 4 * B, guarded: guarded)
    let qb = Guarded(dev, B, guarded: guarded), fb = Guarded(dev, 4, guarded: guarded)
    let all = [ib, db, cb, dcb, qb, fb]
    for x in all { x.fillGuards() }
    idx.withUnsafeBytes { ib.content.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    p.data.withUnsafeBytes { db.content.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    memset(db.content + dlen, 0, PackedTesting.tail)
    memset(cb.content, 0x5A, 128 * B); memset(dcb.content, 0x5A, 4 * B); memset(qb.content, 0x5A, B); memset(fb.content, 0, 4)
    let err = dispatchUnpack(ctx, idx: (ib.buf, ib.at), data: (db.buf, db.at), coef: (cb.buf, cb.at), dc: (dcb.buf, dcb.at),
                             nq: (qb.buf, qb.at), flag: (fb.buf, fb.at), nblk: B, dlen: dlen)
    T.trials += 1
    if err != nil { T.gpuErrors += 1 }
    let flag = fb.content.load(as: Int32.self)
    if anyBad { T.violating += 1 }
    if flag != 0 { T.flagged += 1 }
    if (flag != 0) != anyBad || (flag != 0 && flag != 512) { T.flagWrong += 1 }
    T.guardChanged += all.reduce(0) { $0 + $1.changedGuards() }
    // a rejected block: dc 0, nq 0, its coefficients untouched
    let c = cb.content.assumingMemoryBound(to: UInt8.self), d = dcb.content.assumingMemoryBound(to: Int32.self)
    let q = qb.content.assumingMemoryBound(to: UInt8.self)
    for b in Set(forgedAt) where violates(idx[b], dlen: dlen) {
        if d[b] != 0 || q[b] != 0 || (0..<128).contains(where: { c[b * 128 + $0] != 0x5A }) { T.badBlockWrites += 1 }
    }
    // the blocks that were not forged must unpack to their arrays (valid quads, DC, nq)
    if let a = p.arrays {
        let ci = cb.content.assumingMemoryBound(to: Int16.self)
        let forged = Set(forgedAt)
        for b in 0..<B where !forged.contains(b) {
            let n = Int(min(a.nq[b], 4))
            if d[b] != a.dc[b] || q[b] != a.nq[b] || (0..<(16 * n)).contains(where: { ci[b * 64 + $0] != a.coef[b * 64 + $0] }) { T.badBlockWrites += 1; break }
        }
    }
}

/// Public-API trial: forge words in a packed object; decode(packed:) must fall back exactly when a word fails a
/// check, to pixels identical to the normal decode, and write nothing past the image in `output`.
private func forgedDecodeTrial(_ dec: Decoder, _ pk: PackedCoefficients, _ want: [PixelFormat: [UInt8]], _ g: inout XorShift64,
                               _ T: inout ForgedTally) {
    let words = PackedTesting.indexWords(pk), dlen = PackedTesting.dataLength(pk), B = words.count
    let saved = Array(words)
    defer { for i in 0..<B { words[i] = saved[i] } }
    let count = 1 + Int(g.next() % 4)
    for _ in 0..<count {
        let b = Int(g.next() % UInt64(B)), kind = Int(g.next() % 6)
        words[b] = forgeWord(kind, saved[b], dlen: dlen, &g)
    }
    let anyBad = words.contains { violates($0, dlen: dlen) }
    let fmts: [PixelFormat] = [.rgb, .bgr, .gray, .rgba, .bgra]
    let f = fmts[Int(g.next() % 5)]
    let nout = pk.width * pk.height * f.channels
    let out = dec.ctx.device.makeBuffer(length: nout + Guarded.band, options: .storageModeShared)!
    let op = out.contents().assumingMemoryBound(to: UInt8.self)
    for i in 0..<(nout + Guarded.band) { op[i] = Guarded.fillByte(i) }
    let img = dec.decode(packed: pk, format: f, output: out)
    T.decodes += 1
    if (0..<Guarded.band).contains(where: { op[nout + $0] != Guarded.fillByte(nout + $0) }) { T.outTailChanged += 1 }
    if anyBad {
        if !dec.packedFellBack { T.fallbackMissing += 1 }
        if dec.packedFellBack { T.fellBack += 1 }
        let same = img.map { im in want[f]!.withUnsafeBytes { $0.elementsEqual(im.bytes) } } ?? false
        if !same { T.fallbackWrong += 1 }
    } else {
        T.validDecodes += 1                      // a forged but in-range payload: any pixels, or a fallback, are fine
    }
}

private func checkForged(_ t: PTally, trials: Int) {
    let ctx = MetalContext.shared
    var payloads: [Payload] = []
    for v in packVectors {
        let a = vectorArrays(v)
        let p = PackedTesting.pack(coef: a.coef, dc: a.dc, nq: a.nq)!
        payloads.append(Payload(name: "vector seed \(v.seed)", idx: p.index, data: p.data, arrays: a))
    }
    // real decodes from the synthetic corpus (small files; packed objects, also used for the public-API trials)
    let dec = Decoder(), dec2 = Decoder()
    var objs: [(PackedCoefficients, [PixelFormat: [UInt8]])] = []
    for it in makeCorpusSmall() {
        guard let (_, pk) = dec.decodeAndPack(it.data), let pk else { continue }
        payloads.append(Payload(name: it.name, idx: Array(PackedTesting.indexWords(pk)),
                                data: Array(UnsafeRawBufferPointer(PackedTesting.dataBytes(pk))), arrays: nil))
        var want: [PixelFormat: [UInt8]] = [:]
        for f in [PixelFormat.rgb, .bgr, .gray, .rgba, .bgra] { want[f] = dec.decode(it.data, format: f).map { Array($0.bytes) } }
        objs.append((pk, want))
    }
    var T = ForgedTally()
    for seed: UInt64 in [11, 12, 13, 14] {
        var g = XorShift64(s: seed &* 0x9E37_79B9_7F4A_7C15)
        for i in 0..<(trials / 4) {
            let p = payloads[i % payloads.count]
            forgedKernelTrial(ctx, p, &g, &T, guarded: i % 2 == 0)
            if !objs.isEmpty && i % 2 == 1 {
                let (pk, want) = objs[(i / 2) % objs.count]
                forgedDecodeTrial(dec2, pk, want, &g, &T)
            }
        }
    }
    // the objects decode exactly again once restored
    var restored = 0
    for (pk, want) in objs { if let im = dec2.decode(packed: pk), !dec2.packedFellBack, want[.rgb]!.withUnsafeBytes({ $0.elementsEqual(im.bytes) }) { restored += 1 } }
    print("  payloads: \(payloads.count) (4 vectors, \(payloads.count - 4) corpus decodes); kernel trials \(T.trials) (half with \(Guarded.band)-byte guard bands around all 6 buffers, half exact-size), \(T.violating) with a violating word, flag raised \(T.flagged), flag wrong \(T.flagWrong), guard bytes changed \(T.guardChanged), wrong block writes \(T.badBlockWrites), GPU errors \(T.gpuErrors)")
    print("  decode(packed:) trials \(T.decodes): \(T.decodes - T.validDecodes) with a violating word, fell back \(T.fellBack), missing fallback \(T.fallbackMissing), pixels differing from the normal decode \(T.fallbackWrong), bytes past the image in output changed \(T.outTailChanged); \(T.validDecodes) in-range forgeries (no check fails, any result allowed); restored objects exact \(restored)/\(objs.count)")
    t.check(T.flagWrong == 0 && T.guardChanged == 0 && T.badBlockWrites == 0 && T.gpuErrors == 0 && T.violating > 0, "kernel trials")
    t.check(T.fallbackMissing == 0 && T.fallbackWrong == 0 && T.outTailChanged == 0 && restored == objs.count, "decode(packed:) trials")
    // an output buffer the kernels cannot write for the CPU: declined, as by decode(bytes:output:)
    if let (pk, px) = objs.first {
        let n = px[.rgb]!.count
        let want = "output buffer must be .storageModeShared on the decoder's device"
        for (name, opt) in [("private", MTLResourceOptions.storageModePrivate), ("managed", .storageModeManaged)] {
            let ob = ctx.device.makeBuffer(length: n, options: opt)!
            let img = dec2.decode(packed: pk, output: ob)
            t.check(img == nil && dec2.reason == want, "decode(packed:output:) into a \(name) buffer: \(img == nil ? dec2.reason ?? "?" : "accepted")")
        }
        let ok = ctx.device.makeBuffer(length: n, options: .storageModeShared)!
        let img = dec2.decode(packed: pk, output: ok)
        t.check(img != nil && !dec2.packedFellBack && px[.rgb]!.withUnsafeBytes { $0.elementsEqual(img!.bytes) }, "decode(packed:output:) into a shared buffer")
    }
}

/// the small files of the corpus (up to 97x203): payloads for the forged trials
func makeCorpusSmall() -> [CorpusItem] {
    makeCorpus().filter { $0.expectGPU && $0.data.count < 60_000 && !$0.name.hasPrefix("tj_480x640") && !$0.name.hasPrefix("tj_1080x") }
        .enumerated().filter { $0.offset % 6 == 0 }.map(\.element)
}

// ---- corpus through the packed path ----

private func checkCorpus(_ t: PTally) {
    let corpus = makeCorpus()
    let normal = Decoder(), packer = Decoder(), repeat_ = Decoder()
    var ok = 0, declined = 0, wrong = 0, unexpected = 0, fellBack = 0, extra = 0, extraWrong = 0, notPacked = 0
    var kept: [(String, PackedCoefficients, [UInt8])] = []
    for item in corpus {
        for format in [PixelFormat.rgb, .gray] {
            let n = normal.decode(item.data, format: format).map { Array($0.bytes) }
            let r = packer.decodeAndPack(item.data, format: format)
            if !item.expectGPU || n == nil {
                if r == nil && n == nil && !item.expectGPU { declined += 1 } else { unexpected += 1; print("  unexpected: \(item.name) \(format)") }
                continue
            }
            guard let r, let ref = Turbo.decode(item.data, gray: format == .gray) else { unexpected += 1; print("  packing decode declined: \(item.name)"); continue }
            guard let pk = r.packed else { notPacked += 1; wrong += 1; print("  not packed: \(item.name)"); continue }
            let first = Array(r.image.bytes)
            let again = repeat_.decode(packed: pk, format: format).map { Array($0.bytes) }
            if repeat_.packedFellBack { fellBack += 1 }
            if first == ref.px && n! == ref.px && again == ref.px && !repeat_.packedFellBack { ok += 1 } else {
                wrong += 1; print("  DIFFERENT \(item.name) \(format): pack decode \(first == ref.px), normal \(n! == ref.px), packed decode \(again == ref.px)")
            }
            // the other formats from the same packed copy, against the normal decode (api-check ties those to libjpeg-turbo)
            if format == .rgb && item.data.count < 2_000_000 {
                for f in [PixelFormat.bgr, .rgba, .bgra] {
                    extra += 1
                    let a = repeat_.decode(packed: pk, format: f).map { Array($0.bytes) }
                    if a == nil || repeat_.packedFellBack || a != normal.decode(item.data, format: f).map({ Array($0.bytes) }) { extraWrong += 1; print("  DIFFERENT \(item.name) \(f) from packed") }
                }
                if pk.byteCount < 1_000_000 { kept.append((item.name, pk, ref.px)); if kept.count > 64 { kept.removeFirst() } }
            }
        }
    }
    // older packed copies, in reverse order, after other images went through the same decoder
    var late = 0
    for (name, pk, px) in kept.reversed() {
        let a = repeat_.decode(packed: pk).map { Array($0.bytes) }
        if a == px && !repeat_.packedFellBack { late += 1 } else { print("  DIFFERENT late \(name)") }
    }
    print("  formats .bgr/.rgba/.bgra from the packed copies: \(extra - extraWrong)/\(extra) identical; \(late)/\(kept.count) older copies decoded again later, identical; fallbacks \(fellBack); not packed \(notPacked)")
    print("packed exact: \(ok), declined as expected: \(declined), wrong: \(wrong), unexpected decline/accept: \(unexpected)")
    t.check(wrong == 0 && unexpected == 0 && extraWrong == 0 && late == kept.count && fellBack == 0, "packed corpus")
    checkPackedLoad(t)
}

/// The device profile's load correction: a decode(packed:) is never a load sample (the profile predicts normal
/// decodes), but it is this process's GPU work, so a public call overlapping it is not a sample either
private func checkPackedLoad(_ t: PTally) {
    _ = DeviceProfile.current.measuredRouting(timeout: 30)        // no calibration call overlaps the ones below
    let dev = MetalContext.shared.device
    let jpg = Turbo.encode(corpusContent(1600, 1200, "smooth", 93), 1600, 1200, quality: 90, samp: 2)
    let dec = Decoder()
    guard let r = dec.decodeAndPack(jpg), let pk = r.packed else { t.check(false, "load: no packed copy"); return }
    for _ in 0..<2 { _ = dec.decode(packed: pk) }                  // setup done
    let n0 = DeviceProfileTesting.loadSampleCount
    let ok = dec.decode(packed: pk) != nil && !dec.packedFellBack
    let n1 = DeviceProfileTesting.loadSampleCount
    let lock = NSLock()
    var got = -1
    let started = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        started.signal()
        let g = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 300)
        lock.lock(); got = g; lock.unlock()
    }
    started.wait()
    Thread.sleep(forTimeInterval: 0.03)
    var decodes = 0
    while true {
        lock.lock(); let g = got; lock.unlock()
        if g >= 0 { break }
        _ = dec.decode(packed: pk); decodes += 1
    }
    t.check(ok && n1 == n0 && got == 0,
            "load: a decode(packed:) is no sample (\(n1 - n0)); a call overlapping \(decodes) of them is none either (\(got))")
}

/// A deliberate out-of-bounds read for test.sh: the kernel is told a dlen far past the data buffer, so check (a)
/// lets offsets past the buffer through; under Metal shader validation this must be reported (the control that the
/// validated forged run would have seen such a read). Not in the default list.
private func checkControl(_ t: PTally) {
    let ctx = MetalContext.shared, dev = ctx.device, B = 4096
    let idx = (0..<B).map { UInt32(1 << 20) + UInt32($0) * 2 | 4 << 28 }
    let ib = idx.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    let db = dev.makeBuffer(length: 4096, options: .storageModeShared)!
    let cb = dev.makeBuffer(length: B * 128, options: .storageModeShared)!, dcb = dev.makeBuffer(length: B * 4, options: .storageModeShared)!
    let qb = dev.makeBuffer(length: B, options: .storageModeShared)!, fb = dev.makeBuffer(length: 4, options: .storageModeShared)!
    let err = dispatchUnpack(ctx, idx: (ib, 0), data: (db, 0), coef: (cb, 0), dc: (dcb, 0), nq: (qb, 0), flag: (fb, 0), nblk: B, dlen: 0x0fff_ffff)
    print("  control dispatch with a lying dlen: command buffer error \(String(describing: err)); flag \(fb.contents().load(as: Int32.self))")
}

func runPackedCheck(_ argv: [String]) -> Bool {
    let all = ["vectors", "forged", "corpus", "control"]
    var names = argv.filter { Int($0) == nil }
    let trials = argv.compactMap { Int($0) }.first ?? 4000
    if names.isEmpty { names = ["vectors", "forged", "corpus"] }
    if let u = names.first(where: { !all.contains($0) }) { print("unknown check \(u); checks: \(all.joined(separator: " "))"); return false }
    print("reference: \(Turbo.version)")
    var failed = 0
    for name in names {
        let t = PTally(), t0 = now()
        switch name {
        case "vectors": checkVectors(t)
        case "forged": checkForged(t, trials: trials)
        case "control": checkControl(t)
        default: checkCorpus(t)
        }
        print("\(t.bad == 0 ? "PASS" : "FAIL") \(name): \(t.ok) checks passed, \(t.bad) failed (\(fmt(now() - t0, 1)) s)")
        if t.bad > 0 { failed += 1 }
    }
    print(failed == 0 ? "packed-check: all \(names.count) checks passed" : "packed-check: \(failed) of \(names.count) checks FAILED")
    return failed == 0
}

// ---- measurements ----

func runPackedBench(rounds: Int) {
    print("packed-bench: load before \(Bench.shell("sysctl -n vm.loadavg"))")
    let img = Synth.make(width: 6720, height: 4480, seed: 11)
    let normal = Decoder(), packedDec = Decoder(), packer = Decoder()
    for (label, q, s) in [("6720x4480 q95 4:2:2", 95, 1), ("6720x4480 q90 4:2:0", 90, 2), ("6720x4480 q95 4:4:4", 95, 0)] {
        let data = Turbo.encode(img, 6720, 4480, quality: q, samp: s)
        let ref = Turbo.decode(data)!.px
        var packMs: [Double] = [], pk: PackedCoefficients?
        for _ in 0..<7 { autoreleasepool { pk = packer.decodeAndPack(data)?.packed; packMs.append(packer.packSeconds * 1000) } }
        guard let pk else { print("\(label): not packed"); continue }
        let nblk = PackedTesting.blockCount(pk)
        let arrays = nblk * (128 + 4 + 1)
        let mp = 6720.0 * 4480 / 1e6, per30 = 30 / mp
        let exact = packedDec.decode(packed: pk).map { im in ref.withUnsafeBytes { $0.elementsEqual(im.bytes) } } ?? false
        print("\(label): JPEG \(fmt(Double(data.count) / 1e6)) MB, \(nblk) blocks; packed copy \(fmt(Double(pk.byteCount) / 1e6)) MB (\(fmt(Double(pk.byteCount) / 1e6 * per30)) MB per 30 MP) vs coefficient arrays \(fmt(Double(arrays) / 1e6)) MB; pack (CPU, after the decode) median \(fmt(median(packMs), 2)) ms, min \(fmt(packMs.min()!, 2)) ms (\(fmt(median(packMs) * per30, 2)) ms per 30 MP); packed decode \(exact ? "exact" : "DIFFERENT")\(packedDec.packedFellBack ? " (FELL BACK)" : "")")
        for _ in 0..<5 { _ = normal.decode(data); _ = packedDec.decode(packed: pk) }
        var nw: [Double] = [], ng: [Double] = [], pw: [Double] = [], pg: [Double] = []
        var rn: [Double] = [], rp: [Double] = []
        let reps = 15
        for _ in 0..<rounds {
            var a: [Double] = [], b: [Double] = []
            for _ in 0..<reps {
                var t0 = now(); _ = normal.decode(data); a.append(now() - t0); ng.append(normal.gpuSeconds)
                t0 = now(); _ = packedDec.decode(packed: pk); b.append(now() - t0); pg.append(packedDec.gpuSeconds)
            }
            nw += a; pw += b; rn.append(median(a)); rp.append(median(b))
        }
        func ms(_ x: Double) -> String { fmt(x * 1000, 3) }
        print("  repeat decode, \(rounds) interleaved rounds x \(reps): normal wall \(ms(median(nw))) ms [round medians \(rn.map(ms).joined(separator: " "))], GPU \(ms(median(ng))) ms (min \(ms(ng.min()!)))")
        print("                                  packed wall \(ms(median(pw))) ms [round medians \(rp.map(ms).joined(separator: " "))], GPU \(ms(median(pg))) ms (min \(ms(pg.min()!))); wall \(fmt((median(pw) / median(nw) - 1) * 100, 1))%, GPU \(fmt((median(pg) / median(ng) - 1) * 100, 1))%")
        print("  load now \(Bench.shell("sysctl -n vm.loadavg"))")
    }
}
