import Foundation
import ExactJPEG
import Metal

// ejm: exactness tests and benchmarks for ExactJPEG.
//   ejm corpus                 decode a synthetic corpus, compare with libjpeg-turbo byte for byte
//   ejm api-check [name ...]   API behaviour checks against libjpeg-turbo (APICheck.swift)
//   ejm decode [iters]         speed: Metal vs libjpeg-turbo vs ImageIO on 6720x4480 synthetic photos
//   ejm fuzz <dir> [iters] [seed] mutation fuzzer (see Fuzz.swift)
//   ejm manifest write|check [path]  SHA-256 manifest of libjpeg-turbo outputs (fixed exactness target)
//   ejm decode-files <dir> [iters]    exactness + speed on a directory of JPEGs (no names printed)
//   ejm public-bench <dir> [iters] [--quick] [--out path]  real public JPEGs: exactness and speed (PublicBench.swift)
//   ejm pc-set <dir> [--out path] [--quick]  the PC library's public set on this Mac (PCSet.swift)
//   ejm quick [iters]          Metal-only medians for A/B work (6720x4480 decode, 3840/2048 q95/q90 4:4:4 encode)
//   ejm host                   host-side overhead: Swift vs Objective-C++ command encoding
//   ejm write-synth <out.jpg>  write one synthetic camera-like JPEG (local testing only)
//   ejm export-corpus <dir>    write the decoder corpus as <dir>/<name>.jpg and the iOS timing inputs (Corpus.swift)
//   ejm export-public <outdir> <dir> ...  public-bench's files and libjpeg-turbo references for the iOS --public mode (ExportPublic.swift)
//   ejm decode-profile [rounds] [WxH ...]  per-stage GPU time of a decode (DecodeProfile.swift)
//   ejm selfcheck              run the library's startup self-check: pass or fail, and the time taken
//   ejm profile                the DeviceProfile: layer 1, then the routing measurement (DeviceProfileCmd.swift)
//   ejm inflight [s] [r] [t,..] throughput against images in flight, 1-8 threads (InFlight.swift)
//   ejm decode-split [s] [r] [--quick] [--out path]  2 GPU decoders plus libjpeg-turbo threads on one queue (DecodeSplit.swift)
//   ejm mixed [prefix ...]     mixed-size sequences through one Decoder and one Encoder (Mixed.swift)
//   ejm encode-retry           fresh encoders on images that need a second attempt (Mixed.swift)
//   ejm packed-check [name ...] [trials]  the opt-in packed path: vectors, forged index words, corpus (PackedCheck.swift)
//   ejm packed-bench [rounds]  pack cost, memory and repeat decode time of the packed path (PackedCheck.swift)
//   ejm enc-limit-child <case>  one encoder limit case for `ejm api-check encoder-limits` (EncLimits.swift)
//   ejm usage-child <mode>     one child-process case of the API usage checks (UsageChecks.swift)
//   ejm export-refs-child <dir>  refs.json alone, for no corpus file, for `ejm api-check device-refs` (Corpus.swift)
//   ejm selfcheck-gen [path]   regenerate Sources/ExactJPEG/SelfCheckData.swift with libjpeg-turbo (SelfCheckGen.swift)
//   ejm decline-corpus [--list] generated CMYK/YCCK/RGB/multi-scan/arithmetic/12-bit/lossless/... files (DeclineCorpus.swift)
//   ejm encode-fuzz <dir> [iters] [seed]  random encoder inputs against libjpeg-turbo (EncodeFuzz.swift)
//   ejm turbo-version          the libjpeg-turbo loaded at run time (from its path) and the headers' version
//   ejm exactness <test dir> [out.json] [--allow-runtime] [--allow-dirty]  the exactness record from a passed
//                              scripts/test.sh run (Results.swift)
// With --record=<dir> anywhere on the command line, corpus, encode-corpus, manifest and decline-corpus also write
// their counts to <dir>/<command>.json (scripts/test.sh does; `ejm exactness` reads them).

func now() -> Double { CFAbsoluteTimeGetCurrent() }

func fmt(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

let recordDir = CommandLine.arguments.first { $0.hasPrefix("--record=") }.map { String($0.dropFirst("--record=".count)) }
let args = CommandLine.arguments.filter { !$0.hasPrefix("--record=") }
let cmd = args.count > 1 ? args[1] : "corpus"
/// exit, first writing this command's exactness counts (Exact.v) to <--record dir>/<cmd>.json when one was given
func finish(_ ok: Bool) -> Never {
    if let dir = recordDir, !dir.isEmpty {
        var r = Exact.v
        r["passed"] = ok; r["command"] = Array(args.dropFirst()); r["reference"] = Turbo.version
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let js = try! JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
        try! js.write(to: URL(fileURLWithPath: "\(dir)/\(cmd).json"))
    }
    exit(ok ? 0 : 1)
}
switch cmd {
case "corpus": finish(runCorpus())
case "decline-corpus": finish(runDeclineCorpus(Array(args.dropFirst(2))))
case "encode-fuzz": exit(runEncodeFuzz(outDir: args[2], iters: args.count > 3 ? Int(args[3])! : 2000, seed: args.count > 4 ? UInt64(args[4])! : 1) ? 0 : 1)
case "turbo-version":
    print("runtime \(Turbo.runtimeVersion ?? "unknown")")
    print("headers \(Turbo.headerVersion)")
    print("path \(Turbo.runtimePath)")
case "export-corpus": exit(runExportCorpus(dir: args[2]) ? 0 : 1)
case "export-public": exit(runExportPublic(Array(args.dropFirst(2))))
case "export-refs-child": exit(exportDeviceRefs(dir: args[2], corpus: []) ? 0 : 1)   // api-check device-refs
case "selfcheck": exit(runSelfCheckCommand() ? 0 : 1)
case "selfcheck-gen": exit(runSelfCheckGen(path: args.count > 2 ? args[2] : "Sources/ExactJPEG/SelfCheckData.swift") ? 0 : 1)
case "selfcheck-child": exit(runSelfCheckChild(args.count > 2 ? args[2] : "") ? 0 : 1)
case "enc-limit-child": exit(runEncLimitChild(args.count > 2 ? args[2] : "") ? 0 : 1)
case "usage-child": exit(runUsageChild(args.count > 2 ? args[2] : "") ? 0 : 1)
case "api-check": exit(runAPICheck(Array(args.dropFirst(2))) ? 0 : 1)
case "encode-corpus": finish(runEncodeCorpus())
case "encode": runEncodeBench(iters: args.count > 2 ? Int(args[2])! : 20)
case "fuzz": exit(runFuzz(outDir: args[2], iters: args.count > 3 ? Int(args[3])! : 10000, seed: args.count > 4 ? UInt64(args[4])! : 1) ? 0 : 1)
case "oob-selfcheck":      // a deliberate out-of-bounds write; with MTL_SHADER_VALIDATION=1 (and
                           // MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1) the report goes to stderr only: on macOS 26 and 27
                           // cb.error stays nil. test.sh greps stderr for it.
    let ctx = MetalContext.shared
    let b = ctx.device.makeBuffer(length: 4096, options: .storageModeShared)!
    let desc = MTLCommandBufferDescriptor(); desc.errorOptions = .encoderExecutionStatus
    let cb = ctx.queue.makeCommandBuffer(descriptor: desc)!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(ctx.pipeline("fill_u32"))
    var v: UInt32 = 7, n: UInt32 = 1 << 20
    e.setBuffer(b, offset: 0, index: 0); e.setBytes(&v, length: 4, index: 1); e.setBytes(&n, length: 4, index: 2)
    e.dispatchThreadgroups(MTLSize(width: 4096, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    print("command buffer error: \(String(describing: cb.error))")
case "compile-cost":       // one-time costs, excluded from the benchmarks
    var cold: [Double] = [], psos: [Double] = [], warm: [Double] = [], npso = 0
    for k in 0..<5 {
        let t0 = now()
        let c = try! MetalContext(salt: "cold \(UUID().uuidString) \(k)")
        let t1 = now(); c.warmUp(); let t2 = now(); npso = c.pipelineCount
        cold.append(t1 - t0); psos.append(t2 - t1)
        let t3 = now(); let w = try! MetalContext(); w.warmUp(); warm.append(now() - t3)
    }
    print("Metal library from source, cold (unique source): \(fmt(median(cold) * 1000, 1)) ms; building all \(npso) pipelines (warmUp): \(fmt(median(psos) * 1000, 1)) ms")
    print("same source again in a new context (OS shader cache): \(fmt(median(warm) * 1000, 1)) ms including pipelines")
case "write-synth-small":  // a 1200x800 synthetic camera-like JPEG (q95 4:2:2) for the C example
    try! Turbo.encode(Synth.make(width: 1200, height: 800, seed: 5), 1200, 800, quality: 95, samp: 1).write(to: URL(fileURLWithPath: args[2]))
case "check-reencode":     // out.jpg must equal libjpeg-turbo's q90 4:2:0 encode of libjpeg-turbo's decode of in.jpg
    let i = try! Data(contentsOf: URL(fileURLWithPath: args[2])), o = try! Data(contentsOf: URL(fileURLWithPath: args[3]))
    let r = Turbo.decode(i)!
    let ok = Turbo.encode(r.px, r.w, r.h, quality: 90, samp: 2) == o
    print(ok ? "C API decode + encode: byte-identical to libjpeg-turbo" : "C API output DIFFERS from libjpeg-turbo")
    exit(ok ? 0 : 1)
case "manifest":
    finish(runManifest(args[2], args.count > 3 ? args[3] : "testdata/manifest-libjpeg-turbo-3.2.0.json"))
case "public-bench": exit(runPublicBench(Array(args.dropFirst(2))))
case "pc-set": exit(runPCSet(Array(args.dropFirst(2))))
case "decode-files": exit(runDecodeFiles(dir: args[2], iters: args.count > 3 ? Int(args[3])! : 5) ? 0 : 1)
case "bench-json": runBenchJSON(iters: args.count > 2 ? Int(args[2])! : 20, dir: args.count > 3 ? args[3] : "results/bench")
case "exactness":   // ejm exactness <scripts/test.sh work dir> [out.json] [--allow-runtime] [--allow-dirty]
    let flags = args.dropFirst(2).filter { $0.hasPrefix("--") }, pos = args.dropFirst(2).filter { !$0.hasPrefix("--") }
    if let f = flags.first(where: { !["--allow-runtime", "--allow-dirty"].contains($0) }) { print("unknown flag \(f)"); exit(1) }
    guard let dir = pos.first else { print("usage: ejm exactness <test dir> [out.json] [--allow-runtime] [--allow-dirty]"); exit(1) }
    exit(runExactnessReport(dir: dir, out: pos.count > 1 ? pos[pos.startIndex + 1] : dir + "/exactness.json",
                            allowRuntime: flags.contains("--allow-runtime"), allowDirty: flags.contains("--allow-dirty")) ? 0 : 1)
case "charts": exit(runCharts(results: args.count > 2 ? args[2] : "results", out: args.count > 3 ? args[3] : "docs/images") ? 0 : 1)
case "throughput": runThroughputBench(count: args.count > 2 ? Int(args[2])! : 24)
case "decode-concurrency": runDecodeConcurrency(rounds: 2)
case "decode-ab":          // chunkBits A/B, 1 and 2 decoder threads (DecodeProfile.swift chunkAB): ejm decode-ab [WxH ...]
    let sizes = args.count > 2 ? args.dropFirst(2).map { s -> (Int, Int) in let p = s.split(separator: "x"); return (Int(p[0])!, Int(p[1])!) }
                               : [(640, 480), (1600, 1200), (2048, 1536), (6720, 4480)]
    print("load: \(Bench.shell("sysctl -n vm.loadavg"))")
    var allOK = true
    for (w, h) in sizes {
        let jpeg = Turbo.encode(Synth.make(width: w, height: h, seed: w == 6720 ? 11 : 21), w, h, quality: 90, samp: 2)
        print("ab \(w)x\(h) q90 4:2:0 (\(jpeg.count / 1024) KB)")
        let (lines, _, ok) = chunkAB(jpeg, want: Turbo.decode(jpeg)!.px, bits: [4096, 2048])
        lines.forEach { print($0) }
        allOK = allOK && ok
    }
    exit(allOK ? 0 : 1)
case "decode-profile":     // per-stage GPU time of a decode (DecodeProfile.swift): ejm decode-profile [rounds] [WxH ...]
    let rounds = args.count > 2 ? Int(args[2])! : 3
    let sizes = args.count > 3 ? args.dropFirst(3).map { s -> (Int, Int) in let p = s.split(separator: "x"); return (Int(p[0])!, Int(p[1])!) }
                               : [(640, 480), (1600, 1200), (2048, 1536)]
    print("load: \(Bench.shell("sysctl -n vm.loadavg")); empty dispatches: \(emptyDispatchCost())")
    print("threadgroup memory: \(decodeKernelMemory())")
    for (w, h) in sizes {
        let jpeg = Turbo.encode(Synth.make(width: w, height: h, seed: 21), w, h, quality: 90, samp: 2)
        let (lines, _) = decodeProfileReport(label: "\(w)x\(h) q90 4:2:0 (\(jpeg.count / 1024) KB)", jpeg: jpeg, rounds: rounds, reps: 7)
        lines.forEach { print($0) }
        clockExperiments(jpeg, label: "\(w)x\(h)").lines.forEach { print($0) }
    }
case "perf-large": runPerfLarge(rounds: 6)
case "perf-small": runPerfSmall(rounds: args.count > 2 ? Int(args[2])! : 8)
case "host": runHostBench()
case "profile": runProfileCommand(args.count > 2 ? args[2] : "")
case "profile-child": exit(runProfileChild(args.count > 2 ? args[2] : "") ? 0 : 1)
case "inflight": runInFlight(seconds: args.count > 2 ? Double(args[2])! : 2, rounds: args.count > 3 ? Int(args[3])! : 3,
                             threads: args.count > 4 ? args[4].split(separator: ",").map { Int($0)! } : [1, 2, 3, 4, 6, 8])
case "decode-split": exit(runDecodeSplit(Array(args.dropFirst(2))))
case "quick": runQuick(iters: args.count > 2 ? Int(args[2])! : 30)
case "decode": runDecodeBench(iters: args.count > 2 ? Int(args[2])! : 20)
case "write-synth":
    let img = Synth.make(width: 6720, height: 4480, seed: 1)
    try! Turbo.encode(img, 6720, 4480, quality: 95, samp: 1).write(to: URL(fileURLWithPath: args[2]))
case "mixed": exit(runMixed(Array(args.dropFirst(2))) ? 0 : 1)
case "packed-check": exit(runPackedCheck(Array(args.dropFirst(2))) ? 0 : 1)
case "packed-bench": runPackedBench(rounds: args.count > 2 ? Int(args[2])! : 3)
case "encode-retry": exit(runEncodeRetry() ? 0 : 1)
default: print("unknown command \(cmd)")
}
