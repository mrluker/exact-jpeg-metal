# Changes

## 0.1.0 (2026-11-19)

First tagged release (`v0.1.0`). Everything below, from the first public commit on.

## 2026-11-19: `ejm decode-split`

New command `ejm decode-split [seconds] [rounds] [--quick] [--out <path>]` (CLI.md): decode throughput with 2 GPU
decoder threads plus N libjpeg-turbo threads on one shared queue, against GPU only (2 in flight) and libjpeg-turbo
on all cores, every bar from one run, as the sister PC library measured it (1.46x at 2 MP, 1.09x at 6 MP, 0.97x and
0.95x at 12 and 24 MP, 1.06x on 30 MP photos there). Sizes 2, 6, 12, 24 and 30 MP at q90 4:2:0 plus 30 MP q95
4:2:2, 16 distinct synthetic JPEGs per size, N = cores - 1 and cores - 2, medians over 3 interleaved rounds. Every
decoded image is compared byte for byte with libjpeg-turbo's; a mismatch exits 1.

Fairness fixes after review: the rate counts only decodes completed by the deadline, over the window length (no
tail); the gain always uses the split declared in advance, 2 GPU threads + (cores - 1) libjpeg-turbo threads, with
cores - 2 reported but never chosen; 16 JPEGs per size; `charts` refuses a record with `passed` not true or a
missing variant, and picks the latest record per chip and GPU core count by its `measured` time. Writes
`results/bench/<chip>-gpu<cores>-<date>-<HHmm>-decode-split.json`. `ejm charts` draws `docs/images/decode-split.svg`
from the latest non-quick record per chip (skipped with a message when there is none yet) and no longer reads
`*-decode-split.json` files as `bench-json` runs. A `--quick` smoke run on an M1 Max after the fairness fixes (not results):
8260/8260 decodes identical, gains (2 GPU + 9 libjpeg-turbo threads) 1.27x, 1.52x, 1.38x, 1.08x, 1.08x and 1.10x
from 2 MP to 30 MP 4:2:2. No full run is recorded yet.

## 2026-11-19: launch README

The README is rewritten for the public repository, in the layout of exact-gpu-jpeg's: the identity claim, the
public set (102 JPEGs) on the M1 Max, the M4 and the iPhone 13, the synthetic benchmarks, where it loses, the claim
table, install, use and credit. The opt-in packed repeat-decode path is named UnHuff ("a Huffman-free coefficient
format for exact repeat JPEG decodes"); its API names (`Decoder.decodeAndPack`, `Decoder.decode(packed:)`) are
unchanged and it stays in memory only. API.md's section heading follows. The README's `<!-- generated:... -->`
blocks of synthetic tables are gone (`ejm charts` reports "no markers" for them and still writes the charts). The
install lines name `github.com/mrluker/exact-jpeg-metal` on the `main` branch (no release tag yet).

## 2026-11-19: `ejm pc-set`

New command `ejm pc-set <pc-set dir> [--out <path>] [--quick]` (CLI.md): the sister PC library's public-set
benchmark on this Mac, row for row in the PC's shape, over 17 public images (rgb8bit and the 3 libjpeg-turbo vgl
frames) and 102 Pillow-made JPEGs (6 settings). A quick smoke run on an M1 Max: 102/102 decodes and 102/102 packed
decodes identical to libjpeg-turbo, 68/68 encodes of the source PPMs byte-identical to Pillow's files (so Pillow
13.0.0 writes the same JFIF header and choices as libjpeg-turbo's defaults at these settings); ImageIO and
VideoToolbox identical on 0 of 102. `PublicBench.swift` helpers it reuses (`mono`, `jnum`, the ImageIO and
VideoToolbox readers) are no longer file-private.

## 2026-11-19: audit fixes, final round (input buffers, C reason strings, call gate, test record)

A last review round found the issues below. Each fix came with a check that failed before it and passes after it
(the self-check case check is verification: the data was already right).

- `Decoder.decode(buffer:length:)` read the input through `contents()` before any check: a `.private` buffer
  (no CPU contents) or one from another device was used unchecked. It now declines first, with "input buffer must
  be .storageModeShared (the decoder reads it on the CPU)", "input buffer is from another Metal device than the
  decoder's" or "length larger than the buffer" (`api-check buffer-input`; before, a `.private` buffer was read
  as "not a JPEG"). The decoder's "no compute encoder" failure now ends the compute encoder when still open.
- `Encoder.encode(buffer:)` and `encodeBatch` did not check the input buffer's storage mode or device: a
  `.private` buffer was encoded (from whatever the GPU read). Each job's buffer must now be `.storageModeShared` on
  the encoder's device, checked with its offset and span before any GPU binding; otherwise `InvalidInput`, a batch
  naming the job (`api-check encoder-buffer-input`; before, a `.private` buffer returned a file, alone and as job 1).
- C API: `ejm_decoder_reason` / `ejm_encoder_error` read the handle's string unsynchronised, and a thread whose
  call returned busy read the other call's string, which that call could free meanwhile. The string is now
  replaced under a lock, and a thread whose last call on the handle was rejected reads the static "decoder used
  from two threads at once" / "encoder used from two threads at once" instead (`api-check c-reason-race`; before,
  every busy return read `NULL`). The header documents both lifetimes.
- The call gate kept the thread id of every thread it ever rejected: the list grew with short-lived threads, and a
  later thread that reused an id read the busy reason. The rejection now lives in the rejected thread's own
  storage, freed when it exits (`api-check gate-records`: 200 records kept and 200 of 200 fresh threads saw the
  busy reason before; none after).
- `Decoder.declineReason(bytes:format:)` reset the last decode's `gpuSeconds`, `passes`, host timings,
  `stageTimes` and `reason`; as a query it now leaves them alone (`api-check decline-reason-stats`).
- `ejm exactness` now refuses a run whose `run.json` does not say libjpeg-turbo 3.2.0 (unless `--allow-runtime`),
  whose fuzz lengths are below `test.sh`'s defaults (read from its `FUZZ_DEFAULT=...` line), or that had
  uncommitted changes (unless `--allow-dirty`); an override is listed in the record's `overrides`. `test.sh`
  passes the two flags itself, with a warning, when they apply (`api-check exactness-record`: 13 of 13 failed
  before).
- iOS check: `ejm export-corpus` writes `refs.json` only with libjpeg-turbo 3.2.0 (removing an older one
  otherwise); `run-device.sh` exports again when `refs.json` is not from 3.2.0 or is older than the `ejm` binary or
  the manifest, and stops when it still is not; the app fails a full run on a `refs.json` from another version
  (`api-check device-refs`). Its `--timing-only`, `--decode-profile` and `--decode-ab` modes end with "no
  exactness checks in this mode" instead of "device check passed".
- `api-check encoder-limits`: the span-real case passed when its sparse buffer could not be made; it is now
  reported as SKIPPED, and api-check and `test.sh` print the count of skipped cases.
- New `api-check selfcheck-cases`: every built-in self-check case's JPEG markers (sampling factors, 16-bit DQT
  values, restart interval) and every encode case's settings match its name; mislabeled controls are rejected.
- Documented: a 16-bit quantisation value above 32767 in a table a component uses declines the file (as since
  2026-11-18), even where every coefficient it would multiply is zero, so libjpeg-turbo's output would not depend
  on it. That rare over-decline is deliberate: safety over a per-coefficient check.

The corpora and their counts are unchanged (decoder 582 exact, 36 declined; encoder 869 of 869).

## 2026-11-19: API usage fixes (threads, Metal setup, C arguments, load correction, stale timings)

Independent reviews found six issues in how the library behaves when it is used in ways it does not support, or
when the machine cannot set it up. Each fix came with a check that failed before it and passes after it.

- One `Decoder` or `Encoder` used from two threads at once was not detected: the calls shared buffers and could
  return another call's pixels or bytes as success. Every public entry point now takes a try-lock for the whole
  call; a call that finds another running declines at once with "decoder used from two threads at once"
  (`Decoder.busyReason`, seen only by that thread through `reason`) or throws `InvalidInput("encoder used from two
  threads at once")` (`Encoder.busyError`); it never waits. `ejm_decode`, `ejm_decode_view` and `ejm_encode` do
  the same per handle (`EJM_DECLINED` / `EJM_ERROR`, the handle untouched). Before (`api-check concurrent-use`, 4
  threads x 200 calls on one instance): the decoder gave 2 wrong results, the encoder and the C handles stopped
  the process; after: every result exact or declined or thrown as busy.
- A Metal setup failure stopped the process (`MetalContext.shared`, a pipeline state that does not build).
  `Decoder()` and `Encoder()` (`init(ctx:)` now takes an optional context, `nil` meaning shared) are made anyway:
  `setupError` holds the error and every call declines or throws with it; `MetalContext.sharedSetupError` reports
  it up front; `ejm_decoder_create` / `ejm_encoder_create` return `NULL`. A kernel that does not build declines
  the decode that needs it, or makes the encoder's `setupError`. Simulated with the new testing variable
  `EJM_TEST_METAL_SETUP` (`api-check metal-setup`: before, all four cases stopped the process).
- `ejm_decode` / `ejm_decode_view` with a length above `SIZE_MAX / 2` (negative as a Swift `Int`) passed it on to
  `UnsafeRawBufferPointer` (a trap in debug builds, a misleading decline in release); now `EJM_ERROR`. With too
  small an output, `ejm_decode` first runs the checks that need no GPU memory (new
  `Decoder.declineReason(bytes:format:)`), so a file that would be declined gets `EJM_DECLINED` with its reason
  instead of `EJM_ERROR` "output buffer too small" (`api-check c-api-args`: 7 of 13 cases wrong before).
- The C header now states how long the reason, error and view pointers live (until the next call on the handle
  or its destruction) and qualifies "out untouched" for a Metal command-buffer failure, as API.md did.
- Load correction: `loadCorrectionEnabled = false` did not stop background device reads already running (up to
  5 s more); a traced call's route advice started them; a decode that needed the 64-pass retry and an encode
  resubmitted for capacity were recorded as load samples. All fixed (3 new checks in `api-check device-profile`,
  each failing before).
- After a call that ended before any GPU work, the decoder's `gpuSeconds`, `passes`, host timings and
  `stageTimes` and the encoder's `gpuSeconds` and `stageTimes` still showed the call before; each call now resets
  them at its start (`api-check stale-stats`: 4 of 6 checks failed before). The self-check's fast-path flags are
  read behind their own lock, so concurrent first calls never read them in a data race.

The corpora and their counts are unchanged (decoder 582 exact, 36 declined; encoder 869 of 869).

## 2026-11-18: decoder audit fixes

An independent review of the decoder found eight issues; each now has an `ejm api-check` group (or, for the
self-check, more checks in `self-check`) that failed before its fix and passes after it.

- A JPEG cut right after a 0xFF byte (no byte after it, no EOI) was decoded with that 0xFF as entropy-coded data.
  libjpeg-turbo's memory source reads it as the start of a marker (a fake EOI) and fills the rest of the scan with
  zero bits, so such a file could be accepted with different pixels: 12 of 12 files whose data ends with a stuffed
  0xFF, cut after it, were (`trailing-ff`). The GPU unstuffing now ends the data at such a byte and both trailer
  checks (`checkTrailer` and its GPU copy) accept a lone final 0xFF; those 12 files are declined, and a whole scan
  followed by a lone 0xFF still decodes exactly.
- `maxPixels` had no clamp, and the kernels index the output, coefficients and planes with 32-bit offsets. An
  image whose output, coefficient (128 bytes per block) or plane buffer would reach 2 GB is now declined ("image
  too large: ..."), whatever `maxPixels` says. Before, 65500x65500 with `maxPixels = Int.max` allocated 12.9 GB
  (`offset-limit`). No image within the default `maxPixels` is affected.
- The layout cache trusted a 64-bit hash of the header bytes; each entry now keeps the bytes and a hit must match
  them exactly. With a forced collision (`Decoder.layoutKeyOverride`, testing only) a second file decoded with the
  first one's quantisers before (`layout-identity`).
- Buffers were allocated before the cheap checks: the input buffer from the file size before the 256 MB check, and
  the output buffer (up to 1 GiB by default) before the "entropy-coded data too short" and GPU budget checks,
  although API.md said the budget was checked before anything is allocated. Every decode path now runs all
  checks that need no GPU memory first, adds a check against the device's `maxBufferLength`, and guards every
  allocation: a failure declines with "cannot allocate the input / output / scratch buffer (N MB)" instead of
  crashing on a force unwrap (also in the scratch arena). Before: a 654-byte file claiming 16384x16384 allocated
  806 MB, a 1 MB `maxGPUBytes` budget allocated 1.9 MB first, a 258 MB file through `decode(path:)` was read into
  a 338 MB buffer, and failing allocations crashed the process; now none allocates anything and the last declines
  (`alloc-order`, `alloc-failure`; testing hooks `Decoder.allocatedBytes`, `Decoder.failAllocations`).
  `decode(path:)` reads the file's first 64 KB for the checks when its buffer must grow.
- A 16-bit quantisation value above 32767 is negative in libjpeg-turbo (int16 multiplier tables), where its C and
  SIMD IDCTs can differ (32768 times a -1 coefficient). Such files were already declined through the IDCT range
  check; they are now declined up front as "quantisation value above 32767" (`quant16`).
- An `output` buffer with `.private` or `.managed` storage, or from another device, was accepted; it is now
  declined ("output buffer must be .storageModeShared on the decoder's device", `output-buffer`).
- The reason "DC value outside int16" was never given: such a DC was reported only as the coefficient range. The
  IDCT now sets its own bit (`dc-reason`).
- The startup self-check decoded every case with 4096-bit chunks, while every stream under 256 KB uses 2048, and
  had no 4:4:0 case and no 16-bit quantisation table. Each case is now decoded at its default chunk size, the
  no-restart case also at 4096 and 64 bits, and two cases are added ("decode 4:4:0", "decode 16-bit quantisation
  tables", from libjpeg-turbo at q8 without `force_baseline`). Its decode half took 12.1 to 18.1 ms before and 13.1
  to 23.9 ms after (5 runs each, noisy M1 Max).

The decoder corpus is unchanged (582 exact, 36 declined, the same declined set).

## 2026-11-18: encoder limits, errors instead of wrong files or traps

An audit of the encoder found inputs that returned a wrong file as success or stopped the process. Each now
throws `InvalidInput` (`EJM_ERROR` from `ejm_encode`), and each has a case in the new `ejm api-check
encoder-limits`, which runs every case in a child process so a trap fails the case instead of the run. Before
the fixes 23 of the 29 original cases failed (13 by trapping); after them all 31 pass (two cases were added with the fixes: an image near the bit limit, and a budget decision that must not depend on the estimate).

- Entropy-coded data over 2^31 - 1 bits (about 256 MB): the GPU's bit counts and offsets are 32-bit signed and
  wrapped. 9000x9000 q100 4:4:4 noise returned a 625-byte file as success (libjpeg-turbo writes 332,727,093
  bytes). The count kernels (`enc_count`, `enc_len`) now also sum each image's bits exactly in 64 bits (one
  SIMD-group sum and one atomic add per 32 blocks); past the limit the encode throws, at or below it no 32-bit
  partial sum can have overflowed. The limit is on the real count, so 30 MP 4:4:4 photos and 8000x8000 q100
  4:4:4 noise (2.10e9 bits) still encode, identical. A GPU count outside 0...blocks x 1744 + 7 (the per-block
  worst case, see API.md "Encoder"), or a stuffed byte count outside bits / 8 to twice that, now throws as an
  internal error instead of being used.
- Pixels spanning more than 4 GiB from the first: the kernels address pixels in 32 bits, and rows past 4 GiB
  read wrong pixels (a sparse 6 GB buffer gave a file different from libjpeg-turbo's). Now rejected.
- Argument checks before anything else: `encode(bytes:)` allocated and copied before validating; sizes and
  offsets near `Int.max`, `rowBytes` of 2^31 or more with one row, a default `rowBytes` that overflows, and
  `ejm_encode` with a huge `row_bytes` or negative `channels` trapped. All checks now come first, with
  overflow-reporting arithmetic, and `rowBytes` is at most 2^31 - 1.
- GPU memory: a new `Encoder.maxGPUBytes` (default half the working set, the decoder's rule). Submissions are
  sized from the current output estimate (before: a fixed 160 bytes per block), a batch is split to fit, an
  image that alone needs more throws, and every allocation is checked (a failed `makeBuffer` trapped). The
  output estimate and buffer capacities are capped at the worst case (one pathological image could otherwise
  make later capacities grow without bound, and a large estimate trapped converting the output capacity to
  32 bits); a resubmitted image is sized from its real count, so every image is done in at most 3 submissions.
  Same bytes in every case.
- Batches: an error in a batch of several jobs names the job ("job 3: quality must be 1...100"); a batch stays
  all or nothing.
- `jpegHeader` checks width, height (1...65500) and quality (1...100) as the encoder does; heights above 65535
  or negative sizes trapped, and quality was clamped silently.
- An empty ICC profile throws, as libjpeg-turbo's `jpeg_write_icc_profile` fails; before, it was skipped
  silently. An empty EXIF block still writes an empty APP1 segment, which is what libjpeg-turbo's
  `jpeg_write_marker` writes (whole file identical).
- Docs: API.md states the verified sizes (widths to 8000, heights to 8000 by whole-file comparison) apart from
  the allowed ones (65500, 2^28 pixels), the new limits, errors and C return codes. The 3.1.2 porting notes stay;
  the output target is libjpeg-turbo 3.2.0.

## 2026-11-18: tests and tools audit fixes

Test and tooling changes only; the library is unchanged. See [CLI.md](CLI.md).

- New `ejm decline-corpus`, run by `test.sh`: 60 generated files (CMYK with and without Adobe APP14, YCCK,
  RGB-coded by Adobe transform 0 or by `R`,`G`,`B` ids, multi-scan sequential, arithmetic SOF9 and SOF10, 12-bit,
  lossless, hierarchical SOF5, fractional sampling, SOF1 8-bit, integral 3x1 and 4x2 factors, and JFIF or Adobe
  transform 1 cases the docs leave open), each decoded to RGB and gray. On an M1 Max with libjpeg-turbo 3.2.0
  (2026-11-18) every class the docs say is declined is declined with a reason, and SOF1 8-bit, the integral
  factors, the JFIF-with-RGB-ids, JFIF-with-Adobe-0 and Adobe transform 1 files decode byte-identical to
  libjpeg-turbo (84 declined, 36 exact, 0 wrong).
- `ejm manifest check` pairs entries by name, fails unless the manifest's reference is libjpeg-turbo 3.2.0, counts
  an accepted decline-expected file as a failure, and requires complete counts (582/582 decodes, 36/36 declines,
  864/864 encodes, which `test.sh` checks). `ejm manifest write` refuses unless the loaded libjpeg-turbo is 3.2.0.
- The libjpeg-turbo version reported everywhere is the one loaded at run time (from the loaded library's path;
  `ejm turbo-version`), not the header macro. `test.sh` warns loudly when it is not 3.2.0 and then relies on the
  pinned manifest check, which must pass with full counts; it no longer reads `pkg-config` for this.
- `ejm mixed`: a truncated or corrupt item is compared with libjpeg-turbo's warned output, and an item
  libjpeg-turbo fails on must be declined; before, these passed when the shared decoder matched a fresh one.
- Fuzzing: `ejm fuzz` fails when under 10% of the mutated files decode exactly (about 20% do), so an all-decline
  regression fails; new `ejm encode-fuzz` (random sizes 1 to 300, strides, offsets, qualities, 1, 3 or 4 channels,
  subsamplings, single and batch calls) against libjpeg-turbo, 5000 iterations in `test.sh`.
- The exactness record: `ejm exactness <test dir> [out]` builds it from a passed `test.sh` run (the steps' own
  recorded counts, the fuzz summaries, the shader-validation report count read from the logs, run id and commit)
  and refuses when any part is missing or failed; `test.sh` writes `work/test-<date>/exactness.json`.
- `test.sh`'s shader-validation pattern matches Metal's general report markers; the deliberate-fault controls still
  must match it. `ejm corpus` fails when libjpeg-turbo cannot give a reference. The C and Swift example scripts
  delete `out.jpg` before running.
- iOS check app: `run-device.sh` exits 5 when the app reported failures. The app checks `.bgr`, `.rgba`, `.bgra`
  decodes and EXIF and ICC encodes against libjpeg-turbo's hashes, exported by `ejm export-corpus` to
  `Corpus/refs.json` (before: the RGB decode reordered, and `jpegHeader` plus the scan; ICC was skipped). Not yet
  run on a device.

## 2026-11-18: `ejm public-bench`, real public JPEGs

A new benchmark command, `ejm public-bench <dir> [<dir> ...] [iters] [--quick] [--out <path>]`, measures the
library on directories of real public JPEGs kept outside the repository and checked against a SHA-256 list
(`SHA256SUMS` or `expected.txt`): for example the q95 4:2:0 and 4:4:4 imagecompression.info images with
libjpeg-turbo's three vgl frames, zune-jpeg's 7680x4320 speed-bench files and Google's Venice sizes. Progressive
files are reported as declined by design, with the other decoders still measured. Per file it records Metal decode
exactness against libjpeg-turbo, wall and GPU time, sync passes and per-stage GPU times; libjpeg-turbo decode on
one thread and on all cores; Metal with 2 decoders in flight; ImageIO and the VideoToolbox hardware JPEG decoder
(code from the research/hw-hybrid branch) with their pixel identity against libjpeg-turbo; and the q95 re-encode,
Metal against libjpeg-turbo byte for byte. Results go to `results/public/`; `--out` writes elsewhere (smoke
runs). Failed calls are counted and mark a case invalid instead of being timed; timing uses a monotonic clock.
Two controls separate decoder error from colour handling: ImageIO with its hardware key false, and VideoToolbox
decoding to bi-planar YCbCr, whose Y plane is compared with libjpeg-turbo's (the BGRA comparison includes
VideoToolbox's YCbCr to RGB conversion). See [CLI.md](CLI.md).

In our runs VideoToolbox's `444f` output on odd-width 4:4:4 images (444/deer 4043x2641, 444/bridge 2749x4049) was
intermittently wrong (Y plane max diff up to 133 where it is otherwise within 1); the cause was not determined.
`public-bench` lists every Y-plane max diff above 1 as an outlier, with the plane's width, height and stride.

## 2026-11-18: opt-in packed copies for repeat decodes

New, off by default (API.md "Repeat decodes from a packed copy"): `Decoder.decodeAndPack(_:format:output:)`
decodes a JPEG and also returns a `PackedCoefficients`, an opaque in-memory copy of the quantised coefficients
the Huffman stage produced; `Decoder.decode(packed:format:output:)` decodes that copy again, in any format,
without the Huffman stage, to the same pixels. It pays for a photo decoded more than once while the copy is in
memory. No file form, no setting or environment variable that turns it on; `decode` encodes the same GPU
dispatches as before (A/B against e35b804, `ejm quick 20`, 7 interleaved rounds, load 11 to 28, 6720x4480: the
minimum GPU times agree within 0.01 ms in all three subsamplings; the medians of the round medians differ by
+0.02, +0.04 and +0.11 ms, within this machine's noise at that load).

Measured on the M1 Max, 6720x4480 synthetic photos (`ejm packed-bench 4`, load 14.8 to 16.9): the pack costs
12.0 to 18.5 ms of CPU once (after the first decode, all cores), the copy holds 12.5 to 22.7 MB of GPU memory
(against the decoder's 94 to 188 MB coefficient arrays) plus the JPEG bytes it keeps, and a repeat decode takes
1.58 to 2.32 ms of GPU instead of 4.62 to 5.51 ms (wall 1.88 to 2.67 ms instead of 5.15 to 6.18 ms).

The new kernel `packed_unpack` (in `kernelNames`, so `warmUp()` now builds 48 pipeline states) checks every
block's index entry before reading through it; a failed check sets a new error bit, the colour kernel writes no
pixels, and the decoder decodes the kept JPEG bytes normally. The block count always comes from the JPEG's frame.

Tests: `ejm packed-check` (the packed form's four test vectors, 4000 kernel runs with forged index entries
behind guard bands and 2000 forged `decode(packed:)` calls that must fall back to identical pixels, the decoder
corpus through the packed path: 582 exact, 36 declined as expected), run by `scripts/test.sh`, which also runs
the vectors and forged entries under Metal shader validation (0 reports) and checks that validation reports a
deliberate out-of-bounds read by the unpack kernel.
## 2026-11-18: the ejm tool moves to its own package, Tools/

The root `Package.swift` declared the libjpeg-turbo reference (`CJPEGTurbo`, a `pkgConfig: "libjpeg"` system
library) next to the library. SwiftPM evaluates every target of a dependency, so an app that depended only on
`ExactJPEG` got these warnings on every build on a machine without Homebrew's pkg-config:
"failed to retrieve search paths with pkg-config; maybe pkg-config is not installed" and, twice, "you may be able
to install libjpeg using your system-packager". That read as "needs libjpeg"; the library needs nothing.

The root package now has only `ExactJPEG` and `ExactJPEGC` (sources unchanged, macOS 14 / iOS 16). The tooling
moved, with its history, to a nested package `Tools/Package.swift` that depends on the root by path:
`Tools/Sources/ejm`, `Tools/Sources/TurboRef`, `Tools/Sources/HostBenchObjC` and `Tools/Sources/CJPEGTurbo`. The
`ejm` commands are unchanged. One difference in how it is linked: a package can depend on another package's
products but not its targets, so `ejm` now depends on the `ExactJPEGC` product and loads the library, Swift API
and C API alike, from `libExactJPEGC.dylib` (built next to it) instead of linking both targets statically. It
still holds one copy of the library; it does not also depend on the `ExactJPEG` product, which would add a second,
static copy (the Objective-C runtime then reports every class as "implemented in both").

```bash
swift build -c release --product ExactJPEGC          # the C library, as before: .build/release/libExactJPEGC.dylib
swift build -c release --package-path Tools          # ejm (needs PKG_CONFIG_PATH, which scripts/env.sh sets)
Tools/.build/release/ejm manifest check              # run from the repository root, as before
```

`scripts/build.sh` builds both packages; the other scripts, `Examples/ios-check` (`project.yml`, `run-device.sh`)
and the docs use the new paths. `scripts/check-docs.sh` also scans `Tools/Sources` for `EJM_*` variables.

## 2026-11-18: README tables match benchmark rows by height too

`ejm charts` looked up the libjpeg-turbo and ImageIO rows of each README table by width, quality and
subsampling only, so the 3840x2880 q95 4:4:4 row showed the 3840x2560 row's CPU and ImageIO times and a wrong
speed-up (M1 Max 10.2x instead of 11.4x). It now matches height as well. The SVG charts already matched the
full size and are unchanged.

## 2026-11-18: iOS routing estimates from the iPhone 13's measurements

The iOS sustained estimate (decode 2.9 ms + 1.0 ms/MP, encode 2.5 + 1.2) came from single calls, which on the A15
run in its slow clock state, so it was 2.2 to 2.7x too high. It is now the iPhone 13's measurement with two
decoders or two encoders kept busy (wall ms per image, the minimum over three runs on 2026-11-18, least squares
from 0.07 to 3.2 MP): decode 0.81 + 0.80 ms/MP, encode 1.13 + 1.20, cold start 8.5 ms (measured, was 10 est.).

| iPhone 13, two in flight | 0.23 MP | 0.31 | 0.79 | 1.92 | 3.15 |
|---|---|---|---|---|---|
| decode measured (min of 3 runs) | 1.16 ms | 1.22 | 1.44 | 2.41 | 3.23 |
| decode estimate, new | 1.00 | 1.06 | 1.44 | 2.35 | 3.33 |
| decode estimate, old | 3.13 | 3.21 | 3.69 | 4.82 | 6.05 |

Encode's small sizes do not lie on one line (0.23 MP 1.91 ms, 0.79 MP 2.51, 0.96 MP 1.55, 1.92 MP 2.92); the new
line puts every measured size on the same side of the default CPU rate (2.5 ms/MP) as the measurement, the old one
two of them on the wrong side. The iOS sporadic estimate (used until the first measurement, and while one is
deferred, for example in Low Power Mode) now comes from the iPhone 13's own isolated calls (its four accepted
routing measurements at 256x256 and 1600x1200: decode 7.5 and 14.4 ms, encode 2.1 and 12.1 ms), not the M4's
ratios, which put the A15's at a third of that. Mac estimates are unchanged.

- api-check `device-profile`: the estimate against the iPhone 13's measurements (decode within 20%, encode on the
  right side of the CPU rate, cold start), the iOS sporadic estimate within 10% of its isolated calls; both failed
  before the change (8 of the new checks).
- The iOS check app's timing section adds two encoders on two threads and ImageIO on two threads for encode.

## 2026-11-18: the iPhone's routing measurement is no longer rejected against its own estimate

The iPhone 13 measured its cold costs and threw them away: "implausible: cold encode fixed cost 2.305 ms is outside
2.500-50.000 ms". The lower bound was the A15's sustained encode estimate (2.5 ms), which is above the phone's real
cold cost, so the phone kept the estimates. A bound now comes from what cannot be true on any device: a cold
fixed cost must be at least 0.05 ms (`minColdFixedMs`; no Apple GPU completes a command buffer round trip faster,
and the fastest seen, the M4's sustained encode, is 0.29 ms). The fitted fixed costs are floored there too, not at
the estimate's. The upper bound (20x the sustained estimate) is unchanged: a rejection on that side means the
device was busy, and the estimate it keeps is the safe side. `DeviceProfile.measurementFailureReason` (new,
public) says why a measurement was not used, as the end of `summary` already did.

- api-check `device-profile`: the A15 case (estimate 2.9 + 1.0, 2.5 + 1.2; encode median 2.305 ms) is accepted
  and its fitted encode fixed cost stays below 2.5 ms; cold costs under the floor (0.01, 0.02 ms) are rejected; a
  cold cost under the sustained estimate but over the floor is accepted. Output bytes are unaffected (routing only).

## 2026-11-17: bench result file names use one clock

`ejm bench-json` (run by `scripts/bench.sh`) named its file from a UTC date and a local time, so an M4 run at
22:42 CST on 2026-11-17 wrote `results/bench/m4-gpu8-2026-11-18-2242.json`. The name and the `date` field in
its conditions now both use local time, as the `work/bench-<host>-<date>` folder does:
`<chip>-gpu<cores>-<yyyy-MM-dd-HHmm>.json`, the same format as the committed files, so `ejm charts` still picks
the latest run per chip by sorting the names.

## 2026-11-17: opt-in timing and tracing

Off by default; off, each call reads one `Bool` (A/B against the previous commit: 640x480 decode +4.6 µs and
encode -4.3 µs wall, within noise). New, all in API.md "Timing and tracing":

- `Decoder.recordStages` / `Encoder.recordStages` and `stageTimes: [StageTime]`: one compute encoder per stage,
  with GPU timestamps at the encoder boundaries (`MTLCounterSampleBuffer`, `.atStageBoundary`), still one command
  buffer, one commit and one wait. Decoder stages: unstuff, segments, chunks, sync0 ... sync<n>, first_blocks,
  decode_write, dc_scan, idct, colour; encoder stages: fill+dct or fill+fused, count or len, scan, write or
  compact, stuff_count, stuff_scan, stuff_scatter. The encoders are ordered by an `MTLEvent`: with `MTLFence`s
  between them the encoder's output differed (the encoder's buffers are untracked). Empty where the device cannot
  sample at stage boundaries. Cost on the M1 Max: 30 MP decode +0.02 to +0.17 ms of GPU, 30 MP encode +0.20 ms.
- `DeviceProfile.routingDecision(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)` returns a
  `RoutingDecision` (the answer, the predicted CPU and GPU times, the GPU set, whether the CPU was cold, the
  detected warmth, the routing source and whether the margin decided it); `prefersCPU` is now a wrapper of it.
- `EJM_TRACE=1` logs one line per decode and encode to stderr (size, subsampling, bytes, ok or the decline
  reason, wall, prep, encode, wait and GPU ms, passes, chunk bits and the routing advice for that size);
  `EJM_TRACE=stages` also records and lists the stages; `MetalContext.trace` receives the same lines in an app.
- `Encoder.profileStages` (it makes invalid output) is now `@_spi(Testing)`; `ejm perf-small` imports the SPI.

Tests: api-check `trace` (stage names and counts for decodes and encodes on both entropy paths and a mixed
batch, the stage sum within the command buffer's GPU time, bytes identical with recording on, `routingDecision`
against `prefersCPU` for 120 argument sets, one trace line per call and none when the callback is nil);
`scripts/test.sh` runs the decoder and encoder corpora again with `EJM_TRACE=stages` (582 exact, 869 identical).

## 2026-11-17: no environment reads per decode

`EJM_COLOR_SPEC` was read on every decode with `ProcessInfo.processInfo.environment[...]`, which rebuilds the
whole environment dictionary each call (about 22 µs with 48 variables, 88 µs with 248). It is now read once per
process (`Decoder.envColorSpec`), like `EJM_CHUNK_BITS`, `EJM_NCP`, `EJM_FUSED_MAX_BLOCKS` and
`EJM_PROFILE_CACHE` already were; `EJM_SELFCHECK_FAIL` (read at most once per self-check half, so never per call)
is read once too. No variable was documented as changeable while a process runs; all are now set before it
starts. No other library code reads the environment. Same bytes (test.sh).

Measured on the M1 Max, 640x480 q95 4:2:2 decodes (median of 400 per process, 6 interleaved rounds against
afbf0c2 under `env -i`, load 8-9 and other GPU work running): wall 41 µs, 66 µs and 316 µs faster with 2, 48 and
248 environment variables. The 640x480 encode does not read the environment and is unchanged (within 5 µs);
30 MP decode and encode differences (up to 0.17 ms either way) are within this machine's noise at 7.8 to 9 ms
per call.

## 2026-11-17: an out-of-bounds read on the encoder's retry path

The encoder sizes its bit-word buffer from an output-size estimate. When an image needed more than that, the
Huffman kernels (`enc_write`, `enc_compact`) wrote nothing and the host encoded the image again with a larger
estimate (`Encoder.retries`), but the byte-stuffing kernels (`stuff_count`, `stuff_scatter`) still ran on the
first attempt and read up to the real bit count, up to about 4 KB past the end of the bit words. In the
two-pass layout the bit words sit near the end of the arena, so for the last image of an exactly sized arena
(over 1 MB) the read left the buffer: a fresh two-pass encoder on 640x480 edges at q75 4:4:4 read at offset
2074880 of a 2074880-byte buffer. Output was never affected (the attempt was always discarded), and only Metal
shader validation showed it. Both stuffing kernels now take `capWords` and return at once when the bits did not
fit, the same test as the Huffman kernels and the host; when they fit nothing changes, so the bytes are the same.

New tests in `scripts/test.sh`:

- the encoder corpus and `ejm encode-retry` (fresh encoders on 640x480 edges q75 and nine noise images at q100
  4:4:4, every one retried) under shader validation, with `EJM_FUSED_MAX_BLOCKS=0` and `2000000`; any report
  fails. Before the fix the two-pass run gave 14 reports;
- `ejm mixed`: mixed-size sequences through one `Decoder` and one `Encoder` (small and 30 MP in both orders,
  mixed shapes and subsamplings, declined files in the middle, gray among colour, 40 distinct headers; encodes
  on the default, two-pass and single-pass paths, with retries and mixed-size `encodeBatch` calls), every output
  compared byte for byte with a fresh instance doing that item alone and with libjpeg-turbo. About 12 s.

## 2026-11-17: close routing calls go to the GPU

On the M4, three live acceptance runs of 56 cells each found every clear-cut cell (winner more than 25% ahead)
routed right every time, while cells within about 20% of a crossover swapped winners between identical runs
(256x256 encode GPU warm / CPU cold: CPU 0.64 ms, then 1.20 ms). New `DeviceProfile.cpuPreferenceMargin` (0.2):
`prefersCPU` advises the CPU only when it is predicted at least 20% faster. A close call then goes to the GPU,
which frees the caller's CPU and keeps the GPU warm for the next call. Fixture (58 cells): no wrong call with the
loser over 25% slower; with the M4's measured warm CPU rates 0-1 wrong calls, regret 0-0.40 ms. The routing
formulas are otherwise unchanged; at this point their errors are within run-to-run noise on the M4.

## 2026-11-17: the cold GPU ramps, and a cold CPU's tiny job is capped

Two fixes to the routing model, found by real-device acceptance tests on an M4. Routing is advice only
(`prefersCPU`); output bytes and the codec path are unchanged.

- **The cold GPU cost saturates.** A long job warms the GPU as it runs: the M4's isolated cold decodes took 4.1 ms
  at 256x256, 7.5 at 1.92 MP, 8.73 at 2.8 MP, 12.38 at 9.8 MP and 25.7-28.5 at 30.1 MP (encode 1.5, 5.6-6.4, 6.48,
  17.97, 26.7-35.6), so past about 3 MP the cold decode climbs 0.5-0.65 ms/MP, the warm slope, not 2.0. The
  straight line (cold fixed + cold slope x MP) put the cold-GPU / warm-CPU crossover at 5.7 MP decode and 6.0 MP
  encode against a real one of about 3 and 2.5-3, sending 3-6 MP jobs to a CPU 1.2-2x slower. The sporadic set
  is now `fixed + warm x MP + rampMs x (1 - exp(-(msPerMP - warm) x MP / rampMs))`, `warm` the sustained per-MP
  cost, fitted through the same two isolated calls (256x256 median, one 1600x1200) with `rampMs` = 2.5 x the
  excess the 1600x1200 call shows over the sustained slope. New optional `Routing` fields `decodeRampMs`,
  `decodeWarmMsPerMP`, `encodeRampMs`, `encodeWarmMsPerMP` (nil: the straight line, as for the warm and
  sustained sets), `Routing.ramp(_:)` and `Routing.costDescription`; `gpuMs(megapixels:operation:)` applies the
  ramp. The chord is held to 6x the sustained slope (was the slope, to 4x) and still rejected over 20x; with no
  excess to ramp (under 0.05 ms) the fit falls back to the old straight line. `estimatedSporadicRouting` is the
  same fit through two calls at the M4's ratios of isolated to sustained time (was every sustained cost x4); on
  the M4: decode 3.95 ms + 2.25 ms/MP (ramp 6.18 ms, then 0.50), encode 1.31 + 3.00 (ramp 8.65, then 0.56). It
  reproduces the M4's isolated calls at 2.8, 9.8 and 30.1 MP within 18% (decode 0%, +18%, -2%; encode +17%,
  -17%, +1%; the second 30 MP runs -12% and -25%), and the crossovers at the default CPU rates are now 2.99 MP
  decode and 3.45 MP encode.
- **A cold CPU's tiny job is capped.** On the M4 a 256x256 encode on a cold CPU took 0.64 ms against 0.49 warm,
  where the model's short-job ratio (4-7) predicts 2-3.5x. `CPUColdModel.coldMs(warmMs:)` is now
  `min(curve, warm + 0.25 ms + (ratio - 1) x max(0, warm - 0.25 ms))` (`cpuTinyPenaltyMs`, `cpuTinyJobMs`), and
  the curve alone is `CPUColdModel.rampedMs(warmMs:)` (the CPU proxy is fitted to it). The cap is continuous. A
  flat `min(curve, warm + 0.25 ms)` under 1 ms warm, as first designed, sent the ground truth's 640x480 decode
  (GPU warm 2.54 / CPU cold 4.02; 0.8-0.9 ms warm) to the CPU, 58% slower, so past 0.25 ms the cap rises at the
  curve's own short-job rate and meets the curve at about 1.2-1.4 ms warm. With the M4's measured CPU model
  (ratio 7.16, rampMs 22.2) the cell "256x256 encode, GPU warm 0.84 / CPU cold 0.64" now goes to the CPU.
- **The acceptance fixture** in api-check `device-profile` gains the M4's 3840x2560 and 6720x4480 rows (16 cells,
  the GPU wins all) and a second 2048x1365 "GPU cold, CPU warm" pair (decode: the CPU wins, 8.73 against 7.36;
  encode a tie, 6.48 against 6.67): 58 cells. It runs with the CPU model fitted from the default proxy and with the
  M4's measured one, each at the default and the M4's measured CPU rates. No run makes a wrong call where the
  loser is over 25% slower. With the fitted model: 2 wrong (640x480 encode warm/warm, 11%; 2048x1365 encode GPU
  cold/CPU warm, 19%), regret 1.27 ms, 0.64 ms per wrong call, at both rates. With the M4's measured model: 3
  wrong (the same two, and 640x480 decode cold/cold, GPU advised, 15%, 0.40 ms), regret 1.67 ms, 0.56 ms per
  wrong call. New checks: the ramp passes through both calls, ramp 2.5 x the excess, the long-job slope the
  sustained one, the chord cap, the degenerate fallback, the M4 estimate against the isolated calls, the tiny
  cap and its continuity, and the cold-GPU / warm-CPU crossover between 2 and 4 MP (3.17 and 3.58 MP on the
  M4-like measured set).
- The cache key now ends in `routing-v5` (the cached sporadic set has the ramp fields); `routing-v4` files are
  ignored. The daily merge keeps the minimum of each ramp field too (the cost rises with each, so the merge is
  never above either set). `summary`, `dictionary` (`decode_ramp_ms`, `decode_warm_ms_per_mp`,
  `encode_ramp_ms`, `encode_warm_ms_per_mp`) and `ejm profile` (the GPU cold line, and `--measure N`'s sporadic
  line) show the ramp.

## 2026-11-17: routing knows whether the GPU and the CPU are warm

`prefersCPU` assumed both sides cold for occasional calls and both warm for `sustained: true`. Either can be
warm or cold on its own: a CPU that just decoded something is ramped up, a GPU 300 ms after its last call is not.
Now the library tracks both and routes on the pair. Evidence: an M4 ground-truth table (ExactJPEG and
libjpeg-turbo 3.2.1, 1 thread; every GPU and CPU warmth, 5 sizes, decode and encode; API.md "Device profile").

- **Automatic state.** The GPU is warm when this process had a command buffer in flight or one finished within
  `warmWindow` (250 ms), read from the command-buffer tracking the busy gate already has (nothing added to a
  decode or encode). The CPU is warm within 250 ms of a new `DeviceProfile.noteCPUWork()`, which a caller's CPU
  codec path calls when a job finishes, or while the process used more than half a core over the last sampled
  window (`getrusage`, read only when `prefersCPU` or `currentWarmth` runs). `DeviceProfile.currentWarmth` (a
  `DeviceProfile.Warmth`) reports both with their ages.
- **`prefersCPU(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)`.** `sustained` is now `Bool?`, default
  nil: follow the GPU's state. New `cpuWarm: Bool? = nil` for the CPU; when nil it is `sustained` if that is
  given. So `sustained: true` alone still means both warm and `sustained: false` alone both cold: existing calls
  compile and keep their meaning. Only a call with both nil (including one that left `sustained` out, which used
  to mean both cold) follows the detected warmth on both sides.
- **A third GPU set, `warmRouting`**, for the automatic warm state: the sustained per-MP costs plus 0.65x
  (`gpuWarmFixedFraction`) the cold fixed costs. The M4's GPU 200 ms after the same work is not the sustained
  one (256x256 decode 3.2-3.5 ms against 1.36 sustained); routing it as sustained sent a 256x256 encode to a GPU
  29% slower.
- **The cold GPU has a cold per-MP cost.** The measurement adds one isolated 1600x1200 decode and one encode, so
  `sporadicRouting` is a measured cold fixed cost plus a measured cold per-MP cost, held between the sustained
  slope and 4x it (the M4's cold slope to 1600x1200 is 2.0 ms/MP decode against 0.50 sustained). Until measured,
  `estimatedSporadicRouting` is every sustained cost x4 (was the fixed costs only). The fixed cost is now the
  256x256 median less that image's 0.066 MP of per-MP work.
- **A CPU cold model, owned by the library**: `cold = warm + rampMs x (1 - exp(-(ratio - 1) x warm / rampMs))`
  (`DeviceProfile.CPUColdModel`, `cpuColdModel`, `pinCPUColdModel(_:)`). The M4's isolated libjpeg-turbo calls
  ran about 4x warm when short and 1.3x at 30 MP; the saturating exponential fitted them with 5% rms error, the
  piecewise `warm x k` up to a cap with 10%. Default `defaultCPUColdModel` (ratio 4.0, rampMs 18), the M4 fit.
  Measured on the device by a CPU proxy in the same background measurement (an integer 8x8 DCT timed chunk by
  chunk from idle on a user-initiated thread, at most 50 ms of CPU), cached with it; a re-measure replaces it
  whole with the newer valid fit (ratio and ramp are fitted together, so no field-by-field merge), and a fit made
  while the GPU part was not used is saved in a file of its own until a full measurement folds it in. A
  proxy run that shows no ramp (an already warm, busy CPU) is not used and the default stays. The design asked
  for the proxy at two sizes, isolated against back to back; a back-to-back warm reference needs about 100 ms of
  CPU on the M4 before its clock is fully up, over the budget, so one isolated run is read at every size and a
  least-squares fit of its chunk times gives the warm rate, the ratio and the ramp together.
- **`cpuMsPerMP` is a warm rate now.** When the CPU is cold the cold model is applied to it. A caller who
  followed the old advice and passed a cold rate should pass its warm rate (its codec timed back to back).
- **`coldCPUFactor` is deprecated**, not removed (removing a public symbol would break source); it is no longer
  used.
- **The M4 ground truth as acceptance.** api-check `device-profile` measures an M4 profile from M4-like injected
  timings and checks every cell: no wrong call where the loser is more than 25% slower (cells within 10% are
  ties), at the default CPU rates and at the M4's measured ones. Two calls are wrong, both under 25%: a 640x480
  encode warm/warm (11%, 0.19 ms) and a 2048x1365 encode with the GPU cold and the CPU warm (19%, 1.08 ms; the
  GPU's two cold cells there differ by 53%). Regret 1.27 ms over 40 calls, 0.64 ms per wrong call. Every CPU
  ratio from 3.5 to 4.75 and every rampMs from 10 to 30 ms passes. The design's warm/warm crossovers (0.38 MP
  decode, 0.15 MP encode) hold for the sustained set and encode; for decode the sustained estimate and the
  default rate give 0.53 MP (1.33 / (3.0 - 0.5)), and the ground truth's warm/warm decode is a tie at 1024x768,
  so the check uses 0.53 MP.
- The cache key now ends in `routing-v4`; `routing-v3` files are ignored. `summary`, `dictionary` and
  `ejm profile` show the warm set, the CPU cold model (or why the proxy was not used) and the current warmth;
  `ejm profile` prints the crossover for each GPU set against the warm and the cold CPU, and `--measure N` the
  1600x1200 calls and the proxy's fit.
- On the M1 Max (busy: load 9-13 on 10 cores, the busy gate's sample injected as idle), 3 fresh processes: cold
  GPU decode 6.02-6.32 ms + 1.08-1.41 ms/MP (raw slopes from the 1600x1200 call up to 4.5 ms/MP, held to 4x the
  sustained 0.354), encode 1.30-1.73 ms + 1.11-1.58 ms/MP; the CPU proxy saw no ramp in any (the CPU was already
  warm), so the default CPU model stayed. Cost: 3.98-3.99 s of wall time (mostly idle gaps), 40-54 ms of GPU time
  (was 25-30 ms) and 6.6-20.5 ms of CPU for the proxy.
- All warmth timestamps are monotonic (`DispatchTime` uptime), including `GPUActivity`'s command-buffer stamps
  and the busy gate's quiet waits, which used the wall clock (`CFAbsoluteTimeGetCurrent`); a clock reading earlier
  than a stamp reads as cold. The process CPU-time window is 0.05-0.25 s (a busy-then-idle second reads cold 250
  ms later) and skips the library's own proxy run; other host-side work in the process counts as CPU activity.
- Per-call codec cost is unchanged (the command-buffer stamps read the monotonic clock instead of the wall clock).

## 2026-11-17: sporadic advice assumes a cold CPU too

For occasional calls `prefersCPU` compared a cold GPU (sporadic routing) against the CPU's warm rate. On an M4,
isolated libjpeg-turbo calls 250 ms apart ran 2.6-4x their warm rate, so mid-size images (about 0.8-1.5 MP) were
advised to a CPU about 2x slower: at 1024x768 the GPU took 6.3 ms decode and 3.9 ms encode in isolation, the CPU
7.2 and 7.4. New `DeviceProfile.coldCPUFactor` (3.0) multiplies the default CPU rates when `sustained` is false;
with it the M4's sporadic crossovers come out near the measured ones (decode about 0.7 MP, encode about 0.2 MP).
A rate passed by the caller is used as given.

## 2026-11-17: sustained routing is an estimate, sporadic adds a measured cold cost

Measurements on an M4 MacBook Air (Apple9, 8-core GPU, quiet, load 1.4-2.2) showed the two-set measurement did not
work: the sustained keep-alive never reached the warm state (large job 2.3-2.5x the estimate after 11-18 steps),
although `ejm decode-ab` and `ejm decode-profile` reach it easily on the same machine; the sporadic two-parameter
fit was noise between identical runs (decode ms/MP 2.04, 0.085, 2.20; encode 0.63, 0.85, 2.12; fixed cost
4.9-6.2 ms), since each isolated call lands in a different clock state; and it cost 5.1 s of wall time and about
1 s of GPU time, too much at app launch and for a phone's battery. Meanwhile the layer-1 sustained estimate
matches the M4's measured warm state. So:

- Sustained routing is the layer-1 estimate only, from device-reported properties, calibrated on warm
  measurements of two Macs: the M4 (decode 1.33 ms + 0.50 ms/MP, encode 0.29 + 0.56) and the M1 Max (one settled
  warm measurement, decode 1.105 + 0.299, encode 0.227 + 0.382; the estimate gives 1.33 + 0.354 and 0.29 +
  0.396 there). No measurement, no keep-alive.
- Sporadic routing is the sustained per-MP cost plus a measured cold fixed cost per operation: the median wall
  time of 5 isolated 256x256 decodes and of 5 encodes, interleaved, each after at least 250 ms without this
  process's GPU work. `coldStartMs` is the first decode (a fresh decoder). Plausible only between the sustained
  fixed cost and 20x it; otherwise rejected and not cached. `estimatedSporadicRouting` is now the sustained
  per-MP costs with the fixed costs x4 (was every cost x4).
- The busy gate, the cache, the daily re-measure with min-merge, `EJM_PROFILE_CACHE`, `clearCache` and
  `pinRouting` are unchanged. The cache key now ends in `routing-v3`, so `routing-v2` files are ignored.
- On the M1 Max (load 6.2-6.5, busy gate sample injected as idle), 3 fresh processes: cold decode 5.94, 7.03,
  6.76 ms; cold encode 1.79, 2.04, 1.87 ms; cold start 4.9-7.1 ms; 3.9-4.0 s of wall time (mostly the idle gaps)
  and 25-30 ms of GPU time (was about 5 s and 0.4-1.4 s).
- `ejm profile`: the "busy gate now" sample is taken 1 s after this process's last GPU work (Device Utilization %
  is a decaying average, so 300 ms still showed our own self-check), or labelled as including it.
  `--measure N` prints each run's isolated call times.
- Public API: no symbol of the stable API is removed. `Routing.measurementRounds` now holds the isolated calls
  per operation (5); `summary` no longer reports sustained rounds or a "sustained estimate kept" note, and
  `dictionary` drops `sustained_rounds` and `sustained_note`. Removed from the `@_spi(Testing)` hooks:
  `DeviceProfileTesting.converge(_:estimate:)` (now `DeviceProfileTesting.measure(_:estimate:)`),
  `DeviceProfileTesting.sustainedEntry(_:)`, `MeasurementTimings.sporadic`, `.keepAliveRatio`, `.sustainedRound`,
  `.coldStartMs`, `.Times`, `.Ratio`, `.Round` and `init(sporadic:keepAliveRatio:sustainedRound:coldStartMs:)`
  (now `MeasurementTimings.init(decode:encode:)`), `Measurement.sustained`, `.sporadicReason`, `.sustainedReason`,
  `.rounds` and `.keepAliveSteps` (now `Measurement.reason`, `.decodeMs`, `.encodeMs`).
  `DeviceProfileTesting.sampleNow(_:)` gains a `quiet:` parameter (default 1 s). The measurement's own gate also
  waits for 1 s without this process's GPU work (was 300 ms), up to 3 s (was 2 s), for the same reason.
- api-check `device-profile` (88 checks): on injected call times, the median of 5 with one outlier, an
  implausible cold cost rejected (below the sustained fixed cost, above 20x, for decode and encode), sporadic =
  sustained slope + cold fixed cost, the sustained set equal to the estimate, the cache round trip; the keep-alive,
  settle and two-set child modes (`warmup`, `nowarm`, `nowarm2`, `unsettled`) are removed with the code they
  tested.
- Decoder chunking is unchanged: 2048-bit chunks below 256 KB of entropy-coded data on every device. The 8-core
  M4 was 5-9% faster with 2048 bits up to 723 KB (1600x1200 470 KB 1.855 to 1.690 ms, 2048x1536 723 KB 2.186 to
  2.082 ms, 6720x4480 4961 KB 9.86 to 10.49 ms, wall per image at 1 thread), but the iPhone 13's A15 was 6-9%
  slower with 2048 at 723 KB, and a family rule fitted to one 8-core Apple9 GPU would also cover the M3, the M4
  Pro and Max and the A17 Pro.

## 2026-11-17: two routing sets, sporadic and sustained

An Apple GPU under a light, bursty load settles into one of several clock states, and two timing rounds agree
within 10% inside any of them: on the M4, warm (decode 1.33 ms + 0.50 ms/MP, encode 0.29 + 0.56), intermediate
(about 2.5 + 1.03, 0.58 + 1.23) and slow (about 5.3 + 2.3, 0.9 + 2.5). The intermediate state passed the
plausibility check and was cached (crossovers 1.30 MP decode and 0.46 MP encode against the real 0.38 and 0.15),
and the slow state was rejected on every launch, so each launch re-measured for 0.5-1 s. The iPhone 13's A15 drops
to a slow state after about 0.5 s of sequential commit-and-wait decodes (1600x1200 at 11.2 ms of GPU time) and
stays at 2.9 ms with one command buffer always queued. Both states are real for apps, so:

- Two sets: `sporadicRouting` (also `routing`; single calls, each timed after 250 ms of GPU idle, plus the cold
  start) and `sustainedRouting` (2 threads keeping 2 command buffers in flight, after a keep-alive of 2048x1536
  jobs has brought the large job within 1.5x of the estimate; then rounds until two agree within 10%).
  `prefersCPU(width:height:operation:cpuMsPerMP:sustained:)`: `sustained: true` for a caller that keeps 2 or more
  jobs in flight, `false` (the default) for occasional single calls. `pinRouting(_:sustained:)`,
  `estimatedSporadicRouting` (the warm estimate x4).
- Plausibility: sustained above 2x the estimate's ms/MP (or 4x its fixed cost) is rejected; sporadic only above
  10x, since slow states are genuine there.
- If the sustained set never reaches the warm state (or never settles), the sporadic set is cached alone, the
  sustained estimate is kept and said so in `summary`, and later launches do not re-measure; the sustained set is
  retried in the daily re-measure. Cache files from before this change are ignored (the key now ends in
  `routing-v2`).
- `ejm profile` prints both sets; its "busy gate now" sample waits for 300 ms without this process's GPU work.
- On the M1 Max (load 44 to 160 with about 50% outside GPU utilization, idle sample injected) sporadic measured
  decode 4.5-7.7 ms + 0.0-2.5 ms/MP; the sustained set never reached the warm state (large job 1.7-5.6x the
  estimate, also over a 3 s keep-alive), so its estimate was kept. Cost about 5 s wall, 0.4-1.4 s GPU.
- api-check `device-profile` (103 checks) covers each path on injected timings: a cold keep-alive and first round
  give the settled sustained set, a GPU that never warms or never settles keeps the sustained estimate with the
  sporadic set cached alone and not re-measured on the next launch, each set's own plausibility bound,
  `prefersCPU(sustained:)`.

## 2026-11-17: 2048-bit Huffman chunks for small images

When `Decoder.chunkBits` and `EJM_CHUNK_BITS` are unset, an image with less than 256 KB of entropy-coded data is now
decoded in 2048-bit chunks (was 4096 for every size). Output bytes are unchanged: the whole decoder corpus decodes
byte-identically with 2048-bit chunks (582 of 582), and api-check already covers every power of 2 from 64 to 65536.
Interleaved A/B (`ejm decode-ab`, iOS check app `--decode-ab`, 4 rounds, one decoder thread, wall per image):
iPhone 13 (A15) 256x256 4.42 to 3.84 ms, 640x480 6.76 to 5.89 ms, 1024x768 8.28 to 7.65 ms; M1 Max 256x256 1.40 to
1.25 ms, 640x480 1.85 to 1.53 ms, 1024x768 1.91 to 1.64 ms. Images from 256 KB up keep 4096 bits (at 470 KB the
two settings were within noise on both devices; at 723 KB 4096 was 6% faster on the A15).

## 2026-11-17: self-check failure reasons say how a case failed

A failed case now ends with "(output differs)", "(declined: <reason>)" or "(<error type>: <message>)", after the
case name. The "self-check failed on <GPU name>, <OS version>: <case>" prefix is unchanged and matches the CUDA
sibling library's.

## 2026-11-17: the routing measurement waits for a warm GPU

On the M4 the cached routing came from a measurement taken before the GPU clock ramped (decode 5.26 ms +
2.17 ms/MP against a settled 1.33 + 0.50): crossovers of 7 MP decode and 5 MP encode against the real 0.38 and
0.15 MP, so `prefersCPU` would have sent 2048 and 3840 encodes to a CPU 3-5x slower for a day. Fixed:

- The measurement repeats timing rounds until two in a row agree within 10% on every fitted field, at most
  about 1 s; the result is their mean (`Routing.measurementRounds` says how many). Not settled: nothing cached,
  the estimate stays, retried at the next allowed time.
- A result more than 3x the estimate's ms/MP or 4x its fixed cost is rejected the same way; `summary` says why.
- The estimate is re-based on the settled M4 numbers (decode 1.33 ms + 0.50 ms/MP, encode 0.29 + 0.56), with the
  per-MP cost scaled by (8 / cores)^0.25 instead of 8 / cores: the M1 Max settled at decode 2.0 + 0.34 and encode
  0.40 + 0.48, which the old 8 / cores scaling (0.092 ms/MP) would have rejected. iOS: decode 2.9 + 1.0 ms/MP,
  encode 2.5 + 1.2 (est.).
- The busy gate ignores this process's own GPU work: Decoder and Encoder command buffers are tracked, and
  utilization is sampled only after 300 ms without our work (waiting up to 2 s, else deferred). On the M4 a gate
  had read "GPU 47%/0%", most likely the process's own self-check.
- `suggestedInFlight` is 3 with at least 8 GB of working set, else 2 (M4 two-pass encode 157, 218, 230 images/s
  at 1, 2, 3; flat after), capped by memory. The M4 rules in `ejm profile --rules` and api-check use its reported
  working set, 12124 MB.
- On the M1 Max (load 14 to 31, idle sample injected) fresh processes settled at decode 2.04-2.20 ms +
  0.27-0.37 ms/MP and encode 0.39-0.47 + 0.48-0.51, costing 103-281 ms wall and 39-121 ms GPU; at load 35 none
  settled within 1 s, and nothing was cached.
- `ejm inflight` takes a thread list and times single-pass and two-pass encodes; `ejm profile --assume-idle`;
  api-check `device-profile` covers a cold first round, a never-settling and an implausible sequence (in process
  and through the cache in child processes) and the gate waiting out our own GPU work.

## 2026-11-17: the library configures itself per device

New `DeviceProfile` (API.md "Device profile"): what the device reports, the settings derived from it, and routing
advice. No table of device models.

- Layer 1, deterministic: GPU name, family, core count (IORegistry `gpu-core-count` on macOS; an estimate on iOS,
  marked `gpuCoresEstimated`), working set, CPU performance cores; from these `encoderPath`, `suggestedInFlight`
  and `maxGPUBytes` (half the working set, the existing decoder budget).
- Behaviour change: `Encoder.fusedMaxBlocks` now defaults to 0 (two-pass) on Apple9 and later GPUs, where the fused
  kernel was 11-23% slower (M4); earlier families keep the single-pass default (M1 Max: 43% faster at 1500x1000).
  Both paths give identical bytes. `EJM_FUSED_MAX_BLOCKS` overrides the default; an assignment overrides both.
  The self-check now encodes one image on each path whatever the default.
- `suggestedInFlight`: `min(max(ceil(gpuCores / 16), 2), 8)`, capped by the working set at 360 MB per image. New
  `ejm inflight`; on the M1 Max (load 8-9) 30 MP decodes ran at 172, 218, 213, 221, 221, 218 images/s with 1, 2,
  3, 4, 6, 8 threads and 3840x2560 encodes at 251, 306, 314, 317, 335, 338; the M4 had saturated at 2 as well, so
  the requested form `ceil(gpuCores / k)` could not fit both (k = 4 to 7 for the M4, 16 to 31 for the M1 Max) and
  has a floor of 2.
- Layer 2, routing: `routing` (fixed + per-MP wall time of warm decode and encode, cold start), `prefersCPU(width:
  height:operation:cpuMsPerMP:)`, `measuredRouting(timeout:)`, `pinRouting(_:)`, `clearCache()`, `MetalContext.profile`.
  Estimated from the core count until measured; the first read of a profile starts a background measurement
  (utility QoS; M1 Max about 110-190 ms wall, 53-112 ms GPU) cached in the Caches directory per GPU, OS build and
  library version, re-measured at most once a day and merged by field-by-field minimum (merge count and dates in
  the JSON), and only on an idle device (macOS: GPU utilization under 20% twice, load under the core count; iOS:
  not hot, not Low Power Mode), else deferred for 10 minutes. `EJM_PROFILE_CACHE=0` disables the cache. Apps that never read a profile run no measurement;
  6720x4480 decode and 3840x2560 / 2048x1365 encode per-call times are unchanged (4 interleaved rounds of
  `ejm quick` against main).
- Tests: `scripts/test.sh` now covers every value a tuner can pick: the encoder corpus with
  `EJM_FUSED_MAX_BLOCKS=0` and `2000000` (869 of 869 each), the decoder corpus at chunk settings 2048/3 and 8192/15
  (582 exact each, the same declined set; `ejm corpus` prints a `declined set:` line). New api-check check
  `device-profile` (12 checks now). The chunk default stays 4096/7 everywhere (an M4 sweep put it within 3.3% of
  the best).
- `ejm` benchmarks print the profile in use, and `bench-json` records it as `device_profile` in the conditions.
  New `ejm profile`. The iOS check app records the profile (layer 1 and measured routing) in its results.

## 2026-11-17: startup self-check

The library now checks itself on each GPU before trusting it. Before a device's first decode it decodes five small
built-in JPEGs (4:2:0 at an odd size with restart markers, 4:2:0 without restarts spanning 8 Huffman chunks and again in 64-bit chunks for 2 synchronisation passes, 4:2:2,
4:4:4 and gray; to `.rgb`, `.bgr`, `.rgba` and `.gray`), and before its first encode it encodes two synthetic
images (the fused path, and the two-pass path with padded RGBX rows), comparing the SHA-256 of each output with
libjpeg-turbo's. `warmUp()` runs both halves. If anything differs, every later decode on that device declines and
every encode fails, with "self-check failed on <GPU name>, <OS version>: <case>", so callers fall back to their CPU
codec. Each half runs once per process per device; after it passes, the per-call cost is one flag check.

- New: `MetalContext.selfCheck(decode:encode:)`, `SelfCheckFailed` (thrown by the encoder), `EJM_SELFCHECK_FAIL=1`
  (forces a failure for testing), `ejm selfcheck`, `ejm selfcheck-gen` (writes `Sources/ExactJPEG/SelfCheckData.swift`,
  11,852 bytes of libjpeg-turbo JPEG data plus hashes; `scripts/test.sh` checks it is fresh), and the api-check
  check `self-check` (11 checks now).
- Behaviour change for callers: an encoder on a device that failed the check throws `SelfCheckFailed`, not
  `InvalidInput`; C callers see `EJM_DECLINED` / `EJM_ERROR` with the reason. On a working GPU nothing changes,
  and decode and encode output bytes are unchanged.
- Cost (M1 Max, load average 11 to 13, medians of 10 fresh processes, A/B against a build with the check off):
  first decode about 11 ms more, first encode about 2 ms more, `warmUp()` about 29 ms more. Later calls: 6720x4480
  decodes unchanged within noise over 3 interleaved rounds against launch-prep. Details in API.md, "Startup self-check".

## 2026-11-17: `Decoder.startT` is internal

`Decoder.startT` (the `CFAbsoluteTimeGetCurrent()` timestamp at the start of the last decode, used only to compute
`hostPrepSeconds`) was public by accident. Nothing outside the library used it, including `ejm`, so it is now
internal. Source change for callers that read it: use `hostPrepSeconds`, or take a timestamp before the call.
Decode and encode output bytes are unchanged.

## 2026-11-16: five API fixes and `ejm api-check`

A docs review found five places where the API did not do what its documentation or comments said. Each one now
has a check in the new `ejm api-check` (`Sources/ejm/APICheck.swift`, run by `scripts/test.sh`). Each check was
run on the old code first and failed, then passed after the fix. Decode and encode output bytes did not change
for any input that was accepted before.

| # | problem | fix | check (before, then after) |
|---|---|---|---|
| 1 | `Decoder.eagerPasses` was not range-checked. With 0 the decoder read the pass-status array at index -1 and could return wrong pixels (1201x803 file: bytes differ, `passes` 0); with -1 it crashed; more than 64 wrote past the 64-entry array | clamped to 1...64 on assignment (`Decoder.swift`, `eagerPasses` `didSet`) | `eager-range`: crashed (SIGTRAP), 5 failures logged before the crash; then 28 of 28 passed |
| 2 | `MetalContext.warmUp()` / `kernelNames` skipped kernels the library uses: the default colour kernel `color_k` (built per function-constant specialisation) and the encoder's `enc_fused`, `enc_dummy_dcq`, `enc_len`, `enc_compact` | `kernelNames` lists all 24 plain kernels; `warmUp()` also builds 23 `color_k` specialisations (luma full size, chroma kinds 0-4, four colour modes, three gray modes): 47 pipeline states, about 2 ms. New `MetalContext.pipelineCount` | `warmup`: 4 kernels missing, and 26 new pipeline states built after `warmUp()`; then 47 after `warmUp()` and still 47 after decoding 30 files in all formats and encoding |
| 3 | `ejm_decode` promised `out` untouched on `EJM_DECLINED`, but on the zero-copy path (and with Swift `output:`) the colour kernel wrote `out` in the same command buffer that found the error | `first_blocks` (thread 0) now also flags non-convergence (`ERR_SYNC`) and repeats the host's trailer check on the GPU (`ERR_TRAILER`); the colour kernels return at once when any error bit is set. The host still checks the trailer for the reason text and declines with "internal: GPU and host trailer checks disagree" if the two ever differ (`ejm fuzz` reports that as a finding). No extra dispatch or submission | `decline-untouched`: 54 failures (9 declined files x 3 formats; zero-copy and `output:` both overwritten); then 117 of 117 passed, including accepted trailers still accepted |
| 4 | gray JPEG to `.rgba` / `.bgra` declined ("gray JPEG to RGBA not implemented") although `PixelFormat` said gray is replicated in all four colour formats | colour mode 6: Y, Y, Y, 255, as libjpeg-turbo's `JCS_EXT_RGBA` / `JCS_EXT_BGRA` (`Decode.metal` `put_px`) | `gray-rgba`: 10 of 10 declined; then 10 of 10 byte-identical to libjpeg-turbo |
| 5 | `jpegHeader` stopped the process with a precondition failure for an EXIF block over 65533 bytes or an ICC profile over 255 chunks, where the encoder throws `InvalidInput` | `jpegHeader` now `throws` `InvalidInput` with the encoder's messages (source change for callers: add `try`) | `header-limits`: crashed (SIGTRAP) at the first oversized block; then 5 of 5 passed |

The checks that replace "not verified" entries in [API.md](API.md), all against libjpeg-turbo 3.2.0 on 30
synthetic files (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1, gray; 1x1 to 1201x803, odd sizes, restart intervals):

| check | result |
|---|---|
| `formats`: Swift decode to `.rgb`, `.bgr`, `.gray`, `.rgba`, `.bgra` | 150 of 150 byte-identical |
| `c-api`: `ejm_decode` zero-copy and copy paths and `ejm_decode_view`, all five formats | 450 of 450 |
| `output`: `decode(bytes:...output:)` (exact size and 4096 bytes larger) and `decode(buffer:length:...output:)`; one byte short declines | 600 of 600. No offset parameter, so a nonzero output offset is not supported |
| `icc`: ICC of 560, 65519, 65520, 200000 and 255 x 65519 bytes, EXIF of 1006 and 65533 bytes, EXIF plus ICC; 4:4:4 and 4:2:0; whole file against `jpeg_write_marker` + `jpeg_write_icc_profile` (what `tj3SetICCProfile` uses), and the decode | 48 of 48 |
| `tuning`: `eagerPasses` 1, 2, 4, 16, 64; `chunkBits` 64 to 65536 by powers of 2 x `checkpoints` nil, 1, 2, 3, 7, 15, 31 | 375 of 375 (no limit found) |

Performance (base a9c4fae against this change, 3 interleaved rounds, same machine under background load; minimum
GPU time per case): 6720x4480 decodes 4.905 / 4.604 / 5.566 ms before, 4.907 / 4.610 / 5.592 ms after; 1200x800
decode 1.38 ms both; encodes unchanged (2.892 to 2.882 ms, 0.780 to 0.774 ms; small batches equal). The
differences are within run-to-run noise.
