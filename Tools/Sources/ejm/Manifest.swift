import Foundation
import CryptoKit
import Metal
import ExactJPEG

// A manifest of SHA-256 hashes that fixes the exactness target across machines and libjpeg-turbo versions.
//
//   ejm manifest write [path]   (default testdata/manifest-libjpeg-turbo-3.2.0.json) from the local libjpeg-turbo
//   ejm manifest check [path]   regenerate the synthetic corpus and check, against the stored hashes:
//       source     the seeded synthetic images (Synth.swift) are bit-identical to the ones the manifest was made from
//       encode     Metal's JPEG bytes == the stored libjpeg-turbo encode, for every encoder case
//       decode     Metal's pixels == the stored libjpeg-turbo decode, for every decoder file whose JPEG bytes match
//                  the manifest (if the local libjpeg-turbo writes different bytes, that file is compared with the
//                  local libjpeg-turbo decode instead, and counted separately)
//       local      whether the local libjpeg-turbo reproduces the stored hashes (informational)
//   Entries are paired with the corpus by name. The check fails unless the manifest's reference is libjpeg-turbo
//   3.2.0, every name is present on both sides, no decline-expected file is accepted, and the decode and encode
//   counts are complete; the last line, "manifest counts: ...", is what scripts/test.sh requires.
//   `write` refuses unless the libjpeg-turbo loaded at run time is 3.2.0 (Turbo.runtimeVersion).

func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
func sha(_ b: [UInt8]) -> String { sha(Data(b)) }
func sha(_ p: UnsafeRawBufferPointer) -> String { SHA256.hash(data: p).map { String(format: "%02x", $0) }.joined() }

func runManifest(_ mode: String, _ path: String) -> Bool {
    let lib = Turbo.version
    if mode == "write" {
        guard Turbo.runtimeVersion == Turbo.target else {
            print("manifest write: refused, the loaded libjpeg-turbo is \(Turbo.runtimeVersion ?? "of unknown version") (\(Turbo.runtimePath)), the manifest's target is \(Turbo.target)")
            return false
        }
        var dec: [[String: Any]] = [], enc: [[String: Any]] = []
        for it in makeCorpus() {
            var e: [String: Any] = ["name": it.name, "jpeg": sha(it.data), "gpu_expected": it.expectGPU]
            if let r = Turbo.decode(it.data) { e["rgb"] = sha(r.px) }
            if let g = Turbo.decode(it.data, gray: true) { e["gray"] = sha(g.px) }
            dec.append(e)
        }
        var lastSrc = ""
        for c in encodeCases() {
            let s = sha(c.src)
            var e: [String: Any] = ["name": c.name, "jpeg": sha(Turbo.encode(c.src, c.w, c.h, quality: c.q, samp: c.samp))]
            if s != lastSrc { e["source"] = s; lastSrc = s }
            enc.append(e)
        }
        let m: [String: Any] = ["reference": lib, "generator": "ejm synthetic corpus v1 (Sources/ejm/Synth.swift, Corpus.swift, Manifest.swift)",
                                "decode": dec, "encode": enc]
        let js = try! JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! js.write(to: URL(fileURLWithPath: path))
        print("wrote \(path): \(dec.count) decoder files, \(enc.count) encoder cases, reference \(lib)")
        return true
    }
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let m = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let dec = m["decode"] as? [[String: Any]], let enc = m["encode"] as? [[String: Any]] else {
        print("cannot read \(path)"); return false
    }
    let reference = m["reference"] as? String ?? "?"
    print("manifest: \(path) (reference \(reference)); local reference: \(lib) (\(Turbo.runtimePath)); device: \(MetalContext.shared.device.name)")
    let D = Decoder(), E = Encoder()
    var c: [String: Int] = [:]
    var fails: [String] = []
    if reference != "libjpeg-turbo \(Turbo.target)" { fails.append("manifest reference is \(reference), not libjpeg-turbo \(Turbo.target)") }
    let corpus = makeCorpus()
    var decByName: [String: [String: Any]] = [:]
    for e in dec {
        guard let n = e["name"] as? String else { fails.append("decoder entry without a name"); continue }
        if decByName[n] != nil { fails.append("\(n): twice in the manifest") }
        decByName[n] = e
    }
    let corpusNames = Set(corpus.map(\.name))
    for n in decByName.keys.sorted() where !corpusNames.contains(n) { fails.append("\(n): in the manifest, not in the corpus") }
    var wantDecode = 0, wantDeclined = 0
    for it in corpus {
        guard let e = decByName[it.name] else { fails.append("\(it.name): not in the manifest"); continue }
        if (e["gpu_expected"] as? Bool) != it.expectGPU { fails.append("\(it.name): gpu_expected differs from the manifest") }
        let sameJPEG = sha(it.data) == (e["jpeg"] as? String)
        c[sameJPEG ? "decode_jpeg_matches_manifest" : "decode_jpeg_differs_local_libjpeg", default: 0] += 1
        for (fmt, key) in [(PixelFormat.rgb, "rgb"), (.gray, "gray")] {
            let img = D.decode(it.data, format: fmt)
            if !it.expectGPU {
                wantDeclined += 1
                if img == nil { c["declined_as_expected", default: 0] += 1 }
                else { c["unexpected_accept", default: 0] += 1; fails.append("\(it.name) \(key): accepted, the manifest expects a decline") }
                continue
            }
            wantDecode += 1
            guard let img else { fails.append("\(it.name) \(key): declined (\(D.reason ?? "?"))"); continue }
            let got = sha(img.bytes)
            if sameJPEG {
                if got == (e[key] as? String) { c["decode_exact_vs_manifest", default: 0] += 1 } else { fails.append("\(it.name) \(key): differs from the manifest") }
            } else if let r = Turbo.decode(it.data, gray: fmt == .gray), sha(r.px) == got {
                c["decode_exact_vs_local_libjpeg", default: 0] += 1
            } else { fails.append("\(it.name) \(key): differs from local libjpeg-turbo") }
        }
    }
    let cases = encodeCases()
    var encByName: [String: [String: Any]] = [:]
    for e in enc {
        guard let n = e["name"] as? String else { fails.append("encoder entry without a name"); continue }
        if encByName[n] != nil { fails.append("\(n): twice in the manifest") }
        encByName[n] = e
    }
    let caseNames = Set(cases.map(\.name))
    for n in encByName.keys.sorted() where !caseNames.contains(n) { fails.append("\(n): in the manifest, not among the encoder cases") }
    var srcBuf: (sha: String, buf: MTLBuffer)? = nil
    for k in cases {
        guard let e = encByName[k.name] else { fails.append("\(k.name): not in the manifest"); continue }
        if let s = e["source"] as? String {
            let local = sha(k.src)
            if local != s { fails.append("\(k.name): synthetic source differs from the manifest (generator not reproducible here)") }
            c[local == s ? "sources_match" : "sources_differ", default: 0] += 1
        }
        let ssrc = sha(k.src)
        if srcBuf?.sha != ssrc { srcBuf = (ssrc, sharedBuffer(k.src, D.ctx.device)) }
        let ss: Subsampling = [.s444, .s422, .s420][k.samp]
        let got = sha(try! E.encode(buffer: srcBuf!.buf, width: k.w, height: k.h, quality: k.q, subsampling: ss))
        if got == (e["jpeg"] as? String) { c["encode_exact_vs_manifest", default: 0] += 1 } else { fails.append("\(k.name): encode differs from the manifest") }
        let loc = sha(Turbo.encode(k.src, k.w, k.h, quality: k.q, samp: k.samp))
        c[loc == (e["jpeg"] as? String) ? "local_libjpeg_encode_matches" : "local_libjpeg_encode_differs", default: 0] += 1
    }
    // complete counts: every decodable file in both formats exact (against the manifest, or the local libjpeg-turbo
    // where its JPEG bytes differ), at least one against the manifest itself, every encoder case exact
    let vsManifest = c["decode_exact_vs_manifest"] ?? 0, vsLocal = c["decode_exact_vs_local_libjpeg"] ?? 0
    let encExact = c["encode_exact_vs_manifest"] ?? 0
    if vsManifest == 0 { fails.append("no decode was checked against the manifest's own hashes") }
    if vsManifest + vsLocal != wantDecode { fails.append("decodes exact \(vsManifest + vsLocal), expected \(wantDecode)") }
    if (c["declined_as_expected"] ?? 0) != wantDeclined { fails.append("declined as expected \(c["declined_as_expected"] ?? 0), expected \(wantDeclined)") }
    if encExact != cases.count { fails.append("encoder cases exact \(encExact), expected \(cases.count)") }
    for (k, v) in c.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    for f in fails.prefix(30) { print("  FAIL \(f)") }
    var rec: [String: Any] = c; rec["failures"] = fails.count; rec["reference"] = reference; rec["local_reference"] = lib
    Exact.v["manifest"] = rec
    print("manifest counts: decode exact vs manifest \(vsManifest)/\(wantDecode), vs local libjpeg-turbo \(vsLocal); declined \(c["declined_as_expected"] ?? 0)/\(wantDeclined), unexpected accept \(c["unexpected_accept"] ?? 0); encode exact \(encExact)/\(cases.count)")
    print(fails.isEmpty ? "manifest check: PASSED" : "manifest check: \(fails.count) FAILURES")
    return fails.isEmpty
}
