import Foundation
import ExactJPEG
import Metal
import TurboRef

// ejm mixed [prefix ...]: mixed-size sequences through ONE Decoder and ONE Encoder, so state kept between calls
// (buffers sized for an earlier image, the layout cache, the output-size estimate, the two-pass set) cannot change
// a later result. Every output is compared byte for byte with a fresh Decoder/Encoder doing that item alone and
// with libjpeg-turbo (for a truncated or corrupt item, libjpeg-turbo's warned output; where libjpeg-turbo fails, the
// item must be declined). The encoder sequences run on the device default path, two-pass and single-pass.
// ejm encode-retry: fresh encoders on images whose first attempt underestimates the output (the retry path),
// compared with libjpeg-turbo; test.sh runs it under Metal shader validation.

nonisolated(unsafe) private var pxCache: [String: [UInt8]] = [:]
private func pixels(_ w: Int, _ h: Int, _ kind: String, _ seed: UInt32) -> [UInt8] {
    let k = "\(w)x\(h)\(kind)\(seed)"
    if let p = pxCache[k] { return p }
    let p: [UInt8]
    if kind == "flat" { p = [UInt8](repeating: 0, count: w * h * 3).enumerated().map { UInt8(truncatingIfNeeded: 90 + ($0.offset % 3) * 40) } }
    else if kind == "photo" { p = Synth.make(width: w, height: h, seed: seed) }
    else { p = corpusContent(w, h, kind, seed) }
    pxCache[k] = p
    return p
}

private func firstDiff(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int? {
    let n = min(a.count, b.count)
    if a.count == b.count && memcmp(a.baseAddress!, b.baseAddress!, n) == 0 { return nil }
    var i = 0
    while i < n && a[i] == b[i] { i += 1 }
    return i
}
private func firstDiff(_ a: Data, _ b: Data) -> Int? {
    a.withUnsafeBytes { x in b.withUnsafeBytes { y in firstDiff(x, y) } }
}

struct DItem { let label: String; let jpeg: Data; let format: PixelFormat }

/// libjpeg-turbo's decode, also when it only warned (corrupt data it repaired: that output is the reference, as in
/// the fuzzer); nil when it fails
private func mxTurboDecode(_ d: Data, _ f: PixelFormat) -> (px: [UInt8], warned: Bool)? {
    guard let i = Turbo.info(d) else { return nil }
    var px = [UInt8](repeating: 0, count: i.w * i.h * f.channels)
    let r = d.withUnsafeBytes { src in
        px.withUnsafeMutableBufferPointer { tr_decode_fmt(src.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, $0.baseAddress, Int32(f.rawValue)) }
    }
    return r < 0 ? nil : (px, r == 1)
}

/// one decode item: (w, h, samp 0/1/2, quality, restartMCUs, restartRows, gray, kind)
private func dItem(_ w: Int, _ h: Int, samp: Int = 2, q: Int = 90, rst: Int = 0, rstRows: Int = 0, gray: Bool = false,
                   kind: String = "photo", seed: UInt32 = 3, format: PixelFormat = .rgb, progressive: Bool = false) -> DItem {
    let src = pixels(w, h, kind, seed)
    let g = gray ? stride(from: 0, to: src.count, by: 3).map { src[$0] } : src
    let j = Turbo.encode(g, w, h, gray: gray, quality: q, samp: samp, restartMCUs: rst, restartRows: rstRows, progressive: progressive)
    let s = ["444", "422", "420"][samp]
    let label = "\(w)x\(h) \(gray ? "gray" : s) q\(q)\(rst > 0 ? " rst\(rst)" : "")\(rstRows > 0 ? " rstrows\(rstRows)" : "")\(progressive ? " progressive" : "") \(format)"
    return DItem(label: label, jpeg: j, format: format)
}

private func corrupt(_ d: DItem, truncateAt frac: Double? = nil, flipAt: Double? = nil) -> DItem {
    var j = d.jpeg
    if let frac { j = j.prefix(Int(Double(j.count) * frac)) }
    if let flipAt { let i = Int(Double(j.count) * flipAt); j[i] = j[i] ^ 0x5A; j[i + 7] = 0xFF; j[i + 8] = 0xD3 }
    return DItem(label: d.label + (frac != nil ? " TRUNCATED" : " CORRUPT"), jpeg: j, format: d.format)
}

func runMixed(_ filter: [String]) -> Bool {
    var allOK = true
    func want(_ name: String) -> Bool { filter.isEmpty || filter.contains { name.hasPrefix($0) } }

    // ---------------- decode ----------------
    let small = dItem(64, 64)
    let big = dItem(6720, 4480, samp: 2, q: 95, seed: 11)
    let big422 = dItem(6720, 4480, samp: 1, q: 95, seed: 11)
    let mixedList = [dItem(2048, 2048, samp: 0, q: 92, seed: 4), dItem(4032, 3024, samp: 2, q: 90, seed: 5),
                     dItem(1234, 777, samp: 1, q: 85, seed: 6), dItem(3000, 4500, samp: 2, q: 88, rst: 7, seed: 7),
                     dItem(640, 480, samp: 0, q: 75, rstRows: 1, seed: 8), big422]
    let prog = dItem(1600, 1200, progressive: true)
    let gray1 = dItem(4032, 3024, gray: true, seed: 5), gray2 = dItem(64, 64, gray: true)
    var dseqs: [(String, [DItem])] = [
        ("D1 small-big-small", [small, big, small]),
        ("D2 big-small-big", [big, small, big]),
        ("D3 mixed list", mixedList),
        ("D4 mixed list reversed", mixedList.reversed()),
        ("D5 declined in the middle", [mixedList[1], prog, small, corrupt(big, truncateAt: 0.6), mixedList[2],
                                       corrupt(mixedList[0], flipAt: 0.5), big, small, mixedList[4]]),
        ("D6 gray among colour", [mixedList[0], gray1, mixedList[4], gray2, big, gray1, small]),
        ("D7 formats mixed", [DItem(label: big.label + " rgba", jpeg: big.jpeg, format: .rgba), DItem(label: small.label + " gray", jpeg: small.jpeg, format: .gray),
                              DItem(label: mixedList[2].label + " bgra", jpeg: mixedList[2].jpeg, format: .bgra),
                              DItem(label: gray1.label + " bgra", jpeg: gray1.jpeg, format: .bgra), big422, DItem(label: big.label + " bgr", jpeg: big.jpeg, format: .bgr)]),
        ("D8 restart intervals and subsamplings", [dItem(2000, 1500, samp: 0, rst: 1, seed: 9), dItem(2000, 1500, samp: 1, rst: 13, seed: 9),
                                                   dItem(2000, 1500, samp: 2, rstRows: 3, seed: 9), dItem(333, 4999, samp: 2, rst: 2, seed: 9),
                                                   dItem(4999, 333, samp: 1, seed: 9), dItem(2000, 1500, samp: 2, rst: 1, seed: 9)]),
    ]
    // layout cache churn: 40 distinct headers (cache holds 33), then the first ones again
    var churn: [DItem] = []
    for k in 0..<40 { churn.append(dItem(64 + 8 * k, 48 + 5 * k, samp: k % 3, q: 70 + k % 25, seed: UInt32(k))) }
    churn += Array(churn.prefix(5)) + [big] + Array(churn.prefix(3))
    dseqs.append(("D9 layout cache churn", churn))
    let shared = Decoder()
    for (name, seq) in dseqs where want(name) {
        var ok = true
        var lines: [String] = []
        for (i, it) in seq.enumerated() {
            let fresh = Decoder()
            let fimg = fresh.decode(it.jpeg, format: it.format)
            let freshBytes = fimg.map { Data($0.bytes) }
            let freshReason = fresh.reason
            let simg = shared.decode(it.jpeg, format: it.format)
            let sReason = shared.reason
            let ref = mxTurboDecode(it.jpeg, it.format)
            var st = ""
            switch (simg, freshBytes) {
            case (nil, nil): st = "declined by both (\(sReason ?? "?"))\(ref.map { $0.warned ? " [turbo warns]" : " [turbo decodes cleanly]" } ?? " [turbo fails]")"
                if let ref, !ref.warned, !it.label.contains("progressive") { ok = false; st += " UNEXPECTED" }
            case (nil, _?): ok = false; st = "FAIL shared declined (\(sReason ?? "?")), fresh decoded"
            case (_?, nil): ok = false; st = "FAIL shared decoded, fresh declined (\(freshReason ?? "?"))"
            case (let s?, let f?):
                if let d = firstDiff(s.bytes, f.withUnsafeBytes { $0 }) { ok = false; st = "FAIL vs fresh: first differing byte \(d)" }
                else if let ref {
                    // a warned decode is still libjpeg-turbo's output for that file: the GPU must equal it or decline
                    if let d = ref.px.withUnsafeBytes({ firstDiff(s.bytes, $0) }) { ok = false; st = "FAIL vs turbo\(ref.warned ? " (warned)" : ""): first differing byte \(d)" }
                    else { st = "ok (= fresh = turbo\(ref.warned ? ", which warned" : ""), \(s.bytes.count) bytes)" }
                } else { ok = false; st = "FAIL: decoded, but libjpeg-turbo fails on it (no reference; must decline)" }
            }
            lines.append("  [\(i)] \(it.label): \(st)")
        }
        print("\(ok ? "PASS" : "FAIL") \(name) (\(seq.count) items)")
        lines.forEach { print($0) }
        allOK = allOK && ok
    }

    // ---------------- encode ----------------
    struct EItem { let w, h: Int; let kind: String; let q: Int; let samp: Int; let seed: UInt32; var channels = 3; var pad = 0; var exif: Data? = nil
        var label: String { "\(w)x\(h) \(kind) q\(q) \(["444", "422", "420"][samp])\(channels == 4 ? " rgbx" : "")\(pad > 0 ? " pad\(pad)" : "")\(exif != nil ? " exif" : "")" } }
    let sub: [Subsampling] = [.s444, .s422, .s420]
    let es = EItem(w: 64, h: 64, kind: "photo", q: 75, samp: 2, seed: 3)
    let eb = EItem(w: 6720, h: 4480, kind: "photo", q: 95, samp: 2, seed: 11)
    let eb2 = EItem(w: 6720, h: 4480, kind: "photo", q: 90, samp: 1, seed: 11)
    let emix = [EItem(w: 2048, h: 2048, kind: "photo", q: 92, samp: 0, seed: 4), EItem(w: 4032, h: 3024, kind: "photo", q: 90, samp: 2, seed: 5),
                EItem(w: 1234, h: 777, kind: "photo", q: 85, samp: 1, seed: 6), EItem(w: 3000, h: 4500, kind: "photo", q: 88, samp: 2, seed: 7),
                EItem(w: 640, h: 480, kind: "edges", q: 75, samp: 0, seed: 8), EItem(w: 6720, h: 4480, kind: "photo", q: 95, samp: 1, seed: 11)]
    var flats: [EItem] = (0..<30).map { EItem(w: 256 + $0, h: 256, kind: "flat", q: 50, samp: 2, seed: UInt32($0)) }
    flats.append(EItem(w: 6720, h: 4480, kind: "noise", q: 100, samp: 0, seed: 21))
    flats.append(es)
    flats.append(EItem(w: 4032, h: 3024, kind: "noise", q: 98, samp: 2, seed: 22))
    var emisc = [EItem(w: 1999, h: 1333, kind: "photo", q: 90, samp: 2, seed: 12, channels: 4, pad: 64), es,
                 EItem(w: 4032, h: 3024, kind: "photo", q: 90, samp: 2, seed: 5, channels: 4), eb]
    emisc.insert(EItem(w: 1234, h: 777, kind: "photo", q: 85, samp: 1, seed: 6, exif: Data(repeating: 0x41, count: 900)), at: 2)

    var bufs: [String: (MTLBuffer, Int)] = [:]
    func job(_ e: EItem) -> EncodeJob {
        let k = e.label + "\(e.seed)"
        if bufs[k] == nil {
            let px = pixels(e.w, e.h, e.kind, e.seed)
            let rb = e.w * e.channels + e.pad
            let b = MetalContext.shared.device.makeBuffer(length: rb * e.h, options: .storageModeShared)!
            let p = b.contents().assumingMemoryBound(to: UInt8.self)
            for y in 0..<e.h { for x in 0..<e.w { for c in 0..<e.channels { p[y * rb + x * e.channels + c] = c < 3 ? px[(y * e.w + x) * 3 + c] : 0x77 } } }
            bufs[k] = (b, rb)
        }
        let (b, rb) = bufs[k]!
        return EncodeJob(buffer: b, width: e.w, height: e.h, channels: e.channels, rowBytes: rb, quality: e.q, subsampling: sub[e.samp], exif: e.exif)
    }
    var turboCache: [String: Data] = [:]
    func turboRef(_ e: EItem) -> Data {
        let k = e.label + "\(e.seed)"
        if let t = turboCache[k] { return t }
        let px = pixels(e.w, e.h, e.kind, e.seed)
        var t: Data
        if let exif = e.exif {
            var out: UnsafeMutablePointer<UInt8>? = nil; var len = 0
            let r = px.withUnsafeBufferPointer { p in exif.withUnsafeBytes { x in
                tr_encode_meta(p.baseAddress, Int32(e.w), Int32(e.h), Int32(e.q), Int32(e.samp), x.baseAddress!.assumingMemoryBound(to: UInt8.self), exif.count, nil, 0, &out, &len) } }
            precondition(r == 0); t = Data(bytes: out!, count: len); tr_free(out)
        } else { t = Turbo.encode(px, e.w, e.h, quality: e.q, samp: e.samp) }
        turboCache[k] = t
        return t
    }
    func freshEncode(_ e: EItem, _ fused: Int?) -> Data {
        let f = Encoder(); if let fused { f.fusedMaxBlocks = fused }
        return try! f.encodeBatch([job(e)])[0]
    }
    func check(_ name: String, _ seq: [EItem], _ outs: [Data], _ fused: Int?, _ extra: String) {
        var ok = true, lines: [String] = []
        for (i, e) in seq.enumerated() {
            let f = freshEncode(e, fused), t = turboRef(e)
            var st: String
            if let d = firstDiff(outs[i], f) { ok = false; st = "FAIL vs fresh: first differing byte \(d) (sizes \(outs[i].count) / \(f.count))" }
            else if let d = firstDiff(outs[i], t) { ok = false; st = "FAIL vs turbo: first differing byte \(d) (sizes \(outs[i].count) / \(t.count))" }
            else { st = "ok (= fresh = turbo, \(outs[i].count) bytes)" }
            lines.append("  [\(i)] \(e.label): \(st)")
        }
        print("\(ok ? "PASS" : "FAIL") \(name) (\(seq.count) items) \(extra)")
        lines.forEach { print($0) }
        allOK = allOK && ok
    }
    let eseqs: [(String, [EItem])] = [
        ("E1 small-big-small", [es, eb, es]), ("E2 big-small-big", [eb, es, eb2]),
        ("E3 mixed list", emix), ("E4 mixed list reversed", emix.reversed()),
        ("E5 estimate: flat then noise", flats), ("E6 rgbx, row padding, exif mixed", emisc),
        ("E7 photo then edges", [emix[0], emix[4]]), ("E8 edges alone", [emix[4]]), ("E9 small photo then edges", [es, emix[4]]),
    ]
    let paths: [(String, Int?)] = [("device default", nil), ("two-pass", 0), ("single-pass", 2_000_000)]
    for (pname, fused) in paths {
        let shared = Encoder(); if let fused { shared.fusedMaxBlocks = fused }
        for (name, seq) in eseqs where want(name) {
            var outs: [Data] = []
            var thrown: String? = nil
            for e in seq { do { outs.append(try shared.encodeBatch([job(e)])[0]) } catch { thrown = "\(error)"; break } }
            if let thrown { print("FAIL \(name) [\(pname)]: threw \(thrown) at item \(outs.count)"); allOK = false; continue }
            check("\(name) [\(pname), one at a time]", seq, outs, fused, "retries \(shared.retries) fusedFallbacks \(shared.fusedFallbacks)")
        }
        // encodeBatch with mixed sizes in one batch
        for (name, seq) in [("B1 batch mixed list", emix), ("B2 batch mixed reversed", Array(emix.reversed())),
                            ("B3 batch small/big interleaved", [es, eb, es, emix[2], eb2, es]), ("B4 batch flat then noise", flats),
                            ("B5 batch rgbx/pad/exif", emisc)] where want(name) {
            do {
                let outs = try shared.encodeBatch(seq.map(job))
                check("\(name) [\(pname)]", seq, outs, fused, "retries \(shared.retries) fusedFallbacks \(shared.fusedFallbacks)")
            } catch { print("FAIL \(name) [\(pname)]: threw \(error)"); allOK = false }
        }
        // healthy afterwards, and the retry path was taken (E5 and B4 are built to need it)
        if want("H") {
            let o = try? shared.encodeBatch([job(es)])
            let okH = o.map { firstDiff($0[0], turboRef(es)) == nil } ?? false
            print("\(okH ? "PASS" : "FAIL") H encoder healthy after all sequences [\(pname)]"); allOK = allOK && okH
        }
        if want("E5") || want("B4") {
            print("\(shared.retries > 0 ? "PASS" : "FAIL") R retries taken [\(pname)]: \(shared.retries)"); allOK = allOK && shared.retries > 0
        }
    }
    if want("H") {
        let img = shared.decode(small.jpeg)
        let okH = img.map { i in mxTurboDecode(small.jpeg, .rgb)!.px.withUnsafeBytes { firstDiff(i.bytes, $0) == nil } } ?? false
        print("\(okH ? "PASS" : "FAIL") H decoder healthy after all sequences"); allOK = allOK && okH
    }
    print(allOK ? "MIXED: ALL PASSED" : "MIXED: FAILURES")
    return allOK
}

/// ejm encode-retry: each image through a fresh Encoder (path from EJM_FUSED_MAX_BLOCKS or the device default), so
/// the output-size estimate starts from its initial value and these images need a second attempt. 640x480 edges q75
/// 4:4:4 alone is the case that read past the end of the arena before 2026-11-17 (an exactly sized arena over 1 MB);
/// the noise images at q100 4:4:4 overflow the estimate by far. Every result must equal libjpeg-turbo's.
func runEncodeRetry() -> Bool {
    let dev = MetalContext.shared.device
    var cases: [(Int, Int, String, Int, UInt32)] = [(640, 480, "edges", 75, 8)]
    for w in stride(from: 360, through: 1000, by: 80) { cases.append((w, 400, "noise", 100, UInt32(w))) }
    var ok = 0, bad = 0, retries = 0
    for (w, h, kind, q, seed) in cases {
        let px = corpusContent(w, h, kind, seed)
        let e = Encoder()
        do {
            let d = try e.encode(buffer: sharedBuffer(px, dev), width: w, height: h, quality: q, subsampling: .s444)
            if d == Turbo.encode(px, w, h, quality: q, samp: 0) { ok += 1 } else { bad += 1; print("  DIFFERENT \(w)x\(h) \(kind) q\(q)") }
        } catch { bad += 1; print("  THREW \(w)x\(h) \(kind) q\(q): \(error)") }
        retries += e.retries
    }
    print("encode-retry: identical files \(ok), different \(bad), retries \(retries) (fused max blocks \(Encoder().fusedMaxBlocks))")
    if retries < cases.count { print("FAIL: expected every image to need a second attempt") }
    return bad == 0 && retries >= cases.count
}
