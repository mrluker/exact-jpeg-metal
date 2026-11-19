import Foundation
import ExactJPEG
import TurboRef

// ejm decline-corpus [--list]: the file classes the docs say the GPU path declines (README "Decode a JPEG",
// docs/HOW-IT-WORKS.md, docs/API.md "Behaviour notes"), generated here: CMYK and YCCK (Adobe APP14), RGB-coded files
// (Adobe transform 0, or component ids 'R','G','B' without JFIF), multi-scan sequential (one component per scan, or
// Y then CbCr), arithmetic coding (SOF9, SOF10), 12-bit (SOF1 with P = 12), lossless (SOF3), hierarchical (SOF5),
// fractional sampling; plus the classes the docs say it takes (SOF1 8-bit extended sequential, integral factors
// other than the usual ones) and a few the docs leave open (Adobe transform 1, an Adobe or RGB-id file that also has
// a JFIF marker). libjpeg-turbo writes most of them (TurboRef tr_encode_ex); the others are spliced from its
// output (APP14 and JFIF segments, SOF marker and sampling bytes).
//
// Every file is decoded to .rgb and .gray. The rule for every one: the GPU declines with a reason, or its output
// equals libjpeg-turbo's (tr_decode: islow, fancy upsampling) byte for byte. A GPU result where libjpeg-turbo fails
// is wrong too. Separately, each class records what the docs promise ("decline", "accept", or "either"), and a
// result against the promise is counted ("against the docs") without being called wrong.
// The last line, "decline corpus: ...", is what scripts/test.sh requires.

private enum Promise: String { case decline, accept, either }

private struct DCItem {
    let name: String, cls: String, data: Data, promise: Promise
}

/// marker codes in file order (SOI, segments, SOS, ... EOI); entropy-coded data and RSTn are skipped
func jpegMarkers(_ d: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    let n = d.count
    while i + 1 < n {
        guard d[i] == 0xFF else { i += 1; continue }
        let m = d[i + 1]
        if m == 0xFF { i += 1; continue }
        if m == 0x00 || (m >= 0xD0 && m <= 0xD7) { i += 2; continue }
        out.append(m)
        if m == 0xD8 || m == 0xD9 { i += 2; continue }
        guard i + 3 < n else { break }
        let L = Int(d[i + 2]) << 8 | Int(d[i + 3])
        i += 2 + L
        if m == 0xDA {          // skip the entropy-coded data to the next real marker
            while i + 1 < n && !(d[i] == 0xFF && d[i + 1] != 0 && !(d[i + 1] >= 0xD0 && d[i + 1] <= 0xD7)) { i += 1 }
        }
    }
    return out
}

private func isSOF(_ m: UInt8) -> Bool { m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC }

/// offset of the first SOF segment's 0xFF
private func sofAt(_ d: [UInt8]) -> Int? { segments(d).segs.first { isSOF($0.m) }?.at }

private func encodeEx(_ px: [UInt8], _ w: Int, _ h: Int, _ set: (inout tr_enc_opts) -> Void) -> Data {
    var o = tr_enc_opts()
    o.in_components = 3; o.jpeg_colorspace = -1; o.quality = 85; o.force_baseline = 1
    o.write_jfif = -1; o.write_adobe = -1
    set(&o)
    var out: UnsafeMutablePointer<UInt8>? = nil
    var len = 0
    let r = px.withUnsafeBufferPointer { p in withUnsafePointer(to: &o) { tr_encode_ex(p.baseAddress, Int32(w), Int32(h), $0, &out, &len) } }
    precondition(r == 0, "tr_encode_ex failed")
    let d = Data(bytes: out!, count: len)
    tr_free(out)
    return d
}

private func setSampling(_ o: inout tr_enc_opts, _ f: [(Int32, Int32)]) {
    withUnsafeMutableBytes(of: &o.h) { hb in withUnsafeMutableBytes(of: &o.v) { vb in
        for (k, (h, v)) in f.enumerated() { hb.storeBytes(of: h, toByteOffset: 4 * k, as: Int32.self); vb.storeBytes(of: v, toByteOffset: 4 * k, as: Int32.self) }
    } }
}

private let app14Prefix: [UInt8] = [0xFF, 0xEE, 0x00, 0x0E, 0x41, 0x64, 0x6F, 0x62, 0x65, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00]
private let jfifSegment: [UInt8] = [0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]

private func dropSegment(_ d: [UInt8], _ m: UInt8) -> [UInt8] {
    guard let s = segments(d).segs.first(where: { $0.m == m }) else { return d }
    var o = d; o.removeSubrange(s.at..<s.end); return o
}
/// insert a segment right after SOI and any APP0
private func insertSegment(_ d: [UInt8], _ seg: [UInt8]) -> [UInt8] {
    let segs = segments(d).segs
    let at = segs.first?.m == 0xE0 ? segs[0].end : 2
    var o = d; o.insert(contentsOf: seg, at: at); return o
}

private func makeDeclineCorpus() -> [DCItem] {
    var out: [DCItem] = []
    for (w, h) in [(37, 23), (64, 48)] {
        let rgb = corpusContent(w, h, "smooth", UInt32(w * 31 + h))
        let gray = stride(from: 0, to: rgb.count, by: 3).map { rgb[$0] }
        var cmyk = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { cmyk[4 * i + c] = 255 &- rgb[3 * i + c] }
            cmyk[4 * i + 3] = UInt8(truncatingIfNeeded: (i % w) * 3 + (i / w) * 5)
        }
        let sz = "\(w)x\(h)"
        func add(_ cls: String, _ variant: String, _ p: Promise, _ d: Data) { out.append(DCItem(name: "\(cls)_\(variant)_\(sz)", cls: cls, data: d, promise: p)) }
        func addB(_ cls: String, _ variant: String, _ p: Promise, _ b: [UInt8]) { add(cls, variant, p, Data(b)) }

        // CMYK / YCCK (4 components)
        add("cmyk", "adobe", .decline, encodeEx(cmyk, w, h) { $0.in_components = 4; $0.jpeg_colorspace = 3 })
        add("cmyk", "no-adobe", .decline, encodeEx(cmyk, w, h) { $0.in_components = 4; $0.jpeg_colorspace = 3; $0.write_adobe = 0 })
        add("ycck", "adobe", .decline, encodeEx(cmyk, w, h) { $0.in_components = 4; $0.jpeg_colorspace = 4 })
        // RGB-coded
        add("rgb", "adobe0", .decline, encodeEx(rgb, w, h) { $0.jpeg_colorspace = 2 })
        add("rgb", "ids-no-jfif", .decline, encodeEx(rgb, w, h) { $0.jpeg_colorspace = 2; $0.write_adobe = 0 })
        add("jfif-wins", "rgb-ids-with-jfif", .either, encodeEx(rgb, w, h) { $0.jpeg_colorspace = 2; $0.write_adobe = 0; $0.write_jfif = 1 })
        let ycc = [UInt8](Turbo.encode(rgb, w, h, quality: 85, samp: 2))
        addB("rgb", "ycc-adobe0-no-jfif", .decline, insertSegment(dropSegment(ycc, 0xE0), app14Prefix + [0]))
        addB("jfif-wins", "ycc-adobe0-with-jfif", .either, insertSegment(ycc, app14Prefix + [0]))
        addB("adobe1", "ycc-adobe1-no-jfif", .either, insertSegment(dropSegment(ycc, 0xE0), app14Prefix + [1]))
        // multi-scan sequential
        add("multiscan", "1-per-scan-444", .decline, encodeEx(rgb, w, h) { setSampling(&$0, [(1, 1), (1, 1), (1, 1)]); $0.scan_mode = 1 })
        add("multiscan", "1-per-scan-420", .decline, encodeEx(rgb, w, h) { $0.scan_mode = 1 })
        add("multiscan", "y-then-cbcr-420", .decline, encodeEx(rgb, w, h) { $0.scan_mode = 2 })
        add("multiscan", "1-per-scan-420-rst2", .decline, encodeEx(rgb, w, h) { $0.scan_mode = 1; $0.restart_mcus = 2 })
        // arithmetic coding
        add("arith", "sof9-420", .decline, encodeEx(rgb, w, h) { $0.arith = 1 })
        add("arith", "sof9-444", .decline, encodeEx(rgb, w, h) { $0.arith = 1; setSampling(&$0, [(1, 1), (1, 1), (1, 1)]) })
        add("arith", "sof9-gray", .decline, encodeEx(gray, w, h) { $0.in_components = 1; $0.arith = 1 })
        add("arith", "sof10-progressive", .decline, encodeEx(rgb, w, h) { $0.arith = 1; $0.progressive = 1 })
        // 12-bit
        add("12bit", "sof1-420", .decline, encodeEx(rgb, w, h) { $0.precision = 12 })
        add("12bit", "sof1-gray", .decline, encodeEx(gray, w, h) { $0.in_components = 1; $0.precision = 12 })
        // lossless
        add("lossless", "sof3-rgb", .decline, encodeEx(rgb, w, h) { setSampling(&$0, [(1, 1), (1, 1), (1, 1)]); $0.lossless_psv = 1 })
        add("lossless", "sof3-gray-psv7", .decline, encodeEx(gray, w, h) { $0.in_components = 1; $0.lossless_psv = 7 })
        // SOF1, 8-bit extended sequential Huffman (the docs: taken)
        add("sof1-8bit", "16bit-dqt-420", .accept, encodeEx(rgb, w, h) { $0.quality = 1; $0.force_baseline = 0 })
        add("sof1-8bit", "16bit-dqt-gray", .accept, encodeEx(gray, w, h) { $0.in_components = 1; $0.quality = 3; $0.force_baseline = 0 })
        var s1 = ycc; s1[sofAt(s1)! + 1] = 0xC1
        addB("sof1-8bit", "marker-420", .accept, s1)
        // hierarchical: SOF5 marker on a sequential file (libjpeg-turbo has no hierarchical mode)
        var s5 = ycc; s5[sofAt(s5)! + 1] = 0xC5
        addB("hierarchical", "sof5-marker", .decline, s5)
        // other integral sampling factors (the docs: taken, libjpeg's box upsampling)
        let h31 = encodeEx(rgb, w, h) { setSampling(&$0, [(3, 1), (1, 1), (1, 1)]) }
        add("integral", "y3x1", .accept, h31)
        add("integral", "y4x2", .accept, encodeEx(rgb, w, h) { setSampling(&$0, [(4, 2), (1, 1), (1, 1)]) })
        add("integral", "y2x2-cb2x1", .either, encodeEx(rgb, w, h) { setSampling(&$0, [(2, 2), (2, 1), (1, 1)]) })
        // fractional: Y 3x1 with Cb marked 2x1 (3 / 2 is not an integer)
        var fr = [UInt8](h31); let fa = sofAt(fr)!; fr[fa + 11 + 3] = 0x21
        addB("fractional", "y3x1-cb2x1", .decline, fr)
        var fr2 = [UInt8](Turbo.encode(rgb, w, h, quality: 85, samp: 0)); let fb = sofAt(fr2)!
        fr2[fb + 11] = 0x33; fr2[fb + 11 + 3] = 0x22; fr2[fb + 11 + 6] = 0x11
        addB("fractional", "y3x3-cb2x2", .decline, fr2)
    }
    return out
}

/// what each generated class must look like, so a generator change cannot quietly test something else
private func structureProblem(_ it: DCItem) -> String? {
    let d = [UInt8](it.data)
    let ms = jpegMarkers(d)
    guard let sof = ms.first(where: isSOF), let at = sofAt(d) else { return "no SOF" }
    let p = d[at + 4], nc = Int(d[at + 9])
    let scans = ms.filter { $0 == 0xDA }.count
    let hasAdobe = segments(d).segs.contains { s in s.m == 0xEE && s.end - s.at >= 16 && d[(s.at + 4)..<(s.at + 9)].elementsEqual("Adobe".utf8) }
    let hasJFIF = segments(d).segs.contains { s in s.m == 0xE0 && d[(s.at + 4)..<(s.at + 8)].elementsEqual("JFIF".utf8) }
    let ids = (0..<nc).map { d[at + 10 + 3 * $0] }
    func need(_ c: Bool, _ what: String) -> String? { c ? nil : "\(what) (SOF \(String(sof, radix: 16)), P \(p), \(nc) components, \(scans) scans, Adobe \(hasAdobe), JFIF \(hasJFIF), ids \(ids))" }
    switch it.cls {
    case "cmyk", "ycck": return need(nc == 4 && hasAdobe == !it.name.contains("no-adobe"), "expected 4 components")
    case "rgb":
        if it.name.contains("ids") { return need(ids == [0x52, 0x47, 0x42] && !hasAdobe && !hasJFIF, "expected ids RGB, no Adobe, no JFIF") }
        return need(hasAdobe && !hasJFIF, "expected Adobe without JFIF")
    case "jfif-wins":       // libjpeg-turbo: a JFIF marker means YCbCr whatever the ids or an Adobe transform say
        return need(hasJFIF && (it.name.contains("rgb-ids") ? ids == [0x52, 0x47, 0x42] && !hasAdobe : hasAdobe), "expected JFIF with RGB ids or Adobe")
    case "adobe1": return need(hasAdobe && !hasJFIF, "expected Adobe without JFIF")
    case "multiscan": return need(sof == 0xC0 && scans > 1, "expected several baseline scans")
    case "arith": return need(sof == (it.name.contains("sof10") ? 0xCA : 0xC9), "expected SOF9/SOF10")
    case "12bit": return need(sof == 0xC1 && p == 12, "expected SOF1 P=12")
    case "lossless": return need(sof == 0xC3, "expected SOF3")
    case "sof1-8bit": return need(sof == 0xC1 && p == 8 && scans == 1, "expected SOF1 P=8")
    case "hierarchical": return need(sof == 0xC5, "expected SOF5")
    case "integral", "fractional": return need(sof == 0xC0 && scans == 1, "expected one baseline scan")
    default: return "unknown class"
    }
}

func runDeclineCorpus(_ args: [String]) -> Bool {
    print("reference: \(Turbo.version)")
    let items = makeDeclineCorpus()
    let dec = Decoder()
    var declined = 0, exact = 0, wrong = 0, noReason = 0, against = 0, generator = 0
    var byClass: [String: (declined: Int, exact: Int, wrong: Int)] = [:]
    var classOrder: [String] = []
    for it in items {
        if !classOrder.contains(it.cls) { classOrder.append(it.cls) }
        if let p = structureProblem(it) { generator += 1; print("  GENERATOR \(it.name): \(p)") }
        for format in [PixelFormat.rgb, .gray] {
            let img = dec.decode(it.data, format: format)
            let ref = Turbo.decode(it.data, gray: format == .gray)
            var t = byClass[it.cls] ?? (0, 0, 0)
            var st: String
            if let img {
                if let ref, ref.w == img.width, ref.h == img.height, ref.px.count == img.bytes.count, ref.px.elementsEqual(img.bytes) {
                    exact += 1; t.exact += 1; st = "exact\(ref.warned ? " (libjpeg-turbo warned; its output is the reference)" : "")"
                    if it.promise == .decline { against += 1; st += " AGAINST THE DOCS (promised: decline)" }
                } else {
                    wrong += 1; t.wrong += 1
                    st = ref == nil ? "WRONG: GPU decoded, libjpeg-turbo fails on it" : "WRONG: differs from libjpeg-turbo"
                }
            } else {
                declined += 1; t.declined += 1
                let r = dec.reason ?? ""
                if r.isEmpty { noReason += 1 }
                st = "declined (\(r.isEmpty ? "NO REASON" : r))\(ref == nil ? "; libjpeg-turbo fails too" : "")"
                if it.promise == .accept { against += 1; st += " AGAINST THE DOCS (promised: accept)" }
            }
            byClass[it.cls] = t
            if args.contains("--list") || st.contains("WRONG") || st.contains("AGAINST") || st.contains("NO REASON") {
                print("  \(it.name) \(format): \(st)")
            }
        }
    }
    for c in classOrder {
        let t = byClass[c]!, p = Set(items.filter { $0.cls == c }.map(\.promise.rawValue)).sorted().joined(separator: "/")
        print("  class \(c) (docs: \(p)): declined \(t.declined), exact \(t.exact), wrong \(t.wrong)")
    }
    Exact.v["decline_corpus"] = ["files": items.count, "decodes": items.count * 2, "declined": declined, "exact": exact, "wrong": wrong,
                                 "declined_without_reason": noReason, "against_docs": against, "generator_problems": generator]
    print("decline corpus: \(items.count) files, \(items.count * 2) decodes: declined \(declined), exact \(exact), wrong \(wrong), declined without a reason \(noReason), against the docs \(against), generator problems \(generator)")
    return wrong == 0 && noReason == 0 && generator == 0
}
