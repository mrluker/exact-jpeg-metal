import Foundation
import ExactJPEG
import Metal

// ejm encode-fuzz <out_dir> [iters] [seed]: random encoder inputs against libjpeg-turbo. Each iteration picks a size
// (1..300 each side), content (smooth, edges, noise, flat), quality 1..100, subsampling 4:4:4 / 4:2:2 / 4:2:0,
// channels 1, 3 or 4, a row pitch (tight or padded), a buffer offset, and an entry point (encode(bytes:),
// encode(buffer:offset:), or a batch of 2-3 jobs through encodeBatch), on one long-lived Encoder plus a fresh one
// every 64 iterations. 3 and 4 channels must give libjpeg-turbo's bytes for the RGB pixels; 1 channel must throw
// InvalidInput (the encoder takes RGB and RGBA/RGBX only). Mismatching inputs go to <out_dir>/findings;
// summary in <out_dir>/summary.json; the last line, "encode-fuzz: ...", is what scripts/test.sh checks.

func runEncodeFuzz(outDir: String, iters: Int, seed: UInt64) -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outDir + "/findings", withIntermediateDirectories: true)
    var r = Rng(s: seed | 1)
    let dev = MetalContext.shared.device
    var enc = Encoder()
    var counts: [String: Int] = [:], findings = 0
    let t0 = now()
    let subs: [Subsampling] = [.s444, .s422, .s420]
    struct Case { let w, h, q, samp, ch, rb, off: Int; let kind: String; let rgb: [UInt8] }
    func makeCase() -> Case {
        let w = 1 + r.int(300), h = 1 + r.int(300)
        let kind = ["smooth", "edges", "noise", "flat"][r.int(4)]
        let rgb: [UInt8] = kind == "flat" ? [UInt8](repeating: UInt8(r.int(256)), count: w * h * 3) : corpusContent(w, h, kind, UInt32(truncatingIfNeeded: r.next()))
        let q = 1 + r.int(100), samp = r.int(3)
        let ch = [1, 3, 3, 4, 4][r.int(5)]
        let rb = w * ch + (r.chance(0.5) ? 0 : r.int(64))
        let off = r.chance(0.7) ? 0 : 1 + r.int(4096)
        return Case(w: w, h: h, q: q, samp: samp, ch: ch, rb: rb, off: off, kind: kind, rgb: rgb)
    }
    func layout(_ c: Case) -> [UInt8] {
        var px = [UInt8](repeating: 0x5C, count: c.off + c.rb * c.h)
        for y in 0..<c.h { for x in 0..<c.w {
            let s = (y * c.w + x) * 3, d = c.off + y * c.rb + x * c.ch
            if c.ch == 1 { px[d] = c.rgb[s] } else { for k in 0..<3 { px[d + k] = c.rgb[s + k] }; if c.ch == 4 { px[d + 3] = UInt8(truncatingIfNeeded: x &* 7) } }
        } }
        return px
    }
    func label(_ c: Case, _ how: String) -> String { "\(c.w)x\(c.h) \(c.kind) q\(c.q) \(subs[c.samp]) channels \(c.ch) rowBytes \(c.rb) offset \(c.off) via \(how)" }
    func record(_ c: Case, _ how: String, _ got: Result<Data, Error>) {
        let name = label(c, how)
        if c.ch == 1 {
            if case .failure(let e) = got, e is InvalidInput { counts["one_channel_rejected", default: 0] += 1; return }
            findings += 1; print("  FINDING \(name): 1 channel not rejected with InvalidInput (\(got))"); return
        }
        switch got {
        case .failure(let e): findings += 1; print("  FINDING \(name): threw \(e)")
        case .success(let d):
            let want = Turbo.encode(c.rgb, c.w, c.h, quality: c.q, samp: c.samp)
            if d == want { counts["identical", default: 0] += 1 } else {
                findings += 1
                if findings <= 20 {
                    try? Data(c.rgb).write(to: URL(fileURLWithPath: "\(outDir)/findings/\(findings)_\(c.w)x\(c.h)_q\(c.q)_s\(c.samp)_c\(c.ch).rgb"))
                    let n = min(d.count, want.count), first = (0..<n).first { d[$0] != want[$0] } ?? n
                    print("  FINDING \(name): differs from libjpeg-turbo (sizes \(d.count) / \(want.count), first byte \(first))")
                }
            }
        }
    }
    for it in 0..<iters {
        if it % 64 == 63 { enc = Encoder() }
        let mode = r.int(3)
        if mode == 2 {
            let cs = (0..<(2 + r.int(2))).map { _ in makeCase() }
            let jobs = cs.map { c in EncodeJob(buffer: sharedBuffer(layout(c), dev), offset: c.off, width: c.w, height: c.h, channels: c.ch, rowBytes: c.rb, quality: c.q, subsampling: subs[c.samp]) }
            counts["batches", default: 0] += 1
            if cs.contains(where: { $0.ch == 1 }) {
                // one invalid job: the batch throws InvalidInput; the valid ones then go one at a time
                let threw: Bool
                do { _ = try enc.encodeBatch(jobs); threw = false } catch { threw = error is InvalidInput }
                if threw { counts["batch_with_one_channel_rejected", default: 0] += 1 } else { findings += 1; print("  FINDING batch with a 1-channel job did not throw InvalidInput") }
                for (c, j) in zip(cs, jobs) where c.ch != 1 { record(c, "encodeBatch (alone)", Result { try enc.encodeBatch([j])[0] }) }
            } else {
                switch Result(catching: { try enc.encodeBatch(jobs) }) {
                case .success(let outs): for (c, d) in zip(cs, outs) { record(c, "encodeBatch of \(cs.count)", .success(d)) }
                case .failure(let e): for c in cs { record(c, "encodeBatch of \(cs.count)", .failure(e)) }
                }
            }
        } else {
            let c = makeCase(), px = layout(c)
            if mode == 0 {
                record(c, "encode(bytes:)", Result { try px.withUnsafeBytes { try enc.encode(bytes: UnsafeRawBufferPointer(rebasing: $0[c.off...]), width: c.w, height: c.h, channels: c.ch, rowBytes: c.rb, quality: c.q, subsampling: subs[c.samp]) } })
            } else {
                record(c, "encode(buffer:offset:)", Result { try enc.encode(buffer: sharedBuffer(px, dev), offset: c.off, width: c.w, height: c.h, channels: c.ch, rowBytes: c.rb, quality: c.q, subsampling: subs[c.samp]) })
            }
        }
        if it % 1000 == 999 { print("  \(it + 1) iterations, \(fmt(now() - t0, 0)) s, findings \(findings)"); fflush(stdout) }
    }
    let summary: [String: Any] = ["iterations": iters, "seed": seed, "seconds": now() - t0, "counts": counts, "findings": findings,
                                  "reference": Turbo.version, "device": dev.name]
    let js = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try? js.write(to: URL(fileURLWithPath: outDir + "/summary.json"))
    let identical = counts["identical"] ?? 0
    print("encode-fuzz: \(iters) iterations, identical \(identical), 1-channel rejected \(counts["one_channel_rejected"] ?? 0), findings \(findings) (\(fmt(now() - t0, 1)) s)")
    return findings == 0 && identical > 0
}
