import Foundation
import Metal

/// An opt-in, in-memory copy of a decoded JPEG's quantised coefficients, made by `Decoder.decodeAndPack(_:format:output:)`.
/// `Decoder.decode(packed:format:output:)` decodes it again without the Huffman stage, to the same pixels. Opaque:
/// the layout is internal and may change. It keeps its own copy of the original JPEG bytes, so that a decode from it can always fall back to the normal decode.
/// Immutable after creation: several decoders may decode the same object at once.
public final class PackedCoefficients {
    /// image size in pixels
    public let width: Int, height: Int
    /// GPU memory the packed copy holds (index and data buffers), not counting the kept JPEG bytes
    public let byteCount: Int
    let jpeg: Data
    let idx: MTLBuffer, data: MTLBuffer
    let dlen: Int, nblk: Int

    init(jpeg: Data, width: Int, height: Int, idx: MTLBuffer, data: MTLBuffer, dlen: Int, nblk: Int) {
        self.jpeg = jpeg; self.width = width; self.height = height
        self.idx = idx; self.data = data; self.dlen = dlen; self.nblk = nblk
        byteCount = idx.length + data.length
    }
}

/// Packing (CPU) from the arrays the IDCT reads: coef (64 int16 per block, zig-zag order), dc (absolute, int32),
/// nq (valid quads). Format version 1, little-endian: an index word per block, offset (bits 0..27) | n << 28 |
/// wide << 31, n = min(nq, 4); per block at its offset: int16 DC, n uint16 masks (bit i of mask q set iff zig-zag
/// position 16q + i is nonzero), the nonzero values of positions 0..<16n in order as int8, or int16 when any of
/// them is outside -128...127 (wide), then a 0 pad byte to even length; after the dlen data bytes, packTail zero
/// bytes (Decode.metal packed_unpack relies on at least 138 of them).
enum Packer {
    static let tail = 160                         // Decode.metal PACK_TAIL
    static let maxOffset = 0x0fff_ffff

    /// Per block: (bytes, n, wide); nil when the DC is outside int16.
    @inline(__always)
    static func measure(_ c: UnsafePointer<Int16>, _ d: Int32, _ nqb: UInt8) -> (Int, Int, Bool)? {
        if d < -32768 || d > 32767 { return nil }
        let n = Int(min(nqb, 4))
        var nz = 0, wide = false
        for i in 0..<(16 * n) {
            let v = c[i]
            if v != 0 { nz += 1; if v < -128 || v > 127 { wide = true } }
        }
        var size = 2 + 2 * n + (wide ? 2 * nz : nz)
        size += size & 1
        return (size, n, wide)
    }

    /// Writes block b at p (size bytes, from measure).
    @inline(__always)
    static func write(_ c: UnsafePointer<Int16>, _ d: Int32, _ n: Int, _ wide: Bool, _ p: UnsafeMutablePointer<UInt8>) {
        let du = UInt16(bitPattern: Int16(d))
        p[0] = UInt8(du & 255); p[1] = UInt8(du >> 8)
        var w = 2 + 2 * n
        for q in 0..<n {
            var m: UInt16 = 0
            for i in 0..<16 where c[16 * q + i] != 0 { m |= 1 << UInt16(i) }
            p[2 + 2 * q] = UInt8(m & 255); p[3 + 2 * q] = UInt8(m >> 8)
        }
        for i in 0..<(16 * n) {
            let v = c[i]
            if v == 0 { continue }
            if wide { let u = UInt16(bitPattern: v); p[w] = UInt8(u & 255); p[w + 1] = UInt8(u >> 8); w += 2 }
            else { p[w] = UInt8(bitPattern: Int8(truncatingIfNeeded: v)); w += 1 }
        }
        if w & 1 != 0 { p[w] = 0 }
    }

    /// Packs nblk blocks. alloc(dlen + tail) supplies the data memory (zero-filled is not required: the tail is
    /// cleared here); idx receives nblk words. Returns dlen, or nil when a DC is outside int16 or a block's offset
    /// passes 28 bits. Two passes (sizes, then data) over chunks of blocks on all cores.
    static func pack(coef: UnsafePointer<Int16>, dc: UnsafePointer<Int32>, nq: UnsafePointer<UInt8>, nblk: Int,
                     idx: UnsafeMutablePointer<UInt32>, alloc: (Int) -> UnsafeMutablePointer<UInt8>?) -> Int? {
        let nchunk = max(1, min(nblk / 8192, 4 * ProcessInfo.processInfo.activeProcessorCount))
        let per = (nblk + nchunk - 1) / max(nchunk, 1)
        let sums = UnsafeMutablePointer<Int>.allocate(capacity: nchunk + 1)
        defer { sums.deallocate() }
        nonisolated(unsafe) let S = sums, I = idx, CF = coef, DC = dc, NQ = nq
        // pass 1: idx[b] = size | n << 28 | wide << 31 for now; sums[k] = chunk k's bytes, -1 on a bad DC
        DispatchQueue.concurrentPerform(iterations: nchunk) { k in
            var tot = 0
            for b in (k * per)..<min((k + 1) * per, nblk) {
                guard let (size, n, wide) = measure(CF + b * 64, DC[b], NQ[b]) else { tot = -1; break }
                I[b] = UInt32(size) | UInt32(n) << 28 | (wide ? 1 << 31 : 0)
                tot += size
            }
            S[k] = tot
        }
        var off = 0
        var starts = [Int](repeating: 0, count: nchunk)
        for k in 0..<nchunk {
            if sums[k] < 0 { return nil }
            starts[k] = off
            off += sums[k]
        }
        let dlen = off
        // every block's start must fit the 28-bit offset field (the last block starts last), and the data the
        // 28-bit range
        if nblk > 0 && dlen - Int(idx[nblk - 1] & 0x0fff_ffff) > maxOffset { return nil }
        if dlen > maxOffset + 1 { return nil }
        guard let data = alloc(dlen + tail) else { return nil }
        memset(data + dlen, 0, tail)
        nonisolated(unsafe) let D = data
        let st = starts
        DispatchQueue.concurrentPerform(iterations: nchunk) { k in
            var o = st[k]
            for b in (k * per)..<min((k + 1) * per, nblk) {
                let h = I[b], size = Int(h & 0x0fff_ffff), n = Int((h >> 28) & 7), wide = h >> 31 != 0
                write(CF + b * 64, DC[b], n, wide, D + o)
                I[b] = UInt32(o) | (h & 0xf000_0000)
                o += size
            }
        }
        return dlen
    }
}

/// Test hooks for the packed path (`ejm packed-check`). Not a stable interface.
@_spi(Testing) public enum PackedTesting {
    /// the zero bytes after the data
    public static var tail: Int { Packer.tail }
    /// Packs arrays (coef: 64 int16 per block, dc, nq) into (index words, data without the tail); nil as the
    /// packer declines.
    public static func pack(coef: [Int16], dc: [Int32], nq: [UInt8]) -> (index: [UInt32], data: [UInt8])? {
        let nblk = dc.count
        precondition(coef.count == nblk * 64 && nq.count == nblk)
        var idx = [UInt32](repeating: 0, count: nblk)
        var store: UnsafeMutablePointer<UInt8>?
        var cap = 0
        defer { store?.deallocate() }
        let dlen = coef.withUnsafeBufferPointer { c in dc.withUnsafeBufferPointer { d in nq.withUnsafeBufferPointer { q in
            idx.withUnsafeMutableBufferPointer { ip in
                Packer.pack(coef: c.baseAddress!, dc: d.baseAddress!, nq: q.baseAddress!, nblk: nblk, idx: ip.baseAddress!) { n in
                    cap = n; store = .allocate(capacity: n); return store
                }
            } } } }
        guard let dlen, let store else { return nil }
        _ = cap
        return (idx, Array(UnsafeBufferPointer(start: store, count: dlen)))
    }
    /// the index words of a packed object, writable (to forge them); nblk words
    public static func indexWords(_ p: PackedCoefficients) -> UnsafeMutableBufferPointer<UInt32> {
        UnsafeMutableBufferPointer(start: p.idx.contents().assumingMemoryBound(to: UInt32.self), count: p.nblk)
    }
    /// the data bytes of a packed object (dlen, without the tail)
    public static func dataBytes(_ p: PackedCoefficients) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: p.data.contents(), count: p.dlen)
    }
    /// the length of the data before the tail (the kernel's dlen)
    public static func dataLength(_ p: PackedCoefficients) -> Int { p.dlen }
    /// the blocks of the image (from its frame)
    public static func blockCount(_ p: PackedCoefficients) -> Int { p.nblk }
}

extension Decoder {
    /// Decodes like `decode(bytes:format:output:)` and also returns a packed copy of the decode's quantised
    /// coefficients for `decode(packed:format:output:)`. Opt-in; `decode` never packs. nil when the decode
    /// declines (`reason` set); `packed` is nil when the coefficients do not fit the packed form (data over 256 MB).
    public func decodeAndPack(_ data: Data, format: PixelFormat = .rgb, output: MTLBuffer? = nil)
        -> (image: GPUImage, packed: PackedCoefficients?)? {
        guard gate.enter() else { return nil }
        defer { gate.leave() }
        guard callStart() else { return nil }
        packRequest = true
        lastArrays = nil
        defer { packRequest = false; lastArrays = nil }
        guard let img = data.withUnsafeBytes({ decodeBytesCall($0, format, output) }) else { return nil }
        guard let a = lastArrays else { return (img, nil) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let dev = ctx.device
        guard let idx = dev.makeBuffer(length: max(4 * a.nblk, 4), options: .storageModeShared) else { return (img, nil) }
        var dataBuf: MTLBuffer?
        let dlen = Packer.pack(coef: a.coef.assumingMemoryBound(to: Int16.self), dc: a.dc.assumingMemoryBound(to: Int32.self),
                               nq: a.nq.assumingMemoryBound(to: UInt8.self), nblk: a.nblk,
                               idx: idx.contents().assumingMemoryBound(to: UInt32.self)) { n in
            dataBuf = dev.makeBuffer(length: n, options: .storageModeShared)
            return dataBuf?.contents().assumingMemoryBound(to: UInt8.self)
        }
        packSeconds = CFAbsoluteTimeGetCurrent() - t0
        guard let dlen, let dataBuf else { return (img, nil) }
        // its own copy of the JPEG, so a caller's Data(bytesNoCopy:) freed or changed later cannot affect the fallback
        let kept = data.withUnsafeBytes { Data($0) }
        return (img, PackedCoefficients(jpeg: kept, width: img.width, height: img.height, idx: idx, data: dataBuf,
                                        dlen: dlen, nblk: a.nblk))
    }

    /// Decodes a packed copy made by `decodeAndPack(_:format:output:)`: the same pixels as decoding its JPEG, in
    /// any format, without the Huffman stage. `output` as in `decode(bytes:format:output:)`. When the packed copy
    /// fails a check (it belongs to another device, its sizes do not match the JPEG's frame, or the GPU's memory
    /// checks on its index reject it) the decoder decodes the kept JPEG bytes normally instead.
    public func decode(packed p: PackedCoefficients, format: PixelFormat = .rgb, output: MTLBuffer? = nil) -> GPUImage? {
        guard gate.enter() else { return nil }
        defer { gate.leave() }
        guard callStart() else { return nil }
        return p.jpeg.withUnsafeBytes { raw in
            if _slowPath(TraceState.enabled) && !internalUse {
                return traced(raw, raw.count, format) { decodePackedOrFallBack(p, raw, format, output) }
            }
            return decodePackedOrFallBack(p, raw, format, output)
        }
    }

    private func decodePackedOrFallBack(_ p: PackedCoefficients, _ raw: UnsafeRawBufferPointer, _ format: PixelFormat,
                                        _ output: MTLBuffer?) -> GPUImage? {
        // never a load sample (the profile predicts normal decodes), but GPU work other calls must see as overlap
        guard LoadCorrection.isEnabled else { return decodePackedOrFallBackTracked(p, raw, format, output) }
        return LoadCorrection.track { decodePackedOrFallBackTracked(p, raw, format, output) }
    }

    private func decodePackedOrFallBackTracked(_ p: PackedCoefficients, _ raw: UnsafeRawBufferPointer, _ format: PixelFormat,
                                               _ output: MTLBuffer?) -> GPUImage? {
        untimed = true
        defer { untimed = false }
        packedFellBack = false
        if let img = decodePacked(p, raw, format, output) { return img }
        packedFellBack = true                         // any failure: the normal decode of the kept bytes decides
        return decodeBytes(raw, format, output)
    }
}
