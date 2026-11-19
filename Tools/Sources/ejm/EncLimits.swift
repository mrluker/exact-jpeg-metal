import Foundation
import Metal
@_spi(Testing) import ExactJPEG
import ExactJPEGC
import TurboRef

// ejm enc-limit-child <case>: one encoder argument or resource limit, run in its own process by
// `ejm api-check encoder-limits` so that a trap (the failure mode these cases guard against) fails that case
// instead of ending the run. Prints "OK <detail>" when the encoder behaved as documented (threw InvalidInput or
// returned EJM_ERROR with a clear message, or wrote the same file as libjpeg-turbo), "BAD <detail>" otherwise;
// a crash shows as a signal exit status in the parent.

/// the cases, in the order api-check runs them
let encLimitCases = [
    "bits-bound", "bits-job", "bits-noise", "bits-near-limit", "bits-implausible", "tiles-implausible",
    "span-job", "span-real",
    "args-bytes-overflow", "args-validate-overflow", "args-offset-overflow", "args-rowbytes-int32", "args-job-init",
    "args-validate-first", "c-overflow", "c-negative-channels", "c-channels-5", "c-rowbytes-small",
    "budget", "budget-batch", "fail-staging", "fail-output", "fail-scratch", "estimate-poison", "budget-estimate",
    "batch-index",
    "header-height", "header-negative", "header-quality",
    "empty-icc", "empty-exif",
]

private func expectThrow(_ want: String, _ body: () throws -> Void) -> (Bool, String) {
    do { try body(); return (false, "accepted (expected InvalidInput containing \"\(want)\")") }
    catch let e as InvalidInput {
        return (want.isEmpty || e.description.contains(want), "InvalidInput: \(e.description)")
    } catch { return (false, "threw \(type(of: error)): \(error)") }
}

private func turboMeta(_ px: [UInt8], _ w: Int, _ h: Int, _ q: Int, _ s: Int, exif: Data?, icc: Data?) -> Data? {
    var out: UnsafeMutablePointer<UInt8>? = nil
    var len = 0
    var one: UInt8 = 0          // a valid pointer for an empty block (libjpeg-turbo tells nil from length 0)
    func ptr(_ d: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
        guard let d else { return body(nil, 0) }
        if d.isEmpty { return withUnsafePointer(to: &one) { body($0, 0) } }
        return d.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count) }
    }
    let r = px.withUnsafeBufferPointer { p in
        ptr(exif) { e, el in ptr(icc) { i, il in tr_encode_meta(p.baseAddress, Int32(w), Int32(h), Int32(q), Int32(s), e, el, i, il, &out, &len) } }
    }
    guard r == 0 else { return nil }
    defer { tr_free(out) }
    return Data(bytes: out!, count: len)
}

/// a page-aligned anonymous mapping (pages are only backed when touched). Testing: EJM_TEST_NO_SPARSE=1 makes it
/// fail, as on a device without the address space
private func sparse(_ n: Int) -> UnsafeMutableRawPointer? {
    if ProcessInfo.processInfo.environment["EJM_TEST_NO_SPARSE"] == "1" { return nil }
    let p = mmap(nil, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
    return p == MAP_FAILED ? nil : p
}

private func noise(_ n: Int, _ seed: UInt64) -> [UInt8] {
    var r = Rng(s: seed)
    var a = [UInt8](repeating: 0, count: n)
    a.withUnsafeMutableBytes { b in
        let w = b.baseAddress!.assumingMemoryBound(to: UInt64.self)
        for k in 0..<(n / 8) { w[k] = r.next() }
        for k in (n / 8 * 8)..<n { b[k] = UInt8(truncatingIfNeeded: r.next()) }
    }
    return a
}

/// the worst-case entropy-coded bits of one block under the standard Huffman tables (JPEG Annex K.3, code counts
/// per length copied here so the check does not read the library's tables): the longest DC code plus the largest DC
/// difference category (11 for 8-bit samples), 63 AC coefficients each at the longest AC code plus the largest AC
/// magnitude category (10), and an EOB at the longest AC code (an EOB replaces a coefficient, so this adds margin)
private func tableWorstBlockBits() -> Int {
    let dcLum = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], dcChr = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    let acLum = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], acChr = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    func longest(_ c: [Int]) -> Int { (c.lastIndex { $0 > 0 } ?? 0) + 1 }
    let dc = max(longest(dcLum), longest(dcChr)) + 11, ac = max(longest(acLum), longest(acChr))
    return dc + 63 * (ac + 10) + ac
}

func runEncLimitChild(_ name: String) -> Bool {
    setvbuf(stdout, nil, _IOLBF, 0)
    let enc = Encoder()
    let dev = enc.ctx.device
    let tiny = dev.makeBuffer(length: 64, options: .storageModeShared)!
    let px8 = [UInt8](repeating: 128, count: 8 * 8 * 3)
    var r: (Bool, String)
    var skipped: String?          // the case could not run here: "SKIPPED <why>", exit 0, not a pass
    switch name {
    // ---- E1: entropy bit counts are 32-bit on the GPU ----
    case "bits-bound":
        let per = tableWorstBlockBits()
        let ok = Encoder.maxEntropyBitsPerBlock >= per && Encoder.maxEntropyBits(blocks: 1000) == 1000 * Encoder.maxEntropyBitsPerBlock + 7
        r = (ok, "bound \(Encoder.maxEntropyBitsPerBlock) bits per block (table worst case \(per)), image bound blocks x bound + 7")
    case "bits-job":
        // 6000x6000 4:4:4 is 1,687,500 blocks, whose worst case (2.9e9 bits) is past 2^31 - 1; smooth content needs far
        // fewer bits, so it is encoded (the limit is on the real count), identical to libjpeg-turbo
        let w = 6000, h = 6000
        let px = corpusContent(w, h, "smooth", 3)
        do {
            let d = try enc.encode(buffer: sharedBuffer(px, dev), width: w, height: h, quality: 100, subsampling: .s444)
            r = (d == Turbo.encode(px, w, h, quality: 100, samp: 0), "6000x6000 q100 4:4:4 smooth: \(d.count) bytes")
        } catch { r = (false, "\(error)") }
    case "bits-noise", "bits-near-limit":
        // 9000x9000 4:4:4 q100 noise: 2.65e9 bits, past 2^31 - 1: must throw on both entropy paths, never return a
        // file (before the fix it returned a 625-byte file). 8000x8000: 2.10e9 bits, just under: identical.
        let over = name == "bits-noise"
        let w = over ? 9000 : 8000, h = w
        let px = noise(w * h * 3, 5)
        let buf = sharedBuffer(px, dev)
        let want = over ? nil : Turbo.encode(px, w, h, quality: 100, samp: 0)
        var oks: [Bool] = [], notes: [String] = []
        for (label, fb) in [("two-pass", 0), ("single-pass", Int.max)] {
            enc.fusedMaxBlocks = fb
            do {
                let d = try enc.encode(buffer: buf, width: w, height: h, quality: 100, subsampling: .s444)
                let same = d == (want ?? Turbo.encode(px, w, h, quality: 100, samp: 0))
                oks.append(!over && same); notes.append("\(label): returned \(d.count) bytes, \(same ? "identical" : "DIFFERENT")")
            } catch {
                oks.append(over && (error as? InvalidInput)?.description.contains("entropy-coded data") == true)
                notes.append("\(label): \(error)")
            }
        }
        r = (oks.allSatisfy { $0 }, "\(w)x\(h) q100 4:4:4 noise: " + notes.joined(separator: "; "))
    case "bits-implausible", "tiles-implausible":
        enc.testHooks = EncoderTestHooks()
        if name == "bits-implausible" { enc.testHooks.totalBitsOverride = -5 } else { enc.testHooks.tileBytesOverride = -5 }
        r = expectThrow("implausible") { _ = try px8.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8) } }
    // ---- E2: the kernels address pixels with 32-bit offsets ----
    case "span-job":
        r = expectThrow("4 GiB") { _ = try enc.encode(buffer: tiny, width: 8, height: 4, rowBytes: Int(Int32.max)) }
    case "span-real":
        // rows 2^31 - 1 bytes apart in a sparse buffer, row 2 at 4 GiB - 2: past the kernels' 32-bit offsets
        let w = 8, h = 4, rb = Int(Int32.max)
        let len = ((rb * (h - 1) + w * 3) + 16383) & ~16383
        guard let base = sparse(len), let buf = dev.makeBuffer(bytesNoCopy: base, length: len, options: .storageModeShared, deallocator: nil) else {
            skipped = "no \(len)-byte sparse buffer on this device"; r = (true, ""); break
        }
        let px = noise(w * h * 3, 9)
        for y in 0..<h { (base + y * rb).copyMemory(from: px.withUnsafeBytes { $0.baseAddress! + y * w * 3 }, byteCount: w * 3) }
        do {
            let d = try enc.encode(buffer: buf, width: w, height: h, rowBytes: rb, quality: 90)
            let want = Turbo.encode(px, w, h, quality: 90, samp: 2)
            r = (false, "returned a file \(d == want ? "identical to" : "DIFFERENT from (wrong pixels)") libjpeg-turbo's")
        } catch { r = ((error as? InvalidInput)?.description.contains("4 GiB") == true, "\(error)") }
        munmap(base, len)
    // ---- E3: argument checks before any allocation, copy or arithmetic that can trap ----
    case "args-bytes-overflow":
        r = expectThrow("") { _ = try px8.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 65500, rowBytes: Int.max / 2) } }
    case "args-validate-overflow":
        r = expectThrow("") { _ = try enc.encode(buffer: tiny, width: 8, height: 4, rowBytes: Int.max / 2) }
    case "args-offset-overflow":
        r = expectThrow("") { _ = try enc.encode(buffer: tiny, offset: Int.max - 10, width: 8, height: 1) }
    case "args-rowbytes-int32":
        r = expectThrow("rowBytes") { _ = try enc.encode(buffer: tiny, width: 8, height: 1, rowBytes: 1 << 31) }
    case "args-job-init":
        r = expectThrow("") { _ = try enc.encodeBatch([EncodeJob(buffer: tiny, width: Int.max, height: 1)]) }
    case "args-validate-first":
        // an invalid quality is reported before the staging buffer is allocated (that allocation fails here)
        enc.testHooks.failAllocation = "staging"
        r = expectThrow("quality") { _ = try px8.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8, quality: 0) } }
    case "c-overflow", "c-negative-channels", "c-channels-5", "c-rowbytes-small":
        let ce = ejm_encoder_create()!
        defer { ejm_encoder_destroy(ce) }
        let (w, h, c, rb, want): (Int32, Int32, Int32, Int, String) = switch name {
            case "c-overflow": (8, 65500, 3, Int.max / 2, "")
            case "c-negative-channels": (8, 1, -1, 24, "channels")
            case "c-channels-5": (8, 1, 5, 40, "channels")
            default: (8, 2, 3, 23, "rowBytes")
        }
        var out: UnsafeMutablePointer<UInt8>? = nil, n = 0
        let rc = px8.withUnsafeBufferPointer { ejm_encode(ce, $0.baseAddress, w, h, c, rb, 75, 2, &out, &n) }
        let msg = ejm_encoder_error(ce).map { String(cString: $0) } ?? "(no message)"
        if rc == 0 { ejm_free(out) }
        r = (rc == -1 && !msg.isEmpty && (want.isEmpty || msg.contains(want)), "returned \(rc): \(msg)")
    // ---- E4: memory budget and allocation failures ----
    case "budget":
        enc.maxGPUBytes = 1 << 20
        let px = noise(1024 * 1024 * 3, 3)
        r = expectThrow("GPU memory") { _ = try enc.encode(buffer: sharedBuffer(px, dev), width: 1024, height: 1024) }
    case "budget-batch":
        // 8 images that fit one at a time but not together: split into several submissions, all identical
        let w = 512, h = 512
        let imgs = (0..<8).map { noise(w * h * 3, UInt64(20 + $0)) }
        enc.maxGPUBytes = 12 << 20
        do {
            let got = try enc.encodeBatch(imgs.map { EncodeJob(buffer: sharedBuffer($0, dev), width: w, height: h, quality: 95) })
            let same = zip(got, imgs).allSatisfy { $0 == Turbo.encode($1, w, h, quality: 95, samp: 2) }
            r = (same, "8 jobs under a 12 MB budget: \(same ? "all identical to libjpeg-turbo" : "DIFFERENT")")
        } catch { r = (false, "\(error)") }
    case "fail-staging", "fail-output", "fail-scratch":
        enc.testHooks.failAllocation = String(name.dropFirst(5))
        r = expectThrow("could not allocate") { _ = try px8.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8) } }
    case "estimate-poison":
        // a huge output estimate (as after one pathological image), or a NaN one, only sizes buffers; capacity is
        // bounded by the worst case, so the next small image still encodes, identical
        let px = noise(64 * 64 * 3, 4)
        let want = Turbo.encode(px, 64, 64, quality: 90, samp: 2)
        var notes: [String] = [], ok = true
        for e in [3e7, Double.nan, Double.infinity, -1] {
            enc.bytesPerBlockEstimateForTesting = e
            do {
                let d = try enc.encode(buffer: sharedBuffer(px, dev), width: 64, height: 64, quality: 90)
                ok = ok && d == want; notes.append("\(e): \(d == want ? "identical" : "DIFFERENT")")
            } catch { ok = false; notes.append("\(e): \(error)") }
        }
        r = (ok, "64x64 after an estimate of " + notes.joined(separator: ", "))
    case "budget-estimate":
        // whether an image fits the budget does not depend on the estimate earlier images left: a 6 MB budget
        // takes 1024x1024 q75 smooth from a fresh encoder and after the estimate rose to 200 B/block
        let w = 1024, h = 1024
        let px = corpusContent(w, h, "smooth", 12)
        let want = Turbo.encode(px, w, h, quality: 75, samp: 2)
        var notes: [String] = [], ok = true
        for e in [12.0, 200.0] {
            let f = Encoder()
            f.maxGPUBytes = 6 << 20
            f.bytesPerBlockEstimateForTesting = e
            do {
                let d = try f.encode(buffer: sharedBuffer(px, dev), width: w, height: h, quality: 75)
                ok = ok && d == want; notes.append("estimate \(e): \(d == want ? "identical" : "DIFFERENT")")
            } catch { ok = false; notes.append("estimate \(e): \(error)") }
        }
        r = (ok, "1024x1024 under a 6 MB budget: " + notes.joined(separator: "; "))
    // ---- E5: batch errors name the job ----
    case "batch-index":
        let jobs = (0..<5).map { EncodeJob(buffer: tiny, width: 2, height: 2, quality: $0 == 3 ? 0 : 75) }
        r = expectThrow("job 3") { _ = try enc.encodeBatch(jobs) }
    // ---- E6: jpegHeader validates its arguments ----
    case "header-height":
        r = expectThrow("65500") { _ = try jpegHeader(width: 8, height: 70000, quality: 75, subsampling: .s420) }
    case "header-negative":
        r = expectThrow("65500") { _ = try jpegHeader(width: -1, height: 8, quality: 75, subsampling: .s420) }
    case "header-quality":
        r = expectThrow("quality") { _ = try jpegHeader(width: 8, height: 8, quality: 0, subsampling: .s420) }
    // ---- E8: empty ICC and EXIF blocks, as libjpeg-turbo ----
    case "empty-icc":
        let ref = turboMeta(px8, 8, 8, 75, 2, exif: nil, icc: Data())
        let a = expectThrow("ICC") { _ = try px8.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8, icc: Data()) } }
        let b = expectThrow("ICC") { _ = try jpegHeader(width: 8, height: 8, quality: 75, subsampling: .s420, icc: Data()) }
        r = (ref == nil && a.0 && b.0, "libjpeg-turbo \(ref == nil ? "fails" : "writes a file"); encode: \(a.1); jpegHeader: \(b.1)")
    case "empty-exif":
        let ref = turboMeta(px8, 8, 8, 75, 2, exif: Data(), icc: nil)
        let got = try? px8.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8, exif: Data()) }
        r = (ref != nil && got == ref, "libjpeg-turbo \(ref.map { "\($0.count) bytes" } ?? "fails"), encoder \(got.map { "\($0.count) bytes" } ?? "threw")")
    default:
        print("BAD unknown case \(name)"); return false
    }
    if let skipped { print("SKIPPED \(skipped)"); return true }
    print("\(r.0 ? "OK" : "BAD") \(r.1)")
    return r.0
}
