import Foundation
import Metal
@_spi(Testing) import ExactJPEG
import ExactJPEGC
import TurboRef

// ejm api-check [name ...]: API behaviour checks against libjpeg-turbo, beyond the corpus (which decodes only to
// .rgb and .gray through decode(_:format:)). Exits non-zero on any failure. With names, runs only those checks.
//   eager-range        Decoder.eagerPasses outside 1...64 is clamped (no out-of-bounds pass-status access)
//   warmup             after MetalContext.warmUp(), decoding and encoding build no new pipeline states
//   decline-untouched  a declined decode leaves the caller's buffer untouched (C zero-copy and copy paths,
//                      Swift output:)
//   gray-rgba          gray JPEG to .rgba / .bgra, byte-identical to libjpeg-turbo (JCS_EXT_RGBA / BGRA)
//   header-limits      jpegHeader throws InvalidInput for oversized EXIF / ICC, as the encoder does
//   formats            Swift decode to every PixelFormat, byte-identical to libjpeg-turbo
//   c-api              ejm_decode (copy and zero-copy paths) and ejm_decode_view in every format
//   output             Decoder.decode(... output:) into a caller buffer
//   icc                encode with ICC (one and several chunks) and EXIF: whole file identical to libjpeg-turbo
//                      (jpeg_write_marker + jpeg_write_icc_profile), and the decoded pixels identical
//   tuning             non-default eagerPasses, chunkBits and checkpoints give identical bytes
//   self-check         the startup self-check passes; its no-restart case spans several 4096-bit Huffman chunks;
//                      in child processes (ejm selfcheck-child): with EJM_SELFCHECK_FAIL=1 every Swift and C
//                      decode and encode path declines or throws with the reason and leaves outputs untouched, and
//                      the check runs once; 10 concurrent first decodes, then 10 first encodes, run each half once
//   device-profile     DeviceProfile layer 1 is deterministic and follows its rules (M1 Max, M4, iPhone 13
//                      properties); pinned routing and prefersCPU; the routing cache round trip, a corrupt and a stale
//                      file ignored, clearCache; in child processes (ejm profile-child): EJM_PROFILE_CACHE=0 neither
//                      reads nor writes, a seeded cache is used, a corrupt one is replaced, an unwritable one is harmless;
//                      the daily re-measure: merge by field-by-field minimum, the 24-hour gate (injected clock), and in
//                      children a 25-hour-old entry re-measured and merged (count and date updated), a 1-hour-old one not;
//                      the busy gate on injected samples (GPU utilization, load, thermal, Low Power Mode), and in children
//                      a busy device deferred and retried at most every 10 minutes, a busy stale entry left alone;
//                      the measurement on injected call timings (the cold fixed cost is the median of 5 with an
//                      outlier, the sporadic set is the sustained per-MP cost plus it, a cold cost outside the
//                      sustained fixed cost to 20x it is rejected, also through a child process and the cache), the
//                      sustained set is the estimate, prefersCPU(sustained:), and the gate waiting out this
//                      process's own GPU work; warmth (injected clocks): the GPU from this process's command
//                      buffers, the CPU from noteCPUWork and the process CPU time (injected); the cold GPU's per-MP
//                      cost from an isolated 1600x1200 call; the CPU proxy fit (ratio, ramp) from simulated and
//                      noisy chunk times, a flat run not used; the M4 fixture (ground truth for every GPU and CPU
//                      warmth, 5 sizes, decode and encode) with M4-like injected timings: no wrong call where the
//                      loser is over 25% slower; the sustained and cpuWarm overrides (sustained alone sets both
//                      sides); a backward clock step, a busy-then-idle CPU, the proxy's own run, none read as warm;
//                      the cache with the CPU model, which a re-measure replaces whole; in a child (cpuonly), a CPU
//                      fit kept and saved on its own when the GPU part is not used
//   trace              Decoder.recordStages / Encoder.recordStages: stage names and counts (decode on 5 files,
//                      encode at 3 sizes on both entropy paths and a batch mixing them), the stage sum within the
//                      command buffer's GPU time, bytes identical to libjpeg-turbo with recording on;
//                      DeviceProfile.routingDecision against prefersCPU (120 argument sets) and its fields;
//                      MetalContext.trace gets one line per call (decodes, a decline, an encode, a batch), nil none
//   exactness-record   `ejm exactness` refuses a run with another libjpeg-turbo runtime (unless --allow-runtime),
//                      fuzz lengths below test.sh's defaults, or uncommitted changes (unless --allow-dirty); the
//                      overrides are recorded (Results.swift checkExactnessRecord)
//   device-refs        the iOS check's refs.json is written by libjpeg-turbo 3.2.0 only: in children
//                      (ejm export-refs-child, EJM_TEST_TURBO_RUNTIME) another or an unknown version is refused and a
//                      refs.json already there removed (Corpus.swift checkDeviceRefs); the same for the --public
//                      mode's public-refs.json (ejm export-public), which holds no absolute path
//   selfcheck-cases    every built-in self-check case is what its name says, read from its own JPEG markers (SOF
//                      sampling factors and components, DQT precision and values, DRI and RST markers) or, for the
//                      encode cases, from its settings; a case with no rule fails; a mislabeled pair (the 4:2:2 JPEG
//                      named 4:4:0) must fail the rules (the control)
//   (decoder audit checks, DecoderAudit.swift: see decoderAuditChecks there)
//   (API usage checks, UsageChecks.swift: see usageChecks there)
//   encoder-limits     encoder argument and resource limits, each case in a child process (ejm enc-limit-child,
//                      EncLimits.swift) so a trap fails the case: the 32-bit entropy bit count (bound, a job past
//                      it, 8000x8000 noise, implausible GPU counts), 32-bit pixel offsets, overflowing sizes and
//                      offsets (Swift and C API), the GPU memory budget and failed allocations, a poisoned output
//                      estimate, the job index in batch errors, jpegHeader arguments, empty ICC and EXIF blocks
// Test images are synthetic (Synth / corpusContent), encoded by libjpeg-turbo.

final class Tally {
    var ok = 0, bad = 0, skipped = 0      // skipped: cases that could not run on this machine (not a pass)
    func check(_ cond: Bool, _ what: @autoclosure () -> String) {
        if cond { ok += 1 } else { bad += 1; print("  FAIL: \(what())") }
    }
}

struct APIFile { let name: String; let data: Data; let gray: Bool }

func apiFiles() -> [APIFile] {
    var out: [APIFile] = []
    var seed: UInt32 = 101
    let subs = [(0, "444"), (1, "422"), (2, "420"), (3, "440"), (4, "411")]
    for (w, h) in [(1, 1), (37, 29), (203, 97), (640, 480)] {
        seed &+= 1
        let a = corpusContent(w, h, "smooth", seed)
        for (s, n) in subs { out.append(APIFile(name: "\(w)x\(h)_\(n)", data: Turbo.encode(a, w, h, quality: 90, samp: s), gray: false)) }
        let g = stride(from: 0, to: a.count, by: 3).map { a[$0] }
        out.append(APIFile(name: "\(w)x\(h)_gray", data: Turbo.encode(g, w, h, gray: true, quality: 85, samp: 0), gray: true))
    }
    let a = corpusContent(203, 97, "edges", 7)
    for s in 0..<3 {
        out.append(APIFile(name: "203x97_s\(s)_rst3", data: Turbo.encode(a, 203, 97, quality: 80, samp: s, restartMCUs: 3), gray: false))
    }
    let g = stride(from: 0, to: a.count, by: 3).map { a[$0] }
    out.append(APIFile(name: "203x97_gray_rst5", data: Turbo.encode(g, 203, 97, gray: true, quality: 80, samp: 0, restartMCUs: 5), gray: true))
    let b = corpusContent(1201, 803, "smooth", 9)
    out.append(APIFile(name: "1201x803_420_rstrow", data: Turbo.encode(b, 1201, 803, quality: 95, samp: 2, restartRows: 1), gray: false))
    let n = corpusContent(1201, 803, "noise", 11)
    out.append(APIFile(name: "1201x803_noise_422", data: Turbo.encode(n, 1201, 803, quality: 95, samp: 1), gray: false))
    return out
}

let allFormats: [PixelFormat] = [.rgb, .bgr, .gray, .rgba, .bgra]

/// libjpeg-turbo's decode of d to format f (nil if it fails)
func turboDecode(_ d: Data, _ f: PixelFormat) -> [UInt8]? {
    guard let i = Turbo.info(d) else { return nil }
    var px = [UInt8](repeating: 0, count: i.w * i.h * f.channels)
    let r = d.withUnsafeBytes { src in
        px.withUnsafeMutableBufferPointer { tr_decode_fmt(src.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, $0.baseAddress, Int32(f.rawValue)) }
    }
    return r < 0 ? nil : px
}

private func same(_ img: GPUImage?, _ ref: [UInt8]) -> Bool {
    guard let img else { return false }
    let b = img.bytes
    return b.count == ref.count && ref.withUnsafeBytes { memcmp($0.baseAddress!, b.baseAddress!, ref.count) == 0 }
}

private func pageAlloc(_ n: Int) -> (UnsafeMutableRawPointer, Int) {
    let page = Int(getpagesize())
    let cap = max((n + page - 1) / page * page, page)
    return (UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: page), cap)
}

// ---- the five bugs ----

private func checkEagerRange(_ t: Tally, _ files: [APIFile]) {
    let sel = files.filter { ["640x480_420", "1201x803_420_rstrow", "203x97_s1_rst3"].contains($0.name) }
    for g in [0, -1, 65, 1000] {
        let dec = Decoder()
        dec.eagerPasses = g
        t.check((1...64).contains(dec.eagerPasses), "eagerPasses = \(g) reads back \(dec.eagerPasses), not clamped to 1...64")
        for f in sel {
            let img = dec.decode(f.data, format: .rgb)
            t.check(same(img, turboDecode(f.data, .rgb)!), "eagerPasses = \(g), \(f.name): \(img == nil ? "declined: \(dec.reason ?? "?")" : "bytes differ")")
            t.check((1...64).contains(dec.passes), "eagerPasses = \(g), \(f.name): passes = \(dec.passes)")
        }
    }
}

private func checkWarmUp(_ t: Tally, _ files: [APIFile]) {
    // every kernel in the Metal source is in kernelNames (color_k only through its specialisations)
    var srcNames: [String] = []
    for f in ["Common", "Decode", "Encode"] {
        guard let s = try? String(contentsOfFile: "Sources/ExactJPEG/Shaders/\(f).metal", encoding: .utf8) else {
            print("  (Sources/ExactJPEG/Shaders/\(f).metal not found: run from the repository root for the source check)"); continue
        }
        let re = try! NSRegularExpression(pattern: #"kernel\s+void\s+(\w+)"#)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) { srcNames.append(String(s[Range(m.range(at: 1), in: s)!])) }
    }
    let missing = srcNames.filter { $0 != "color_k" && !MetalContext.kernelNames.contains($0) }
    t.check(missing.isEmpty, "kernels missing from MetalContext.kernelNames: \(missing)")
    let ctx = try! MetalContext()
    ctx.warmUp()
    let n0 = ctx.pipelineCount
    let dec = Decoder(ctx: ctx), enc = Encoder(ctx: ctx)
    for f in files { for fmt in allFormats { _ = dec.decode(f.data, format: fmt) } }
    let px = corpusContent(321, 123, "smooth", 3)
    for ss in [Subsampling.s444, .s422, .s420] {
        _ = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 321, height: 123, subsampling: ss) }
        _ = try? enc.encodeBatch([EncodeJob(buffer: sharedBuffer(px, ctx.device), width: 321, height: 123, subsampling: ss)])
    }
    enc.fusedMaxBlocks = 0      // the two-pass entropy path
    _ = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 321, height: 123) }
    let n1 = ctx.pipelineCount
    t.check(n1 == n0, "warmUp() built \(n0) pipeline states; decoding and encoding then built \(n1 - n0) more")
    print("  warmUp(): \(n0) pipeline states; after decodes in every format and encodes: \(n1)")
}

/// declined inputs: trailer markers, corrupt entropy-coded data, a renumbered restart marker
private func declinedInputs() -> [(String, Data)] {
    let a = corpusContent(640, 480, "smooth", 21)
    let base = Turbo.encode(a, 640, 480, quality: 90, samp: 2)
    var out: [(String, Data)] = []
    for m: UInt8 in [0xD8, 0xC4] {
        var d = base; d[d.count - 1] = m; out.append(("trailer FF\(String(m, radix: 16, uppercase: true))", d))
    }
    let s0 = try! base.withUnsafeBytes { try parseJPEGHeader($0) }.scanStart
    let dec = Decoder()
    var rng = Rng(s: 12345)
    var corrupt = 0
    for _ in 0..<400 where corrupt < 6 {
        var d = base
        let at = s0 + rng.int(d.count - s0 - 64)
        for k in 0..<3 { d[at + k] = UInt8(truncatingIfNeeded: rng.next()) }
        if dec.decode(d) == nil, let r = dec.reason, !r.contains("after the scan") {
            out.append(("corrupt at \(at): \(r)", d)); corrupt += 1
        }
    }
    let r = Turbo.encode(a, 640, 480, quality: 90, samp: 2, restartMCUs: 4)
    if let i = (r.startIndex..<(r.count - 1)).first(where: { r[$0] == 0xFF && r[$0 + 1] == 0xD3 }) {
        var d = r; d[i + 1] = 0xD5; out.append(("RST3 renumbered", d))
    }
    return out
}

private func checkDeclineUntouched(_ t: Tally) {
    let cases = declinedInputs()
    let cd = ejm_decoder_create()!
    defer { ejm_decoder_destroy(cd) }
    let dec = Decoder()
    for (name, d) in cases {
        for fmt in [PixelFormat.rgb, .rgba, .gray] {
            let need = 640 * 480 * fmt.channels
            // C, zero-copy path (page-aligned, capacity a multiple of the page size)
            let (p, cap) = pageAlloc(need + 1)      // + 1: room for the unaligned copy-path call below
            memset(p, 0xA5, cap)
            var w: Int32 = 0, h: Int32 = 0
            let r = d.withUnsafeBytes { ejm_decode(cd, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, Int32(fmt.rawValue),
                                                    p.assumingMemoryBound(to: UInt8.self), cap, &w, &h) }
            let bp = UnsafeRawBufferPointer(start: p, count: cap)
            let touched = bp.firstIndex { $0 != 0xA5 }
            t.check(r == 1, "C zero-copy, \(name), \(fmt): returned \(r), expected EJM_DECLINED")
            t.check(touched == nil, "C zero-copy, \(name), \(fmt): declined but out was written (first byte changed at \(touched ?? -1))")
            // C, copy path (out not page-aligned)
            memset(p, 0xA5, cap)
            let r2 = d.withUnsafeBytes { ejm_decode(cd, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, Int32(fmt.rawValue),
                                                     (p + 1).assumingMemoryBound(to: UInt8.self), cap - 1, &w, &h) }
            t.check(r2 == 1 && bp.allSatisfy { $0 == 0xA5 }, "C copy path, \(name), \(fmt): returned \(r2), out touched: \(!bp.allSatisfy { $0 == 0xA5 })")
            p.deallocate()
            // Swift, output:
            let ob = dec.ctx.device.makeBuffer(length: need, options: .storageModeShared)!
            memset(ob.contents(), 0xA5, need)
            let img = d.withUnsafeBytes { dec.decode(bytes: $0, format: fmt, output: ob) }
            let ub = UnsafeRawBufferPointer(start: ob.contents(), count: need)
            t.check(img == nil && ub.allSatisfy { $0 == 0xA5 }, "Swift output:, \(name), \(fmt): declined \(img == nil), output touched: \(!ub.allSatisfy { $0 == 0xA5 })")
        }
    }
    print("  \(cases.count) declined inputs: \(cases.map(\.0).joined(separator: "; "))")
    // trailers the decoder accepts (the GPU trailer check must not decline these): exact as before
    let a = corpusContent(203, 97, "smooth", 23)
    let base = Turbo.encode(a, 203, 97, quality: 90, samp: 1)
    let body = base.prefix(base.count - 2)
    let accepted: [(String, Data)] = [
        ("EOI then junk", base + Data([1, 2, 3, 0xFF, 0xC4])), ("fill bytes before EOI", body + Data([0xFF, 0xFF, 0xFF, 0xD9])),
        ("COM after the scan", body + Data([0xFF, 0xFE, 0, 5, 65, 66, 67, 0xFF, 0xD9])),
        ("APP15 after the scan", body + Data([0xFF, 0xEF, 0, 2, 0xFF, 0xD9])), ("no EOI", body),
    ]
    let ref = turboDecode(base, .rgb)!
    for (name, d) in accepted {
        let img = dec.decode(d)
        t.check(same(img, ref), "\(name): \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
    }
    let rejected: [(String, Data)] = [
        ("APP segment running past the end", body + Data([0xFF, 0xE1, 0, 50, 1])), ("truncated APP marker", body + Data([0xFF, 0xE1, 0])),
        ("APP length 1", body + Data([0xFF, 0xE1, 0, 1, 0xFF, 0xD9])),
        ("SOF marker after EOI-less scan", body + Data([0xFF, 0xC0, 0, 2])),
    ]
    for (name, d) in rejected {
        let img = dec.decode(d)
        t.check(img == nil && dec.reason?.contains("after the scan") == true, "\(name): \(img == nil ? dec.reason ?? "?" : "accepted")")
    }
}

private func checkGrayRGBA(_ t: Tally, _ files: [APIFile]) {
    let dec = Decoder()
    for f in files where f.gray {
        for fmt in [PixelFormat.rgba, .bgra] {
            let img = dec.decode(f.data, format: fmt)
            t.check(same(img, turboDecode(f.data, fmt)!), "gray \(f.name) to \(fmt): \(img == nil ? "declined: \(dec.reason ?? "?")" : "bytes differ")")
        }
    }
}

/// each EncLimits case in its own child process: it must print "OK ..." and exit 0 (a trap is a signal exit)
private func checkEncoderLimits(_ t: Tally) {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    for c in encLimitCases {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["enc-limit-child", c]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { t.check(false, "cannot start \(exe.path): \(error)"); continue }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        let how = p.terminationReason == .uncaughtSignal ? "crashed (signal \(p.terminationStatus))" : "exit \(p.terminationStatus)"
        if p.terminationReason == .exit && p.terminationStatus == 0 && line.hasPrefix("SKIPPED ") {
            t.skipped += 1; print("  \(c): \(line)"); continue
        }
        let ok = p.terminationReason == .exit && p.terminationStatus == 0 && line.hasPrefix("OK ")
        t.check(ok, "\(c): \(how): \(line.isEmpty ? "(no output)" : line)")
        if ok { print("  \(c): \(line)") }
    }
    // a case that cannot run here (span-real without its sparse buffer) is reported as skipped, not as passed
    let p = Process()
    p.executableURL = exe
    p.arguments = ["enc-limit-child", "span-real"]
    p.environment = ProcessInfo.processInfo.environment.merging(["EJM_TEST_NO_SPARSE": "1"]) { $1 }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { t.check(false, "cannot start \(exe.path): \(error)"); return }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    let line = out.split(separator: "\n").last.map(String.init) ?? ""
    t.check(p.terminationReason == .exit && p.terminationStatus == 0 && line.hasPrefix("SKIPPED "),
            "span-real with no sparse buffer (EJM_TEST_NO_SPARSE=1) reports SKIPPED, exit 0: exit \(p.terminationStatus): \(line)")
}

private func checkHeaderLimits(_ t: Tally) {
    func throwsInvalid(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch is InvalidInput { return true } catch { return false }
    }
    let maxICC = 255 * 65519
    t.check(throwsInvalid { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, exif: Data(count: 65534)) },
            "jpegHeader with a 65534-byte EXIF block did not throw InvalidInput")
    t.check(throwsInvalid { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, icc: Data(count: maxICC + 1)) },
            "jpegHeader with a \(maxICC + 1)-byte ICC profile did not throw InvalidInput")
    t.check(!throwsInvalid { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, icc: Data(count: maxICC), exif: Data(count: 65533)) },
            "jpegHeader rejected the largest allowed EXIF (65533) and ICC (\(maxICC)) blocks")
    let enc = Encoder()
    let px = [UInt8](repeating: 128, count: 8 * 8 * 3)
    for (icc, exif) in [(nil, Data(count: 65534)), (Data(count: maxICC + 1), nil)] as [(Data?, Data?)] {
        t.check(throwsInvalid { _ = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8, icc: icc, exif: exif) } },
                "Encoder.encode with an oversized block did not throw InvalidInput")
    }
}

// ---- the "not verified" items ----

private func checkFormats(_ t: Tally, _ files: [APIFile]) {
    let dec = Decoder()
    var n = 0
    for f in files {
        for fmt in allFormats {
            let img = dec.decode(f.data, format: fmt)
            t.check(same(img, turboDecode(f.data, fmt)!), "\(f.name) to \(fmt): \(img == nil ? "declined: \(dec.reason ?? "?")" : "bytes differ")")
            n += 1
        }
    }
    print("  \(files.count) files x \(allFormats.count) formats = \(n) decodes")
}

private func checkCAPI(_ t: Tally, _ files: [APIFile]) {
    let cd = ejm_decoder_create()!
    defer { ejm_decoder_destroy(cd) }
    for f in files {
        for fmt in allFormats {
            let ref = turboDecode(f.data, fmt)!
            let (p, cap) = pageAlloc(ref.count + 1)
            f.data.withUnsafeBytes { src in
                let sp = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var w: Int32 = 0, h: Int32 = 0, c: Int32 = 0
                for (label, o, oc) in [("zero-copy", p, cap), ("copy", p + 1, cap - 1)] {
                    memset(p, 0xA5, cap)
                    let r = ejm_decode(cd, sp, src.count, Int32(fmt.rawValue), o.assumingMemoryBound(to: UInt8.self), oc, &w, &h)
                    let ok = r == 0 && memcmp(o, ref, ref.count) == 0
                    t.check(ok, "ejm_decode \(label), \(f.name), \(fmt): returned \(r) \(r == 0 ? "bytes differ" : String(cString: ejm_decoder_reason(cd)!))")
                }
                var px: UnsafePointer<UInt8>? = nil
                let r = ejm_decode_view(cd, sp, src.count, Int32(fmt.rawValue), &px, &w, &h, &c)
                t.check(r == 0 && Int(c) == fmt.channels && memcmp(px!, ref, ref.count) == 0, "ejm_decode_view \(f.name), \(fmt): returned \(r)")
            }
            p.deallocate()
        }
    }
}

private func checkOutput(_ t: Tally, _ files: [APIFile]) {
    let dec = Decoder()
    let dev = dec.ctx.device
    for f in files {
        for fmt in allFormats {
            let ref = turboDecode(f.data, fmt)!
            for extra in [0, 4096] {
                let ob = dev.makeBuffer(length: ref.count + extra, options: .storageModeShared)!
                let img = f.data.withUnsafeBytes { dec.decode(bytes: $0, format: fmt, output: ob) }
                t.check(same(img, ref) && img!.buffer === ob && img!.offset == 0, "decode(bytes:output:) \(f.name), \(fmt), +\(extra)")
            }
            let ib = f.data.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count + 100, options: .storageModeShared)! }
            let ob = dev.makeBuffer(length: ref.count, options: .storageModeShared)!
            let img = dec.decode(buffer: ib, length: f.data.count, format: fmt, output: ob)
            t.check(same(img, ref) && img!.buffer === ob, "decode(buffer:length:output:) \(f.name), \(fmt)")
            let small = dev.makeBuffer(length: max(ref.count - 1, 1), options: .storageModeShared)!
            let r = f.data.withUnsafeBytes { dec.decode(bytes: $0, format: fmt, output: small) }
            t.check(ref.count == 1 || (r == nil && dec.reason == "output buffer too small"), "output one byte short, \(f.name), \(fmt): \(dec.reason ?? "accepted")")
        }
    }
}

private func checkICC(_ t: Tally) {
    let enc = Encoder(), dec = Decoder()
    var rng = Rng(s: 99)
    func blob(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }) }
    let w = 203, h = 97
    let px = corpusContent(w, h, "smooth", 31)
    let exif = Data("Exif\0\0".utf8) + blob(1000)
    let cases: [(String, Data?, Data?)] = [
        ("ICC 560 B", blob(560), nil), ("ICC 65519 B (one full chunk)", blob(65519), nil),
        ("ICC 65520 B (two chunks)", blob(65520), nil), ("ICC 200000 B (4 chunks)", blob(200_000), nil),
        ("ICC 255 x 65519 B (255 chunks, the maximum)", blob(255 * 65519), nil),
        ("EXIF 1006 B", nil, exif), ("EXIF 65533 B", nil, blob(65533)), ("EXIF + ICC 70000 B", blob(70000), exif),
    ]
    for (name, icc, ex) in cases {
        for (ss, s) in [(Subsampling.s444, 0), (.s420, 2)] {
            var out: UnsafeMutablePointer<UInt8>? = nil
            var len = 0
            let r = px.withUnsafeBufferPointer { p in
                withOpt(ex) { e, el in withOpt(icc) { i, il in tr_encode_meta(p.baseAddress, Int32(w), Int32(h), 90, Int32(s), e, el, i, il, &out, &len) } }
            }
            guard r == 0 else { t.check(false, "\(name): libjpeg-turbo encode failed"); continue }
            let want = Data(bytes: out!, count: len); tr_free(out)
            let got = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: w, height: h, quality: 90, subsampling: ss, icc: icc, exif: ex) }
            t.check(got == want, "\(name), \(ss): encoder output differs from libjpeg-turbo (\(got?.count ?? -1) vs \(want.count) bytes)")
            if let got {
                for fmt in [PixelFormat.rgb, .rgba] {
                    let img = dec.decode(got, format: fmt)
                    t.check(same(img, turboDecode(got, fmt)!), "\(name), \(ss): decode to \(fmt) \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
                }
            }
        }
    }
}

private func withOpt<R>(_ d: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
    guard let d else { return body(nil, 0) }
    return d.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count) }
}

private func checkTuning(_ t: Tally, _ files: [APIFile]) {
    let sel = files.filter { ["640x480_420", "640x480_gray", "203x97_s2_rst3", "1201x803_420_rstrow", "1201x803_noise_422"].contains($0.name) }
    let refs = sel.map { turboDecode($0.data, .rgb)! }
    for g in [1, 2, 4, 16, 64] {
        let dec = Decoder(); dec.eagerPasses = g
        for (f, ref) in zip(sel, refs) {
            let img = dec.decode(f.data)
            t.check(same(img, ref), "eagerPasses \(g), \(f.name): \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
        }
    }
    var n = 0
    for bits in [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536] {
        for cp in [nil, 1, 2, 3, 7, 15, 31] as [Int?] {
            let dec = Decoder(); dec.chunkBits = bits; dec.checkpoints = cp
            for (f, ref) in zip(sel, refs) {
                let img = dec.decode(f.data)
                t.check(same(img, ref), "chunkBits \(bits), checkpoints \(cp.map(String.init) ?? "nil"), \(f.name): \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
                n += 1
            }
        }
    }
    print("  eagerPasses 1, 2, 4, 16, 64; chunkBits 64...65536 x checkpoints nil, 1...31: \(n) tuned decodes")
}

private func checkSelfCheck(_ t: Tally) {
    let r = MetalContext.shared.selfCheck()
    t.check(r == nil, "self-check failed in a normal run: \(r ?? "")")
    if let d = selfCheckCaseJPEG("decode 4:2:0 without restarts") {
        let s0 = (try? d.withUnsafeBytes { try parseJPEGHeader($0) })?.scanStart ?? d.count
        let chunks = ((d.count - s0) * 8 + 4095) / 4096
        let dec = Decoder(); dec.chunkBits = 4096; dec.checkpoints = 7
        let img = dec.decode(d)
        // chunks 1... start from a guessed state and resynchronise; with fewer than 128 chunks (one threadgroup)
        // that happens inside the first sync_pass, so passes is 1
        t.check(img != nil && chunks >= 4, "no-restart case: \(chunks) chunks, \(img == nil ? "declined" : "decoded")")
        print("  no-restart case: \(chunks) chunks of 4096 bits in one segment, \(dec.passes) sync pass(es)")
        // the self-check also decodes it in 64-bit chunks (several threadgroups), so the work between passes runs
        let sp = SelfCheckTesting.smallChunkPasses
        t.check(sp >= 2, "small-chunk self-check decode: \(sp) sync pass(es), expected 2 or more")
        print("  self-check small-chunk decode: \(((d.count - s0) * 8 + 63) / 64) chunks of 64 bits, \(sp) sync passes")
    } else { t.check(false, "no-restart case missing") }
    // coverage: the default chunking of a small stream (2048 bits), 4096 and 64 bits; 4:4:0; a 16-bit DQT
    let used = SelfCheckTesting.chunkBitsUsed
    t.check(used.contains(2048) && used.contains(4096) && used.contains(64), "self-check chunk sizes \(used): 2048 (the default below 256 KB), 4096 and 64 expected")
    let cases = SelfCheckTesting.decodeCases
    func header(_ d: Data) -> JPEGHeader? { try? d.withUnsafeBytes { try parseJPEGHeader($0) } }
    t.check(cases.contains { header($0.jpeg)?.subsampling == "4:4:0" }, "no 4:4:0 self-check case: \(cases.map(\.name))")
    let dqt16 = cases.filter { c in
        let b = [UInt8](c.jpeg)
        return (2..<(b.count - 4)).contains { b[$0] == 0xFF && b[$0 + 1] == 0xDB && b[$0 + 4] >> 4 == 1 }
            && header(c.jpeg)?.quant.contains { $0.contains { $0 > 255 } } == true
    }
    t.check(!dqt16.isEmpty, "no self-check case with a 16-bit quantisation table holding values above 255")
    print("  self-check decodes: chunk sizes \(used); cases \(cases.map(\.name).joined(separator: ", "))")
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    for (mode, forced) in [("forced", true), ("concurrent", false)] {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["selfcheck-child", mode]
        var env = ProcessInfo.processInfo.environment
        env["EJM_SELFCHECK_FAIL"] = forced ? "1" : nil
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { t.check(false, "cannot start \(exe.path): \(error)"); continue }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let lines = out.split(separator: "\n")
        for l in lines { t.check(l.hasPrefix("OK "), "\(mode) child: \(l)") }
        t.check(p.terminationStatus == 0 && !lines.isEmpty, "\(mode) child exited with \(p.terminationStatus)")
        print("  \(mode) child\(forced ? " (EJM_SELFCHECK_FAIL=1)" : ""): \(lines.filter { $0.hasPrefix("OK ") }.count) of \(lines.count) OK")
    }
}

private func checkDeviceProfile(_ t: Tally) {
    let dev = MetalContext.shared.device
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ejm-profile-\(getpid())")
    defer { try? fm.removeItem(at: root) }
    // this process's own first read measures alongside the child processes below: keep that measurement out of
    // the real cache
    DeviceProfileTesting.cacheDirectory = root.appendingPathComponent("parent")
    // the busy gate, with injected samples; this process then measures as if idle, whatever the machine is doing
    for (s, want) in [(DeviceProfile.IdleSample(gpuUtilization: [5, 5], loadAverage: 1, cpuCores: 10), true),
                      (DeviceProfile.IdleSample(gpuUtilization: [25, 5], loadAverage: 1, cpuCores: 10), false),
                      (DeviceProfile.IdleSample(gpuUtilization: [5, 20], loadAverage: 1, cpuCores: 10), false),
                      (DeviceProfile.IdleSample(gpuUtilization: [19, 19], loadAverage: 9.9, cpuCores: 10), true),
                      (DeviceProfile.IdleSample(gpuUtilization: [0, 0], loadAverage: 10, cpuCores: 10), false),
                      (DeviceProfile.IdleSample(gpuUtilization: [], loadAverage: nil, cpuCores: 6), true),
                      (DeviceProfile.IdleSample(gpuUtilization: [], loadAverage: nil, cpuCores: 6, thermalSerious: true), false),
                      (DeviceProfile.IdleSample(gpuUtilization: [], loadAverage: nil, cpuCores: 6, lowPowerMode: true), false)] {
        t.check(s.idle == want, "busy gate: \(s.summary) should be \(want ? "idle" : "busy")")
    }
    let real = DeviceProfileTesting.sampleNow(dev)
    t.check(real.gpuUtilization.count == 2 && real.loadAverage != nil, "real sample reads GPU utilization twice and the load: \(real.summary)")
    print("  busy gate on this machine now: \(real.summary) (\(real.idle ? "idle" : "busy"))")
    #if os(macOS)
    // the first Device Utilization read after a quiet stretch still holds the last busy period: it is discarded
    var reads = [89, 5, 6]
    DeviceProfileTesting.utilizationRead = { reads.isEmpty ? 0 : reads.removeFirst() }
    let staleRead = DeviceProfileTesting.sampleRaw(dev)
    DeviceProfileTesting.utilizationRead = nil
    // the GPU part only: the real sampler also reads this machine's load average, which a busy machine puts over
    // its core count, so idle is checked on the same utilization with the load held at 0
    let staleGPUIdle = DeviceProfile.IdleSample(gpuUtilization: staleRead.gpuUtilization, loadAverage: 0, cpuCores: staleRead.cpuCores).idle
    t.check(staleRead.gpuUtilization == [5, 6] && staleGPUIdle, "stale first utilization read (89%, then 5%, 6%) discarded: \(staleRead.summary)")
    #endif
    DeviceProfileTesting.idleSampler = { DeviceProfile.IdleSample(gpuUtilization: [0, 0], loadAverage: 0, cpuCores: 10) }
    // layer 1: deterministic, the same from a fresh computation, and the rules on reported properties
    let a = DeviceProfileTesting.fresh(dev), b = DeviceProfileTesting.fresh(dev), p = DeviceProfile.current
    for q in [b, p] {
        t.check(q.gpuName == a.gpuName && q.family == a.family && q.gpuCores == a.gpuCores && q.gpuCoresEstimated == a.gpuCoresEstimated
                && q.recommendedMaxWorkingSetSize == a.recommendedMaxWorkingSetSize && q.cpuPerformanceCores == a.cpuPerformanceCores
                && q.encoderPath == a.encoderPath && q.suggestedInFlight == a.suggestedInFlight && q.maxGPUBytes == a.maxGPUBytes
                && q.estimatedRouting == a.estimatedRouting, "layer 1 not deterministic: \(q.summary) against \(a.summary)")
    }
    // this process's own measurement (started by the first read above) finishes and is saved in its directory,
    // before the cache directory moves for the checks below
    // A real measurement on this machine: saved when measured; on a busy machine it can be rejected (implausible,
    // our own work not pausing), which caches nothing; an output mismatch fails the check.
    let m = p.measuredRouting(timeout: 30)
    let why = DeviceProfileTesting.failureReason(p)
    t.check((m != nil && p.routingSource == .measured && DeviceProfileTesting.loadCache(p) == m)
            || (m == nil && why != nil && !why!.contains("differ") && DeviceProfileTesting.loadCache(p) == nil),
            "real background measurement: \(m.map { "\($0)" } ?? why ?? "nothing")")
    t.check(a.maxGPUBytes == Int(Double(dev.recommendedMaxWorkingSetSize) * 0.5), "maxGPUBytes is not half the working set")
    t.check(a.estimatedRouting.measured == false, "estimate marked measured")
    let enc = Encoder()
    if ProcessInfo.processInfo.environment["EJM_FUSED_MAX_BLOCKS"] == nil {
        t.check((enc.fusedMaxBlocks == 0) == (a.encoderPath == .twoPass), "Encoder default fusedMaxBlocks \(enc.fusedMaxBlocks) against \(a.encoderPath)")
    }
    let m4 = DeviceProfileTesting.derive(name: "M4", family: .apple9, gpuCores: 8, workingSet: 12124 << 20, cpuCores: 4)
    t.check(m4.encoderPath == .twoPass && m4.suggestedInFlight == 3 && !m4.gpuCoresEstimated, "M4 rules: \(m4.summary)")
    let mx = DeviceProfileTesting.derive(name: "M1 Max", family: .apple7, gpuCores: 32, workingSet: 55_662_788_608, cpuCores: 8)
    t.check(mx.encoderPath == .fused && mx.suggestedInFlight == 3, "M1 Max rules: \(mx.summary)")
    let ip = DeviceProfileTesting.derive(name: "iPhone 13", family: .apple8, gpuCores: nil, workingSet: 2_863_311_530, cpuCores: 6)
    t.check(ip.encoderPath == .fused && ip.gpuCores == 4 && ip.gpuCoresEstimated && ip.suggestedInFlight == 2, "iPhone 13 rules: \(ip.summary)")
    let small = DeviceProfileTesting.derive(name: "7.9 GB", family: .apple9, gpuCores: 10, workingSet: 7_900 << 20, cpuCores: 4)
    t.check(small.suggestedInFlight == 2, "in flight below 8 GB: \(small.summary)")
    let tiny = DeviceProfileTesting.derive(name: "small", family: .apple8, gpuCores: 64, workingSet: 1 << 29, cpuCores: 2)
    t.check(tiny.suggestedInFlight == 1, "working-set cap: \(tiny.summary)")
    // routing advice: pinned numbers, monotonic in size
    let pinned = DeviceProfile.Routing(decodeFixedMs: 1, decodeMsPerMP: 0.1, encodeFixedMs: 0.5, encodeMsPerMP: 0.2, coldStartMs: 5, measured: false)
    p.pinRouting(pinned)
    t.check(p.routingSource == .pinned && p.routing == pinned, "pinRouting")
    t.check(p.prefersCPU(width: 100, height: 100, operation: .decode) && !p.prefersCPU(width: 4000, height: 3000, operation: .decode)
            && p.prefersCPU(width: 100, height: 100, operation: .encode) && !p.prefersCPU(width: 4000, height: 3000, operation: .encode)
            && !p.prefersCPU(width: 100, height: 100, operation: .decode, cpuMsPerMP: 1000), "prefersCPU against pinned numbers")
    p.pinRouting(nil)
    t.check(p.routingSource != .pinned, "unpin")
    // the measurement on injected timings (no GPU work while timingOverride is set), against the M4's estimate
    // (sustained decode 1.33 ms + 0.50 ms/MP, encode 0.29 ms + 0.56 ms/MP)
    let ctx = MetalContext.shared, est = m4.estimatedRouting
    func run(_ d: [Double], _ e: [Double]) -> DeviceProfileTesting.Measurement {
        DeviceProfileTesting.timingOverride = .init(decode: d, encode: e)
        defer { DeviceProfileTesting.timingOverride = nil }
        return DeviceProfileTesting.measure(ctx, estimate: est)
    }
    func show(_ m: DeviceProfileTesting.Measurement) -> String {
        m.sporadic.map { $0.costDescription + String(format: ", cold start %.2f", $0.coldStartMs) } ?? m.reason ?? "-"
    }
    let mpS = 256.0 * 256 / 1e6, mpL = 1600.0 * 1200 / 1e6
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    let se = m4.estimatedSporadicRouting
    func rise(_ r: DeviceProfile.Routing, _ op: DeviceProfile.Operation) -> Double {
        r.gpuMs(megapixels: mpL, operation: op) - r.gpuMs(megapixels: mpS, operation: op)
    }
    // median of 5 with one outlier each: the outlier (40 ms decode, 30 ms encode) does not move it; with no large
    // call timed, the rise from 256x256 to 1600x1200 is the estimate's and the curve passes through the 256x256
    // median
    let md = run([5.0, 5.2, 40, 4.8, 5.1], [1.0, 30, 1.1, 0.9, 1.05])
    t.check(md.sporadic.map { near($0.gpuMs(megapixels: mpS, operation: .decode), 5.1) && near($0.gpuMs(megapixels: mpS, operation: .encode), 1.05)
                && $0.coldStartMs == 5.0 && $0.measured && $0.measurementRounds == 5
                && abs(rise($0, .decode) - rise(se, .decode)) < 1e-6 && abs(rise($0, .encode) - rise(se, .encode)) < 1e-6
                && $0.ramp(.decode) != nil && $0.ramp(.encode) != nil } == true,
            "median of 5 with an outlier: \(show(md)) (want 5.1 and 1.05 at 256x256, cold start 5.0, the estimate's rise to 1600x1200)")
    // the cold ramp through one isolated 1600x1200 call and the small median: ramp 2.5 x the excess over the
    // sustained slope, D = large - small - sustained x 1.855 MP; the per-MP cost falls to the sustained one
    let ml = DeviceProfileTesting.measure(ctx, estimate: est, timings: .init(decode: [3.9, 4.11, 3.63, 4.0, 3.8], encode: [1.3, 1.47, 1.17, 1.25, 1.35],
                                                                              decodeLarge: 6.0, encodeLarge: 4.0))
    if let s = ml.sporadic, let rd = s.ramp(.decode), let re = s.ramp(.encode) {
        let dD = 6.0 - 3.9 - est.decodeMsPerMP * (mpL - mpS), dE = 4.0 - 1.3 - est.encodeMsPerMP * (mpL - mpS)
        let longD = s.gpuMs(megapixels: 31, operation: .decode) - s.gpuMs(megapixels: 30, operation: .decode)
        t.check(abs(s.gpuMs(megapixels: mpL, operation: .decode) - 6.0) < 1e-9 && abs(s.gpuMs(megapixels: mpS, operation: .decode) - 3.9) < 1e-9
                && abs(s.gpuMs(megapixels: mpL, operation: .encode) - 4.0) < 1e-9 && abs(s.gpuMs(megapixels: mpS, operation: .encode) - 1.3) < 1e-9
                && abs(rd.rampMs - 2.5 * dD) < 1e-9 && abs(re.rampMs - 2.5 * dE) < 1e-9 && rd.warmMsPerMP == est.decodeMsPerMP
                && re.warmMsPerMP == est.encodeMsPerMP && abs(longD - est.decodeMsPerMP) < 0.01,
                "cold ramp from the 1600x1200 call: \(show(ml)) (30-31 MP decode \(fmt(longD, 3)) ms/MP)")
    } else { t.check(false, "cold ramp measurement not used, or without a ramp: \(show(ml))") }
    // a chord over 6x the sustained slope (8x here: decode 4.0, encode 4.48 ms/MP) is held to 6x before the fit
    let mcap = DeviceProfileTesting.measure(ctx, estimate: est, timings: .init(decode: [3.9, 3.9, 3.9, 3.9, 3.9], encode: [1.3, 1.3, 1.3, 1.3, 1.3],
                                                                                decodeLarge: 3.9 + 8 * 0.5 * (mpL - mpS), encodeLarge: 1.3 + 8 * 0.56 * (mpL - mpS)))
    t.check(mcap.sporadic.map { abs(rise($0, .decode) - 6 * est.decodeMsPerMP * (mpL - mpS)) < 1e-9 && abs(rise($0, .encode) - 6 * est.encodeMsPerMP * (mpL - mpS)) < 1e-9 } == true,
            "chord cap: \(show(mcap))")
    // a large call faster than the sustained slope allows (degenerate: nothing to ramp): the old straight line at
    // the sustained slope; over 20x the sustained slope: rejected
    let mlo = DeviceProfileTesting.measure(ctx, estimate: est, timings: .init(decode: [4, 4, 4, 4, 4], encode: [1, 1, 1, 1, 1], decodeLarge: 3, encodeLarge: 1))
    t.check(mlo.sporadic.map { $0.decodeMsPerMP == est.decodeMsPerMP && $0.encodeMsPerMP == est.encodeMsPerMP && $0.ramp(.decode) == nil && $0.ramp(.encode) == nil } == true,
            "slope floor, no ramp: \(show(mlo))")
    // the estimate before measurement, on the M4: the M4's isolated calls at 2.8, 9.8 and 30 MP within 20%
    var repro: [String] = []
    for (op, pts) in [(DeviceProfile.Operation.decode, [(2048, 1365, 8.73), (3840, 2560, 12.38), (6720, 4480, 25.69), (6720, 4480, 28.5)]),
                      (.encode, [(2048, 1365, 6.48), (3840, 2560, 17.97), (6720, 4480, 26.65), (6720, 4480, 35.6)])] {
        for (k, (w, h, truth)) in pts.enumerated() {
            let mp = Double(w * h) / 1e6, model = se.gpuMs(megapixels: mp, operation: op), err = model / truth - 1
            repro.append("\(op) \(w)x\(h) \(fmt(model)) against \(truth) (\(fmt(err * 100, 0))%)")
            if k < 3 { t.check(abs(err) <= 0.20, "M4 cold estimate \(op) \(w)x\(h): \(fmt(model)) ms against isolated \(truth) (\(fmt(err * 100, 0))%)") }
        }
    }
    print("  M4 sporadic estimate: \(se.costDescription); isolated calls reproduced: \(repro.joined(separator: "; "))")
    let mhi = DeviceProfileTesting.measure(ctx, estimate: est, timings: .init(decode: [4, 4, 4, 4, 4], encode: [1, 1, 1, 1, 1], decodeLarge: 30, encodeLarge: 3))
    t.check(mhi.sporadic == nil && mhi.reason?.hasPrefix("implausible: cold per-MP") == true, "slope over 20x rejected: \(show(mhi))")
    // plausibility: the cold fixed cost is at least minColdFixedMs (no GPU round trip is faster, on any device) and at
    // most 20x the sustained estimate's fixed cost (decode 1.33, encode 0.29)
    for (d, e, what) in [([0.01, 0.01, 0.01, 0.01, 0.01], [1.0, 1.0, 1.0, 1.0, 1.0], "decode below minColdFixedMs"),
                         ([5.0, 5, 5, 5, 5], [0.02, 0.02, 0.02, 0.02, 0.02], "encode below minColdFixedMs"),
                         ([30.0, 30, 30, 30, 30], [1.0, 1.0, 1.0, 1.0, 1.0], "decode above 20x"),
                         ([5.0, 5, 5, 5, 5], [6.0, 6, 6, 6, 6], "encode above 20x")] {
        let m = run(d, e)
        t.check(m.sporadic == nil && m.reason?.hasPrefix("implausible") == true, "\(what) rejected: \(show(m))")
    }
    t.check(run([26.5, 26.5, 26.5, 26.5, 26.5], [0.29, 0.29, 0.29, 0.29, 0.29]).sporadic != nil, "at the bounds: accepted")
    t.check(run([1.0, 1.0, 1.0, 1.0, 1.0], [0.2, 0.2, 0.2, 0.2, 0.2]).sporadic != nil, "below the sustained estimate, above the floor: accepted")
    // the iOS sustained estimate against the iPhone 13 (A15, 4 cores): wall ms per image with two decoders or two
    // encoders kept busy, the minimum over three runs on 2026-11-18. Decode within 20% from 0.2 to 3.2 MP; encode,
    // whose small sizes do not lie on one line, only on which side of the default CPU rate (2.5 ms/MP) each size falls
    // except near the crossover (0.786 MP: CPU, 0.96 MP: GPU).
    let ios = DeviceProfileTesting.estimate(gpuCores: 4, coresEstimated: true)
    for (mp, ms) in [(0.234, 1.16), (0.307, 1.22), (0.786, 1.44), (1.92, 2.41), (3.146, 3.23)] {
        let m = ios.gpuMs(megapixels: mp, operation: .decode)
        t.check(abs(m / ms - 1) <= 0.20, "iPhone 13 sustained decode \(mp) MP: estimate \(fmt(m)) ms against measured \(ms)")
    }
    for (mp, ms) in [(0.066, 0.94), (0.234, 1.91), (0.307, 2.29), (0.786, 2.51), (0.96, 1.55), (1.92, 2.92), (2.796, 4.90)] {
        let m = ios.gpuMs(megapixels: mp, operation: .encode), cpu = DeviceProfile.defaultCPUEncodeMsPerMP * mp
        t.check((m < cpu) == (ms < cpu), "iPhone 13 sustained encode \(mp) MP: estimate \(fmt(m)) ms and measured \(ms) on the same side of the CPU's \(fmt(cpu))")
    }
    t.check(abs(ios.coldStartMs - 8.5) < 1e-9, "iOS cold start: the iPhone 13's measured 8.5 ms")
    // the iOS sporadic estimate reproduces the iPhone 13's isolated calls (its measured routing at 256x256 and 1600x1200)
    let iosSp = DeviceProfileTesting.sporadicEstimate(ios, ios: true)
    for (op, mp, ms) in [(DeviceProfile.Operation.decode, 0.065536, 7.5), (.decode, 1.92, 14.4), (.encode, 0.065536, 2.1), (.encode, 1.92, 12.1)] {
        let m = iosSp.gpuMs(megapixels: mp, operation: op)
        t.check(abs(m / ms - 1) <= 0.10, "iPhone 13 sporadic estimate \(op) \(mp) MP: \(fmt(m)) ms against isolated \(ms)")
    }
    // the iPhone 13 (A15) on 2026-11-18: its estimate's encode fixed cost (2.5 ms) is above its real cold one; the
    // measured median 2.305 ms was rejected as below the estimate. Now accepted, and the fitted fixed cost is the
    // measurement's, not clamped up to the estimate.
    let a15 = DeviceProfile.Routing(decodeFixedMs: 2.9, decodeMsPerMP: 1.0, encodeFixedMs: 2.5, encodeMsPerMP: 1.2, coldStartMs: 10, measured: false)
    let mphone = DeviceProfileTesting.measure(ctx, estimate: a15, timings: .init(decode: [3.8, 3.8, 3.8, 3.8, 3.8], encode: [2.305, 2.305, 2.305, 2.305, 2.305]))
    t.check(mphone.sporadic.map { $0.encodeFixedMs < 2.5 && $0.encodeFixedMs >= DeviceProfileTesting.minColdFixedMs } == true,
            "A15 cold encode 2.305 ms under its 2.5 ms estimate: accepted, fixed cost not clamped to the estimate: \(show(mphone))")
    // the sustained set is the estimate, never measured; prefersCPU follows the set the caller names
    t.check(p.sustainedRouting == p.estimatedRouting && !p.sustainedRouting.measured, "sustained is the estimate: \(p.sustainedRouting)")
    let slowR = DeviceProfile.Routing(decodeFixedMs: 6, decodeMsPerMP: 1.6, encodeFixedMs: 1.2, encodeMsPerMP: 2.0, coldStartMs: 9, measured: true)
    let warmR = DeviceProfile.Routing(decodeFixedMs: 1.5, decodeMsPerMP: 0.4, encodeFixedMs: 0.3, encodeMsPerMP: 0.5, coldStartMs: 9, measured: true)
    p.pinRouting(slowR, sustained: warmR)
    t.check(p.sporadicRouting == slowR && p.routing == slowR && p.sustainedRouting == warmR
            && p.prefersCPU(width: 1600, height: 1200, operation: .decode, cpuMsPerMP: 3.0, sustained: false, cpuWarm: true)
            && !p.prefersCPU(width: 1600, height: 1200, operation: .decode, cpuMsPerMP: 3.0, sustained: true, cpuWarm: true),
            "prefersCPU(sustained:) picks the set: 1600x1200 decode CPU 5.8 ms warm, sporadic 9.1, sustained 2.3")
    // a cold CPU: the caller's warm rate through the cold model (pinned to the default, ratio 4, ramp 18 ms):
    // 1600x1200 decode 5.8 ms warm, 16.8 cold, against sporadic GPU 9.1: the GPU
    p.pinCPUColdModel(DeviceProfile.defaultCPUColdModel)
    t.check(!p.prefersCPU(width: 1600, height: 1200, operation: .decode, cpuMsPerMP: 3.0, sustained: false, cpuWarm: false)
            && p.prefersCPU(width: 256, height: 256, operation: .decode, sustained: false, cpuWarm: false),
            "a cold CPU applies the cold model to the caller's warm rate")
    t.check(p.cpuColdModel == DeviceProfile.defaultCPUColdModel && p.summary.contains("CPU cold model (pinned) ratio 4.00, ramp 18.0 ms"), "pinned CPU model: \(p.summary)")
    p.pinCPUColdModel(nil)
    p.pinRouting(nil)
    checkWarmth(t, m4, ctx)
    // the busy gate waits for our own GPU work to pause for 1 s before sampling, and defers when it does not
    var quietAtSample: [Double] = []
    let gp = DeviceProfileTesting.derive(name: "gate", family: a.family, gpuCores: a.gpuCores, workingSet: a.recommendedMaxWorkingSetSize, cpuCores: 1)
    DeviceProfileTesting.idleSampler = { quietAtSample.append(DeviceProfileTesting.ownGPUQuietSeconds); return idleSample }
    let jg = apiFiles()[20].data          // 640x480 4:2:0
    let dq = Decoder()
    _ = dq.decode(jg)
    t.check(DeviceProfileTesting.runGate(gp) && quietAtSample.count == 1 && quietAtSample[0] >= 1.0,
            "gate sampled \(quietAtSample.first.map { fmt($0, 3) } ?? "never") s after our last GPU work (want >= 1.0)")
    let stop = Slot(false)
    let started = Slot(false)
    let busyThread = Thread { let d = Decoder(); while !stop.value { _ = d.decode(jg); started.value = true } }
    busyThread.start()
    while !started.value { Thread.sleep(forTimeInterval: 0.005) }      // our own work is running
    let tg = now()
    let ok = DeviceProfileTesting.runGate(gp)
    let waited = now() - tg
    stop.value = true
    t.check(!ok && quietAtSample.count == 1 && waited >= 1.9 && (DeviceProfileTesting.failureReason(gp) ?? "").contains("own GPU work"),
            "gate with our own work running: deferred after \(fmt(waited, 2)) s without sampling (\(DeviceProfileTesting.failureReason(gp) ?? "-"))")
    while !busyThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
    DeviceProfileTesting.idleSampler = { DeviceProfile.IdleSample(gpuUtilization: [0, 0], loadAverage: 0, cpuCores: 10) }
    // cache round trip, corrupt and stale files, in a scratch directory
    let saved = DeviceProfileTesting.cacheDirectory
    let d0 = root.appendingPathComponent("roundtrip")
    DeviceProfileTesting.cacheDirectory = d0
    DeviceProfileTesting.saveCache(seeded, a)
    t.check(DeviceProfileTesting.loadCache(a) == seeded && DeviceProfileTesting.loadCPUCache(a) == nil, "cache round trip")
    let cm = DeviceProfile.CPUColdModel(ratio: 3.25, rampMs: 21.5, measured: true, measurementMs: 37)
    DeviceProfileTesting.saveCache(seeded, cpu: cm, a)
    t.check(DeviceProfileTesting.loadCache(a) == seeded && DeviceProfileTesting.loadCPUCache(a) == cm
            && DeviceProfileTesting.cacheKey(a).hasSuffix("|routing-v5"), "cache round trip with the CPU cold model, key routing-v5")
    let cbad = DeviceProfile.CPUColdModel(ratio: 40, rampMs: 21.5, measured: true)
    DeviceProfileTesting.saveCache(seeded, cpu: cbad, a)
    t.check(DeviceProfileTesting.loadCache(a) == nil, "a cache entry with an implausible CPU model is ignored")
    // a re-measure replaces the CPU model whole with the newer valid fit, never a max of two runs' fields: a bad
    // first fit (ratio 9.5) goes at the next one
    let newerCPU = DeviceProfile.CPUColdModel(ratio: 2.5, rampMs: 30, measured: true, measurementMs: 41)
    let badFirst = DeviceProfile.CPUColdModel(ratio: 9.5, rampMs: 4, measured: true, measurementMs: 40)
    let cmg = DeviceProfileTesting.mergeCPU(cm, newerCPU)
    t.check(cmg == newerCPU && DeviceProfileTesting.mergeCPU(badFirst, newerCPU) == newerCPU
            && DeviceProfileTesting.mergeCPU(nil, cm) == cm && DeviceProfileTesting.mergeCPU(cm, nil) == cm
            && DeviceProfileTesting.mergeCPU(cm, cbad) == cm,
            "CPU model merge replaces, not ratchets: \(cmg.map { "\($0)" } ?? "nil")")
    DeviceProfileTesting.saveCache(seeded, a)
    let f = DeviceProfileTesting.cacheFile(a)!
    try? Data("{\"key\": 1, garbage".utf8).write(to: f)
    t.check(DeviceProfileTesting.loadCache(a) == nil, "corrupt cache file read")
    let stale = DeviceProfileTesting.derive(name: a.gpuName + " other", family: a.family, gpuCores: a.gpuCores, workingSet: 1, cpuCores: 1)
    DeviceProfileTesting.saveCache(seeded, stale)
    if let sf = DeviceProfileTesting.cacheFile(stale) { try? fm.removeItem(at: f); try? fm.copyItem(at: sf, to: f) }
    t.check(DeviceProfileTesting.loadCache(a) == nil, "stale cache file (another key) read")
    // merge by minimum, and the 24-hour gate with an injected clock
    let newer = DeviceProfile.Routing(decodeFixedMs: 0.8, decodeMsPerMP: 0.9, encodeFixedMs: 1.0, encodeMsPerMP: 0.1, coldStartMs: 6, measured: true,
                                      measurementMs: 99, measurementGPUMs: 50)
    let mg = DeviceProfileTesting.merge(seeded, newer)
    t.check(mg == DeviceProfile.Routing(decodeFixedMs: 0.8, decodeMsPerMP: 0.5, encodeFixedMs: 0.75, encodeMsPerMP: 0.1, coldStartMs: 5,
                                        measured: true, measurementMs: 99, measurementGPUMs: 50), "merge is not the field-by-field minimum: \(mg)")
    let savedClock = DeviceProfileTesting.clock
    let T = Date(timeIntervalSince1970: 1_800_000_000)
    DeviceProfileTesting.clock = { T }
    for (measuredAgo, attemptAgo, due) in [(25.0, 25.0, true), (23.0, 23.0, false), (48.0, 1.0, false), (24.0, 24.0, true)] {
        DeviceProfileTesting.saveEntry(seeded, a, merges: 2, lastMeasured: T - measuredAgo * 3600, lastAttempt: T - attemptAgo * 3600)
        t.check(DeviceProfileTesting.remeasureDue(a) == due, "gate: measured \(measuredAgo) h, tried \(attemptAgo) h ago: due should be \(due)")
    }
    DeviceProfileTesting.saveCache(seeded, a)                 // a first save is stamped with the clock
    let fe = DeviceProfileTesting.entry(a)
    t.check(fe?.merges == 0 && fe?.lastMeasured == T && DeviceProfileTesting.remeasureDue(a) == false, "first save: merges 0, dated by the clock")
    DeviceProfileTesting.clock = { T + 24 * 3600 }
    t.check(DeviceProfileTesting.remeasureDue(a) == true, "gate: 24 h after the first save")
    DeviceProfileTesting.clock = savedClock
    try? Data("{\"key\": 2, garbage".utf8).write(to: f)
    t.check(DeviceProfileTesting.entry(a) == nil && DeviceProfileTesting.remeasureDue(a) == nil, "corrupt cache file read by the merge path")
    DeviceProfile.clearCache()
    t.check(((try? fm.contentsOfDirectory(atPath: d0.path)) ?? ["?"]).isEmpty, "clearCache left files")
    DeviceProfileTesting.cacheDirectory = saved
    // first reads in child processes: EJM_PROFILE_CACHE=0, a seeded cache, a corrupt one, an unwritable directory
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let blocker = root.appendingPathComponent("file")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: blocker)
    for mode in ["nocache", "cache", "corrupt", "stale", "recent", "busy", "busystale", "implausible", "cpuonly", "unwritable", "loadoff"] {
        let dir = mode == "unwritable" ? blocker.appendingPathComponent("cache") : root.appendingPathComponent(mode)
        if mode != "unwritable" {
            DeviceProfileTesting.cacheDirectory = dir
            if mode == "stale" || mode == "recent" || mode == "busystale" {
                DeviceProfileTesting.saveEntry(staleSeed, a, merges: 3, lastMeasured: Date() - (mode == "recent" ? 1 : 25) * 3600)
            } else if !["busy", "implausible", "cpuonly"].contains(mode) { DeviceProfileTesting.saveCache(seeded, a) }
            if mode == "corrupt", let cf = DeviceProfileTesting.cacheFile(a) { try? Data([0xFF, 0x00, 0x7B]).write(to: cf) }
            DeviceProfileTesting.cacheDirectory = saved
        }
        let pr = Process()
        pr.executableURL = exe
        pr.arguments = ["profile-child", "\(mode):\(dir.path)"]
        var env = ProcessInfo.processInfo.environment
        env["EJM_PROFILE_CACHE"] = mode == "nocache" ? "0" : nil
        env["EJM_LOAD_CORRECTION"] = mode == "loadoff" ? "0" : nil
        pr.environment = env
        let pipe = Pipe()
        pr.standardOutput = pipe
        do { try pr.run() } catch { t.check(false, "cannot start \(exe.path): \(error)"); continue }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pr.waitUntilExit()
        let lines = out.split(separator: "\n")
        for l in lines { t.check(l.hasPrefix("OK "), "child: \(l)") }
        t.check(pr.terminationStatus == 0 && !lines.isEmpty, "\(mode) child exited with \(pr.terminationStatus)")
        print("  \(mode) child: \(lines.filter { $0.hasPrefix("OK ") }.count) of \(lines.count) OK")
    }
    print("  layer 1: \(a.summary)")
    if m == nil { print("  this process's real measurement: not used (\(why ?? "?"))") }
    let pc = p.cpuColdModel
    print("  CPU cold model: " + (pc.measured ? "measured ratio \(fmt(pc.ratio)), ramp \(fmt(pc.rampMs, 1)) ms, proxy \(fmt(pc.measurementMs, 1)) ms CPU" : "default (\(DeviceProfileTesting.cpuFailureReason(p) ?? "not measured"))"))
    if let m { print(String(format: "  measured: decode %.2f ms + %.3f ms/MP, encode %.2f ms + %.3f ms/MP; cost %.0f ms wall, %.0f ms GPU",
                            m.decodeFixedMs, m.decodeMsPerMP, m.encodeFixedMs, m.encodeMsPerMP, m.measurementMs, m.measurementGPUMs)) }
}

func runAPICheck(_ names: [String]) -> Bool {
    let checks = ["eager-range", "warmup", "decline-untouched", "gray-rgba", "header-limits", "formats", "c-api", "output", "icc", "tuning",
                  "self-check", "device-profile", "trace", "encoder-limits", "exactness-record", "device-refs", "selfcheck-cases"] + decoderAuditChecks.map(\.name) + usageChecks.map(\.name)
    setvbuf(stdout, nil, _IOLBF, 0)             // keep the output of a check that crashes
    let run = names.isEmpty ? checks : names
    if let u = run.first(where: { !checks.contains($0) }) { print("unknown check \(u); checks: \(checks.joined(separator: " "))"); return false }
    print("reference: \(Turbo.version)")
    let files = apiFiles()
    var failed: [String] = [], skipped = 0
    for name in run {
        let t = Tally(), t0 = now()
        switch name {
        case "eager-range": checkEagerRange(t, files)
        case "warmup": checkWarmUp(t, files)
        case "decline-untouched": checkDeclineUntouched(t)
        case "gray-rgba": checkGrayRGBA(t, files)
        case "header-limits": checkHeaderLimits(t)
        case "formats": checkFormats(t, files)
        case "c-api": checkCAPI(t, files)
        case "output": checkOutput(t, files)
        case "icc": checkICC(t)
        case "self-check": checkSelfCheck(t)
        case "device-profile": checkDeviceProfile(t)
        case "trace": checkTrace(t, files)
        case "encoder-limits": checkEncoderLimits(t)
        case "exactness-record": checkExactnessRecord(t)
        case "device-refs": checkDeviceRefs(t)
        case "selfcheck-cases": checkSelfCheckCases(t)
        case let n where decoderAuditChecks.contains { $0.name == n }: decoderAuditChecks.first { $0.name == n }!.run(t)
        case let n where usageChecks.contains { $0.name == n }: usageChecks.first { $0.name == n }!.run(t)
        default: checkTuning(t, files)
        }
        print("\(t.bad == 0 ? "PASS" : "FAIL") \(name): \(t.ok) checks passed, \(t.bad) failed\(t.skipped > 0 ? ", \(t.skipped) SKIPPED" : "") (\(fmt(now() - t0, 1)) s)")
        skipped += t.skipped
        if t.bad > 0 { failed.append(name) }
    }
    print("api-check: skipped cases \(skipped) (could not run on this machine; not failures)")
    print(failed.isEmpty ? "api-check: all \(run.count) checks passed" : "api-check: FAILED \(failed.joined(separator: ", "))")
    return failed.isEmpty
}

/// The M4's ground truth (2026-11-17, M4 MacBook Air, ExactJPEG and libjpeg-turbo 3.2.1 at 1 thread; decode q95
/// 4:2:2, encode q90 4:4:4; median of 5 single calls, ms). Cold: 300 ms with no work on that side; warm: 200 ms of
/// the same operation on that side just before (in warm/warm the GPU and CPU calls alternated). Each cell is GPU,
/// CPU; the states are (GPU warm, CPU warm): cold/cold, GPU warm/CPU cold, GPU cold/CPU warm, warm/warm. The
/// 3840x2560 and 6720x4480 rows and the second 2048x1365 GPU cold/CPU warm cells (nil: not in that run) are a
/// later run of the same harness.
let m4Fixture: [(w: Int, h: Int, op: DeviceProfile.Operation, cells: [(gpu: Double, cpu: Double)?])] = [
    (256, 256, .decode, [(4.11, 0.74), (3.24, 1.25), (3.63, 0.16), (3.45, 0.58)]),
    (256, 256, .encode, [(1.47, 1.23), (0.85, 0.66), (1.17, 0.14), (0.81, 0.48)]),
    (640, 480, .decode, [(3.01, 2.61), (2.54, 4.02), (4.22, 0.82), (4.27, 2.11)]),
    (640, 480, .encode, [(2.64, 2.68), (1.48, 2.65), (1.85, 0.77), (1.67, 1.86)]),
    (1024, 768, .decode, [(5.71, 6.12), (4.32, 7.48), (5.38, 2.14), (3.35, 3.49)]),
    (1024, 768, .encode, [(3.70, 9.70), (3.05, 7.43), (3.13, 1.97), (2.32, 2.75)]),
    (1600, 1200, .decode, [(7.81, 13.37), (3.89, 14.75), (7.51, 5.07), (4.52, 6.12)]),
    (1600, 1200, .encode, [(6.40, 14.07), (6.51, 16.60), (5.64, 4.62), (3.67, 5.55)]),
    (2048, 1365, .decode, [(9.30, 19.22), (4.66, 20.15), (8.74, 7.31), (5.31, 7.88)]),
    (2048, 1365, .encode, [(8.55, 19.84), (9.04, 16.99), (5.59, 6.67), (4.30, 7.10)]),
    (2048, 1365, .decode, [nil, nil, (8.73, 7.36), nil]),
    (2048, 1365, .encode, [nil, nil, (6.48, 6.67), nil]),
    (3840, 2560, .decode, [(12.31, 49.69), (8.21, 52.55), (12.38, 25.26), (9.15, 25.04)]),
    (3840, 2560, .encode, [(21.28, 43.62), (13.01, 42.69), (17.97, 23.43), (11.29, 23.17)]),
    (6720, 4480, .decode, [(28.50, 101.75), (16.06, 107.09), (25.69, 75.77), (21.47, 74.68)]),
    (6720, 4480, .encode, [(35.56, 101.69), (20.55, 89.18), (26.65, 70.68), (17.45, 70.53)]),
]
let warmthStates = [(false, false), (true, false), (false, true), (true, true)]
let warmthNames = ["cold/cold", "GPU warm/CPU cold", "GPU cold/CPU warm", "warm/warm"]

/// warmth tracking, the CPU proxy fit, the M4 fixture and the overrides
private func checkWarmth(_ t: Tally, _ m4: DeviceProfile, _ ctx: MetalContext) {
    defer {
        DeviceProfileTesting.warmthClock = nil; DeviceProfileTesting.processCPUTime = nil; DeviceProfileTesting.gpuActivity = nil
        DeviceProfileTesting.resetWarmth()
    }
    // the GPU side follows this process's own command buffers: warm within 250 ms of the last, and while one runs
    let jg = apiFiles()[20].data          // 640x480 4:2:0
    _ = Decoder().decode(jg)
    let last = DeviceProfileTesting.realGPUActivity.lastEnd
    DeviceProfileTesting.processCPUTime = { 1.0 }          // no process CPU signal
    DeviceProfileTesting.warmthClock = { last + 0.1 }
    let w1 = DeviceProfile.currentWarmth
    DeviceProfileTesting.warmthClock = { last + 0.3 }
    let w2 = DeviceProfile.currentWarmth
    DeviceProfileTesting.gpuWorkBegin()
    DeviceProfileTesting.warmthClock = { last + 10 }
    let w3 = DeviceProfile.currentWarmth
    DeviceProfileTesting.gpuWorkEnd()
    t.check(abs(DeviceProfileTesting.monotonicNow - last) < 5, "GPU activity stamps are on the monotonic clock (\(last) against \(DeviceProfileTesting.monotonicNow))")
    // a clock step backward (only an injected clock can give one now): reads cold, not warm for the length of the step
    DeviceProfileTesting.warmthClock = { last - 3600 }
    let wb = DeviceProfile.currentWarmth
    t.check(!wb.gpuWarm && wb.gpuIdleSeconds == nil, "GPU warmth after a backward clock step: \(wb)")
    t.check(last > 0 && w1.gpuWarm && abs((w1.gpuIdleSeconds ?? -1) - 0.1) < 1e-6 && !w2.gpuWarm && w3.gpuWarm && w3.gpuInFlight && w3.gpuIdleSeconds == 0,
            "GPU warmth from our command buffers: 0.1 s \(w1), 0.3 s \(w2), in flight \(w3)")
    // the CPU side: noteCPUWork within 250 ms
    DeviceProfileTesting.resetWarmth()
    let T = 1_000_000.0
    DeviceProfileTesting.gpuActivity = { (0, 0) }
    DeviceProfileTesting.warmthClock = { T }
    let c0 = DeviceProfile.currentWarmth
    DeviceProfile.noteCPUWork()
    DeviceProfileTesting.warmthClock = { T + 0.2 }
    let c1 = DeviceProfile.currentWarmth
    DeviceProfileTesting.warmthClock = { T + 0.3 }
    let c2 = DeviceProfile.currentWarmth
    DeviceProfileTesting.warmthClock = { T - 3600 }
    let cb = DeviceProfile.currentWarmth
    t.check(!cb.cpuWarm && cb.cpuIdleSeconds == nil, "CPU warmth after a backward clock step: \(cb)")
    t.check(!c0.cpuWarm && c0.cpuIdleSeconds == nil && !c0.gpuWarm && c0.gpuIdleSeconds == nil && c1.cpuWarm && abs((c1.cpuIdleSeconds ?? -1) - 0.2) < 1e-6
            && !c2.cpuWarm, "CPU warmth from noteCPUWork: never \(c0); 0.2 s \(c1); 0.3 s \(c2)")
    // and the process's CPU time: over half a core across the last window (0.05-1 s) counts as warm
    DeviceProfileTesting.resetWarmth()
    var cpuNow = 5.0
    DeviceProfileTesting.processCPUTime = { cpuNow }
    func at(_ dt: Double, _ cpu: Double) -> DeviceProfile.Warmth { cpuNow = cpu; DeviceProfileTesting.warmthClock = { T + dt }; return DeviceProfile.currentWarmth }
    let r0 = at(0, 5.0), r1 = at(0.25, 5.2), r2 = at(0.5, 5.21), r3 = at(0.52, 5.3), r4 = at(3.0, 9.0)
    t.check(!r0.cpuWarm && r0.processCPUCores == nil && r1.cpuWarm && abs((r1.processCPUCores ?? 0) - 0.8) < 1e-6 && !r2.cpuWarm
            && abs((r2.processCPUCores ?? 0) - 0.04) < 1e-6 && r3.processCPUCores == nil && !r4.cpuWarm && r4.processCPUCores == nil,
            "CPU warmth from the process CPU time: \(r0) | \(r1) | \(r2) | \(r3) | \(r4)")
    // busy then idle: 0.55 s of CPU in the first 0.55 s, then idle; read at 0.6 s the window is over 0.25 s old,
    // so it restarts (cold), and 0.1 s later the window shows the idle (cold); a 1 s window would read 0.92 cores
    DeviceProfileTesting.resetWarmth()
    let b0 = at(10, 0), b1 = at(10.6, 0.55), b2 = at(10.7, 0.55)
    t.check(b0.processCPUCores == nil && !b1.cpuWarm && b1.processCPUCores == nil && !b2.cpuWarm && b2.processCPUCores == 0,
            "busy then idle reads cold after 0.25 s: \(b1) | \(b2)")
    // a backward step in the CPU-time window: the reference restarts
    let bk = at(9.0, 9.9)
    t.check(!bk.cpuWarm && bk.processCPUCores == nil, "CPU-time window after a backward clock step: \(bk)")
    // the library's own CPU proxy run is not the caller's CPU activity: skipped while it runs, window restarted after
    DeviceProfileTesting.resetWarmth()
    let x0 = at(20, 1.0)
    DeviceProfileTesting.proxyRunBegin()
    let x1 = at(20.1, 1.09)
    DeviceProfileTesting.proxyRunEnd()
    let x2 = at(20.15, 1.09), x3 = at(20.25, 1.091)
    t.check(x0.processCPUCores == nil && x1.processCPUCores == nil && !x1.cpuWarm && x2.processCPUCores == nil
            && abs((x3.processCPUCores ?? -1) - 0.01) < 1e-6 && !x3.cpuWarm, "proxy run excluded from the CPU time: \(x1) | \(x2) | \(x3)")
    DeviceProfileTesting.processCPUTime = { 1.0 }

    // load correction: observed / predicted per kind of call (device, side, operation, starting state, size),
    // weighted, fading back to 1 (half-life 8 s), a 1.25x dead zone, applied once the caller reported a CPU job
    do {
        var tl = 1000.0
        DeviceProfileTesting.loadCorrectionClock = { tl }
        DeviceProfileTesting.resetLoadCorrection()
        defer { DeviceProfileTesting.resetLoadCorrection(); DeviceProfileTesting.loadCorrectionClock = nil }
        let lp = DeviceProfile.current
        func f(_ op: DeviceProfile.Operation, _ mp: Double, _ set: DeviceProfile.GPUSet, cpuWarm: Bool = true) -> DeviceProfile.LoadFactors {
            let w = Int((mp * 1e6).squareRoot()); return lp.loadFactors(width: w, height: w, operation: op, gpuSet: set, cpuWarm: cpuWarm)
        }
        for _ in 0..<5 { DeviceProfileTesting.addLoadSample(lp, cpu: false, .decode, state: 1, megapixels: 2, observedMs: 30, predictedMs: 10) }
        t.check(f(.decode, 2, .warm) == DeviceProfile.LoadFactors(gpu: 1, cpu: 1), "GPU samples alone apply nothing until the caller reports a CPU job: \(f(.decode, 2, .warm))")
        DeviceProfileTesting.resetLoadCorrection()
        DeviceProfileTesting.addLoadSample(lp, cpu: true, .decode, state: 1, megapixels: 0.01, observedMs: 1, predictedMs: 1)   // a CPU job reported
        DeviceProfileTesting.addLoadSample(lp, cpu: false, .decode, state: 1, megapixels: 2, observedMs: 30, predictedMs: 10)
        let one = f(.decode, 2, .warm).gpu
        // with the 1.25x dead zone: one 3x sample (a third of full weight) applies e^(ln 3 / 3 - ln 1.25) = 1.15x
        t.check(abs(one - 1.15) < 0.02, "one 3x sample moves the factor only partly (\(fmt(one)), expected 1.15)")
        for _ in 0..<4 { DeviceProfileTesting.addLoadSample(lp, cpu: false, .decode, state: 1, megapixels: 2, observedMs: 30, predictedMs: 10) }
        t.check(abs(f(.decode, 2, .warm).gpu - 2.4) < 0.05 && f(.decode, 0.3, .warm).gpu == 1 && f(.decode, 2, .sporadic).gpu == 1
                && f(.encode, 2, .warm).gpu == 1 && f(.decode, 2, .warm).cpu == 1 && f(.decode, 2, .sustained).gpu == 1,
                "five 3x samples on warm 2 MP GPU decodes: that kind 2.4x (3x past the dead zone); small images, the cold GPU, encodes, the CPU and the sustained set stay 1")
        let other = DeviceProfileTesting.derive(name: "other", family: .apple9, gpuCores: 8, workingSet: 11_453_251_584, cpuCores: 4)
        t.check(other.loadFactors(width: 1414, height: 1414, operation: .decode, gpuSet: .warm, cpuWarm: true).gpu == 1,
                "factors belong to a device: another profile (a what-if) is not corrected")
        for _ in 0..<3 { DeviceProfileTesting.addLoadSample(lp, cpu: true, .encode, state: 0, megapixels: 0.3, observedMs: 1000, predictedMs: 1) }
        t.check(abs(f(.encode, 0.3, .warm, cpuWarm: false).cpu - 3.2) < 1e-9, "samples clamp at 4x, 3.2x past the dead zone: \(fmt(f(.encode, 0.3, .warm, cpuWarm: false).cpu))")
        for _ in 0..<5 { DeviceProfileTesting.addLoadSample(lp, cpu: true, .decode, state: 1, megapixels: 2, observedMs: 12, predictedMs: 10) }
        t.check(f(.decode, 2, .warm).cpu == 1, "idle-level drift (1.2x) stays inside the dead zone: \(fmt(f(.decode, 2, .warm).cpu))")
        tl += 8
        let half = f(.decode, 2, .warm).gpu
        tl += 60
        let gone = f(.decode, 2, .warm).gpu
        t.check(half > 1.5 && half < 2.4 && abs(gone - 1) < 0.05, "the factor fades: after 8 s \(fmt(half)), after 68 s \(fmt(gone))")
        DeviceProfile.loadCorrectionEnabled = false
        t.check(DeviceProfile.loadCorrectionEnabled == false && f(.encode, 0.3, .warm, cpuWarm: false).cpu == 1, "loadCorrectionEnabled false: factors 1")
        DeviceProfile.loadCorrectionEnabled = true
        // a decision follows the factors (warm GPU set, warm CPU, on this device's profile)
        DeviceProfileTesting.resetLoadCorrection()
        DeviceProfileTesting.addLoadSample(lp, cpu: true, .encode, state: 1, megapixels: 0.01, observedMs: 1, predictedMs: 1)
        let mp2 = 2.0
        let gpu2 = lp.warmRouting.gpuMs(megapixels: mp2, operation: .decode)
        let rate = 0.8 * gpu2 / mp2 / 1.2          // a CPU rate that makes the GPU win by a clear margin, at 1.25x
        let before = lp.routingDecision(width: 1414, height: 1414, operation: .decode, cpuMsPerMP: rate, sustained: nil, cpuWarm: true)
        for _ in 0..<5 { DeviceProfileTesting.addLoadSample(lp, cpu: false, .decode, state: 1, megapixels: mp2, observedMs: 40, predictedMs: 10) }
        let after = lp.routingDecision(width: 1414, height: 1414, operation: .decode, cpuMsPerMP: rate, sustained: nil, cpuWarm: true)
        t.check(before.gpuSet != .warm || (!before.prefersCPU && after.prefersCPU && abs(after.loadFactors.gpu - 3.2) < 0.05),
                "advice follows the load: GPU \(fmt(before.predictedGPUms)) against CPU \(fmt(before.predictedCPUms)) ms; with the GPU 4x slow \(fmt(after.predictedGPUms)) against \(fmt(after.predictedCPUms)) (set \(before.gpuSet))")
    }
    // the wiring, deterministic: which calls become samples (start / finish as the decoder and encoder use them)
    do {
        let savedClock = DeviceProfileTesting.warmthClock, savedGPU = DeviceProfileTesting.gpuActivity
        DeviceProfileTesting.warmthClock = nil; DeviceProfileTesting.gpuActivity = nil
        DeviceProfileTesting.resetLoadCorrection()
        defer { DeviceProfileTesting.resetLoadCorrection(); DeviceProfileTesting.warmthClock = savedClock; DeviceProfileTesting.gpuActivity = savedGPU }
        let dev = MetalContext.shared.device
        let alone = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5)
        let tracked = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5, trackedInside: true)
        let setup = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5, setupInside: true)
        let overlapping = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5, overlappingCall: true)
        let after = DeviceProfileTesting.simulateCall(dev, width: 1000, height: 1000, ms: 5)
        t.check(alone == 1 && tracked == 0 && setup == 0 && overlapping == 0 && after == 1,
                "a call alone is a sample (\(alone)); with untracked GPU work of this process inside (an encode batch, calibration: \(tracked)), setup work inside (\(setup)) or another public call overlapping (\(overlapping)) it is not; the next call alone is again (\(after))")
        // real calls: a decode and an encode are one sample each (the profile's measurement done first, so no
        // calibration call of the library overlaps them)
        _ = DeviceProfile.current.measuredRouting(timeout: 30)
        let px = [UInt8](repeating: 100, count: 1024 * 768 * 3)
        let enc = Encoder(), dec = Decoder()
        let jpg = try! px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }
        _ = try! px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }
        _ = dec.decode(jpg)                                       // setup: buffers sized
        let n0 = DeviceProfileTesting.loadSampleCount
        _ = dec.decode(jpg)
        let n1 = DeviceProfileTesting.loadSampleCount
        _ = try! px.withUnsafeBytes { try enc.encode(bytes: $0, width: 1024, height: 768, quality: 90) }
        let n2 = DeviceProfileTesting.loadSampleCount
        let fresh = Decoder()
        _ = fresh.decode(jpg)                                     // a new decoder's first call allocates: setup
        let n3 = DeviceProfileTesting.loadSampleCount
        _ = DeviceProfileTesting.measure(MetalContext.shared)     // the library's own calibration calls (internalUse)
        let n4 = DeviceProfileTesting.loadSampleCount
        t.check(n1 - n0 == 1 && n2 - n1 == 1 && n3 == n2 && n4 == n3,
                "real calls: a decode and an encode are one sample each (\(n1 - n0), \(n2 - n1)); a new decoder's first call (setup, \(n3 - n2)) and the library's own calibration (\(n4 - n3)) are none")
        #if os(macOS)
        // the background device reads: a decode does not start them, a warmth query does (both after the GPU has
        // been idle long enough that this process's own work no longer makes it warm)
        let stopped = DeviceProfileTesting.stopDeviceActivityPolling()
        Thread.sleep(forTimeInterval: 0.4)
        _ = dec.decode(jpg)
        let fromDecode = DeviceProfileTesting.deviceActivityPolling
        _ = DeviceProfileTesting.stopDeviceActivityPolling()
        Thread.sleep(forTimeInterval: 0.4)
        _ = DeviceProfile.currentWarmth
        let fromQuery = DeviceProfileTesting.deviceActivityPolling
        t.check(stopped && !fromDecode && fromQuery, "a decode does not start the background device reads (\(fromDecode)); a warmth query does (\(fromQuery))")
        // turning load correction off stops reads already running (they ran on for up to 5 s before 2026-11-19)
        DeviceProfile.loadCorrectionEnabled = false
        let t0 = now()
        while DeviceProfileTesting.deviceActivityPolling && now() - t0 < 1.0 { Thread.sleep(forTimeInterval: 0.01) }
        let offStopped = !DeviceProfileTesting.deviceActivityPolling, offAfter = now() - t0
        DeviceProfile.loadCorrectionEnabled = true
        Thread.sleep(forTimeInterval: 0.3)
        t.check(offStopped && !DeviceProfileTesting.deviceActivityPolling,
                "loadCorrectionEnabled = false stops the running device reads within 1 s (\(offStopped ? fmt(offAfter) + " s" : "still running")), and turning it on again does not restart them")
        // a traced call's trace line reads the routing advice without starting them (a declined call: no GPU work, so
        // this process's own work does not make the GPU warm)
        _ = DeviceProfileTesting.stopDeviceActivityPolling()
        Thread.sleep(forTimeInterval: 0.4)
        let savedTrace = MetalContext.trace
        var lines = 0
        MetalContext.trace = { _ in lines += 1 }
        let tooShort = claimSize(jpg, 8000, 8000)
        _ = dec.decode(tooShort)
        MetalContext.trace = savedTrace
        let fromTrace = DeviceProfileTesting.deviceActivityPolling
        _ = DeviceProfileTesting.stopDeviceActivityPolling()
        t.check(lines == 1 && !fromTrace, "a traced call (\(lines) line) does not start the background device reads (\(fromTrace))")
        #endif
        // a call that retried inside (a decode's second attempt with 64 passes, an encode resubmitted for capacity)
        // is no sample: its time is not one attempt's
        do {
            let noise = Turbo.encode(corpusContent(1600, 1200, "noise", 91), 1600, 1200, quality: 95, samp: 0)
            let rd = Decoder()
            rd.eagerPasses = 1
            _ = rd.decode(noise); _ = rd.decode(noise)            // setup done
            let m0 = DeviceProfileTesting.loadSampleCount
            let ok = rd.decode(noise) != nil
            let m1 = DeviceProfileTesting.loadSampleCount
            t.check(ok && rd.passes > 1, "the retry decode needs more than one pass (\(rd.passes), \(rd.reason ?? "ok"))")
            let npx = corpusContent(1024, 768, "noise", 92)
            let re = Encoder()
            _ = try? npx.withUnsafeBytes { try re.encode(bytes: $0, width: 1024, height: 768, quality: 100, subsampling: .s444) }
            _ = try? npx.withUnsafeBytes { try re.encode(bytes: $0, width: 1024, height: 768, quality: 100, subsampling: .s444) }
            let r0 = re.retries
            re.bytesPerBlockEstimateForTesting = 1                 // far too small: the image is resubmitted
            let m2 = DeviceProfileTesting.loadSampleCount
            _ = try? npx.withUnsafeBytes { try re.encode(bytes: $0, width: 1024, height: 768, quality: 100, subsampling: .s444) }
            let m3 = DeviceProfileTesting.loadSampleCount
            t.check(m1 == m0 && re.retries > r0 && m3 == m2,
                    "a decode that retried (\(m1 - m0) samples) and an encode resubmitted for capacity (retries \(re.retries - r0), \(m3 - m2) samples) are no samples")
        }
    }
    // other processes' GPU use: a read counts only when this process had no GPU work in its interval
    do {
        t.check(DeviceProfileTesting.otherGPUPercent(devicePercent: 60, ownBusySeconds: 0) == 60
                && DeviceProfileTesting.otherGPUPercent(devicePercent: 60, ownBusySeconds: 0.01) == nil,
                "a read with none of our GPU work in its interval is used (60%); with some of ours it is not")
        #if os(macOS)
        let stopped = DeviceProfileTesting.stopDeviceActivityPolling()      // no background read takes the test's values
        var reads = [10, 70, 80]
        let rl = NSLock()
        DeviceProfileTesting.deviceActivityRead = { rl.lock(); defer { rl.unlock() }; return reads.isEmpty ? 0 : reads.removeFirst() }
        DeviceProfileTesting.resetDeviceActivity()
        let first = DeviceProfileTesting.deviceActivityReadNow()          // no earlier read: a baseline only
        Thread.sleep(forTimeInterval: 0.02)
        let second = DeviceProfileTesting.deviceActivityReadNow()
        let stale = DeviceProfileTesting.deviceActivityReadNow(thenAfter: 1.5)
        DeviceProfileTesting.gpuWorkBegin(); Thread.sleep(forTimeInterval: 0.01); DeviceProfileTesting.gpuWorkEnd()
        let ours = DeviceProfileTesting.deviceActivityReadNow()            // our work in this interval: the 80% is not used
        DeviceProfileTesting.deviceActivityRead = nil
        DeviceProfileTesting.resetDeviceActivity()
        t.check(stopped && first == nil && second == 70 && stale == nil && ours == 80,
                "device activity: the first read is a baseline (\(first.map(String.init) ?? "nil")), the next is 70% (\(second.map(String.init) ?? "nil")), older than 1 s it is unknown (\(stale.map(String.init) ?? "nil")), and a read with our own work in its interval is not used (latest stays \(ours.map(String.init) ?? "nil"))")
        #endif
        DeviceProfileTesting.warmthClock = { 5000 }
        DeviceProfileTesting.gpuActivity = { (0, 0) }
        DeviceProfileTesting.deviceGPUPercentRead = { 60 }
        let busy = DeviceProfile.currentWarmth
        DeviceProfileTesting.deviceGPUPercentRead = { 5 }
        let quiet = DeviceProfile.currentWarmth
        DeviceProfileTesting.deviceGPUPercentRead = nil
        let injected = DeviceProfile.currentWarmth          // an injected GPU state alone: no device read
        DeviceProfileTesting.gpuActivity = nil; DeviceProfileTesting.warmthClock = nil
        t.check(busy.gpuWarm && busy.deviceGPUPercent == 60 && !quiet.gpuWarm && quiet.deviceGPUPercent == 5 && injected.deviceGPUPercent == nil,
                "another process at 60% of the GPU counts as warm, 5% does not; an injected GPU state skips the read: \(busy) | \(quiet) | \(injected)")
    }

    // the CPU proxy fit: chunk times of a CPU that follows the model exactly come back as that model
    for (k, r, u) in [(4.0, 18.0, 0.1), (2.0, 8.0, 0.1), (3.0, 30.0, 0.05)] {
        let sim = DeviceProfileTesting.simulateCPUProxy(.init(ratio: k, rampMs: r), chunkMs: u)
        let f = DeviceProfileTesting.fitCPUProxy(sim)
        let ok = f.model.map { abs($0.ratio / k - 1) < 0.15 && abs($0.rampMs / r - 1) < 0.15 && $0.measured } ?? false
        t.check(ok, "proxy fit of ratio \(k), ramp \(r) ms (\(sim.count) chunks, \(fmt(sim.reduce(0, +), 1)) ms): "
                + (f.model.map { "ratio \(fmt($0.ratio)), ramp \(fmt($0.rampMs, 1))" } ?? f.reason ?? "-"))
        if k == 4 { print("  proxy on the M4 fit (ratio 4, ramp 18 ms, 0.1 ms chunks): \(sim.count) chunks, \(fmt(sim.reduce(0, +), 1)) ms CPU, fitted "
                          + (f.model.map { "ratio \(fmt($0.ratio)), ramp \(fmt($0.rampMs, 1)) ms" } ?? "-")) }
    }
    // preempted chunks (every 37th 5x long) do not read as ramp
    var noisy = DeviceProfileTesting.simulateCPUProxy(.init(ratio: 4, rampMs: 18), chunkMs: 0.1)
    for i in stride(from: 5, to: noisy.count - 40, by: 37) { noisy[i] *= 5 }
    let fn = DeviceProfileTesting.fitCPUProxy(noisy)
    t.check(fn.model.map { abs($0.ratio / 4 - 1) < 0.2 && abs($0.rampMs / 18 - 1) < 0.2 } ?? false,
            "proxy fit with preempted chunks: " + (fn.model.map { "ratio \(fmt($0.ratio)), ramp \(fmt($0.rampMs, 1))" } ?? fn.reason ?? "-"))
    // real M4 runs with a weak ramp (a P-core already part-clocked) that the fit before the warm-time floor turned
    // into ratios of 1,000 to 260,000: each must now fit a plausible model or read as no ramp, never "implausible"
    if let fx = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "testdata/cpu-proxy-m4-weak-ramps.json"))) as? [String: Any],
       let runs = fx["runs"] as? [[Double]], !runs.isEmpty {
        let fits = runs.map { DeviceProfileTesting.fitCPUProxy($0) }
        let bad = fits.filter { $0.reason?.hasPrefix("implausible") == true || ($0.model.map { $0.ratio > 10 } ?? false) }
        t.check(bad.isEmpty, "proxy fit of \(runs.count) real M4 weak-ramp runs: " + fits.map { f in
            f.model.map { "ratio \(fmt($0.ratio))" } ?? (f.reason?.hasPrefix("implausible") == true ? "IMPLAUSIBLE" : "no ramp") }.joined(separator: ", "))
    } else {
        t.check(false, "testdata/cpu-proxy-m4-weak-ramps.json missing or unreadable (run api-check from the repository root)")
    }
    // an already warm CPU: flat chunk times are not used; a run cut short is not used either
    let flat = [Double](repeating: 0.05, count: 400)
    let ff = DeviceProfileTesting.fitCPUProxy(flat), fs = DeviceProfileTesting.fitCPUProxy(Array(noisy.prefix(10)))
    t.check(ff.model == nil && ff.reason?.contains("no clock ramp") == true && fs.model == nil, "flat proxy run not used: \(ff.reason ?? "-"); short: \(fs.reason ?? "-")")
    let real = DeviceProfileTesting.runCPUProxy()
    t.check(!real.isEmpty && real.reduce(0, +) < 60, "a real proxy run: \(real.count) chunks, \(fmt(real.reduce(0, +), 1)) ms")

    // the M4 fixture, on an M4 profile measured from M4-like injected timings: isolated 256x256 calls around the
    // fixture's cold 256x256 cells, 1600x1200 calls at the fixture's cold mean, a proxy run of the M4 fit
    let cpuSim = DeviceProfileTesting.simulateCPUProxy(DeviceProfile.defaultCPUColdModel, chunkMs: 0.1)
    let mm = DeviceProfileTesting.measure(ctx, estimate: m4.estimatedRouting,
                                          timings: .init(decode: [4.11, 3.63, 3.9, 4.0, 3.8], encode: [1.47, 1.17, 1.3, 1.25, 1.35],
                                                         decodeLarge: 7.66, encodeLarge: 6.02, cpuChunks: cpuSim))
    guard let cold = mm.sporadic, let cpuModel = mm.cpu else { t.check(false, "M4-like measurement not used: \(mm.reason ?? mm.cpuReason ?? "-")"); return }
    m4.pinRouting(cold, sustained: m4.estimatedRouting)
    m4.pinCPUColdModel(cpuModel)
    defer { m4.pinRouting(nil); m4.pinCPUColdModel(nil) }
    let wr = m4.warmRouting
    print("  M4 models: GPU cold " + cold.costDescription
          + String(format: "; warm decode %.2f + %.2f, encode %.2f + %.2f; CPU cold ratio %.2f, ramp %.1f ms",
                   wr.decodeFixedMs, wr.decodeMsPerMP, wr.encodeFixedMs, wr.encodeMsPerMP, cpuModel.ratio, cpuModel.rampMs))
    let wallNow = DeviceProfileTesting.monotonicNow
    // with the CPU model the proxy fitted (the default's) and with the model measured on the M4 (ratio 7.16, ramp
    // 22.2 ms), each at the default and at the M4's measured warm CPU rates
    let m4MeasuredCPU = DeviceProfile.CPUColdModel(ratio: 7.16, rampMs: 22.2, measured: true)
    for (cpuName, cm) in [("CPU model fitted from the default", cpuModel), ("the M4's measured CPU model", m4MeasuredCPU)] {
    m4.pinCPUColdModel(cm)
    for (rateName, rates) in [("default CPU rates", (3.0, 2.5)), ("the M4's measured warm rates", (2.64, 2.41))] {
        let runName = "\(cpuName), \(rateName)"
        var bad = 0, wrong = 0, lost = 0.0, cells = 0
        for f in m4Fixture {
            for ((gw, cw), (cellOrNil, name)) in zip(warmthStates, zip(f.cells, warmthNames)) {
                guard let cell = cellOrNil else { continue }
                // the automatic state, injected: our GPU work 0.1 s ago or never; noteCPUWork 0.1 s ago or never
                DeviceProfileTesting.resetWarmth()
                DeviceProfileTesting.warmthClock = { wallNow }
                DeviceProfileTesting.gpuActivity = { (0, gw ? wallNow - 0.1 : 0) }
                if cw { DeviceProfileTesting.warmthClock = { wallNow - 0.1 }; DeviceProfile.noteCPUWork(); DeviceProfileTesting.warmthClock = { wallNow } }
                let auto = DeviceProfile.currentWarmth
                t.check(auto.gpuWarm == gw && auto.cpuWarm == cw, "injected state \(name): \(auto)")
                let rate = f.op == .decode ? rates.0 : rates.1
                let cpu = m4.prefersCPU(width: f.w, height: f.h, operation: f.op, cpuMsPerMP: rateName.hasPrefix("default") ? nil : rate)
                let ratio = max(cell.gpu, cell.cpu) / min(cell.gpu, cell.cpu)
                cells += 1
                if ratio <= 1.10 || cpu == (cell.cpu < cell.gpu) { continue }      // a tie, or right
                wrong += 1; lost += abs(cell.gpu - cell.cpu)
                if ratio > 1.25 { bad += 1 }
                print("  M4 fixture (\(runName)): \(f.w)x\(f.h) \(f.op) \(name): advised \(cpu ? "CPU" : "GPU"), truth GPU \(cell.gpu) / CPU \(cell.cpu) ms "
                      + "(loser \(fmt((ratio - 1) * 100, 0))% slower, \(fmt(abs(cell.gpu - cell.cpu))) ms lost)")
            }
        }
        t.check(bad == 0, "M4 fixture, \(runName): \(bad) wrong calls with the loser over 25% slower")
        print("  M4 fixture (\(runName)): \(cells) cells, \(wrong) wrong (none over 25%: \(bad == 0)), regret \(fmt(lost)) ms in all, "
              + "\(wrong > 0 ? fmt(lost / Double(wrong)) : "0") ms per wrong call")
    }
    }
    m4.pinCPUColdModel(cpuModel)
    // the decision table, cold GPU against cold CPU (overrides): 256x256 decode and encode CPU; 1024x768 decode and
    // encode, 1600x1200 decode GPU
    t.check(m4.prefersCPU(width: 256, height: 256, operation: .decode, sustained: false, cpuWarm: false)
            && !m4.prefersCPU(width: 1024, height: 768, operation: .decode, sustained: false, cpuWarm: false)
            && !m4.prefersCPU(width: 1600, height: 1200, operation: .decode, sustained: false, cpuWarm: false)
            && m4.prefersCPU(width: 256, height: 256, operation: .encode, sustained: false, cpuWarm: false)
            && !m4.prefersCPU(width: 1024, height: 768, operation: .encode, sustained: false, cpuWarm: false),
            "M4 cold/cold decision table")
    // the tiny-job cap on the CPU cold model: 256x256 encode at 2.5 ms/MP (0.164 ms warm) costs warm + 0.25 ms
    // cold whatever the ratio, so with the M4's measured model (ratio 7.16, ramp 22.2 ms; the curve alone gives
    // 1.15 ms) the cell "GPU warm 0.84 / CPU cold 0.64" goes to the CPU; the cap is continuous at its knee
    m4.pinCPUColdModel(m4MeasuredCPU)
    let wTiny = 2.5 * 256 * 256 / 1e6, knee = DeviceProfile.cpuTinyJobMs
    DeviceProfileTesting.resetWarmth()
    DeviceProfileTesting.gpuActivity = { (1, 0) }          // GPU warm, CPU cold
    t.check(abs(m4MeasuredCPU.coldMs(warmMs: wTiny) - (wTiny + 0.25)) < 1e-9 && m4MeasuredCPU.rampedMs(warmMs: wTiny) > 1.0
            && m4.prefersCPU(width: 256, height: 256, operation: .encode)
            && abs(m4MeasuredCPU.coldMs(warmMs: knee + 1e-9) - m4MeasuredCPU.coldMs(warmMs: knee - 1e-9)) < 1e-6
            && m4MeasuredCPU.coldMs(warmMs: 2) == m4MeasuredCPU.rampedMs(warmMs: 2),
            "tiny-job CPU cap: 256x256 encode cold \(fmt(m4MeasuredCPU.coldMs(warmMs: wTiny), 3)) ms (curve \(fmt(m4MeasuredCPU.rampedMs(warmMs: wTiny), 3))), "
            + "against GPU warm \(fmt(m4.warmRouting.gpuMs(megapixels: 256 * 256 / 1e6, operation: .encode), 3)) ms")
    m4.pinCPUColdModel(cpuModel)
    // the cold GPU against a warm CPU at the default rates crosses over near 3 MP (the M4's isolated calls: about
    // 3 MP decode, 2.5-3 MP encode; the straight line put it at 5.7 and 6.0)
    for op in [DeviceProfile.Operation.decode, .encode] {
        let x = crossoverMP(cold, op, cpuModel, cpuWarm: true, rate: op == .decode ? 3.0 : 2.5) ?? 0
        t.check(x >= 2.0 && x <= 4.0, "GPU cold/CPU warm \(op) crossover \(fmt(x, 2)) MP (want 2-4)")
        print("  M4 GPU cold/CPU warm \(op) crossover at the default CPU rate: \(fmt(x, 2)) MP")
    }
    // sustained (kept fed) against a warm CPU: the crossovers at the default rates are the estimate's, with the CPU
    // needing to be cpuPreferenceMargin (20%) faster: decode 1.33 / (3.0 x 1.2 - 0.5) = 0.43 MP, encode
    // 0.29 / (2.5 x 1.2 - 0.56) = 0.12 MP
    let mg = 1 + DeviceProfile.cpuPreferenceMargin
    for (op, want) in [(DeviceProfile.Operation.decode, 1.33 / (3.0 * mg - 0.5)), (.encode, 0.29 / (2.5 * mg - 0.56))] {
        let x = crossoverMP(m4.sustainedRouting, op, cpuModel, cpuWarm: true, rate: op == .decode ? 3.0 : 2.5) ?? 0
        let side = Int((x * 1e6).squareRoot())
        t.check(abs(x / want - 1) < 0.3 && m4.prefersCPU(width: side - 20, height: side - 20, operation: op, sustained: true, cpuWarm: true)
                && !m4.prefersCPU(width: side + 20, height: side + 20, operation: op, sustained: true, cpuWarm: true),
                "sustained/warm \(op) crossover \(fmt(x, 3)) MP (want \(fmt(want, 3)) +-30%)")
    }
    // the overrides: 1600x1200 decode with the automatic state saying both cold (GPU), then cpuWarm: true (CPU),
    // sustained: true with it (GPU); and, CPU warm, the automatic GPU state (warm: GPU) against sustained: false (CPU)
    DeviceProfileTesting.resetWarmth()
    DeviceProfileTesting.gpuActivity = { (0, 0) }
    let a0 = m4.prefersCPU(width: 1600, height: 1200, operation: .decode)
    let a1 = m4.prefersCPU(width: 1600, height: 1200, operation: .decode, cpuWarm: true)
    let a2 = m4.prefersCPU(width: 1600, height: 1200, operation: .decode, sustained: true, cpuWarm: true)
    DeviceProfileTesting.gpuActivity = { (1, 0) }          // a command buffer in flight: warm
    let a3 = m4.prefersCPU(width: 1600, height: 1200, operation: .decode, cpuWarm: true)
    let a4 = m4.prefersCPU(width: 1600, height: 1200, operation: .decode, sustained: false, cpuWarm: true)
    // sustained given without cpuWarm keeps its old meaning: sustained is both warm, sporadic both cold, whatever
    // the detected CPU state: 1600x1200 decode, CPU noted warm just now, sustained: false: cold/cold, the GPU
    // (7.7 ms against 15.3; a warm CPU would win at 5.8); 640x480 decode, CPU detected cold, sustained: true:
    // warm/warm, the CPU (0.92 ms against 1.48; a cold CPU would lose at 3.4)
    DeviceProfileTesting.resetWarmth()
    DeviceProfile.noteCPUWork()
    let e0 = !m4.prefersCPU(width: 1600, height: 1200, operation: .decode, sustained: false)
    let e1 = m4.prefersCPU(width: 1600, height: 1200, operation: .decode)          // GPU in flight, CPU warm: auto
    DeviceProfileTesting.resetWarmth()
    let e2 = m4.prefersCPU(width: 640, height: 480, operation: .decode, sustained: true)
    t.check(e0 && !e1 && e2, "explicit sustained without cpuWarm: sporadic GPU \(e0), sustained CPU \(e2) (auto with both warm: \(e1 ? "CPU" : "GPU"))")
    t.check(!a0 && a1 && !a2 && !a3 && a4, "overrides: auto cold/cold GPU \(!a0), cpuWarm CPU \(a1), sustained GPU \(!a2); with a warm CPU: GPU warm GPU \(!a3), sustained: false CPU \(a4)")
}

/// trace: Decoder.recordStages / Encoder.recordStages (stage names and counts, the sum within the command buffer's
/// GPU time, bytes identical with recording on), routingDecision against prefersCPU, and MetalContext.trace (one
/// line per call; nil: none)
private func checkTrace(_ t: Tally, _ files: [APIFile]) {
    let dev = MetalContext.shared.device
    let supported = dev.supportsCounterSampling(.atStageBoundary)
    print("  stage-boundary timestamps: \(supported ? "supported" : "not supported (stageTimes must stay empty)")")
    let sel = files.filter { ["37x29_444", "640x480_420", "640x480_gray", "203x97_s2_rst3", "1201x803_noise_422"].contains($0.name) }
    let dec = Decoder()
    dec.recordStages = true
    var ndec = 0
    for f in sel {
        let ref = turboDecode(f.data, .rgb)!
        let img = dec.decode(f.data)
        t.check(same(img, ref), "recordStages decode \(f.name): \(img == nil ? "declined: \(dec.reason ?? "?")" : "differs")")
        let names = dec.stageTimes.map(\.name)
        let g = names.filter { $0.hasPrefix("sync") }.count
        let want = ["unstuff", "segments", "chunks"] + (0..<g).map { "sync\($0)" } + ["first_blocks", "decode_write", "dc_scan", "idct", "colour"]
        if supported {
            t.check(names == want && (g == dec.eagerPasses || g == 64), "decode \(f.name) stages \(names)")
            let sum = dec.stageTimes.reduce(0) { $0 + $1.gpuSeconds }
            t.check(sum > 0 && sum <= dec.gpuSeconds * 1.01 + 2e-6,
                    "decode \(f.name): stage sum \(sum * 1000) ms against GPU \(dec.gpuSeconds * 1000) ms")
        } else {
            t.check(names.isEmpty, "decode \(f.name): stages listed without stage-boundary sampling")
        }
        ndec += 1
    }
    dec.recordStages = false
    t.check(dec.stageTimes.isEmpty, "recordStages = false clears stageTimes")
    _ = dec.decode(sel[0].data)
    t.check(dec.stageTimes.isEmpty, "a decode with recordStages off lists stages")

    // encoder: both paths and a batch mixing them
    let enc = Encoder()
    enc.recordStages = true
    var nenc = 0
    for (w, h, s, q) in [(37, 29, 1, 90), (640, 480, 2, 75), (1201, 803, 0, 95)] {
        let px = corpusContent(w, h, "smooth", UInt32(w))
        let ref = Turbo.encode(px, w, h, quality: q, samp: s)
        for fused in [false, true] {
            enc.fusedMaxBlocks = fused ? 2_000_000 : 0
            let ss: Subsampling = s == 0 ? .s444 : s == 1 ? .s422 : .s420
            let got = try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: w, height: h, quality: q, subsampling: ss) }
            t.check(got == ref, "recordStages encode \(w)x\(h) s\(s) q\(q) \(fused ? "fused" : "two-pass") differs")
            let names = enc.stageTimes.map(\.name)
            let want = fused ? ["fill+fused", "len", "scan", "compact", "stuff_count", "stuff_scan", "stuff_scatter"]
                             : ["fill+dct", "count", "scan", "write", "stuff_count", "stuff_scan", "stuff_scatter"]
            if supported {
                t.check(names == want, "encode \(w)x\(h) \(fused ? "fused" : "two-pass") stages \(names)")
                let sum = enc.stageTimes.reduce(0) { $0 + $1.gpuSeconds }
                t.check(sum > 0 && sum <= enc.gpuSeconds * 1.01 + 2e-6,
                        "encode \(w)x\(h): stage sum \(sum * 1000) ms against GPU \(enc.gpuSeconds * 1000) ms")
            } else {
                t.check(names.isEmpty, "encode: stages listed without stage-boundary sampling")
            }
            nenc += 1
        }
    }
    do {   // a small image on the single-pass path and a larger one on the two-pass path, in one batch
        let a = corpusContent(64, 48, "smooth", 3), b = corpusContent(640, 480, "edges", 4)
        enc.fusedMaxBlocks = 200
        let r = try? enc.encodeBatch([EncodeJob(buffer: sharedBuffer(a, dev), width: 64, height: 48, quality: 90, subsampling: .s420),
                                      EncodeJob(buffer: sharedBuffer(b, dev), width: 640, height: 480, quality: 90, subsampling: .s420)])
        t.check(r == [Turbo.encode(a, 64, 48, quality: 90, samp: 2), Turbo.encode(b, 640, 480, quality: 90, samp: 2)], "recordStages mixed batch differs")
        if supported {
            // a retry (the edges image outgrows the output estimate) is a second submission with one path, whose
            // stages are added under their own names
            let names = enc.stageTimes.map(\.name)
            t.check(Array(names.prefix(7)) == ["fill+dct|fill+fused", "count|len", "scan", "write|compact", "stuff_count", "stuff_scan", "stuff_scatter"]
                    && Set(names.dropFirst(7)).isSubset(of: ["fill+dct", "count", "write", "fill+fused", "len", "compact"]),
                    "mixed batch stages \(names)")
        }
        nenc += 1
    }
    enc.recordStages = false
    t.check(enc.stageTimes.isEmpty, "Encoder.recordStages = false clears stageTimes")

    // routingDecision is what prefersCPU answers, with its parts consistent
    let p = MetalContext.shared.profile
    var nr = 0
    for (w, h) in [(64, 64), (256, 256), (640, 480), (1600, 1200), (6720, 4480)] {
        for op in [DeviceProfile.Operation.decode, .encode] {
            for sus in [true, false] as [Bool?] {
                for cw in [true, false, nil] as [Bool?] {
                    for rate in [nil, 1.0] as [Double?] {
                        let r = p.routingDecision(width: w, height: h, operation: op, cpuMsPerMP: rate, sustained: sus, cpuWarm: cw)
                        let b = p.prefersCPU(width: w, height: h, operation: op, cpuMsPerMP: rate, sustained: sus, cpuWarm: cw)
                        let m = DeviceProfile.cpuPreferenceMargin
                        t.check(r.prefersCPU == b, "routingDecision \(w)x\(h) \(op) sustained \(String(describing: sus)) cpuWarm \(String(describing: cw)): \(r.prefersCPU) against prefersCPU \(b)")
                        t.check(r.prefersCPU == (r.predictedCPUms * (1 + m) < r.predictedGPUms), "routingDecision \(w)x\(h) \(op): prefersCPU not from its predictions")
                        t.check(r.marginApplied == (!r.prefersCPU && r.predictedCPUms < r.predictedGPUms), "routingDecision \(w)x\(h) \(op): marginApplied")
                        t.check(r.gpuSet == (sus! ? .sustained : .sporadic), "routingDecision gpuSet \(r.gpuSet) for sustained \(sus!)")
                        t.check(r.cpuCold == !(cw ?? sus!), "routingDecision cpuCold \(r.cpuCold)")
                        t.check(r.warmth == nil, "routingDecision with sustained given: no detected warmth")
                        t.check(r.source == p.routingSource, "routingDecision source")
                        nr += 1
                    }
                }
            }
        }
    }
    let auto = p.routingDecision(width: 640, height: 480, operation: .decode)
    t.check(auto.warmth != nil && auto.gpuSet != .sustained, "routingDecision with automatic warmth: \(auto.gpuSet), warmth \(String(describing: auto.warmth))")

    // MetalContext.trace: one line per call, decodes (one declined) and encodes (one a batch); nil: none
    final class Lines: @unchecked Sendable { var v: [String] = [] }
    let lines = Lines(), old = MetalContext.trace
    MetalContext.trace = { lines.v.append($0) }
    let d2 = Decoder(), e2 = Encoder()
    let f = sel[1]
    _ = d2.decode(f.data)
    _ = f.data.withUnsafeBytes { d2.decode(bytes: $0, format: .bgra) }
    _ = d2.decode(Data([0xFF, 0xD8, 0xFF, 0xD9, 0, 0]))
    let px = corpusContent(320, 200, "smooth", 5)
    _ = try? px.withUnsafeBytes { try e2.encode(bytes: $0, width: 320, height: 200, quality: 80, subsampling: .s422) }
    _ = try? e2.encodeBatch([EncodeJob(buffer: sharedBuffer(px, dev), width: 320, height: 200),
                             EncodeJob(buffer: sharedBuffer(px, dev), width: 320, height: 200, subsampling: .s444)])
    t.check(lines.v.count == 5, "trace: \(lines.v.count) lines for 5 calls")
    if lines.v.count == 5 {
        t.check(lines.v[0].hasPrefix("ejm decode 640x480 4:2:0 ") && lines.v[0].contains(" ok wall ") && lines.v[0].contains(" route "), "trace decode line: \(lines.v[0])")
        t.check(lines.v[1].contains(" bgra ok "), "trace decode line (bgra): \(lines.v[1])")
        t.check(lines.v[2].contains(" declined ("), "trace declined line: \(lines.v[2])")
        t.check(lines.v[3].hasPrefix("ejm encode 320x200 4:2:2 q80 3ch ") && lines.v[3].contains(" B ok wall ") && lines.v[3].contains(" route "), "trace encode line: \(lines.v[3])")
        t.check(lines.v[4].hasPrefix("ejm encode batch of 2 "), "trace batch line: \(lines.v[4])")
        t.check(!lines.v.contains { $0.contains(" stages ") }, "trace lists stages with recordStages off")
    }
    d2.recordStages = true
    _ = d2.decode(f.data)
    t.check(lines.v.count == 6 && (!supported || lines.v[5].contains(" stages unstuff ")), "trace line with recordStages: \(lines.v.last ?? "none")")
    MetalContext.trace = nil
    _ = d2.decode(f.data)
    _ = try? px.withUnsafeBytes { try e2.encode(bytes: $0, width: 320, height: 200) }
    t.check(lines.v.count == 6, "trace nil: \(lines.v.count - 6) more lines")
    MetalContext.trace = old
    print("  \(ndec) decodes and \(nenc) encodes with recordStages; \(nr) routing decisions; \(lines.v.count) trace lines")
    if let l = lines.v.first { print("  e.g. \(l)") }
}

/// The markers of a JPEG up to its scan: SOF type, components (id, h, v), DQT tables (precision, values), DRI, and
/// whether the entropy-coded data holds RST markers. nil when the markers do not parse.
struct JPEGMarkers {
    var sof = -1, comps: [(id: Int, h: Int, v: Int)] = [], dqt: [(pq: Int, values: [Int])] = [], dri = 0, rst = false
    init?(_ d: Data) {
        let b = [UInt8](d)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let m = Int(b[i + 1]); if m == 0xFF { i += 1; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { return nil }
            let seg = Array(b[(i + 4)..<(i + 2 + len)])
            switch m {
            case 0xC0...0xCF where m != 0xC4 && m != 0xC8 && m != 0xCC:
                sof = m
                guard seg.count >= 6 else { return nil }
                let n = Int(seg[5])
                guard seg.count >= 6 + 3 * n else { return nil }
                comps = (0..<n).map { (k: Int) -> (Int, Int, Int) in
                    let id = Int(seg[6 + 3 * k]), hv = Int(seg[7 + 3 * k])
                    return (id, hv >> 4, hv & 15)
                }
            case 0xDB:
                var j = 0
                while j < seg.count {
                    let pq = Int(seg[j] >> 4), n = pq == 1 ? 128 : 64
                    guard j + 1 + n <= seg.count else { return nil }
                    dqt.append((pq, (0..<64).map { k in pq == 1 ? Int(seg[j + 1 + 2 * k]) << 8 | Int(seg[j + 2 + 2 * k]) : Int(seg[j + 1 + k]) }))
                    j += 1 + n
                }
            case 0xDD:
                guard seg.count >= 2 else { return nil }
                dri = Int(seg[0]) << 8 | Int(seg[1])
            case 0xDA:
                var k = i + 2 + len
                while k + 1 < b.count { if b[k] == 0xFF && (0xD0...0xD7).contains(b[k + 1]) { rst = true; break }; k += 1 }
                return
            default: break
            }
            i += 2 + len
        }
        return nil
    }
    /// "HxV" of component k
    func samp(_ k: Int) -> String { k < comps.count ? "\(comps[k].h)x\(comps[k].v)" : "none" }
    var summary: String {
        "SOF\(String(format: "%X", sof & 15)), \(comps.count) components \((0..<comps.count).map(samp).joined(separator: " ")), DQT precisions \(dqt.map(\.pq)) max \(dqt.flatMap(\.values).max() ?? -1), DRI \(dri), RST \(rst)"
    }
}

/// what a self-check decode case's name promises about its JPEG: nil when it holds, else what is wrong
func selfCheckCaseProblem(_ name: String, _ jpeg: Data) -> String? {
    guard let m = JPEGMarkers(jpeg) else { return "markers do not parse" }
    var bad: [String] = []
    func need(_ c: Bool, _ what: String) { if !c { bad.append(what) } }
    // every case: a baseline (or extended 8-bit) Huffman frame, quantisers within the decoder's 16-bit limit
    need(m.sof == 0xC0 || m.sof == 0xC1, "a baseline / extended Huffman frame")
    need(m.dqt.allSatisfy { $0.values.allSatisfy { $0 >= 1 && $0 <= 32767 } }, "quantisation values in 1...32767")
    let chroma11 = m.comps.count == 3 && m.samp(1) == "1x1" && m.samp(2) == "1x1"
    switch name {
    case "decode 4:2:0 with restart markers":
        need(m.comps.count == 3 && m.samp(0) == "2x2" && chroma11, "luma 2x2, chroma 1x1"); need(m.dri > 0 && m.rst, "DRI > 0 and RST markers")
    case "decode 4:2:0 without restarts":
        need(m.comps.count == 3 && m.samp(0) == "2x2" && chroma11, "luma 2x2, chroma 1x1"); need(m.dri == 0 && !m.rst, "no DRI, no RST")
    case "decode 4:2:2": need(m.comps.count == 3 && m.samp(0) == "2x1" && chroma11, "luma 2x1, chroma 1x1")
    case "decode 4:4:4": need(m.comps.count == 3 && m.samp(0) == "1x1" && chroma11, "every component 1x1")
    case "decode gray": need(m.comps.count == 1, "one component")
    case "decode 4:4:0": need(m.comps.count == 3 && m.samp(0) == "1x2" && chroma11, "luma 1x2, chroma 1x1")
    case "decode 16-bit quantisation tables":
        need(m.dqt.contains { $0.pq == 1 }, "a DQT with Pq = 1")
        need(m.dqt.contains { $0.pq == 1 && $0.values.contains { $0 > 255 } }, "a 16-bit value above 255 (one an 8-bit table cannot hold)")
    default: bad.append("no rule for this name (add one)")
    }
    return bad.isEmpty ? nil : "wanted \(bad.joined(separator: "; ")); has \(m.summary)"
}

private func checkSelfCheckCases(_ t: Tally) {
    let cases = SelfCheckTesting.decodeCases
    t.check(cases.count >= 7, "\(cases.count) decode cases")
    for c in cases {
        let p = selfCheckCaseProblem(c.name, c.jpeg)
        t.check(p == nil, "\(c.name): \(p ?? "")")
        if p == nil, let m = JPEGMarkers(c.jpeg) { print("  \(c.name): \(m.summary)") }
    }
    // the control: the rules tell a mislabeled case
    if let j422 = cases.first(where: { $0.name == "decode 4:2:2" })?.jpeg, let j420 = cases.first(where: { $0.name == "decode 4:2:0 with restart markers" })?.jpeg {
        t.check(selfCheckCaseProblem("decode 4:4:0", j422) != nil, "control: the 4:2:2 JPEG named 4:4:0 passes the rules")
        t.check(selfCheckCaseProblem("decode 4:2:0 without restarts", j420) != nil, "control: the restart JPEG named without restarts passes the rules")
        t.check(selfCheckCaseProblem("decode 16-bit quantisation tables", j422) != nil, "control: an 8-bit-table JPEG named 16-bit passes the rules")
    } else { t.check(false, "control cases missing") }
    for e in SelfCheckTesting.encodeCases {
        let wantTwo = e.name.contains("two-pass"), wantFused = e.name.contains("fused")
        t.check(wantTwo != wantFused && e.twoPass == wantTwo && (e.channels == 3 || e.channels == 4) && e.rowBytes >= e.width * e.channels,
                "\(e.name): twoPass \(e.twoPass), \(e.width)x\(e.height)x\(e.channels), rowBytes \(e.rowBytes)")
        print("  \(e.name): \(e.twoPass ? "two-pass" : "fused") path, \(e.width)x\(e.height), \(e.channels) channels, rowBytes \(e.rowBytes), q\(e.quality) \(e.subsampling)")
    }
}
