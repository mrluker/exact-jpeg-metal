import Foundation
import Metal
import ImageIO
import CoreGraphics
import ExactJPEG

// --public: the comparison of `ejm public-bench` on the phone, on the files `ejm export-public Public <dir> ...` wrote
// on the Mac (run-device.sh --public does it; Public/ is gitignored and copied into the bundle). There is no
// libjpeg-turbo here: Public/public-refs.json holds libjpeg-turbo 3.2.0's decode of each file as a SHA-256 and its q95
// re-encode of those pixels as a SHA-256, and for the files the GPU path declines by design (progressive, arithmetic)
// libjpeg-turbo's pixels themselves (<name>.rgb.lzfse). Per file, in public-bench's order:
//   Metal decode to RGB: identical to libjpeg-turbo or not (a decline by design is counted apart, not a failure),
//     median wall and GPU ms, sync passes, per-stage GPU times of one decode
//   ImageIO decode (kCGImageSourceUseHardwareAcceleration true, as public-bench's "imageio"): median ms, and its
//     pixel identity against libjpeg-turbo's pixels (identical, max diff, PSNR; gray output counts as R = G = B, as
//     libjpeg-turbo's RGB decode of a gray file), read in place from the CGImage; the reference pixels are the Metal
//     decode when its SHA-256 equals libjpeg-turbo's, else the bundled .rgb.lzfse, else none (Metal differs: a failure)
//   Metal q95 re-encode of libjpeg-turbo's pixels at the file's sampling: identical to libjpeg-turbo's bytes or not,
//     median ms (skipped where the export skipped it: 4:4:0, 4:1:1, gray)
// Timing rule as public-bench: 1 s of the same work, then 15 timed calls, median, monotonic clock (PublicShared.swift
// pbTimes); 7 calls for files above 20 MP (recorded per file as "iters"). Not measured here: libjpeg-turbo,
// VideoToolbox, the throughput cases and ImageIO encode. A Metal decode or encode that differs, a decline that is not
// by design, or a bundled file that differs from the export is a failure (fail(): run-device.sh exits 5), as is a last
// timed decode or encode whose output differs from the first one's. A timed call that fails makes its case invalid
// (summary.invalid_cases; run-device.sh exits 5 on any). Per file, "memory": the largest footprint sampled after each
// phase (each phase's buffers are released before the next) and the process's peak so far.

extension Runner {
    func publicBench() {
        let root = bundle.appendingPathComponent("Public")
        guard let refsData = try? Data(contentsOf: root.appendingPathComponent("public-refs.json")),
              let refs = (try? JSONSerialization.jsonObject(with: refsData)) as? [String: Any],
              let entries = refs["files"] as? [[String: Any]] else {
            fail("Public/public-refs.json missing or unreadable (run-device.sh --public <dir> ... exports it)"); return
        }
        let reference = refs["reference"] as? String ?? "missing"
        if reference != "libjpeg-turbo 3.2.0" { fail("Public/public-refs.json reference is \(reference), not libjpeg-turbo 3.2.0"); return }
        let pi = ProcessInfo.processInfo
        let warmS = 1.0, itersDefault = 15, itersLarge = 7, largeMP = 20.0
        var cond: [String: Any] = [
            "thermal_start": thermalName(), "low_power_mode_start": pi.isLowPowerModeEnabled, "memory_start": memMB(),
            "reference": reference, "directories": refs["directories"] ?? NSNull(), "export_skipped": refs["skipped"] ?? [],
            "gpu_warmup": "\(warmS) s of the same work before each timed case, then \(itersDefault) timed calls (\(itersLarge) for files above \(Int(largeMP)) MP), median; no discarded iterations",
            "clock": "clock_gettime_nsec_np(CLOCK_UPTIME_RAW); failed calls are counted, not timed, and make a case invalid",
            "iters": itersDefault, "iters_above_20_mp": itersLarge,
            "imageio": "kCGImageSourceUseHardwareAcceleration true (public-bench's imageio); identity against libjpeg-turbo's pixels",
            "not_measured": "libjpeg-turbo (not on iOS), ImageIO with the key false, VideoToolbox, Metal and libjpeg-turbo throughput, ImageIO encode",
            "reference_decode": refs["reference_decode"] ?? NSNull(), "reference_encode": refs["reference_encode"] ?? NSNull(),
            "thermal_pause": "before each file, while the thermal state is serious or critical, 15 s pauses (up to 10 minutes)",
        ]
        if pi.isLowPowerModeEnabled { say("WARNING: Low Power Mode is on: these timings are not representative") }
        say("== public: \(entries.count) files (\(reference)); thermal \(thermalName()), Low Power Mode \(pi.isLowPowerModeEnabled ? "on" : "off")")
        let t0 = now()
        let dec = Decoder(), enc = Encoder()
        var records: [[String: Any]] = [], invalid: [String] = []
        for (k, e) in entries.enumerated() {
            autoreleasepool {
                let file = e["file"] as? String ?? "?"
                status("public \(k + 1)/\(entries.count) \(file)")
                let th = waitCool(file)
                var r: [String: Any] = [:]
                for key in ["dir", "subsampling_dir", "name", "sha256", "sha256_checked", "bytes", "published_by_libjpeg_turbo", "width", "height",
                            "subsampling", "frame", "progressive", "sof_kind"] { r[key] = e[key] ?? NSNull() }
                r["file"] = file; r["thermal"] = th
                guard let data = try? Data(contentsOf: root.appendingPathComponent(file)), sha(data) == e["sha256"] as? String else {
                    fail("public \(file): not bundled or differs from public-refs.json"); return
                }
                let w = e["width"] as? Int ?? 0, h = e["height"] as? Int ?? 0, px = w * h
                let iters = Double(px) / 1e6 > largeMP ? itersLarge : itersDefault
                r["iters"] = iters
                r["mp"] = jnum(Double(px) / 1e6); r["bytes_per_pixel"] = jnum(Double(data.count) / Double(max(px, 1)), 1e4)
                let refSHA = e["ref_rgb_sha256"] as? String ?? "?"
                let byDesign = e["declined_by_design"] as? String
                func note(_ t: Timed, _ what: String) { if !t.valid { invalid.append("\(file) \(what): \(t.failures) failed") } }

                // Metal decode
                var m: [String: Any] = [:]
                var refPx: [UInt8]? = nil
                var line = ""
                var peak = footprintMB().current      // the largest footprint sampled in this file's phases
                func sample() { peak = max(peak, footprintMB().current) }
                if let img = dec.decode(data) {
                    let firstSHA = sha(img.bytes)
                    let same = firstSHA == refSHA
                    m["identical"] = same
                    if same { refPx = Array(img.bytes) } else { fail("public \(file): Metal decode DIFFERENT from libjpeg-turbo 3.2.0") }
                    sample()
                    var gpu: [Double] = []
                    var last: GPUImage? = nil
                    let wall = pbTimes(iters, warm: warmS) { last = dec.decode(data); gpu.append(dec.gpuSeconds); return last != nil }
                    note(wall, "Metal decode")
                    // the last timed call's output against the first decode's (one hash, outside the timed calls)
                    let lastSame = last.map { sha($0.bytes) == firstSHA } ?? false
                    last = nil
                    m["last_timed_identical_to_first"] = lastSame
                    if !lastSame { fail("public \(file): the last timed Metal decode differs from the first (or failed)") }
                    gpu = Array(gpu.suffix(iters))
                    for (key, v) in wall.json("wall_ms") { m[key] = v }
                    m["gpu_ms"] = wall.valid ? jnum(median(gpu) * 1000) : NSNull()
                    m["passes"] = dec.passes
                    dec.recordStages = true
                    _ = dec.decode(data)
                    let ok = dec.decode(data) != nil       // the second decode's stages (recorder set up by the first)
                    let stages = ok ? dec.stageTimes : []
                    dec.recordStages = false
                    m["stages"] = stages.map { ["stage": $0.name, "gpu_ms": jnum($0.gpuSeconds * 1000)] }
                    m["stages_total_gpu_ms"] = jnum(stages.reduce(0) { $0 + $1.gpuSeconds } * 1000)
                    line += "decode \(same ? "identical" : "DIFFERENT"), Metal \(wall.text) ms (GPU \(fmt(median(gpu) * 1000)) ms, \(dec.passes) passes)"
                } else if let kd = byDesign {
                    m["declined"] = kd; m["declined_by_design"] = true
                    line += "decode declined by design: \(kd)"
                } else {
                    m["identical"] = false; m["declined"] = dec.reason ?? "?"
                    fail("public \(file): Metal decode declined (\(dec.reason ?? "?"))")
                    line += "decode DECLINED (\(dec.reason ?? "?"))"
                }
                r["metal_decode"] = m

                // libjpeg-turbo's pixels for a file the GPU path declines by design: the bundled .rgb.lzfse
                if refPx == nil, let pf = e["ref_rgb_file"] as? String {
                    // the compressed and decompressed Data go at the end of this pool; only refPx stays
                    refPx = autoreleasepool { () -> [UInt8]? in
                        guard let z = try? Data(contentsOf: root.appendingPathComponent(pf)),
                              let raw = try? (z as NSData).decompressed(using: .lzfse) as Data, sha(raw) == refSHA else { return nil }
                        return [UInt8](raw)
                    }
                    if refPx == nil { fail("public \(file): bundled reference pixels \(pf) missing or differ from public-refs.json") }
                    sample()
                }

                // ImageIO decode, and its identity against libjpeg-turbo's pixels
                do {
                    let t = pbTimes(iters, warm: warmS) { autoreleasepool { imageIODecodeKey(data, hardware: true) != nil } }
                    note(t, "imageio")
                    var io = t.json("ms_1_thread")
                    io["kCGImageSourceUseHardwareAcceleration"] = true
                    autoreleasepool {
                        // compared in place (cgImageIdentity: no RGB copy); the CGImage goes at the end of this pool
                        if let img = imageIODecodeKey(data, hardware: true) {
                            sample()
                            if let ref = refPx {
                                if let idt = cgImageIdentity(img, ref) { for (key, v) in idt { io[key] = v } }
                                else { io["error"] = "no pixels: \(img.bitsPerComponent)-bit, \(img.bitsPerPixel) bits per pixel, colour model \(img.colorSpace.map { "\($0.model.rawValue)" } ?? "?")" }
                            } else {
                                io["error"] = "no libjpeg-turbo pixels (the Metal decode differs)"
                            }
                        } else { io["error"] = "decode failed" }
                    }
                    r["imageio"] = io
                    line += "; ImageIO \(t.text) ms, \(identityText(io))"
                }

                // Metal q95 re-encode of libjpeg-turbo's pixels
                var en: [String: Any] = ["quality": 95, "subsampling": e["subsampling"] ?? NSNull()]
                let ref = e["encode"] as? [String: Any] ?? [:]
                let ss: Subsampling? = ["4:4:4": .s444, "4:2:2": .s422, "4:2:0": .s420][e["subsampling"] as? String ?? ""]
                if let skip = ref["skipped"] as? String {
                    en["skipped"] = skip; line += "; encode skipped (\(skip))"
                } else if let want = ref["turbo_sha256"] as? String, let ss, refPx != nil {
                    // the pixels move to the Metal buffer; the array goes before the encodes
                    let buf = sharedBuffer(refPx!, enc.ctx.device)
                    refPx = nil
                    sample()
                    do {
                        let got = try enc.encode(buffer: buf, width: w, height: h, quality: 95, subsampling: ss)
                        let same = sha(got) == want
                        if !same { fail("public \(file): Metal q95 encode DIFFERENT from libjpeg-turbo 3.2.0") }
                        var gpu: [Double] = []
                        var last: Data? = nil
                        let t = pbTimes(iters, warm: warmS) {
                            last = try? enc.encode(buffer: buf, width: w, height: h, quality: 95, subsampling: ss)
                            gpu.append(enc.gpuSeconds); return last != nil
                        }
                        note(t, "Metal encode")
                        let lastSame = last == got
                        en["last_timed_identical_to_first"] = lastSame
                        if !lastSame { fail("public \(file): the last timed Metal encode differs from the first (or failed)") }
                        gpu = Array(gpu.suffix(iters))
                        en["identical"] = same; en["bytes"] = got.count; en["turbo_bytes"] = ref["turbo_bytes"] ?? NSNull()
                        for (key, v) in t.json("metal_ms") { en[key] = v }
                        en["metal_gpu_ms"] = t.valid ? jnum(median(gpu) * 1000) : NSNull()
                        line += "; encode q95 \(same ? "identical" : "DIFFERENT") \(t.text) ms"
                    } catch {
                        en["identical"] = false; en["error"] = "\(error)"
                        fail("public \(file): Metal q95 encode failed: \(error)")
                        line += "; encode FAILED"
                    }
                } else {
                    en["identical"] = false
                    en["error"] = refPx == nil ? "no libjpeg-turbo pixels (the Metal decode differs)" : "no reference encode in public-refs.json"
                    fail("public \(file): q95 encode not checked: \(en["error"]!)")
                    line += "; encode NOT CHECKED"
                }
                r["encode"] = en
                refPx = nil
                let fp = footprintMB()
                r["memory"] = ["footprint_peak_sampled_mb": max(peak, fp.current), "footprint_end_mb": fp.current,
                               "footprint_lifetime_peak_mb": fp.peak, "available_end_mb": os_proc_available_memory() / 1_000_000,
                               "note": "peak_sampled: the largest footprint read after each phase, with that phase's buffers alive; lifetime_peak: the process's peak so far (task_vm_info ledger_phys_footprint_peak)"]
                records.append(r)
                say("pub \(file): \(w)x\(h) \(e["subsampling"] ?? "?") \(e["frame"] ?? "?"); \(line); thermal \(th)")
            }
        }
        cond["thermal_end"] = thermalName(); cond["low_power_mode_end"] = pi.isLowPowerModeEnabled; cond["memory_end"] = memMB()
        cond["seconds"] = now() - t0

        // totals, as public-bench's identity totals: declines by design, skips and errors are not compared files
        func totals(_ key: String, _ recs: [[String: Any]]) -> [String: Any] {
            let rs = recs.compactMap { $0[key] as? [String: Any] }
                .filter { $0["skipped"] == nil && $0["declined_by_design"] as? Bool != true && ($0["identical"] != nil || $0["error"] != nil) }
            let errs = rs.filter { $0["error"] != nil }, ok = rs.filter { $0["error"] == nil }
            let ps = ok.compactMap { $0["psnr_db"] as? Double }
            return ["files": ok.count, "identical": ok.filter { $0["identical"] as? Bool == true }.count, "errors": errs.count,
                    "max_diff": ok.compactMap { $0["max_diff"] as? Int }.max() ?? 0,
                    "psnr_min_db": ps.min() ?? NSNull(), "psnr_max_db": ps.max() ?? NSNull()]
        }
        func summary(_ recs: [[String: Any]]) -> [String: Any] {
            ["files": recs.count,
             "metal_declined_by_design": recs.filter { ($0["metal_decode"] as? [String: Any])?["declined_by_design"] as? Bool == true }.count,
             "identity": ["metal_decode": totals("metal_decode", recs), "metal_encode": totals("encode", recs), "imageio_hardware_key": totals("imageio", recs)]]
        }
        var sum = summary(records)
        var perDir: [String: Any] = [:]
        for d in Set(records.compactMap { $0["dir"] as? String }).sorted() { perDir[d] = summary(records.filter { $0["dir"] as? String == d }) }
        sum["per_directory"] = perDir
        sum["invalid_cases"] = invalid
        sum["export_skipped"] = refs["skipped"] ?? []
        results["public"] = ["conditions": cond, "records": records, "summary": sum]

        let id = sum["identity"] as! [String: [String: Any]]
        func nm(_ k: String) -> String { "\(id[k]!["identical"]!)/\(id[k]!["files"]!)" }
        say("public totals: decode identical \(nm("metal_decode")), declined by design \(sum["metal_declined_by_design"]!), encode identical \(nm("metal_encode")), ImageIO identical \(nm("imageio_hardware_key")) (max diff \(id["imageio_hardware_key"]!["max_diff"]!), \(id["imageio_hardware_key"]!["errors"]!) errors)")
        say("public invalid cases (a call failed): \(invalid.isEmpty ? "none" : invalid.joined(separator: "; "))")
        say("public thermal \(cond["thermal_start"]!) -> \(cond["thermal_end"]!), Low Power Mode \(cond["low_power_mode_start"]!) -> \(cond["low_power_mode_end"]!), \(fmt(now() - t0, 1)) s")
    }
}

/// this process's memory footprint now and its peak so far (task_vm_info), in MB; -1 when task_info fails
private func footprintMB() -> (current: Int, peak: Int) {
    var info = task_vm_info_data_t()
    var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
    guard r == KERN_SUCCESS else { return (-1, -1) }
    return (Int(info.phys_footprint) / 1_000_000, Int(info.ledger_phys_footprint_peak) / 1_000_000)
}
