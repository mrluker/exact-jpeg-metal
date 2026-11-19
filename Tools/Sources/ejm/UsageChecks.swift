import Foundation
import Metal
@_spi(Testing) import ExactJPEG
import ExactJPEGC

// API usage checks, run by `ejm api-check` (each one also by name). The ones that can trap run in a child process
// (`ejm usage-child <mode>`), so a trap fails the check instead of ending the run:
//   concurrent-use     one Decoder, one Encoder and one C decoder / encoder handle used from 4 threads at once
//                      (200 calls each): every result is exact (against libjpeg-turbo) or the call declines / throws
//                      with "decoder used from two threads at once" / "encoder used from two threads at once"
//                      (EJM_DECLINED / EJM_ERROR in C); none is wrong, nothing traps, and some calls did overlap
//   metal-setup        Metal setup failures, simulated with EJM_TEST_METAL_SETUP: no device, a shader library that
//                      does not compile, a decoder kernel and an encoder kernel whose pipeline state fails to build.
//                      Decoder() and Encoder() still construct; every decode declines and every encode throws with
//                      the setup error (or the self-check failure naming the kernel); ejm_*_create return NULL when
//                      MetalContext.shared has no setup; nothing traps
//   c-api-args         ejm_decode / ejm_decode_view / ejm_inspect with a length above SIZE_MAX / 2 (negative as a
//                      Swift Int: -1, Int.min) return EJM_ERROR (1 from ejm_inspect) without trapping; ejm_decode
//                      with too small an output for a file that would be declined anyway returns EJM_DECLINED with
//                      the decline reason, not EJM_ERROR "output buffer too small"; a good file with too small an
//                      output still gets EJM_ERROR; the output stays untouched
//   stale-stats        after a call that ends before any GPU work (a decline, a throw), the decoder's gpuSeconds,
//                      passes, host timings and stageTimes and the encoder's gpuSeconds and stageTimes are reset,
//                      not left from the call before
//   buffer-input       decode(buffer:length:) with a .private input buffer (no CPU contents) and with a length past
//                      the buffer declines with a reason, traced (EJM_TRACE=1) and not, in child processes, no trap
//   c-reason-race      a child: one thread decodes and encodes through one C handle each, alternating good and bad
//                      input so the reason / error string is replaced and freed all the time, while 3 more threads
//                      call the same handles: every busy return (EJM_DECLINED / EJM_ERROR) reads the static
//                      "... used from two threads at once" string from ejm_decoder_reason / ejm_encoder_error, no
//                      trap (ejm usage-child c-reason-race)
//   gate-records       200 short-lived threads each rejected once by a Decoder's call gate: each sees busyReason,
//                      the gate keeps no per-thread record after they exit (Decoder.gateRecordCount back to where
//                      it was), fresh threads (which may reuse the thread ids) and the holder see no busy reason,
//                      and a rejected thread's next call clears its busy reason
//   encoder-buffer-input  Encoder.encode(buffer:) and encodeBatch with an input buffer the encoder must not use
//                      (.private storage; an offset or span past the buffer) throw InvalidInput, a batch naming
//                      the job, before any GPU work; traced (EJM_TRACE=1) and not, in child processes, no trap
//   decline-reason-stats  Decoder.declineReason(bytes:) leaves the last decode's gpuSeconds, passes, host timings,
//                      stageTimes and reason as they were (it is a query, not a call that resets them)
nonisolated(unsafe) let usageChecks: [(name: String, run: (Tally) -> Void)] = [
    ("concurrent-use", checkConcurrentUse),
    ("metal-setup", checkMetalSetup),
    ("c-api-args", checkCAPIArgs),
    ("stale-stats", checkStaleStats),
    ("buffer-input", checkBufferInput),
    ("c-reason-race", { runUsageChildren($0, [("c-reason-race", [:])]) }),
    ("gate-records", checkGateRecords),
    ("decline-reason-stats", checkDeclineReasonStats),
    ("encoder-buffer-input", { runUsageChildren($0, [("encoder-buffer-input", [:]), ("encoder-buffer-input", ["EJM_TRACE": "1"])]) }),
]

let decoderBusy = "decoder used from two threads at once"
let encoderBusy = "encoder used from two threads at once"

/// runs `ejm usage-child <mode>` with extra environment; its OK / FAIL lines become checks
private func runUsageChildren(_ t: Tally, _ modes: [(mode: String, env: [String: String])]) {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    for (mode, extra) in modes {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["usage-child", mode]
        p.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { t.check(false, "cannot start \(exe.path): \(error)"); continue }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let lines = out.split(separator: "\n")
        for l in lines { t.check(l.hasPrefix("OK "), "\(mode) child: \(l)") }
        let how = p.terminationReason == .uncaughtSignal ? "signal \(p.terminationStatus)" : "status \(p.terminationStatus)"
        t.check(p.terminationReason == .exit && p.terminationStatus == 0 && !lines.isEmpty, "\(mode) child ended with \(how)")
        print("  \(mode): \(lines.filter { $0.hasPrefix("OK ") }.count) of \(lines.count) OK, \(how)")
    }
}

private func checkConcurrentUse(_ t: Tally) {
    runUsageChildren(t, [("concurrent-decoder", [:]), ("concurrent-encoder", [:]), ("concurrent-c", [:])])
}

/// `ejm usage-child <mode>`: prints OK / FAIL lines; false on any FAIL
func runUsageChild(_ mode: String) -> Bool {
    setvbuf(stdout, nil, _IOLBF, 0)
    var ok = true
    func report(_ cond: Bool, _ what: String) { print((cond ? "OK " : "FAIL ") + what); if !cond { ok = false } }
    switch mode {
    case "concurrent-decoder": concurrentDecoder(report)
    case "concurrent-encoder": concurrentEncoder(report)
    case "concurrent-c": concurrentC(report)
    case "c-args": cArgs(report)
    case "buffer-input": bufferInput(report)
    case "c-reason-race": cReasonRace(report)
    case "encoder-buffer-input": encoderBufferInput(report)
    case let m where m.hasPrefix("setup-failed:"): setupFailed(String(m.dropFirst("setup-failed:".count)), report)
    default: report(false, "unknown usage-child mode \(mode)")
    }
    return ok
}

private let threads = 4, callsPerThread = 200

/// two different files (so a result holding the other thread's pixels is caught) and their libjpeg-turbo decodes
private func concurrencyFiles() -> [(jpeg: Data, ref: [UInt8], w: Int, h: Int)] {
    [(640, 480, "smooth", 2), (320, 240, "noise", 0)].enumerated().map { k, s in
        let jpg = Turbo.encode(corpusContent(s.0, s.1, s.2, UInt32(41 + k)), s.0, s.1, quality: 90, samp: s.3)
        return (jpg, Turbo.decode(jpg)!.px, s.0, s.1)
    }
}

/// counts of a concurrent run, under a lock
private final class Counts: @unchecked Sendable {
    let lock = NSLock()
    var exact = 0, busy = 0, wrong = 0, other: [String] = []
    func add(exact e: Bool = false, busy b: Bool = false, wrong w: Bool = false, other o: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if e { exact += 1 }; if b { busy += 1 }; if w { wrong += 1 }
        if let o, other.count < 5 { other.append(o) }
    }
    var summary: String { "exact \(exact), declined as busy \(busy), wrong \(wrong), other \(other)" }
}

private func concurrentDecoder(_ report: (Bool, String) -> Void) {
    let files = concurrencyFiles()
    let dec = Decoder()
    let dev = MTLCreateSystemDefaultDevice()!
    report(dec.decode(files[0].jpeg) != nil, "a first decode alone works (\(dec.reason ?? "ok"))")
    let srcs = files.map { f in f.jpeg.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: f.jpeg.count, options: .storageModeShared)! } }
    let c = Counts()
    DispatchQueue.concurrentPerform(iterations: threads) { k in
        let out = dev.makeBuffer(length: 640 * 480 * 3, options: .storageModeShared)!
        for i in 0..<callsPerThread {
            let fi = (k + i) % 2, f = files[fi]
            let img = i % 2 == 0 ? f.jpeg.withUnsafeBytes { dec.decode(bytes: $0, output: out) }
                                 : dec.decode(buffer: srcs[fi], length: f.jpeg.count, output: out)
            if let img {
                let same = img.buffer === out && img.width == f.w && img.height == f.h
                    && memcmp(out.contents(), f.ref, f.ref.count) == 0
                c.add(exact: same, wrong: !same)
            } else {
                let r = dec.reason ?? "nil"
                c.add(busy: r == decoderBusy, other: r == decoderBusy ? nil : r)
            }
        }
    }
    report(c.wrong == 0 && c.other.isEmpty && c.exact > 0 && c.busy > 0,
           "one Decoder from \(threads) threads, \(threads * callsPerThread) calls: \(c.summary) (wanted: no wrong, no other, some of each)")
    report(dec.decode(files[1].jpeg).map { memcmp($0.bytes.baseAddress!, files[1].ref, files[1].ref.count) == 0 } == true,
           "the decoder works alone afterwards")
}

private func concurrentEncoder(_ report: (Bool, String) -> Void) {
    let dev = MTLCreateSystemDefaultDevice()!
    let imgs = [(640, 480, "smooth"), (320, 240, "edges")].enumerated().map { k, s in
        let px = corpusContent(s.0, s.1, s.2, UInt32(51 + k))
        let buf = px.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: px.count, options: .storageModeShared)! }
        return (buf: buf, w: s.0, h: s.1, ref: Turbo.encode(px, s.0, s.1, quality: 85, samp: 2))
    }
    let enc = Encoder()
    let first = try? enc.encode(buffer: imgs[0].buf, width: imgs[0].w, height: imgs[0].h, quality: 85)
    report(first == imgs[0].ref, "a first encode alone works")
    let c = Counts()
    DispatchQueue.concurrentPerform(iterations: threads) { k in
        for i in 0..<callsPerThread {
            let fi = (k + i) % 2, m = imgs[fi]
            do {
                let d: Data
                if i % 2 == 0 { d = try enc.encode(buffer: m.buf, width: m.w, height: m.h, quality: 85) }
                else { d = try enc.encodeBatch([EncodeJob(buffer: m.buf, width: m.w, height: m.h, quality: 85)])[0] }
                c.add(exact: d == m.ref, wrong: d != m.ref)
            } catch {
                let s = "\(error)"
                c.add(busy: s == encoderBusy, other: s == encoderBusy ? nil : s)
            }
        }
    }
    report(c.wrong == 0 && c.other.isEmpty && c.exact > 0 && c.busy > 0,
           "one Encoder from \(threads) threads, \(threads * callsPerThread) calls: \(c.summary) (wanted: no wrong, no other, some of each)")
    let again = try? enc.encode(buffer: imgs[1].buf, width: imgs[1].w, height: imgs[1].h, quality: 85)
    report(again == imgs[1].ref, "the encoder works alone afterwards")
}

private func concurrentC(_ report: (Bool, String) -> Void) {
    let files = concurrencyFiles()
    guard let cd = ejm_decoder_create(), let ce = ejm_encoder_create() else { report(false, "cannot create C handles"); return }
    defer { ejm_decoder_destroy(cd); ejm_encoder_destroy(ce) }
    let px = corpusContent(320, 240, "edges", 61), ref = Turbo.encode(px, 320, 240, quality: 80, samp: 2)
    let c = Counts(), e = Counts()
    DispatchQueue.concurrentPerform(iterations: threads) { k in
        // one byte past a page multiple: the copy path, so the pixels compared are those copied out for this call
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 640 * 480 * 3 + 1)
        defer { out.deallocate() }
        for i in 0..<callsPerThread {
            let fi = (k + i) % 2, f = files[fi]
            var w: Int32 = 0, h: Int32 = 0
            let r = f.jpeg.withUnsafeBytes { ejm_decode(cd, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), f.jpeg.count, 0, out, 640 * 480 * 3 + 1, &w, &h) }
            if r == 0 {
                let same = Int(w) == f.w && Int(h) == f.h && memcmp(out, f.ref, f.ref.count) == 0
                c.add(exact: same, wrong: !same)
            } else {
                c.add(busy: r == 1, other: r == 1 ? nil : "rc \(r)")
            }
            if i % 4 == 0 {
                var jp: UnsafeMutablePointer<UInt8>? = nil, len = 0
                let r = px.withUnsafeBufferPointer { ejm_encode(ce, $0.baseAddress, 320, 240, 3, 960, 80, 2, &jp, &len) }
                if r == 0 { let same = Data(bytes: jp!, count: len) == ref; e.add(exact: same, wrong: !same); ejm_free(jp) }
                else { e.add(busy: r == -1, other: r == -1 ? nil : "rc \(r)") }
            }
        }
    }
    report(c.wrong == 0 && c.other.isEmpty && c.exact > 0 && c.busy > 0,
           "one C decoder handle from \(threads) threads: \(c.summary) (busy: EJM_DECLINED)")
    report(e.wrong == 0 && e.other.isEmpty && e.exact > 0,
           "one C encoder handle from \(threads) threads: \(e.summary) (busy: EJM_ERROR)")
}

private func checkMetalSetup(_ t: Tally) {
    runUsageChildren(t, [("setup-failed:nodevice", ["EJM_TEST_METAL_SETUP": "nodevice"]),
                         ("setup-failed:compile", ["EJM_TEST_METAL_SETUP": "compile"]),
                         ("setup-failed:pipeline", ["EJM_TEST_METAL_SETUP": "pipeline:idct_islow"]),
                         ("setup-failed:encpipeline", ["EJM_TEST_METAL_SETUP": "pipeline:enc_count"])])
}

/// a child run with EJM_TEST_METAL_SETUP set: nodevice / compile make MetalContext.shared's setup fail (no
/// device; the shader library does not compile), pipeline:<kernel> makes that kernel's pipeline state fail to
/// build. No call may trap; every decode declines and every encode throws, with the setup error as the reason
/// (or, for a kernel the self-check needs, the self-check's failure naming it)
private func setupFailed(_ kind: String, _ report: (Bool, String) -> Void) {
    let shared = kind == "nodevice" || kind == "compile"
    let want = kind == "nodevice" ? "no Metal device" : kind == "compile" ? "EJM_TEST_METAL_SETUP=compile"
             : kind == "pipeline" ? "idct_islow" : "enc_count"
    let err = MetalContext.sharedSetupError
    report(shared ? err?.contains(want) == true : err == nil, "MetalContext.sharedSetupError: \(err ?? "nil")")
    let dev = MTLCreateSystemDefaultDevice()!
    let jpg = Turbo.encode(corpusContent(64, 48, "smooth", 71), 64, 48, quality: 90, samp: 2)
    let dec = Decoder()
    let decodeWanted = kind == "encpipeline" ? nil : want     // a broken encoder kernel leaves decoding alone
    // a failed self-check half fails the device's whole self-check, so a broken decoder kernel stops encodes too
    // (once the decode half has run, as it has here)
    let encodeWanted: String? = want
    func declined(_ img: GPUImage?, _ what: String) {
        if let decodeWanted {
            report(img == nil && dec.reason?.contains(decodeWanted) == true, "\(what) declines: \(dec.reason ?? "nil")")
        } else {
            report(img != nil, "\(what) decodes (\(dec.reason ?? "ok"))")
        }
    }
    declined(dec.decode(jpg), "decode(_:)")
    let src = jpg.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: jpg.count, options: .storageModeShared)! }
    declined(dec.decode(buffer: src, length: jpg.count), "decode(buffer:)")
    let path = NSTemporaryDirectory() + "ejm-setup-\(getpid()).jpg"
    try! jpg.write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    declined(dec.decode(path: path), "decode(path:)")
    report(dec.allocatedBytes == 0 || decodeWanted == nil || !shared, "nothing allocated (\(dec.allocatedBytes) bytes)")
    let enc = Encoder()
    let px = [UInt8](repeating: 128, count: 64 * 48 * 3)
    do { _ = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 64, height: 48) }; report(encodeWanted == nil, "encode(bytes:) succeeded") }
    catch { report(encodeWanted.map { "\(error)".contains($0) } == true, "encode(bytes:) throws: \(error)") }
    let pb = px.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: px.count, options: .storageModeShared)! }
    do { _ = try enc.encodeBatch([EncodeJob(buffer: pb, width: 64, height: 48)]); report(encodeWanted == nil, "encodeBatch succeeded") }
    catch { report(encodeWanted.map { "\(error)".contains($0) } == true, "encodeBatch throws: \(error)") }
    if shared {
        report(ejm_decoder_create() == nil && ejm_encoder_create() == nil, "ejm_decoder_create and ejm_encoder_create return NULL")
    } else {
        guard let cd = ejm_decoder_create(), let ce = ejm_encoder_create() else { report(false, "C handles not created"); return }
        defer { ejm_decoder_destroy(cd); ejm_encoder_destroy(ce) }
        var out = [UInt8](repeating: 7, count: 64 * 48 * 3), w: Int32 = 0, h: Int32 = 0
        let r = jpg.withUnsafeBytes { s in out.withUnsafeMutableBufferPointer { ejm_decode(cd, s.baseAddress!.assumingMemoryBound(to: UInt8.self), jpg.count, 0, $0.baseAddress, $0.count, &w, &h) } }
        let why = ejm_decoder_reason(cd).map { String(cString: $0) } ?? "nil"
        if let decodeWanted { report(r == 1 && why.contains(decodeWanted) && out.allSatisfy { $0 == 7 }, "ejm_decode declines, out untouched: \(r) \(why)") }
        else { report(r == 0, "ejm_decode decodes: \(r) \(why)") }
        var jp: UnsafeMutablePointer<UInt8>? = nil, len = 0
        let e = px.withUnsafeBufferPointer { ejm_encode(ce, $0.baseAddress, 64, 48, 3, 192, 75, 2, &jp, &len) }
        let ew = ejm_encoder_error(ce).map { String(cString: $0) } ?? "nil"
        if let encodeWanted { report(e == -1 && ew.contains(encodeWanted), "ejm_encode fails: \(e) \(ew)") }
        else { report(e == 0, "ejm_encode encodes: \(e) \(ew)"); ejm_free(jp) }
        MetalContext.shared.warmUp()
        report(true, "MetalContext.shared.warmUp() returns (pipelines built: \(MetalContext.shared.pipelineCount))")
    }
}

private func checkCAPIArgs(_ t: Tally) { runUsageChildren(t, [("c-args", [:])]) }

private func cArgs(_ report: (Bool, String) -> Void) {
    guard let cd = ejm_decoder_create() else { report(false, "no C decoder"); return }
    defer { ejm_decoder_destroy(cd) }
    let jpg = Turbo.encode(corpusContent(64, 48, "smooth", 81), 64, 48, quality: 90, samp: 2)
    var out = [UInt8](repeating: 7, count: 64 * 48 * 3)
    var w: Int32 = 0, h: Int32 = 0, c: Int32 = 0
    var px: UnsafePointer<UInt8>? = nil
    for n in [-1, Int.min, Int.min + 1] {
        let r = jpg.withUnsafeBytes { s in out.withUnsafeMutableBufferPointer { ejm_decode(cd, s.baseAddress!.assumingMemoryBound(to: UInt8.self), n, 0, $0.baseAddress, $0.count, &w, &h) } }
        report(r == -1 && out.allSatisfy { $0 == 7 }, "ejm_decode with len \(UInt(bitPattern: n)): \(r), out untouched")
        let v = jpg.withUnsafeBytes { ejm_decode_view(cd, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), n, 0, &px, &w, &h, &c) }
        report(v == -1, "ejm_decode_view with len \(UInt(bitPattern: n)): \(v)")
        let i = jpg.withUnsafeBytes { ejm_inspect($0.baseAddress!.assumingMemoryBound(to: UInt8.self), n, &w, &h, &c) }
        report(i == 1, "ejm_inspect with len \(UInt(bitPattern: n)): \(i)")
    }
    for cap in [-1, Int.min] {
        let r = jpg.withUnsafeBytes { s in out.withUnsafeMutableBufferPointer { ejm_decode(cd, s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, 0, $0.baseAddress, cap, &w, &h) } }
        report(r == -1 && out.allSatisfy { $0 == 7 }, "ejm_decode with capacity \(UInt(bitPattern: cap)): \(r), out untouched")
    }
    // a header claiming 8000x8000 over 64x48 worth of data: declined ("entropy-coded data too short ...") whatever
    // the capacity; a good file with a small capacity is the caller's error
    let big = claimSize(jpg, 8000, 8000)
    for (name, file, want) in [("8000x8000 claimed, too little data", big, Int32(1)), ("a good 64x48 file", jpg, Int32(-1))] {
        let r = file.withUnsafeBytes { s in out.withUnsafeMutableBufferPointer { ejm_decode(cd, s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, 0, $0.baseAddress, 100, &w, &h) } }
        let why = ejm_decoder_reason(cd).map { String(cString: $0) } ?? "nil"
        report(r == want && out.allSatisfy { $0 == 7 } && (want == -1 ? why.contains("too small") : why.contains("too short")),
               "\(name), capacity 100: \(r) (\(why)), \(want) wanted, out untouched")
    }
}

private func checkStaleStats(_ t: Tally) {
    let jpg = Turbo.encode(corpusContent(640, 480, "smooth", 95), 640, 480, quality: 90, samp: 2)
    let dec = Decoder()
    dec.recordStages = true
    let ok = dec.decode(jpg) != nil
    let had = (gpu: dec.gpuSeconds, passes: dec.passes, stages: dec.stageTimes.count)
    t.check(ok && had.gpu > 0 && had.passes > 0, "a decode sets gpuSeconds \(had.gpu), passes \(had.passes), stages \(had.stages)")
    for (name, bad) in [("not a JPEG", Data([0xFF, 0xD8])), ("a header that does not parse", Data([0xFF, 0xD8, 0xFF, 0xD9, 0, 0])),
                        ("too little data", claimSize(jpg, 8000, 8000))] {
        _ = dec.decode(jpg)
        let img = dec.decode(bad)
        t.check(img == nil && dec.gpuSeconds == 0 && dec.passes == 0 && dec.stageTimes.isEmpty && dec.hostPrepSeconds == 0
                && dec.hostEncodeSeconds == 0 && dec.waitSeconds == 0,
                "decoder after a decline before the GPU (\(name): \(dec.reason ?? "?")): gpuSeconds \(dec.gpuSeconds), passes \(dec.passes), stages \(dec.stageTimes.count), host \(dec.hostPrepSeconds) \(dec.hostEncodeSeconds) \(dec.waitSeconds)")
    }
    let enc = Encoder()
    enc.recordStages = true
    let px = corpusContent(320, 240, "edges", 96)
    let e = (try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 320, height: 240) }) != nil
    t.check(e && enc.gpuSeconds > 0, "an encode sets gpuSeconds \(enc.gpuSeconds), stages \(enc.stageTimes.count)")
    let threw = (try? px.withUnsafeBytes { try enc.encode(bytes: $0, width: 320, height: 240, quality: 0) }) == nil
    t.check(threw && enc.gpuSeconds == 0 && enc.stageTimes.isEmpty,
            "encoder after a call that threw before the GPU: gpuSeconds \(enc.gpuSeconds), stages \(enc.stageTimes.count)")
}

private func checkBufferInput(_ t: Tally) {
    runUsageChildren(t, [("buffer-input", [:]), ("buffer-input", ["EJM_TRACE": "1"])])
}

/// decode(buffer:length:) on input buffers it cannot read: declined with a reason before contents() is touched
private func bufferInput(_ report: (Bool, String) -> Void) {
    let dev = MTLCreateSystemDefaultDevice()!
    let jpg = Turbo.encode(corpusContent(64, 48, "smooth", 97), 64, 48, quality: 90, samp: 2)
    let dec = Decoder()
    let good = jpg.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: jpg.count, options: .storageModeShared)! }
    report(dec.decode(buffer: good, length: jpg.count) != nil, "a shared input buffer decodes (\(dec.reason ?? "ok"))")
    let priv = dev.makeBuffer(length: max(jpg.count, 4096), options: .storageModePrivate)!
    let img = dec.decode(buffer: priv, length: jpg.count)
    report(img == nil && dec.reason?.contains("storageModeShared") == true, "a .private input buffer declines: \(dec.reason ?? "nil")")
    for n in [jpg.count + 1, -1, Int.max] {
        let img = dec.decode(buffer: good, length: n)
        report(img == nil && dec.reason != nil, "length \(n) for a \(good.length)-byte buffer declines: \(dec.reason ?? "nil")")
    }
    let devs = MTLCopyAllDevices().filter { $0 !== dev }
    if let other = devs.first, let ob = jpg.withUnsafeBytes({ other.makeBuffer(bytes: $0.baseAddress!, length: jpg.count, options: .storageModeShared) }) {
        let img = dec.decode(buffer: ob, length: jpg.count)
        report(img == nil && dec.reason?.contains("device") == true, "an input buffer of another device declines: \(dec.reason ?? "nil")")
    } else {
        report(true, "an input buffer of another device: not testable here (one Metal device)")
    }
    report(dec.decode(buffer: good, length: jpg.count) != nil, "the decoder works afterwards (\(dec.reason ?? "ok"))")
}

/// see c-reason-race above
private func cReasonRace(_ report: (Bool, String) -> Void) {
    let good = Turbo.encode(corpusContent(256, 192, "smooth", 98), 256, 192, quality: 90, samp: 2)
    let bad = Data([0xFF, 0xD8, 0xFF, 0xD9])
    guard let cd = ejm_decoder_create(), let ce = ejm_encoder_create() else { report(false, "cannot create C handles"); return }
    defer { ejm_decoder_destroy(cd); ejm_encoder_destroy(ce) }
    let px = corpusContent(64, 48, "edges", 99)
    let rounds = 1500
    let c = Counts(), e = Counts()
    DispatchQueue.concurrentPerform(iterations: 4) { k in
        let cap = 256 * 192 * 3 + 1
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { out.deallocate() }
        for i in 0..<rounds {
            // thread 0 alternates good and bad input (the string is set, freed and replaced); the others use good input
            let f = k == 0 && i % 2 == 1 ? bad : good
            var w: Int32 = 0, h: Int32 = 0
            let r = f.withUnsafeBytes { ejm_decode(cd, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), f.count, 0, out, cap, &w, &h) }
            if r == 1 && f == good {
                // only a busy return declines a good file
                let s = ejm_decoder_reason(cd).map { String(cString: $0) }
                c.add(busy: s == decoderBusy, other: s == decoderBusy ? nil : "busy return read \(s ?? "NULL")")
            } else if r == 0 { c.add(exact: true) }
            var jp: UnsafeMutablePointer<UInt8>? = nil, len = 0
            let q: Int32 = k == 0 && i % 2 == 1 ? 0 : 75           // quality 0: an error (the string is replaced)
            let er = px.withUnsafeBufferPointer { ejm_encode(ce, $0.baseAddress, 64, 48, 3, 192, q, 2, &jp, &len) }
            if er == 0 { ejm_free(jp); e.add(exact: true) }
            else if q != 0 {
                let s = ejm_encoder_error(ce).map { String(cString: $0) }
                e.add(busy: s == encoderBusy, other: s == encoderBusy ? nil : "busy return read \(s ?? "NULL")")
            }
        }
    }
    report(c.other.isEmpty && c.busy > 0, "C decoder handle, 4 threads x \(rounds): \(c.summary) (wanted: every busy return reads the busy string, some busy)")
    report(e.other.isEmpty && e.busy > 0, "C encoder handle, 4 threads x \(rounds): \(e.summary) (wanted: every busy return reads the busy string, some busy)")
}

/// pthread_create on a closure; returns the thread to join
private func startThread(_ body: @escaping () -> Void) -> pthread_t {
    final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
    var th: pthread_t? = nil
    let arg = Unmanaged.passRetained(Box(body)).toOpaque()
    let rc = pthread_create(&th, nil, { p in
        let b = Unmanaged<Box>.fromOpaque(p).takeRetainedValue()
        b.f()
        return nil
    }, arg)
    precondition(rc == 0 && th != nil, "pthread_create failed")
    return th!
}

private func checkGateRecords(_ t: Tally) {
    let dec = Decoder()
    let jpg = Turbo.encode(corpusContent(64, 48, "smooth", 100), 64, 48, quality: 90, samp: 2)
    _ = dec.decode(jpg)
    let base = dec.gateRecordCount
    let c = Counts()
    let n = 200
    // n threads alive at once (distinct thread ids), each rejected once while the gate is held, then exiting
    let done = DispatchSemaphore(value: 0), exit = DispatchSemaphore(value: 0)
    var ths: [pthread_t] = []
    dec.withGateHeld {
        for _ in 0..<n {
            ths.append(startThread {
                let r = jpg.withUnsafeBytes { dec.declineReason(bytes: $0) }
                c.add(busy: r == Decoder.busyReason && dec.reason == Decoder.busyReason,
                      other: r == Decoder.busyReason ? nil : "declineReason \(r ?? "nil"), reason \(dec.reason ?? "nil")")
                done.signal()
                exit.wait()
            })
        }
        for _ in 0..<n { done.wait() }
    }
    for _ in 0..<n { exit.signal() }
    for th in ths { pthread_join(th, nil) }
    t.check(c.busy == n && c.other.isEmpty, "\(n) threads rejected while the gate is held: \(c.summary) (wanted: all busy)")
    let after = dec.gateRecordCount
    t.check(after == base, "records kept after \(n) rejected threads exited: \(after), before \(base) (wanted: no growth)")
    let fresh = Counts()
    var fths: [pthread_t] = []
    let fdone = DispatchSemaphore(value: 0), fexit = DispatchSemaphore(value: 0)
    for _ in 0..<n {
        fths.append(startThread { fresh.add(busy: dec.reason == Decoder.busyReason); fdone.signal(); fexit.wait() })
    }
    for _ in 0..<n { fdone.wait() }
    for _ in 0..<n { fexit.signal() }
    for th in fths { pthread_join(th, nil) }
    t.check(fresh.busy == 0, "\(n) fresh threads (thread ids may be reused) reading reason: \(fresh.busy) see the busy reason (wanted 0)")
    t.check(dec.reason != Decoder.busyReason, "the holder sees no busy reason: \(dec.reason ?? "nil")")
    // a thread rejected, kept alive until the gate is free, then calling again
    let rejected = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    let again = Counts()
    var keeper: pthread_t? = nil
    dec.withGateHeld {
        keeper = startThread {
            _ = jpg.withUnsafeBytes { dec.declineReason(bytes: $0) }
            let sawBusy = dec.reason == Decoder.busyReason
            rejected.signal()
            released.wait()
            let r = jpg.withUnsafeBytes { dec.declineReason(bytes: $0) }
            again.add(exact: sawBusy && r == nil && dec.reason != Decoder.busyReason,
                      other: "rejected: busy \(sawBusy); next call \(r ?? "nil"), reason then \(dec.reason ?? "nil")")
        }
        rejected.wait()
    }
    released.signal()
    pthread_join(keeper!, nil)
    t.check(again.exact == 1, "a rejected thread's next call clears its busy reason: \(again.other)")
}

private func checkDeclineReasonStats(_ t: Tally) {
    let jpg = Turbo.encode(corpusContent(640, 480, "smooth", 101), 640, 480, quality: 90, samp: 2)
    let dec = Decoder()
    dec.recordStages = true
    func snap() -> String {
        "gpu \(dec.gpuSeconds) passes \(dec.passes) host \(dec.hostPrepSeconds) \(dec.hostEncodeSeconds) \(dec.waitSeconds) stages \(dec.stageTimes.count) reason \(dec.reason ?? "nil")"
    }
    t.check(dec.decode(jpg) != nil && dec.gpuSeconds > 0 && dec.passes > 0, "a decode sets the stats: \(snap())")
    let before = snap()
    let q1 = jpg.withUnsafeBytes { dec.declineReason(bytes: $0) }
    let q2 = Data([0xFF, 0xD8]).withUnsafeBytes { dec.declineReason(bytes: $0) }
    let q3 = claimSize(jpg, 8000, 8000).withUnsafeBytes { dec.declineReason(bytes: $0) }
    t.check(q1 == nil && q2 != nil && q3 != nil, "declineReason: good \(q1 ?? "nil"), short \(q2 ?? "nil"), too little data \(q3 ?? "nil")")
    t.check(snap() == before, "after three declineReason queries: \(snap()), before \(before)")
    // after a declined decode the reason stays that decode's
    _ = Data([0xFF, 0xD8, 0xFF, 0xD9, 0, 0]).withUnsafeBytes { dec.decode(bytes: $0) }
    let declined = snap()
    _ = jpg.withUnsafeBytes { dec.declineReason(bytes: $0) }
    t.check(snap() == declined, "after a decline then a declineReason query on a good file: \(snap()), before \(declined)")
}

/// see encoder-buffer-input above
private func encoderBufferInput(_ report: (Bool, String) -> Void) {
    let enc = Encoder()
    let dev = enc.ctx.device
    let w = 64, h = 48
    let px = corpusContent(w, h, "smooth", 102)
    let ref = Turbo.encode(px, w, h, quality: 85, samp: 2)
    let good = px.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: px.count, options: .storageModeShared)! }
    let priv = dev.makeBuffer(length: px.count, options: .storageModePrivate)!
    func throwsWith(_ want: String, _ what: String, _ body: () throws -> Void) {
        do { try body(); report(false, "\(what): returned a file (wanted InvalidInput \"\(want)\")") }
        catch let e as InvalidInput { report(e.description.contains(want), "\(what): InvalidInput \(e.description)") }
        catch { report(false, "\(what): \(error), not InvalidInput") }
    }
    report((try? enc.encode(buffer: good, width: w, height: h, quality: 85)) == ref, "a shared input buffer encodes as libjpeg-turbo")
    throwsWith("storageModeShared", "encode(buffer:) with a .private buffer") { _ = try enc.encode(buffer: priv, width: w, height: h, quality: 85) }
    throwsWith("job 1: ", "encodeBatch with a .private buffer in job 1") {
        _ = try enc.encodeBatch([EncodeJob(buffer: good, width: w, height: h, quality: 85), EncodeJob(buffer: priv, width: w, height: h, quality: 85)])
    }
    throwsWith("buffer too small", "an offset past the buffer") { _ = try enc.encode(buffer: good, offset: 1, width: w, height: h, quality: 85) }
    throwsWith("buffer too small", "a negative offset") { _ = try enc.encode(buffer: good, offset: -1, width: w, height: h, quality: 85) }
    throwsWith("buffer too small", "rows past the buffer") { _ = try enc.encode(buffer: good, width: w, height: h, rowBytes: w * 3 + 1, quality: 85) }
    let devs = MTLCopyAllDevices().filter { $0 !== dev }
    if let other = devs.first, let ob = px.withUnsafeBytes({ other.makeBuffer(bytes: $0.baseAddress!, length: px.count, options: .storageModeShared) }) {
        throwsWith("device", "an input buffer of another device") { _ = try enc.encode(buffer: ob, width: w, height: h, quality: 85) }
    } else {
        report(true, "an input buffer of another device: not testable here (one Metal device)")
    }
    report((try? enc.encode(buffer: good, width: w, height: h, quality: 85)) == ref, "the encoder works afterwards")
}
