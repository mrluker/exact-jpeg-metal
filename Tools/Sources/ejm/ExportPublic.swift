import Foundation
import ExactJPEG
import TurboRef

// ejm export-public <outdir> <dir> [<dir> ...]
// The inputs and libjpeg-turbo references of the iOS check app's --public mode (Examples/ios-check/App/PublicMode.swift),
// which runs the comparison of `ejm public-bench` on a phone (no libjpeg-turbo there). The files are chosen and
// SHA-256-checked exactly as public-bench does (selectPublicFiles), copied to <outdir>/<dir name>/[<420|444>/]<file>,
// and described in <outdir>/public-refs.json, one entry per file in public-bench's order:
//   the file's SHA-256 and size; width, height, sampling and frame kind (baseline, extended sequential, progressive,
//   arithmetic ...) from its frame header; libjpeg-turbo's decode (TurboRef tr_decode: islow, fancy upsampling, RGB,
//   as public-bench) as a SHA-256 and byte count; and libjpeg-turbo's q95 re-encode of those pixels at the file's
//   sampling as a SHA-256 (skipped, and said so, where the Encoder has no such sampling, as public-bench).
// A file on which libjpeg-turbo warns is skipped (as public-bench). For a file the GPU path declines by design
// (progressive, arithmetic) the device has no other source of libjpeg-turbo's pixels, so they are written beside it
// as <name>.rgb.lzfse (LZFSE-compressed RGB); for the others the device uses its own decode when its SHA-256 equals
// the reference. Directory names (last path component) and file names only: no absolute paths. public-refs.json is
// written only with libjpeg-turbo 3.2.0 loaded (as export-corpus); with another version nothing is written and an
// earlier public-refs.json in <outdir> is removed. <outdir> must be empty, missing, or an earlier export (it holds
// public-refs.json); it is emptied first. This Mac's GPU decodes and encodes every file against the references.
// Exit 0; 1 if refused, a write failed or this Mac's GPU differs from a reference; 2 on bad arguments or when no file
// was found; 3 when files were skipped (public-bench's exit 2 reasons) and the others were exported.

func runExportPublic(_ argv: [String]) -> Int32 {
    let usage = "usage: ejm export-public <outdir> <dir> [<dir> ...]"
    guard argv.count >= 2 else { print(usage); return 2 }
    let fm = FileManager.default
    let out = argv[0]
    var dirs: [String] = []
    for a in argv.dropFirst() {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue else { print("not a directory: \(a)\n\(usage)"); return 2 }
        let canon = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
        if dirs.contains(canon) { print("note: \(a) given twice; exported once") } else { dirs.append(canon) }
    }
    // the directory's last path component is its name in the export and on the device
    var label: [String: String] = [:]
    for d in dirs {
        let n = (d as NSString).lastPathComponent
        if let other = label.first(where: { $0.value == n }) { print("two directories are named \(n): \(other.key) and \(d); rename one"); return 2 }
        label[d] = n
    }
    let outCanon = URL(fileURLWithPath: out).standardizedFileURL.resolvingSymlinksInPath().path
    if let d = dirs.first(where: { outCanon == $0 || outCanon.hasPrefix($0 + "/") || $0.hasPrefix(outCanon + "/") }) {
        print("the output directory \(out) overlaps the input \(d)"); return 2
    }
    if fm.fileExists(atPath: out) {
        let have = (try? fm.contentsOfDirectory(atPath: out)) ?? []
        if !have.isEmpty && !have.contains("public-refs.json") {
            print("\(out) is not empty and holds no public-refs.json (not an earlier export): not emptied, nothing written"); return 2
        }
    }
    // the device checks its bytes against these hashes: only libjpeg-turbo 3.2.0's (as export-corpus)
    guard Turbo.runtimeVersion == Turbo.target else {
        try? fm.removeItem(atPath: out + "/public-refs.json")
        print("public-refs.json: refused, the loaded libjpeg-turbo is \(Turbo.runtimeVersion ?? "of unknown version") (\(Turbo.runtimePath)), the device check's target is \(Turbo.target)")
        return 1
    }
    do {
        try? fm.removeItem(atPath: out)
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    } catch { print("cannot create \(out): \(error)"); return 1 }

    let selected = selectPublicFiles(dirs)
    var skipped = selected.skipped.map { s -> [String: Any] in
        var s = s; s["dir"] = (s["dir"] as? String).flatMap { label[$0] } ?? "?"; return s
    }
    let dec = Decoder(), enc = Encoder()
    var entries: [[String: Any]] = [], writeErrors = 0
    var macDecOK = 0, macDecBad = 0, macEncOK = 0, macEncBad = 0, declined = 0, jpegBytes = 0, pixelBytes = 0
    for f in selected.files {
        autoreleasepool {
            let dl = label[f.dir]!
            let rel = (f.sub.isEmpty ? "" : f.sub + "/") + (f.path as NSString).lastPathComponent
            let shown = "\(dl)/\(rel)"
            guard let ref = Turbo.decode(f.data) else {
                print("\(shown): libjpeg-turbo cannot decode it; skipped")
                skipped.append(["dir": dl, "file": rel, "reason": "libjpeg-turbo decode error"]); return
            }
            if ref.warned {
                let msg = String(cString: tr_message(tr_last_warning()))
                print("\(shown): libjpeg-turbo warned (\(msg)); not used as a reference, skipped")
                skipped.append(["dir": dl, "file": rel, "reason": "libjpeg-turbo warning", "warning": msg]); return
            }
            let sof = readSOF(f.data)
            let samp = sampling(sof)
            let byDesign = sof?.kind?.byDesign == true ? sof!.kind!.kind : nil
            let frame: String = {
                guard let sof else { return "unknown" }
                if let k = sof.kind { return k.kind }
                return readSOFMarker(f.data) == 0xC0 ? "baseline" : "extended sequential"
            }()
            let w = ref.w, h = ref.h
            var e: [String: Any] = [
                "dir": dl, "subsampling_dir": f.sub, "name": f.name, "file": shown, "sha256": f.sha, "sha256_checked": f.checked,
                "bytes": f.data.count, "published_by_libjpeg_turbo": publishedImages.contains(f.name),
                "width": w, "height": h, "subsampling": samp.name, "frame": frame, "progressive": sof?.progressive ?? false,
                "sof_kind": sof?.kind?.kind ?? (sof == nil ? "unknown" : "sequential Huffman"),
                "ref_rgb_sha256": sha(ref.px), "ref_rgb_bytes": ref.px.count,
            ]
            if let k = byDesign { e["declined_by_design"] = k; declined += 1 }
            let folder = out + "/" + dl + (f.sub.isEmpty ? "" : "/" + f.sub)
            do {
                try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try f.data.write(to: URL(fileURLWithPath: out + "/" + shown))
                jpegBytes += f.data.count
                if byDesign != nil {
                    let z = try (Data(ref.px) as NSData).compressed(using: .lzfse) as Data
                    let pf = shown.dropLast(((f.path as NSString).pathExtension as NSString).length + 1) + ".rgb.lzfse"
                    try z.write(to: URL(fileURLWithPath: out + "/" + pf))
                    e["ref_rgb_file"] = String(pf); e["ref_rgb_file_bytes"] = z.count
                    pixelBytes += z.count
                }
            } catch { writeErrors += 1; print("\(shown): write failed: \(error)"); return }
            // the same comparisons the device makes, on this Mac's GPU
            if let img = dec.decode(f.data) {
                if sha(img.bytes) == e["ref_rgb_sha256"] as? String { macDecOK += 1 } else { macDecBad += 1; print("  this Mac's GPU decode differs: \(shown)") }
            } else if byDesign == nil { macDecBad += 1; print("  this Mac's GPU declined \(shown): \(dec.reason ?? "?")") }
            var en: [String: Any] = ["quality": 95, "subsampling": samp.name]
            if samp.name == "gray" { en["skipped"] = "grayscale" }
            else if let ts = samp.turbo, let ms = samp.metal {
                let want = Turbo.encode(ref.px, w, h, quality: 95, samp: ts)
                en["turbo_sha256"] = sha(want); en["turbo_bytes"] = want.count
                let got = try? enc.encode(buffer: sharedBuffer(ref.px, enc.ctx.device), width: w, height: h, quality: 95, subsampling: ms)
                if got == want { macEncOK += 1 } else { macEncBad += 1; print("  this Mac's GPU encode differs: \(shown) q95 \(samp.name)") }
            } else if samp.turbo != nil { en["skipped"] = "sampling \(samp.name) not supported by the Encoder" }
            else { en["skipped"] = "sampling \(samp.name) has no encoder setting" }
            e["encode"] = en
            entries.append(e)
            print("\(shown): \(w)x\(h) \(samp.name) \(frame)\(byDesign != nil ? " (declined by design; pixels bundled)" : "")\(en["skipped"].map { "; encode skipped: \($0)" } ?? "")")
        }
    }
    let dirInfo = dirs.map { d -> [String: Any] in
        ["name": label[d]!, "files": entries.filter { $0["dir"] as? String == label[d] }.count, "sha256_list": selected.sources[d] ?? "none"]
    }
    let doc: [String: Any] = [
        "reference": Turbo.version, "generated_by": "ejm export-public", "directories": dirInfo, "files": entries, "skipped": skipped,
        "reference_decode": "TurboRef tr_decode: libjpeg-turbo's libjpeg API, JDCT_ISLOW, do_fancy_upsampling TRUE, JCS_RGB (as public-bench)",
        "reference_encode": "TurboRef tr_encode: libjpeg API, quality 95, the file's sampling factors, JDCT_ISLOW, standard Huffman tables (as public-bench)",
        "ref_rgb_files": "LZFSE-compressed RGB of libjpeg-turbo's decode, for the files the GPU path declines by design only",
    ]
    do {
        let js = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try js.write(to: URL(fileURLWithPath: out + "/public-refs.json"))
    } catch { print("could not write \(out)/public-refs.json: \(error)"); return 1 }
    func mb(_ n: Int) -> String { fmt(Double(n) / 1e6, 1) }
    print("wrote \(out)/public-refs.json: \(entries.count) files from \(dirs.count) directories, \(mb(jpegBytes)) MB of JPEG and \(mb(pixelBytes)) MB of reference pixels (\(declined) files declined by design); \(skipped.count) skipped" + (skipped.isEmpty ? "" : ": " + skipped.map { "\($0["dir"]!)/\($0["file"]!) (\($0["reason"]!))" }.joined(separator: ", ")))
    print("this Mac's GPU: decode \(macDecOK) identical, \(macDecBad) different; encode \(macEncOK) identical, \(macEncBad) different")
    if writeErrors > 0 || macDecBad > 0 || macEncBad > 0 { return 1 }
    if entries.isEmpty { print("no JPEG files under \(dirs.joined(separator: ", "))"); return 2 }
    return skipped.isEmpty ? 0 : 3
}

/// the SOFn marker byte of the frame header (0xC0 baseline, 0xC1 extended sequential, ...), nil if none before SOS
private func readSOFMarker(_ d: Data) -> UInt8? {
    let p = [UInt8](d.prefix(1 << 20))
    var i = 2
    guard p.count > 4, p[0] == 0xFF, p[1] == 0xD8 else { return nil }
    while i + 3 < p.count {
        guard p[i] == 0xFF else { return nil }
        let m = p[i + 1]
        if m == 0xFF { i += 1; continue }
        if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) { i += 2; continue }
        if (0xC0...0xCF).contains(m) && m != 0xC4 && m != 0xC8 && m != 0xCC { return m }
        if m == 0xDA { return nil }
        i += 2 + (Int(p[i + 2]) << 8 | Int(p[i + 3]))
    }
    return nil
}
