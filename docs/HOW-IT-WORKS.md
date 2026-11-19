# How it works

The longer explanations behind the [README](../README.md): the pipeline, how the library configures itself, the
robustness checks, why the iPhone is slow one call at a time, fixed costs, and the comparison with the CUDA
sibling `exact-gpu-jpeg`. The API is in [API.md](API.md), the tools in [CLI.md](CLI.md).

## The decode and encode pipelines

1. Header (Swift, `Header.swift`): strict parse; anything unusual is declined.
2. Unstuffing (GPU): removes byte stuffing and restart markers, records restart-interval offsets.
3. Huffman (GPU): self-synchronising chunks with checkpoints, then a write pass ([huffman-sync.md](huffman-sync.md)).
4. DC prediction (GPU segmented prefix sums, restarting at each interval).
5. IDCT (GPU): libjpeg's `jpeg_idct_islow`, with range checks.
6. Upsampling and colour conversion (GPU): libjpeg's fancy upsampling and fixed-point YCbCr tables.

Encoding: colour conversion, downsampling, forward DCT and quantisation in one kernel; then per-block bit
counts, a prefix sum, parallel bit packing and parallel byte stuffing, in one command buffer (the output size is
estimated from the last image and the encode is redone in the rare case it was too small).

The Huffman method is from André Weißenberger and Bertil Schmidt, "Massively Parallel Huffman Decoding on GPUs",
ICPP 2018, doi:10.1145/3225058.3225076. Because the decoder synchronises chunks by itself, camera files without
restart markers decode on the GPU too.

## What the GPU path declines, and why

Where libjpeg-turbo's result would depend on the build, or where it would conceal an error, the GPU path
declines instead of guessing: coefficients so large that libjpeg-turbo's 16-bit SIMD IDCT and its C IDCT differ;
corrupt data of any kind (libjpeg-turbo then warns and fills in); markers after the scan other than APPn/COM.
Three libjpeg-turbo warnings leave the pixels unchanged, and the GPU path accepts those files (the fuzzer checks
every one is pixel-identical): extraneous bytes before a marker, a missing EOI after a complete scan, an unknown
JFIF version number.

On first use, the library also checks each GPU against libjpeg-turbo: it decodes a few built-in JPEGs and encodes
two synthetic images and compares SHA-256 hashes of the outputs with libjpeg-turbo's. If a future GPU, OS or
shader compiler ever changed a byte, it declines all work on that GPU so callers fall back to their CPU codec
([API.md](API.md#startup-self-check)).

## How the library configures itself

There is no table of device models. The first time an `Encoder` is made, the library reads what the device reports
(GPU family, GPU core count from the IORegistry on macOS or an estimate on iOS, GPU working set, CPU performance
cores) and derives its settings from that: the encoder's entropy path (two-pass on Apple9 GPUs such as the M4,
where the single-pass kernel was 11-23% slower; single-pass before, 43% faster on the M1 Max at 1500x1000), how
many images are worth keeping in flight (`suggestedInFlight`: 3 with at least 8 GB of GPU working set, as on the
M4 and the M1 Max, else 2, as on the iPhone 13) and the decoder's memory budget (half the working set).

The image size below which the CPU beats the GPU depends on how warm each side is, because both settle into
different clock states depending on how they are fed. The GPU has three routing sets:

- **Sustained**, for 2 or more jobs in flight: an estimate from the device-reported core count, calibrated on warm
  measurements of two Macs (the M4 at decode 1.33 ms + 0.50 ms/MP, the M1 Max at 1.105 + 0.299). On iOS it is the
  iPhone 13's own measurement with two decoders or encoders kept busy (decode 0.81 ms + 0.80 ms/MP, encode 1.13 +
  1.20; [CHANGES.md](CHANGES.md)). Measuring it at run time did not work, since a short keep-alive never brought
  the M4 to its warm state.
- **Sporadic**, for one call now and then (the M4 ran those in a slow state; the iPhone 13 dropped to 11.2 ms of
  GPU time for a 1600x1200 decode after 0.5 s of sequential calls): a cold fixed and a cold per-MP cost per
  operation, measured once per device, OS build and library version. The first read of `DeviceProfile.current`
  starts a background timing at utility priority (the median of 5 isolated 256x256 decodes and of 5 encodes, then
  one isolated 1600x1200 decode and one encode, each after 250 ms of GPU idle, every output checked), and the
  result is cached in the Caches directory.
- **Warm**, for a call shortly after another: the sustained per-MP cost plus 0.65x the cold fixed cost.

The caller's CPU codec is warm (its rate) or cold: an idle CPU's clock is down, so a short job runs about 4x its
warm time and a long one loses at most a saturating ramp penalty (the M4: ratio 4.0, 18 ms), measured on the
device with a CPU proxy the library owns (an integer 8x8 DCT timed chunk by chunk from idle, at most 50 ms of CPU,
in the same background timing).

Which state applies is tracked automatically: the GPU is warm within 250 ms of this process's last command buffer
(already tracked, nothing added per call), the CPU within 250 ms of `DeviceProfile.noteCPUWork()`, which your CPU
codec path calls after each job, or while the process uses more than half a core; `DeviceProfile.currentWarmth`
reports both for logging.

A cached result 24 hours old is re-measured once in the background and merged by keeping the lower of each cost,
so a measurement under load never makes the numbers worse. The measurement describes an idle device, so it is
deferred while the device is busy (macOS: GPU utilization 20% or more, or a load average above the core count;
iOS: serious thermal state or Low Power Mode), and a cold cost under 0.05 ms or over 20x the sustained fixed cost
is rejected with the estimate kept (`measurementFailureReason` says why). Reacting to live contention, with a
router that follows recent per-call times, is a separate step (planned). On the M1 Max the first run takes about
4 s of wall time (mostly idle gaps), 40-52 ms of GPU time and up to 50 ms of CPU, off any decode's path; later
processes read the cache.

The routing numbers are advice for the caller
(`prefersCPU(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)`: pass your codec's warm rate if you have one,
leave `sustained` and `cpuWarm` nil to follow the tracked state, or pass `sustained: true` for a batch export with
2 or more jobs in flight). The library always uses the GPU when called, and none of these settings changes a
single output byte or what is declined (the tests run every setting a tuner can pick). Details:
[API.md](API.md#device-profile).

## Robustness

Every header is parsed and validated on the CPU before any GPU work; kernels bound every read and write by sizes
they are given; Huffman decoding detects invalid codes, AC runs past coefficient 63, blocks crossing a restart
marker and data that ends early; every loop is bounded.

`ejm fuzz` mutates 72 small synthetic seed files (bit flips, byte changes, truncation anywhere and at every marker
boundary, inserted and deleted bytes, inserted / removed / renumbered restart markers, stray 0xFF, corrupted
DQT/DHT/SOF/SOS/DRI fields, absurd and zero dimensions, bad component counts and sampling factors, bad segment
lengths, duplicated / dropped / reordered segments, random scan data, spliced scans, trailing data) and checks
that every accepted file is pixel-identical to libjpeg-turbo, that repeated decodes agree, that a known-good file
still decodes exactly after bad ones, and that nothing crashes, hangs or reports a GPU error.

| run (M1 Max, 2026-11-17, `results/exactness.json`) | iterations | declined | decoded exactly | findings |
|---|---|---|---|---|
| `ejm fuzz work/f 200000 1` | 200,000 | 149,412 | 50,588 (9,633 with a benign libjpeg-turbo warning) | 0 |
| with Metal shader validation (`MTL_SHADER_VALIDATION=1`, out-of-bounds access reported) | 20,000 | 14,958 | 5,042 | 0 (no validation reports) |

The decoder and encoder corpora also run under shader validation with no reports, and `scripts/test.sh` checks
that validation does catch a deliberate out-of-bounds write (so a clean run means something).

## Why one call at a time is slow on the iPhone 13

Measured on 2026-11-17 with `--decode-profile` (`Tools/Sources/ejm/DecodeProfile.swift`). Most of a mid-size decode's
time is not work but the GPU's power state. When decodes arrive one at a time (commit, wait, return, next call),
there is about 1 ms of idle GPU between them, and within about half a second the iPhone 13's GPU drops to a slow
state and stays there: a 1600x1200 decode then takes 11.2 ms of GPU time. In the fast state the same decode takes
2.9 ms of GPU time (4.0 ms per call), and with one command buffer always queued (two decoder threads) the GPU
never leaves it. A one-threadgroup ALU loop used as a clock meter ran 1.4-3.7x slower after 50 ms of idle than in
a continuous stream. From idle, one-at-a-time 1600x1200 decodes took 4.8, 6.2, 9.5, then 11.2 ms of GPU time in
successive quarter seconds; two decoder threads stayed at 2.9 ms from the first quarter second on.

The number of passes, dispatches and command buffers is not the cause: a decode is 1 command buffer with 1 commit
and wait (no host readback before it completes; the 64-pass retry never ran on these files), 38 dispatches that
cost about 2.4 µs each on the A15 (0.09 ms in all), 2 of the 8 encoded synchronisation passes do work and the 6
others cost about 0.05 ms together, host preparation and encoding take about 0.3-0.4 ms, and no kernel needs more
than 15.4 KB of the 32 KB of threadgroup memory (the synchronisation pass with six Huffman tables; 10.6 KB for
these files). A 6720x4480 decode keeps the GPU busy long enough to stay fast on its own, which is why the
large-image figures hold one call at a time.

Per-stage GPU time (ms) of one-at-a-time decodes on the iPhone 13 (slow clock state; median of 3 runs, prefix
differences), and on the M1 Max for comparison:

| stage | iPhone 13, 640x480 | iPhone 13, 1600x1200 | iPhone 13, 2048x1536 | M1 Max, 1600x1200 |
|---|---|---|---|---|
| unstuffing (count, 2 scans, scatter) | 0.58 | 1.29 | 1.59 | 0.15 |
| restart segments and chunk table | 0.07 | 0.09 | 0.08 | 0.03 |
| synchronisation pass 1 | 2.92 | 3.76 | 3.65 | 0.98 |
| synchronisation pass 2 | 0.40 | 0.35 | 0.88 | 0.11 |
| passes 3-8 (nothing to do) | 0.03 | 0.05 | 0.00 | 0.01 |
| first blocks, Huffman write pass | 0.99 | 2.76 | 3.84 | 0.29 |
| DC prediction scans | 0.21 | 0.28 | 0.30 | 0.09 |
| IDCT | 0.26 | 1.34 | 2.19 | 0.07 |
| upsampling and colour | 0.24 | 1.34 | 2.01 | 0.05 |
| total GPU (ms) | 5.7 | 11.3 | 14.5 | 1.8 |

The iPhone profile predates the 2048-bit chunks for small streams, so its 640x480 column is the 4096-bit decode.
In the fast state the 1600x1200 decode is 2.9 ms of GPU time. Within it the largest stage is the first
synchronisation pass: each GPU thread decodes one Huffman chunk serially, a latency chain that more GPU cores do
not shorten (it also takes 0.8-1 ms on the 32-core M1 Max at every size up to 3 MP). That pass, plus about 1 ms
of submission and completion latency per call, is the floor for one call at a time.

**For app developers:** below the crossover, the CPU alternative on iOS is ImageIO, which is not byte-identical
to libjpeg-turbo. An app that needs exact output there must bundle libjpeg-turbo for its CPU path, or keep the
GPU busy (two `Decoder`s on two threads, or batches) so that the GPU path stays faster.

## Fixed costs and host overhead

One-time costs, excluded from every benchmark: compiling the Metal library from source (no Xcode or `metal`
compiler needed) takes about 145 ms the first time a process sees this source, then about 1.5-5 ms from the OS
shader cache; building all 47 pipeline states of `MetalContext.warmUp()` (24 kernels and 23 specialisations of
the colour kernel) takes about 2 ms.

Host overhead: encoding a decode's ~45 dispatches takes about 40 µs of CPU in Swift; the same calls from
Objective-C++ (what metal-cpp wraps) take the same time (`ejm host`: about 13 µs in both for 45 trivial
dispatches, about 41-43 µs for 200). Most of the gap between wall and GPU time is the fixed commit-to-completion
latency (about 0.35 ms on an M1 Max), which overlapping several images hides.

## Notes on the benchmark corpus

ImageIO's encoder, at the quality setting whose file size is closest to libjpeg-turbo's, gives a lower PSNR on the
4:4:4 cases of these images (3840x2560 q95 4:4:4: 39.0 dB vs 43.7 dB PSNR against the source, max error 71 vs 20),
because it writes 4:2:0 at every quality below 1.0 (read from the SOF of ImageIO encodes on macOS 27.2). When both
are 4:2:0 they are within 0.2 dB; the table is in the README, "Encode quality against ImageIO".

Speed depends on the content: on a harder, noisier synthetic set (15.9 MB at 6720x4480 q95 4:2:2) libjpeg-turbo
takes about twice as long. `ejm decode-files <dir>` measures your own files (and checks them for exactness)
without printing their names; always say which corpus a number comes from.

## Compared with exact-gpu-jpeg (CUDA)

`exact-gpu-jpeg` is the CUDA sibling of this library (NVIDIA GPUs, Python). Its facts below are from its own
launch checklist as of 2026-11-17 (main 9774451); anything marked *unconfirmed* is not stated there.

The same claim in both:

- **What "exact" means for decoding.** Both READMEs say: if the GPU path returns an image, it equals, byte for
  byte, what libjpeg-turbo produces for that file with the accurate integer IDCT (`JDCT_ISLOW`) and fancy
  upsampling.
- **Supported JPEGs.** Both: 8-bit baseline or extended-sequential Huffman JPEGs with one scan holding all
  components; YCbCr or grayscale; 4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1 and other integral factors; with or without
  restart markers; any valid Huffman tables, the standard tables when a file has none; up to 2^28 pixels by
  default.
- **What is declined.** Both decline progressive, arithmetic coding, lossless, hierarchical, 12-bit, CMYK and
  YCCK, RGB-coded JPEGs, multi-scan sequential files, fractional sampling factors, and corrupt or truncated
  files, and both decline instead of guessing where libjpeg-turbo's output would depend on its build (very large
  coefficients) or would conceal an error.
- **Method.** The same pipeline: strict header parse on the CPU, then unstuffing, self-synchronising Huffman
  decoding (no restart markers needed), DC prediction, libjpeg's `jpeg_idct_islow`, and libjpeg's fancy
  upsampling and colour conversion on the GPU.

Where they differ:

| | exact-jpeg-metal (this library) | exact-gpu-jpeg |
|---|---|---|
| GPU | Apple GPUs, Metal family Apple7 or later (M1 / A14 and newer); macOS 14+, iOS 16+ | NVIDIA GPUs through CUDA (CuPy) |
| API languages | Swift, and a C API (`include/exact_jpeg.h`) for C, C++, Rust, Python | Python (CuPy arrays; PyTorch tensors by DLPack) |
| reference libjpeg-turbo | 3.2.0, arm64 (NEON) build from Homebrew; outputs pinned by a SHA-256 manifest | decode: 3.1.2 (build 20251010) as bundled in simplejpeg 1.9.0's Windows x64 wheel, checked in its AVX2, SSE2 and plain C code paths; second reference Pillow 13.0.0 with libjpeg-turbo 3.2.0, which gave the same images on every file compared. Encode: Pillow 13.0.0 (libjpeg-turbo 3.2.0) |
| decode output | RGB, BGR, gray, RGBA, BGRA; uint8, interleaved | RGB, BGR, gray; uint8, float16 or float32; HWC or CHW |
| memory rules | declines images needing more than half the GPU's recommended working set (`Decoder.maxGPUBytes` overrides) | declines when its estimate exceeds a budget (default 90% of free GPU memory) or the entropy-coded data exceeds 256 MB |
| on a decline | returns `nil` / `EJM_DECLINED` with a reason; the caller falls back | `decode()` falls back to a CPU decoder by default (simplejpeg or Pillow); `fallback=False` returns `None` |
| encoder | yes: output files equal libjpeg-turbo's baseline compressor (`jpeg_set_quality`, standard Huffman tables, islow DCT), that is Pillow's `Image.save(f, "JPEG", quality=q, subsampling=s)`; 4:4:4, 4:2:2, 4:2:0; ICC and EXIF | yes: output equal to Pillow 13's `Image.save` with quality, subsampling, ICC and EXIF, Pillow's defaults otherwise |
| test images | synthetic corpus only (`ejm synthetic v1`, generated at run time) | synthetic corpus, crafted extreme coefficients, CC0 photos and private camera photos |
| tested on | M1 Max, M4, iPhone 13 (README "Limitations") | one GPU: GTX 1070 (compute capability 6.1), Windows 10, driver 560.94, CuPy 14.2.0 on CUDA 12 |

The two libraries are checked against different libjpeg-turbo builds (arm64 here, x86-64 there); neither README
reports a cross-check between them. *Unconfirmed*: that the two produce identical bytes for the same file.
