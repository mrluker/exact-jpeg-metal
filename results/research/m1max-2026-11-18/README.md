# M1 Max research outputs, 2026-11-18

Raw text output from research runs on the M1 Max MacBook Pro (32-core GPU, macOS 27.2.0) on 2026-11-18. The main
README cites these files for the M1 Max figures on Apple's JPEG engine, the exact GPU plus CPU hybrid decode,
ImageIO's corpus decode and ImageIO's encode sampling.

**Two sets of runs:**

- Quiet (`hybrid-quiet.txt`, `bench-quiet-conditions.txt`): taken after a restart. CacheDelete does not appear
  among the busiest processes logged in `bench-quiet-conditions.txt`. The benchmark record (main 5b9f5b6, a fresh
  clone) `results/bench/m1max-gpu32-2026-11-18-1345.json` started at load 2.31 and ended at 4.48;
  `hybrid-quiet.txt` started at 3.89 and ran at 7 to 8 during its rounds, from its own CPU variants. The README's
  M1 Max CPU comparisons and hybrid figures come from these.
- Busy (`hw-exact.txt`, `hw-speed.txt`, `hw-concurrency*.txt`, `hybrid.txt`): taken earlier that day while
  CacheDelete held 3-4 CPU cores. The one-minute load average was 7.9 to 9.1 during the `hw-speed.txt` rounds
  the README quotes for the engine, 12 to 23 in `hybrid.txt`, and one round of the 640x480 case in `hw-speed.txt`
  reached 29. The README uses these only for the engine's speed and the exactness checks; the CPU-timed figures
  in `hybrid.txt` are superseded by `hybrid-quiet.txt`.

| File | What it is | Produced by |
|---|---|---|
| `hw-exact.txt` | Which APIs reach Apple's JPEG engine (AppleJPEGDriver frame counters), and the decode difference from libjpeg-turbo 3.2.0 of ImageIO, CoreImage and VideoToolbox (BGRA, and the 420f luma plane) on the 12 timing files, plus VideoToolbox and ImageIO encodes | `ejm hw-exact`, branch `research/hw-hybrid` 0c0510d |
| `hw-speed.txt` | Decode images per second for VideoToolbox (hardware, 420f and BGRA) and ImageIO at 1, 2 and 4 threads, on 6720x4480, 4032x3024, 1600x1200 and 640x480, 3 interleaved rounds; then GPU and engine running together | `ejm hw-speed`, branch `research/hw-hybrid` 0c0510d |
| `hw-concurrency.txt` | GPU decoders (2 threads) next to VideoToolbox on 2 threads, alone and together, 3 rounds | `ejm hw-speed` concurrency phase, branch `research/hw-hybrid` 0c0510d |
| `hw-concurrency-vt4.txt` | The same with VideoToolbox on 4 threads | `ejm hw-speed` concurrency phase, branch `research/hw-hybrid` 0c0510d |
| `hybrid.txt` | Exact GPU plus libjpeg-turbo decode: GPU-only, GPU plus CPU mixes and CPU-only, at 6720x4480, 4032x3024 and 1600x1200, with a byte-for-byte check of every GPU output (busy machine; superseded by `hybrid-quiet.txt`) | `ejm hybrid-decode`, branch `research/hw-hybrid` 0c0510d |
| `hybrid-quiet.txt` | The same on the quiet machine (branch `research/hw-hybrid` 0c0510d): best hybrid 298.88 images/s at 6720x4480 (2 GPU decoders plus 8 CPU threads) against 227.27 GPU-only (3 decoders) and 80.77 CPU-only (10 threads); 1796, 3738 and 7593 GPU outputs compared, 0 mismatches | `ejm hybrid-decode`, branch `research/hw-hybrid` 0c0510d |
| `bench-quiet-conditions.txt` | The stdout of the run that wrote `results/bench/m1max-gpu32-2026-11-18-1345.json`, plus a start line and an end line with the load average and the busiest processes | `bash scripts/bench.sh` at main 5b9f5b6 (fresh clone), plus the start and end lines |
| `imageio-vs-libjpeg-turbo-corpus.txt` | Per file: ImageIO default decode against libjpeg-turbo 3.2.0 `djpeg` PNM output on the 309-file decoder corpus (channels, max difference, fraction of values differing, PSNR) | `imageio-vs-libjpeg-turbo-corpus.swift` (arguments: the PNM directory, then the JPEG files) |
| `imageio-encode-sampling.txt` | The SOF component sampling factors of ImageIO JPEG encodes of a 512x512 test image at quality 0.5 to 1.0 | `imageio-encode-sampling.swift` |
