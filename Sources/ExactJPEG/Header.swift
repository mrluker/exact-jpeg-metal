// Strict JPEG header parser, ported from exact-gpu-jpeg's _header.py.
//
// It accepts only what the GPU path decodes exactly and is deliberately stricter than libjpeg-turbo: anything
// unusual throws Unsupported so the caller can fall back to a CPU decoder. The rules that decide what
// libjpeg-turbo does (colour space guess, default Huffman tables, table validation) follow libjpeg-turbo 3.1.2
// (jdmarker.c, jdapimin.c, jdhuff.c, jstdhuff.c).
//
// Portions are derived from libjpeg-turbo 3.1.2 (see THIRD_PARTY_NOTICES.md for the routines and changes):
//   Copyright (C) 1991-1998, Thomas G. Lane. Modifications by Guido Vollbeding.
//   libjpeg-turbo Modifications: Copyright (C) 2009-2025, D. R. Commander, and the other contributors named
//   in the original file headers.
// Re-implemented and modified by Luke Riley, 2026. Those portions remain under the IJG License
// (licenses/README.ijg); the rest is MIT (LICENSE).

public struct Unsupported: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = s }
}

let maxDimension = 65500
let maxBlocksInMCU = 10

public struct HuffTable: Hashable, Sendable {
    public var counts: [UInt8]   // 16
    public var vals: [UInt8]
}

// libjpeg's standard Huffman tables (jstdhuff.c), keyed by (class, id): class 0 = DC, 1 = AC.
let stdDCLum = HuffTable(counts: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], vals: Array(0..<12))
let stdDCChr = HuffTable(counts: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], vals: Array(0..<12))
let stdACLum = HuffTable(counts: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], vals: [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa])
let stdACChr = HuffTable(counts: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], vals: [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa])

func stdTable(_ tc: Int, _ th: Int) -> HuffTable? {
    switch (tc, th) {
    case (0, 0): return stdDCLum
    case (0, 1): return stdDCChr
    case (1, 0): return stdACLum
    case (1, 1): return stdACChr
    default: return nil
    }
}

/// libjpeg-turbo's table checks (jdmarker.c get_dht, jdhuff.c jpeg_make_d_derived_tbl).
func checkHuffman(_ t: HuffTable, isDC: Bool) throws {
    let n = t.counts.reduce(0) { $0 + Int($1) }
    if n < 1 || n > 256 || t.vals.count != n { throw Unsupported("bad Huffman table") }
    var code = 0
    for l in 1...16 {
        code += Int(t.counts[l - 1])
        if code >= (1 << l) { throw Unsupported("bad Huffman table") }   // also rejects an all-ones code
        code <<= 1
    }
    if isDC && (t.vals.max() ?? 0) > 15 { throw Unsupported("bad Huffman table") }
}

public struct JPEGHeader: Sendable {
    public var width: Int
    public var height: Int
    public var ncomp: Int                 // 1 (grayscale) or 3 (YCbCr)
    public var samp: [(h: Int, v: Int)]   // per component, as used for decoding ((1,1) for a 1-component scan)
    public var quant: [[Int32]]           // per component: 64 values in zig-zag order
    public var dcTabs: [HuffTable]
    public var acTabs: [HuffTable]
    public var td: [Int]
    public var ta: [Int]
    public var dri: Int                   // restart interval in MCUs (0: none)
    public var scanStart: Int             // offset of the first entropy-coded byte

    public var hmax: Int { samp.map(\.h).max()! }
    public var vmax: Int { samp.map(\.v).max()! }

    public var subsampling: String {
        if ncomp == 1 { return "gray" }
        let names: [String: String] = ["1,1": "4:4:4", "2,1": "4:2:2", "2,2": "4:2:0", "1,2": "4:4:0", "4,1": "4:1:1"]
        let (y, c1, c2) = (samp[0], samp[1], samp[2])
        if c1 == c2, y.h % c1.h == 0, y.v % c1.v == 0, let n = names["\(y.h / c1.h),\(y.v / c1.v)"] { return n }
        return samp.map { "\($0.h)x\($0.v)" }.joined(separator: "/")
    }
}

@inline(__always) private func u16(_ p: UnsafeRawBufferPointer, _ i: Int) -> Int { (Int(p[i]) << 8) | Int(p[i + 1]) }

/// Parse the markers up to the first SOS. Throws Unsupported for anything the GPU path does not decode exactly,
/// including malformed headers.
public func parseJPEGHeader(_ p: UnsafeRawBufferPointer) throws -> JPEGHeader {
    let n = p.count
    if n < 4 || p[0] != 0xFF || p[1] != 0xD8 { throw Unsupported("not a JPEG") }
    var i = 2
    var qt: [Int: [Int32]] = [:]
    var dht: [Int: HuffTable] = [:]          // key tc * 4 + th
    var sof: (H: Int, W: Int, comps: [(id: Int, h: Int, v: Int, tq: Int)])? = nil
    var dri = 0
    var jfif = false
    var adobe: Int? = nil
    while true {
        if i + 1 >= n { throw Unsupported("no SOS") }
        if p[i] != 0xFF { throw Unsupported("garbage between markers") }
        while i + 1 < n && p[i + 1] == 0xFF { i += 1 }
        if i + 1 >= n { throw Unsupported("no SOS") }
        let m = Int(p[i + 1])
        i += 2
        if m == 0x00 || m == 0x01 || (0xD0...0xD7).contains(m) { throw Unsupported("unexpected marker \(m)") }
        if m == 0xD8 || m == 0xD9 { throw Unsupported("SOI/EOI before SOS") }
        if i + 2 > n { throw Unsupported("truncated header") }
        let L = u16(p, i)
        if L < 2 || i + L > n { throw Unsupported("bad marker length") }
        let s0 = i + 2
        let sl = L - 2
        @inline(__always) func seg(_ k: Int) -> Int { Int(p[s0 + k]) }
        switch m {
        case 0xDB:                                         // DQT
            var j = 0
            while j < sl {
                let pq = seg(j) >> 4, tq = seg(j) & 15
                if tq > 3 || pq > 1 { throw Unsupported("bad DQT") }
                let w = pq != 0 ? 128 : 64
                if j + 1 + w > sl { throw Unsupported("bad DQT length") }
                qt[tq] = (0..<64).map { k in Int32(pq != 0 ? (seg(j + 1 + 2 * k) << 8) | seg(j + 2 + 2 * k) : seg(j + 1 + k)) }
                j += 1 + w
            }
        case 0xC4:                                         // DHT
            var j = 0
            while j < sl {
                if j + 17 > sl { throw Unsupported("bad DHT length") }
                let tc = seg(j) >> 4, th = seg(j) & 15
                if tc > 1 || th > 3 { throw Unsupported("bad DHT index") }
                let counts = (0..<16).map { UInt8(seg(j + 1 + $0)) }
                let nv = counts.reduce(0) { $0 + Int($1) }
                if nv > 256 || j + 17 + nv > sl { throw Unsupported("bad Huffman table") }
                let t = HuffTable(counts: counts, vals: (0..<nv).map { UInt8(seg(j + 17 + $0)) })
                try checkHuffman(t, isDC: tc == 0)
                dht[tc * 4 + th] = t
                j += 17 + nv
            }
        case 0xC0, 0xC1:                                   // baseline / extended sequential, Huffman
            if sof != nil { throw Unsupported("duplicate SOF") }
            if sl < 6 { throw Unsupported("bad SOF") }
            let prec = seg(0), H = (seg(1) << 8) | seg(2), W = (seg(3) << 8) | seg(4), nc = seg(5)
            if sl != 6 + 3 * nc { throw Unsupported("bad SOF length") }
            if prec != 8 { throw Unsupported("\(prec)-bit samples") }
            if H == 0 || W == 0 { throw Unsupported("empty image or DNL") }
            if H > maxDimension || W > maxDimension { throw Unsupported("image too big") }
            var comps: [(id: Int, h: Int, v: Int, tq: Int)] = []
            for k in 0..<nc {
                let cid = seg(6 + 3 * k), hv = seg(7 + 3 * k), tq = seg(8 + 3 * k)
                let h = hv >> 4, v = hv & 15
                if !(1...4).contains(h) || !(1...4).contains(v) || tq > 3 { throw Unsupported("bad sampling factors") }
                comps.append((cid, h, v, tq))
            }
            if Set(comps.map(\.id)).count != nc { throw Unsupported("duplicate component id") }
            sof = (H, W, comps)
        case 0xC2: throw Unsupported("progressive JPEG")
        case 0xC3, 0xC5, 0xC6, 0xC7: throw Unsupported("lossless or hierarchical JPEG")
        case 0xC8: throw Unsupported("JPG marker")
        case 0xC9...0xCF: throw Unsupported("arithmetic coding")
        case 0xDD:                                         // DRI
            if sl != 2 { throw Unsupported("bad DRI") }
            dri = (seg(0) << 8) | seg(1)
        case 0xE0:
            if sl >= 14 && seg(0) == 0x4A && seg(1) == 0x46 && seg(2) == 0x49 && seg(3) == 0x46 && seg(4) == 0 { jfif = true }
        case 0xEE:
            if sl >= 12 && seg(0) == 0x41 && seg(1) == 0x64 && seg(2) == 0x6F && seg(3) == 0x62 && seg(4) == 0x65 { adobe = seg(11) }
        case 0xE1...0xEF, 0xFE: break                      // other APPn, COM
        case 0xDA:                                         // SOS
            guard let sof else { throw Unsupported("SOS before SOF") }
            if sl < 1 { throw Unsupported("bad SOS") }
            let ns = seg(0)
            if sl != 2 * ns + 4 || !(1...4).contains(ns) { throw Unsupported("bad SOS length") }
            let scomps = (0..<ns).map { k in (id: seg(1 + 2 * k), td: seg(2 + 2 * k) >> 4, ta: seg(2 + 2 * k) & 15) }
            let spec = (seg(1 + 2 * ns), seg(2 + 2 * ns), seg(3 + 2 * ns))
            let comps = sof.comps
            let nc = comps.count
            if nc != 1 && nc != 3 { throw Unsupported("\(nc) components") }
            if spec != (0, 63, 0) { throw Unsupported("not a sequential scan") }
            if scomps.map(\.id) != comps.map(\.id) { throw Unsupported("scan does not hold every component in frame order") }
            var samp: [(h: Int, v: Int)]
            if nc == 3 {
                // jdapimin.c default_decompress_parms: JFIF > Adobe transform > component ids
                let rgb: Bool
                if jfif { rgb = false } else if let a = adobe { rgb = a == 0 } else { rgb = comps.map(\.id) == [82, 71, 66] }
                if rgb { throw Unsupported("RGB-coded JPEG") }
                samp = comps.map { ($0.h, $0.v) }
                let hm = samp.map(\.h).max()!, vm = samp.map(\.v).max()!
                for s in samp where hm % s.h != 0 || vm % s.v != 0 { throw Unsupported("fractional sampling") }
                if samp.reduce(0, { $0 + $1.h * $1.v }) > maxBlocksInMCU { throw Unsupported("too many blocks per MCU") }
            } else {
                samp = [(1, 1)]                            // a single-component scan is non-interleaved
            }
            var q: [[Int32]] = []
            for c in comps {
                guard let t = qt[c.tq] else { throw Unsupported("missing quantisation table") }
                q.append(t)
            }
            var dct: [HuffTable] = [], act: [HuffTable] = []
            for s in scomps {
                if s.td > 3 || s.ta > 3 { throw Unsupported("bad Huffman table id") }
                guard let d = dht[s.td] ?? stdTable(0, s.td), let a = dht[4 + s.ta] ?? stdTable(1, s.ta) else {
                    throw Unsupported("missing Huffman table")
                }
                dct.append(d); act.append(a)
            }
            return JPEGHeader(width: sof.W, height: sof.H, ncomp: nc, samp: samp, quant: q, dcTabs: dct, acTabs: act,
                              td: scomps.map(\.td), ta: scomps.map(\.ta), dri: dri, scanStart: i + L)
        default:
            throw Unsupported("marker \(m)")
        }
        i += L
    }
}

/// After the entropy-coded data (ending at `end`, a marker's 0xFF or the data's end) accept only fill bytes,
/// complete APPn/COM segments, then EOI, the end of the data, or a lone 0xFF as the last byte (libjpeg-turbo's memory
/// source supplies a fake EOI after it; the decoder also ends the entropy-coded data at such a byte, as libjpeg-turbo
/// does, instead of reading it as data). Returns nil if fine, else a reason.
public func checkTrailer(_ p: UnsafeRawBufferPointer, _ end: Int) -> String? {
    let n = p.count
    var i = end
    while i < n {
        if p[i] != 0xFF { return "data after the scan" }
        if i + 1 >= n { return nil }
        let m = Int(p[i + 1])
        if m == 0xFF { i += 1; continue }
        if m == 0xD9 { return nil }
        if (0xE0...0xEF).contains(m) || m == 0xFE {
            if i + 4 > n { return "truncated marker after the scan" }
            let L = u16(p, i + 2)
            if L < 2 || i + 2 + L > n { return "bad marker after the scan" }
            i += 2 + L
            continue
        }
        return "marker \(m) after the scan"
    }
    return nil
}
