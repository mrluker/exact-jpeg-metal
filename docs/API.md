# API reference

This is the reference for everything that ships: the Swift library `ExactJPEG`, the C library `ExactJPEGC`
(`include/exact_jpeg.h`) and the environment variables the code reads. The command-line tool and the scripts are
in [CLI.md](CLI.md). `./scripts/check-docs.sh` fails when a public symbol is missing from this page.

Contents: [quick start](#quick-start) · [exactness evidence](#exactness-evidence) · [decoding](#decoding-swift) ·
[encoding](#encoding-swift) · [header parsing](#header-parsing-swift) · [Metal context](#metal-context-swift) ·
[device profile](#device-profile) ·
[errors](#errors-swift) · [C API](#c-api) · [environment variables](#environment-variables) ·
[behaviour notes](#behaviour-notes)

## Quick start

Requirements: macOS 14+ or iOS 16+, an Apple GPU of Metal family Apple7 or later (M1, A14 and newer), SwiftPM.
The library itself needs nothing else; the shaders compile at run time.

### Swift

Add the package (a local checkout works the same way with `.package(name: "exact-jpeg-metal", path: "...")`)
and depend on the product `ExactJPEG`:

```swift
// Package.swift of your app or tool
// dependencies: [.package(url: "https://github.com/mrluker/exact-jpeg-metal", from: "0.1.0")]
// target dependency: .product(name: "ExactJPEG", package: "exact-jpeg-metal")
```

Decode a file, re-encode it, and encode pixels from ordinary memory. This is
[Examples/swift/Sources/swift-example/main.swift](../Examples/swift/Sources/swift-example/main.swift);
`./scripts/swift-example.sh` builds it as a separate package, runs it on a synthetic JPEG and checks that the
re-encode is byte-identical to libjpeg-turbo.

```swift
import Foundation
import ExactJPEG

let dec = Decoder()                                  // one per thread
guard let img = dec.decode(path: "in.jpg", format: .rgb) else {
    print("declined: \(dec.reason ?? "?")")          // decode this file with libjpeg-turbo or ImageIO instead
    exit(1)
}
print("decoded \(img.width)x\(img.height), \(img.channels) channels")

let enc = Encoder()                                  // one per thread
let jpeg = try enc.encode(buffer: img.buffer, offset: img.offset, width: img.width, height: img.height,
                          channels: img.channels, quality: 90, subsampling: .s420)
try jpeg.write(to: URL(fileURLWithPath: "out.jpg"))

let w = 320, h = 200
let px = [UInt8](repeating: 128, count: w * h * 3)  // RGB, 3 bytes per pixel, rows w * 3 bytes apart
let small = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: w, height: h, quality: 85, subsampling: .s444) }
```

### C

`swift build -c release --product ExactJPEGC` builds `.build/release/libExactJPEGC.dylib`. Compile against
`include/exact_jpeg.h` and link it, as `scripts/c-example.sh` does:

```sh
clang -O2 -Iinclude Examples/c/example.c -L.build/release -lExactJPEGC -Wl,-rpath,"$PWD/.build/release" -o example
```

Use a compiler and SDK from the same developer directory: `scripts/c-example.sh` picks them from
`xcode-select -p`, because a mismatched `clang` on `PATH` can fail to link against a newer SDK.

The complete program is [Examples/c/example.c](../Examples/c/example.c); `./scripts/c-example.sh` builds it, runs
it and checks the result against libjpeg-turbo. The core of it:

```c
#include <stdio.h>
#include <stdlib.h>
#include "exact_jpeg.h"

int decode_and_reencode(const uint8_t *jpeg, size_t n, uint8_t **out, size_t *outlen) {
    int w, h, c;
    if (ejm_inspect(jpeg, n, &w, &h, &c) != 0) return 1;            /* not for the GPU path */
    ejm_decoder *dec = ejm_decoder_create();
    if (!dec) return 1;                                               /* no Metal device */
    size_t cap = (size_t)w * h * 3;
    uint8_t *rgb = malloc(cap);
    int r = ejm_decode(dec, jpeg, n, EJM_RGB, rgb, cap, &w, &h);
    if (r != EJM_OK) { fprintf(stderr, "declined: %s\n", ejm_decoder_reason(dec)); free(rgb); ejm_decoder_destroy(dec); return 1; }
    ejm_encoder *enc = ejm_encoder_create();
    r = ejm_encode(enc, rgb, w, h, 3, (size_t)w * 3, 90, EJM_420, out, outlen);   /* free *out with ejm_free */
    if (r != EJM_OK) fprintf(stderr, "encode failed: %s\n", ejm_encoder_error(enc));
    free(rgb); ejm_encoder_destroy(enc); ejm_decoder_destroy(dec);
    return r == EJM_OK ? 0 : 1;
}
```

## Exactness evidence

"Byte-identical" below always means equal to libjpeg-turbo 3.2.0 (Homebrew, arm64), the reference of the test
suite. A claim is marked verified only when one of these checks covers it; everything else says "not verified".

| key | check | what it compares |
|---|---|---|
| corpus | `ejm corpus` (`Tools/Sources/ejm/Corpus.swift:51-86`), run by `scripts/test.sh` | 291 synthetic files (every subsampling, gray, 1x1 to 6720x4480, q1-100, optimised tables, restart intervals), each decoded as `.rgb` and `.gray`: 582 of 582 byte-identical; 18 progressive files x 2 declined |
| manifest | `ejm manifest check` (`Tools/Sources/ejm/Manifest.swift`), run by `scripts/test.sh` | the same decodes and 864 encodes against SHA-256 hashes stored in `testdata/manifest-libjpeg-turbo-3.2.0.json` |
| fuzz | `ejm fuzz` (`Tools/Sources/ejm/Fuzz.swift:217-252`), run by `scripts/test.sh` | every mutated file the GPU path accepts, decoded as `.rgb` (80%) or `.gray` (20%), is pixel-identical |
| encode-corpus | `ejm encode-corpus` (`Tools/Sources/ejm/EncodeBench.swift:11-62`), run by `scripts/test.sh` | 864 RGB encodes (4:4:4, 4:2:2, 4:2:0, q1-100, 1x1 to 3840x2560) from an `MTLBuffer`, 1 RGBA encode with padded rows, 4 encodes with an EXIF block: 869 of 869 whole files identical |
| c-example | `scripts/c-example.sh` then `ejm check-reencode` (`Tools/Sources/ejm/main.swift:54-59`) | `ejm_decode` (copy path) then `ejm_encode` q90 4:2:0 equals libjpeg-turbo decode then libjpeg-turbo encode, on a 1200x800 q95 4:2:2 file |
| swift-example | `scripts/swift-example.sh` then `ejm check-reencode` | the same check for `Decoder.decode(path:format:)` then `Encoder.encode(buffer:...)` |
| range | `scripts/test.sh`: `ejm encode-corpus` with `EJM_FUSED_MAX_BLOCKS=0` and `2000000`; `ejm corpus` with `EJM_CHUNK_BITS=2048 EJM_NCP=3` and `EJM_CHUNK_BITS=8192 EJM_NCP=15` | every value a tuner can pick: both encoder entropy paths 869 of 869 whole files identical each; both chunk settings 582 of 582 byte-identical with the same declined set as the default run |
| env-runs | `ejm corpus` with `EJM_COLOR_SPEC=0`, with `EJM_CHUNK_BITS=1024 EJM_NCP=3` and with `EJM_CHUNK_BITS=8192 EJM_NCP=1` | 582 of 582 byte-identical in each run (run by hand for this page on commit 8c891d6; not part of `scripts/test.sh`) |
| api-check | `ejm api-check` (`Tools/Sources/ejm/APICheck.swift`), run by `scripts/test.sh` | 30 synthetic files (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1 and gray at 1x1, 37x29, 203x97, 640x480; restart intervals of 3 and 5 MCUs and of one MCU row; 1201x803 4:2:0 and 4:2:2): Swift decode to all five `PixelFormat`s (150 decodes); `ejm_decode` zero-copy and copy paths and `ejm_decode_view` in all five formats (450); `output:` with `decode(bytes:...)` and `decode(buffer:...)` (600); 16 ICC / EXIF encodes as whole files against libjpeg-turbo's `jpeg_write_marker` + `jpeg_write_icc_profile` (what `tj3SetICCProfile` uses) and their decodes; `eagerPasses` 1, 2, 4, 16, 64 and 0, -1, 65, 1000; `chunkBits` 64 to 65536 by powers of 2 times `checkpoints` nil, 1, 2, 3, 7, 15, 31 (350 decodes); 9 declined files checked for an untouched output buffer; `warmUp()` coverage; `jpegHeader` limits; the startup self-check (passes normally; with `EJM_SELFCHECK_FAIL=1` every Swift and C path declines with the reason; runs once under 10 concurrent first calls); `recordStages` on (5 decodes, 7 encodes on both entropy paths and a mixed batch), `routingDecision` against `prefersCPU`, `MetalContext.trace` one line per call; the decoder audit groups of 2026-11-18 (`trailing-ff`, `dc-reason`, `quant16`, `layout-identity`, `output-buffer`, `offset-limit`, `alloc-order`, `alloc-failure`, `path-edges`: `Tools/Sources/ejm/DecoderAudit.swift`); `encoder-limits`: 31 encoder argument and resource cases, each in a child process so a trap fails the case (the 2^31 - 1 entropy bit limit on both paths at 8000x8000 and 9000x9000 q100 4:4:4 noise, the 4 GiB pixel span, overflowing sizes and offsets in Swift and `ejm_encode`, the memory budget, failed allocations, a poisoned output estimate, batch error indices, `jpegHeader` arguments, empty ICC and EXIF); the API usage groups of 2026-11-19 (`concurrent-use`, `metal-setup`, `c-api-args`, `stale-stats`, `buffer-input`, `c-reason-race`, `gate-records`, `decline-reason-stats`, `encoder-buffer-input`: `Tools/Sources/ejm/UsageChecks.swift`); `exactness-record`, `device-refs` and `selfcheck-cases` (the exactness record's refusals, the iOS references' libjpeg-turbo version, the self-check cases against their names). All byte-identical or declined as required (results of 2026-11-16 to 2026-11-19 in [CHANGES.md](CHANGES.md)) |
| bench | `ejm quick`, `ejm perf-small`, `ejm perf-large`, `ejm throughput` | these benchmarks compare every output they time with libjpeg-turbo and print "exact" / "DIFFERENT"; they are not part of `scripts/test.sh` |

The rules the decoder follows (accurate integer IDCT `JDCT_ISLOW`, fancy upsampling, libjpeg-turbo's colour
conversion) and the encoder settings (baseline, `jpeg_set_quality` tables, standard Huffman tables, islow DCT,
no smoothing, Pillow's marker layout) are stated in `Sources/ExactJPEG/Decoder.swift:158`,
`Sources/ExactJPEG/Encoder.swift:237-238` and `include/exact_jpeg.h:4-6`.

Each Swift entry below gives what it does, its default, its exactness status, when to use it and an example. Plain
stored fields of a struct are listed in a table with one example for the struct. Every Swift example is a
complete top-level program (`import ExactJPEG` plus Foundation or Metal where needed) that type-checks against
the library; examples that read `photo.jpg` need such a file in the working directory.

## Decoding (Swift)

### `Decoder`

```swift
public final class Decoder
```

Decodes baseline and extended-sequential Huffman JPEGs on the GPU, or declines. A decode returns a `GPUImage`
whose pixels equal libjpeg-turbo's output, or `nil` with `reason` set. Not thread-safe: use one `Decoder` per
thread (several decoders can share one `MetalContext`). A call made while another thread's call on the same
decoder is running is detected and declines at once, without waiting, with `Decoder.busyReason` ("decoder used
from two threads at once"); that thread then reads that reason until its next call on this decoder, the other
call is not disturbed (api-check concurrent-use: one decoder from 4 threads, 800 calls, every result exact or
declined so, none wrong). The rejection is remembered in the rejected thread's own storage (at most 8 decoders and
encoders per thread, freed when the thread exits), never in the decoder, so short-lived threads leave nothing
behind and a later thread that reuses a thread id does not see it (api-check gate-records: 200 rejected threads,
no record kept after they exit, none of 200 fresh threads sees the busy reason; before 2026-11-19 every rejected
thread's id was kept for good, and the fresh threads all read the busy reason). Before
2026-11-19 such calls shared the decoder's buffers undetected and could return another call's pixels as success.
The returned image lives in the decoder's own output buffer and stays valid until the next decode on the same
decoder from any thread, unless you pass `output:`. Input and output
buffers grow to the largest image seen and are kept for reuse; a small cache keeps the layouts computed from recent headers.

- Exact: verified for all five output formats: `.rgb` and `.gray` by corpus, manifest and fuzz; `.bgr`, `.rgba`
  and `.bgra` (and the first two again) by api-check. See `PixelFormat`.
- When: any JPEG you would otherwise decode with libjpeg-turbo, Pillow or TurboJPEG, when you need identical
  pixels. Always handle `nil` by falling back to a CPU decoder.

```swift
import ExactJPEG

let dec = Decoder()
if let img = dec.decode(path: "photo.jpg") {
    print(img.width, img.height, img.channels)
} else {
    print("fall back to the CPU:", dec.reason ?? "?")
}
```

### `Decoder.init(ctx:)`

```swift
public init(ctx: MetalContext? = nil)
```

Creates a decoder on a Metal context. Default (`nil`): `MetalContext.shared` (the system default GPU). Never
traps: when the shared context's setup failed (no Metal device, the shader library did not compile) the decoder
is still made, `Decoder.ctx` is `nil`, `Decoder.setupError` holds the error ("Metal setup failed: ..."), and every
call declines with it as the reason (api-check metal-setup, simulated with `EJM_TEST_METAL_SETUP`; before
2026-11-19 the process stopped). Allocates nothing on the GPU until the first decode. Exact: not applicable. When: pass your own context to use a specific
`MTLDevice`, or to share the device with your own Metal code; buffers you pass to `decode(buffer:...)` and
`output:` must belong to `ctx.device`.

```swift
import ExactJPEG

let ctx = MetalContext.shared
let a = Decoder(ctx: ctx), b = Decoder(ctx: ctx)   // one per thread, one shared device and queue
print(a.ctx === b.ctx)
```

### `Decoder.decode(_:format:)`

```swift
public func decode(_ data: Data, format: PixelFormat = .rgb) -> GPUImage?
```

Decodes a JPEG held in a `Data`. Same as `decode(bytes:format:output:)` with no `output`: the bytes are copied
into a GPU-visible buffer first. Default format `.rgb`. Exact: verified (corpus, manifest and fuzz call this
function). When: the JPEG is already in memory as `Data`.

```swift
import Foundation
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let dec = Decoder()
if let img = dec.decode(data, format: .gray) { print("gray", img.width, img.height) }
```

### `Decoder.decode(bytes:format:output:)`

```swift
public func decode(bytes: UnsafeRawBufferPointer, format: PixelFormat = .rgb, output: MTLBuffer? = nil) -> GPUImage?
```

Decodes a JPEG from raw memory, copying it into the decoder's input buffer first (every check that needs no GPU
memory runs before that buffer is allocated or filled). `output`: an optional `MTLBuffer` of at least
`width * height * format.channels` bytes to decode into (offset 0); if it is smaller the decode declines with
"output buffer too small". It must have `.storageModeShared` and belong to the decoder's device (`ctx.device`):
the kernels write it and `GPUImage.bytes` reads it through `contents()`; a `.private` or `.managed` buffer, or
one from another device, declines with "output buffer must be .storageModeShared on the decoder's device"
(api-check `output-buffer`). The image always starts at offset 0 of `output`:
there is no offset parameter, so decoding to a nonzero offset is not supported (bind a buffer created with
`makeBuffer(bytesNoCopy:...)` over the target memory instead). A declined decode leaves `output` untouched (the
colour kernel skips the write when any check fails; api-check fills `output` with a sentinel and decodes 9 corrupt
files). The one exception is a fault of the GPU itself ("GPU error: ..." from the command buffer): the kernels
may then have run partway, and the contents of `output` are unspecified. Default: `nil`, decode into the decoder's own buffer. Exact: verified without `output` (corpus;
`decode(_:format:)` calls this) and with `output` (api-check: every file and format, `output` exactly the image
size and 4096 bytes larger; one byte too small declines). When: the JPEG is in memory you
own (a mapped file, a network buffer); pass `output` to keep results beyond the next decode or to decode
straight into memory your own kernels read.

```swift
import Foundation
import Metal
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let dec = Decoder()
let size = data.withUnsafeBytes { try? parseJPEGHeader($0) }.map { $0.width * $0.height * 3 } ?? 0
let mine = dec.ctx.device.makeBuffer(length: max(size, 1), options: .storageModeShared)!
let img = data.withUnsafeBytes { dec.decode(bytes: $0, format: .rgb, output: mine) }
print(img.map { $0.buffer === mine } ?? false, dec.reason ?? "ok")
```

### `Decoder.declineReason(bytes:format:)`

```swift
public func declineReason(bytes: UnsafeRawBufferPointer, format: PixelFormat = .rgb) -> String?
```

The reason `decode(bytes:format:)` would decline this JPEG before any GPU work: the startup self-check, the
header, the size and offset limits, the quantisers, "entropy-coded data too short for the image size", the GPU
memory budget and the device's buffer limit; `nil` when all of these pass (the decode can still decline later,
on the GPU's checks of the entropy-coded data). Allocates nothing. A query: the decoder's `reason`,
`gpuSeconds`, `passes`, host timings and `stageTimes` stay those of the last decode (api-check
decline-reason-stats; before 2026-11-19 it reset them and left its own answer in `reason`). Exact: not
applicable. When: deciding up front, cheaply, whether to keep a file on the GPU path; `ejm_decode` uses it before
reporting too small an output buffer (api-check c-api-args).

```swift
import ExactJPEG

let dec = Decoder()
let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]
print(bytes.withUnsafeBytes { dec.declineReason(bytes: $0) } ?? "would try it")
```

### `Decoder.decode(path:format:)`

```swift
public func decode(path: String, format: PixelFormat = .rgb) -> GPUImage?
```

Reads a file straight into the decoder's GPU-visible input buffer (no intermediate `Data`) and decodes it.
When that buffer must be allocated or grown, the file's first 64 KB are read first (or, when its header is longer,
the file is mapped) and every check runs before the allocation, so a file whose entropy-coded data is over 256 MB
is declined without being read (api-check `alloc-order`).
Declines with "cannot open" or "short read" when the file cannot be read. Has no `output:` parameter. Exact:
verified indirectly (swift-example: a re-encode of its result matches libjpeg-turbo's); it ends in the same
`decode(buffer:length:format:output:)` as the other overloads. When: decoding files; it is the fastest way in
from disk.

```swift
import ExactJPEG

let dec = Decoder()
if let img = dec.decode(path: "photo.jpg", format: .bgra) { print(img.channels) } else { print(dec.reason ?? "?") }
```

### `Decoder.decode(buffer:length:format:output:)`

```swift
public func decode(buffer src: MTLBuffer, length n: Int, format: PixelFormat = .rgb, output: MTLBuffer? = nil) -> GPUImage?
```

Decodes a JPEG that is already in a shared-storage `MTLBuffer` (bytes `0..<length`), with no copy. Every other
overload ends here. Declines, before reading the buffer, with "input buffer is from another Metal device than the
decoder's" when `src.device` is not the decoder's device, "input buffer must be .storageModeShared (the decoder
reads it on the CPU)" when it is not shared storage (a `.private` buffer has no CPU contents), and "length larger
than the buffer" when `length` is negative or exceeds it (api-check buffer-input, traced and not; before
2026-11-19 a `.private` buffer was read through its `contents()` unchecked). `output` as in
`decode(bytes:format:output:)`. Exact: verified (all corpus decodes pass through it) without `output`, and with
`output` by api-check (input in a caller `MTLBuffer` longer than `length`). When:
the JPEG is already in GPU-visible memory, for example read there by your own I/O.

```swift
import Foundation
import Metal
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let dec = Decoder()
let src = data.withUnsafeBytes { dec.ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
let img = dec.decode(buffer: src, length: data.count)
print(img?.width ?? 0)
```

### Decoding the same photo again: UnHuff

*UnHuff: a Huffman-free coefficient format for exact repeat JPEG decodes.*

UnHuff is the name of the packed copy below (opt-in). Off by default: `decode` never packs, and nothing (no setting, no environment variable) turns packing on for
other calls. `Decoder.decodeAndPack(_:format:output:)` decodes a JPEG and also keeps, in memory, a packed copy of
the quantised coefficients its Huffman stage produced; `Decoder.decode(packed:format:output:)` decodes that copy
again without the Huffman stage. The copy lives only in this process (there is no file form). The pixels are the
same as decoding the JPEG, in every format.

It pays when the same photo is decoded more than once while the packed copy is in memory (for example an editor
or viewer that re-renders a picture it already opened). Measured on the M1 Max on 2026-11-19, 6720x4480
synthetic photos (`ejm packed-bench 5`, 5 interleaved rounds of 15 decodes each, normal against packed; pack time
the median of 7; 1-minute load average 3.5 to 3.7; `results/packed/m1max-gpu32-2026-11-19-1157.txt`):

| case | JPEG | packed copy | pack (CPU, once) | normal decode, wall / GPU | packed decode, wall / GPU |
|---|---|---|---|---|---|
| q95 4:2:2 | 8.2 MB | 19.3 MB | 14.0 ms | 5.56 / 4.97 ms | 2.07 / 1.77 ms |
| q90 4:2:0 | 5.1 MB | 12.5 MB | 9.75 ms | 5.15 / 4.66 ms | 1.88 / 1.59 ms |
| q95 4:4:4 | 8.7 MB | 22.7 MB | 15.2 ms | 6.10 / 5.50 ms | 2.62 / 2.32 ms |

So per 30 MP: packing costs about 9.7 to 15.1 ms of CPU once, after the first decode, and the copy holds about 12
to 23 MB of GPU memory (`PackedCoefficients.byteCount`; the decoder's coefficient arrays would be 94 to 188 MB),
plus the JPEG bytes it keeps; each later decode then takes about 58 to 66% less GPU time and 57 to 63% less wall
time. A photo decoded only once should use `decode`: `decodeAndPack` costs its
decode plus the pack.

Safety: the copy's buffers are not trusted blindly. The unpack kernel checks every block's index entry before
reading through it and, if any check fails, the decoder decodes the kept JPEG bytes normally instead (the
colour kernel writes no pixels from the rejected attempt). The block count always comes from the JPEG's frame.
The checks guarantee memory safety (no read or write outside the buffers), not integrity: the copy holds
no checksum, so it is only as trustworthy as the process that made it, which is why there is no way to save or
load one. The copy keeps its own copy of the JPEG bytes (5 to 9 MB for a 30 MP photo), so the fallback does
not depend on the caller's `Data` staying alive or unchanged.
The layout is internal and may change; `PackedCoefficients` exposes none of it.

#### `PackedCoefficients`

```swift
public final class PackedCoefficients
```

The packed copy made by `decodeAndPack`. Opaque and immutable: several decoders on the same device may decode
the same object at once. It keeps the `Data` it was made from (which shares storage with yours until either is
mutated), so a decode from it can always fall back to the normal decode; it holds GPU buffers until released.

| property | meaning |
|---|---|
| `PackedCoefficients.width` | image width in pixels |
| `PackedCoefficients.height` | image height in pixels |
| `PackedCoefficients.byteCount` | bytes of GPU memory the packed copy holds, not counting the kept JPEG bytes |

#### `Decoder.decodeAndPack(_:format:output:)`

```swift
public func decodeAndPack(_ data: Data, format: PixelFormat = .rgb, output: MTLBuffer? = nil)
    -> (image: GPUImage, packed: PackedCoefficients?)?
```

Decodes like `decode(bytes:format:output:)` (same image, same `output` rules, same declines with `reason`) and
then packs. Returns nil when the decode declines; `packed` is nil when the coefficients do not fit the packed
form (more than 256 MB of packed data; the 30 MP photos in the table pack to 16 to 21 bytes per 8x8 block, so
that is about 12 to 16 million blocks at that density). The
pack runs on the CPU after the GPU decode, on all cores. Exact: the image is the normal decode's; `ejm
packed-check corpus` checks every corpus file in `.rgb` and `.gray` against libjpeg-turbo. When: the first decode
of a photo you expect to decode again soon.

```swift
import Foundation
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let dec = Decoder()
if case let (img, packed)? = dec.decodeAndPack(data) {
    print(img.width, img.height, packed?.byteCount ?? 0)
}
```

#### `Decoder.decode(packed:format:output:)`

```swift
public func decode(packed p: PackedCoefficients, format: PixelFormat = .rgb, output: MTLBuffer? = nil) -> GPUImage?
```

Decodes a packed copy, in any format (not only the one `decodeAndPack` used), into the decoder's buffer or
`output` (as in `decode(bytes:format:output:)`). If the copy fails a check (made on another device, its sizes do
not match the JPEG's frame, the GPU rejects an index entry, or any other error bit is set) the decoder decodes the
kept JPEG bytes normally, so the result and `reason` are those of `decode(bytes:format:output:)`. Exact: verified
(`ejm packed-check`: the corpus in `.rgb` and `.gray` against libjpeg-turbo, `.bgr`, `.rgba` and `.bgra` against
the normal decode, copies decoded again after other images; 2000 decodes of copies with forged index entries fall
back to pixels identical to the normal decode). When: every later decode of a photo you packed.

```swift
import Foundation
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let dec = Decoder()
if case let (_, packed?)? = dec.decodeAndPack(data) {
    for format in [PixelFormat.rgb, .bgra] {
        if let img = dec.decode(packed: packed, format: format) { print(format, img.channels) }
    }
}
```

#### Packed-path test hooks (`@_spi(Testing)`)

Visible only with `@_spi(Testing) import ExactJPEG`; not a stable interface; used by `ejm packed-check` and
`ejm packed-bench`. `Decoder.packSeconds` is the host time of the last `decodeAndPack`'s pack; `Decoder.packedFellBack`
is true when the last `decode(packed:)` decoded the kept JPEG instead. `PackedTesting` gives the tests the internal
form: `PackedTesting.pack(coef:dc:nq:)` packs arrays into index words and data, `PackedTesting.tail` is the length
of the zero tail after the data, `PackedTesting.indexWords(_:)` and `PackedTesting.dataBytes(_:)` expose a packed
object's buffers (writable, to forge them), `PackedTesting.dataLength(_:)` and `PackedTesting.blockCount(_:)` its
data length and block count. Exact: forging through these hooks is how the fallback is tested; the defaults
change nothing.

### Decoder settings

These are stored properties; change them before a decode. None of them changes a successful result's pixels,
only whether a file is accepted and how the work is split.

#### `Decoder.chunkBits`

`public var chunkBits: Int?`. Bits of entropy-coded data per Huffman chunk (one GPU thread each in the
synchronisation passes). Default `nil`: use `EJM_CHUNK_BITS` if set, else 2048 when the image has less than
256 KB (262,144 bytes) of entropy-coded data and 4096 otherwise. Values below 64 are raised to 64.
Exact: verified for every power of 2 from 64 to 65536, each with `checkpoints` nil, 1, 2, 3, 7, 15 and 31, on five
files including two restart-interval files and a gray one (api-check, 350 decodes); also 1024 and 8192 through
`EJM_CHUNK_BITS` (env-runs), and the whole decoder corpus with `EJM_CHUNK_BITS=2048` (582 of 582, 2026-11-17).
When: tuning experiments only; the default was chosen by interleaved measurement on an M1 Max and an iPhone 13
(`Decoder.swift:360-369`; `ejm decode-ab`). The 8-core M4 was 5-9% faster with 2048 bits up to 723 KB, but the
threshold stays at 256 KB for every device because the A15 was 6-9% slower with 2048 at 723 KB.

```swift
import ExactJPEG

let dec = Decoder()
dec.chunkBits = 8192
dec.checkpoints = 1
print(dec.decode(path: "photo.jpg") != nil)
```

#### `Decoder.checkpoints`

`public var checkpoints: Int?`. Checkpoints per chunk: the write pass decodes each piece between checkpoints with
its own thread. Default `nil`: `EJM_NCP` if set, else 7. Clamped to `1...(chunkBits / 8 - 1)`. Exact: verified
for nil, 1, 2, 3, 7, 15 and 31 with every `chunkBits` from 64 to 65536 (api-check; with 64 bits every value is
clamped to 7), and for 1 and 3 via env-runs. When: tuning
experiments only. Example: see `Decoder.chunkBits`.

#### `Decoder.eagerPasses`

`public var eagerPasses = 8`. How many synchronisation passes the first attempt encodes. If the Huffman chunks
have not synchronised after them, the decode is redone with 64 passes (a pass after convergence exits at
once). Default 8. Clamped to 1...64 on assignment (the pass-status array has 64 entries), so `eagerPasses = 0`
reads back 1 and `eagerPasses = 1000` reads back 64. Exact: verified for the default (corpus) and for 1, 2, 4, 16
and 64, plus the clamped 0, -1, 65 and 1000 (api-check). When: tuning only; lower values cost a second
submission more often.

```swift
import ExactJPEG

let dec = Decoder()
dec.eagerPasses = 4
if dec.decode(path: "photo.jpg") != nil { print("passes needed:", dec.passes) }
```

#### `Decoder.maxPixels`

`public var maxPixels = 1 << 28`. Images with more than this many pixels are declined ("more than maxPixels").
Default 2^28 (268,435,456). The header parser separately rejects width or height above 65500. Whatever
`maxPixels` says, the effective limit is also the kernels' 32-bit offsets: an image whose output (width x height x
channels), coefficient array (128 bytes per 8x8 block, MCU padding included) or sample planes would reach 2^31
bytes (2 GB) is declined ("image too large: its output, coefficient or plane buffer would reach 2 GB (the kernels
use 32-bit offsets)"), before anything is allocated (api-check `offset-limit`: 65500x65500 with `maxPixels` set to
`Int.max`). With the default `maxPixels` no image reaches that limit (16384x16384 4:4:4 to `.rgba` needs 1 GB of
output and 1.6 GB of coefficients). Exact: not
applicable (it only decides acceptance). When: lower it to bound memory and time per call, for example for
untrusted input (`ejm fuzz` uses 2^22).

```swift
import ExactJPEG

let dec = Decoder()
dec.maxPixels = 50_000_000
if dec.decode(path: "photo.jpg") == nil { print(dec.reason ?? "?") }
```

#### `Decoder.maxGPUBytes`

`public var maxGPUBytes: Int?`. Declines a decode whose scratch memory plus input length plus output buffer length
would exceed this many bytes ("needs about N MB of GPU memory, more than allowed (M MB)"). Default `nil`: half of
`device.recommendedMaxWorkingSetSize` (`DeviceProfile.maxGPUBytes`). Checked before anything is allocated, with
every other check that needs no GPU memory (header, the 256 MB and `maxPixels` limits, the 32-bit offset limit,
output buffer, data long enough for the frame, and each buffer against the device's `maxBufferLength`: "needs a
buffer larger than the device allows (N MB)"); api-check `alloc-order` checks that a declined decode allocated
nothing (`Decoder.allocatedBytes`). An allocation that still fails declines with "cannot allocate the input /
output / scratch buffer (N MB)" (api-check `alloc-failure`). Exact: not applicable. When: set a
smaller budget when other GPU work must keep its memory.

```swift
import ExactJPEG

let dec = Decoder()
dec.maxGPUBytes = 512 << 20
print(dec.decode(path: "photo.jpg") != nil ? "ok" : dec.reason ?? "?")
```

### Decoder results and diagnostics

Read-only (`public private(set)` or `let`) properties describing the last decode.

| property | type | meaning |
|---|---|---|
| `Decoder.ctx` | `MetalContext!` | the context given to `init(ctx:)`, or `MetalContext.shared`; `nil` only when that setup failed |
| `Decoder.setupError` | `String?` | `nil` normally; why the decoder has no Metal setup ("Metal setup failed: ..."): every call then declines with it |
| `Decoder.reason` | `String?` | why the last decode returned `nil`; `nil` after a success. See [decline reasons](#decline-reasons). A thread whose last call found another thread's call running reads `Decoder.busyReason` |
| `Decoder.busyReason` | `String` (static) | "decoder used from two threads at once": the reason of a call made while another thread's call on the same decoder runs |
| `Decoder.passes` | `Int` | synchronisation passes the last successful decode needed; 0 after a decline (before 2026-11-19 a decline left the value of the decode before) |
| `Decoder.gpuSeconds` | `Double` | GPU time of the last decode's command buffer (`gpuEndTime - gpuStartTime`) |
| `Decoder.hostPrepSeconds` | `Double` | host time from the start of the call to the start of command encoding (parse, layout, scratch set-up) |
| `Decoder.hostEncodeSeconds` | `Double` | host time spent encoding the GPU commands |
| `Decoder.waitSeconds` | `Double` | time from commit to completion of the command buffer |

The timing values describe the last call's command buffer; when a decode needs the 64-pass retry they describe
the retry. Each call resets them (and `stageTimes`) at its start, so after a call that declined before any GPU
work they are 0 (api-check stale-stats; before 2026-11-19 they kept the previous call's values). Exact: not applicable. When: diagnostics, logging, benchmarks (`ejm decode` prints them).

On an iPhone, `gpuSeconds` depends strongly on the GPU's clock state: decodes issued one at a time (commit, wait,
next) let an iPhone 13's GPU drop to a slow state within about half a second (a 1600x1200 decode then takes about
11 ms of GPU time instead of about 3); with one command buffer always queued (for example two `Decoder`s on two
threads) it stays fast. See the iPhone section of the README.

#### Profiling hooks (`@_spi(Testing)`)

```swift
@_spi(Testing) public var profileStopAfter: Int   // Decoder.profileStopAfter, default Int.max
@_spi(Testing) public var profileRecord: Bool     // Decoder.profileRecord, default false
@_spi(Testing) public private(set) var profileDispatches: [String]   // Decoder.profileDispatches
```

Visible only with `@_spi(Testing) import ExactJPEG`; not a stable interface. `Decoder.profileStopAfter` = k encodes
only the first k GPU dispatches of each decode, which then returns `nil` with reason `"profile stop"` and
`gpuSeconds` set to that prefix's GPU time; `ejm decode-profile` and the iOS check app (`--decode-profile`) take
differences of these prefixes for per-stage GPU times. With `Decoder.profileRecord` true, `Decoder.profileDispatches`
lists the last decode's dispatches as `"stage:kernel"`. Exact: output is invalid by design while
`profileStopAfter` is not `Int.max`; the defaults change nothing. When: profiling only.

Two hooks for the call gate (api-check gate-records): `Decoder.gateRecordCount` (`Int`, read-only) is the number
of per-thread rejection records alive in the process, for every decoder and encoder (each thread's is freed when it
exits); `Decoder.withGateHeld(_:)` runs a closure while the calling thread holds this decoder's gate, so calls from
other threads find it taken.

Three more test hooks, for `ejm api-check`: `Decoder.allocatedBytes` (`Int`, read-only) is the total size of the
GPU buffers this decoder has allocated so far (input, output, scratch); `Decoder.failAllocations` (`Bool`, default
false) makes every one of its allocations fail, as on a device out of memory; `Decoder.layoutKeyOverride`
(`String?`, default nil) gives every header the same layout cache key, a forced hash collision (the cache compares
the header bytes, so the decode stays exact).

```swift
import ExactJPEG

let dec = Decoder()
if dec.decode(path: "photo.jpg") != nil {
    print("GPU \(dec.gpuSeconds * 1000) ms, prep \(dec.hostPrepSeconds * 1000) ms, encode \(dec.hostEncodeSeconds * 1000) ms, wait \(dec.waitSeconds * 1000) ms, passes \(dec.passes)")
} else {
    print(dec.reason ?? "?", dec.ctx.device.name)
}
```

### `PixelFormat`

```swift
public enum PixelFormat: Int, Sendable { case rgb = 0, bgr = 1, gray = 2, rgba = 4, bgra = 5 }
```

The decoder's output layout: rows of `width * channels` bytes, no padding. The raw values are the C constants
(`EJM_RGB` ...); 3 is not a format (the decoder uses 3 and 6 internally for gray to RGB/BGR and to RGBA/BGRA).

| case | bytes per pixel | from a colour JPEG | from a grayscale JPEG | exact |
|---|---|---|---|---|
| `PixelFormat.rgb` | 3 | R, G, B | Y replicated | verified (corpus, manifest, fuzz) |
| `PixelFormat.bgr` | 3 | B, G, R | Y replicated | verified (api-check) |
| `PixelFormat.gray` | 1 | the Y (luma) channel, as libjpeg-turbo's `JCS_GRAYSCALE` output | Y | verified (corpus, manifest, fuzz) |
| `PixelFormat.rgba` | 4 | R, G, B, 255 | Y, Y, Y, 255 | verified (api-check) |
| `PixelFormat.bgra` | 4 | B, G, R, 255 | Y, Y, Y, 255 | verified (api-check) |

The alpha byte value 255 comes from the colour kernel (`Sources/ExactJPEG/Shaders/Decode.metal`), as in
libjpeg-turbo's `JCS_EXT_RGBA` / `JCS_EXT_BGRA` output (TurboJPEG's `TJPF_RGBA` / `TJPF_BGRA`); api-check compares
all four layouts, from colour and gray JPEGs, with libjpeg-turbo byte for byte. When: `.rgb` for pipelines that compare with Pillow or libjpeg-turbo; `.bgra` / `.rgba` to feed
Core Graphics or Metal textures; `.gray` when only luma is needed.

#### `PixelFormat.channels`

`public var channels: Int`: bytes per pixel (1, 3 or 4) as in the table. Use it to size output buffers.

```swift
import ExactJPEG

for f in [PixelFormat.rgb, .bgr, .gray, .rgba, .bgra] { print(f, f.rawValue, f.channels) }
```

### `GPUImage`

```swift
public struct GPUImage
```

A decoded image in a shared (unified-memory) `MTLBuffer`. It does not own a copy: with the decoder's own buffer
it is valid until the next decode on that decoder.

| field | meaning |
|---|---|
| `GPUImage.buffer` | the `MTLBuffer` holding the pixels (the decoder's, or the one you passed as `output`); usable by your own kernels with no copy |
| `GPUImage.offset` | byte offset of the first pixel in `buffer` (always 0 from the decoder) |
| `GPUImage.width` | width in pixels |
| `GPUImage.height` | height in pixels |
| `GPUImage.channels` | bytes per pixel, `format.channels` |
| `GPUImage.bytes` | the pixels as an `UnsafeRawBufferPointer` of `width * height * channels` bytes (computed from `buffer.contents() + offset`) |

Exact: the bytes are the verified output described under `PixelFormat`. When: read `bytes` to copy or hash the
result; pass `buffer` and `offset` to Metal or to `Encoder.encode(buffer:...)`.

```swift
import Foundation
import ExactJPEG

let dec = Decoder()
if let img = dec.decode(path: "photo.jpg") {
    let copy = Data(img.bytes)                       // keep the pixels beyond the next decode
    print(copy.count == img.width * img.height * img.channels, img.offset, img.buffer.length)
}
```

### Decline reasons

`Decoder.reason` (and `ejm_decoder_reason`) is one of the header parser's `Unsupported` messages (see
`parseJPEGHeader(_:)`), "self-check failed on <GPU name>, <OS version>: <case>" when the device failed its startup
self-check (every decode then declines; see "Startup self-check"), or one of these, from
`Sources/ExactJPEG/Decoder.swift`: "decoder used from two threads at once" (`Decoder.busyReason`), "not a JPEG", "cannot open",
"short read", "input buffer is from another Metal device than the decoder's", "input buffer must be
.storageModeShared (the decoder reads it on the CPU)", "length larger than the buffer", "entropy-coded data larger than 256 MB", "more than maxPixels",
"image too large: its output, coefficient or plane buffer would reach 2 GB (the kernels use 32-bit offsets)",
"quantisation value above 32767" (a 16-bit DQT value that libjpeg-turbo keeps as a negative int16, where its C and
SIMD IDCTs can differ; any such value in a table a component uses declines the file, even where every
coefficient it would multiply is zero and libjpeg-turbo's output would not depend on it: a rare over-decline,
chosen for safety over a per-coefficient check), "output buffer must be .storageModeShared on the decoder's device", "output buffer too
small", "entropy-coded data too short for the image
size", "needs about N MB of GPU memory, more than allowed (M MB)", "needs a buffer larger than the device allows
(N MB)", "cannot allocate the input buffer (N MB)", "cannot allocate the output buffer (N MB)", "cannot allocate
the scratch buffer (N MB)", "no command buffer", "GPU error: ...",
"Huffman chunks did not synchronise"; after the GPU run, one or more of "bad Huffman code", "entropy-coded data
too short", "AC coefficient index past 63", "block runs past its restart marker", "restart markers missing or out
of order", "coefficients outside the range where all libjpeg-turbo IDCTs agree", "DC value outside int16" (set
since 2026-11-18; before, a DC outside int16 was reported only as the coefficient range)
(joined with "; "); then the trailer checks of `checkTrailer(_:_:)`, which the GPU repeats so that a declined
decode writes no pixels; if the two ever disagreed the reason would be "internal: GPU and host trailer checks
disagree" (`ejm fuzz` reports that as a finding). The strings are messages for people, not a
stable interface.

## Encoding (Swift)

### `Encoder`

```swift
public final class Encoder
```

Encodes RGB or RGBA/RGBX pixels to a baseline JPEG file on the GPU. The output file is byte-identical to
libjpeg-turbo's compressor with Pillow's settings: `jpeg_set_quality` tables, standard Huffman tables, islow DCT,
no smoothing, JFIF 1.01 header without density (`Encoder.swift:67-68, 237-238`). Always writes 3 components
(YCbCr); there is no grayscale encode. Not thread-safe: one `Encoder` per thread. A call made while another
thread's call on the same encoder is running is detected and throws `InvalidInput` with `Encoder.busyError`
("encoder used from two threads at once") at once, without waiting or disturbing the other call (api-check
concurrent-use; before 2026-11-19 such calls shared the encoder's buffers undetected). The output size is estimated
from earlier images; when the estimate was too small the image is encoded again (`retries`).

Limits (each throws `InvalidInput`, never a wrong file): the argument checks under `EncodeJob`; pixels spanning
more than 4 GiB from the first one (`rowBytes * (height - 1) + width * channels - 1` above 2^32 - 1: the kernels
address pixels with 32-bit offsets); entropy-coded data of more than 2^31 - 1 bits, about 256 MB (the GPU's bit
offsets are 32-bit signed; the count kernels also sum each image's bits in 64 bits, and an image past the limit
throws "the entropy-coded data is N bits, more than 2^31 - 1" after its first submission). That limit is on the
real count: 8000x8000 q100 4:4:4 noise (2.10e9 bits) encodes, 9000x9000 (2.65e9 bits) throws, on both entropy
paths (api-check encoder-limits). One block needs at most 1744 bits (64 x (16 + 11) + 16), so images up to
1,231,355 blocks (about 26.2 MP at 4:4:4, 39.4 MP at 4:2:2, 52.5 MP at 4:2:0) can never reach the limit; larger
ones reach it only with very high entropy. GPU memory: each submission's scratch and output must fit
`Encoder.maxGPUBytes` (default half the GPU working set, the decoder's rule) and `maxBufferLength`; a failed
allocation throws "could not allocate ..." (before 2026-11-18 these stopped the process).

- Exact: verified (encode-corpus, manifest, c-example, swift-example).
- When: producing JPEGs that must match Pillow or libjpeg-turbo byte for byte.

```swift
import ExactJPEG

let w = 64, h = 48
let rgb = [UInt8](repeating: 200, count: w * h * 3)
let enc = Encoder()
let jpeg = try rgb.withUnsafeBytes { try enc.encode(bytes: $0, width: w, height: h) }   // q75, 4:2:0
print(jpeg.count)
```

### `Encoder.init(ctx:)`

```swift
public init(ctx: MetalContext? = nil)
```

Creates an encoder and builds its pipeline states and Huffman table buffer. Default context (`nil`):
`MetalContext.shared`. Never traps: when that setup failed, or one of its kernels' pipeline states does not
build, the encoder is still made, `Encoder.setupError` holds the error, and every call throws `Unsupported` with
it (`Encoder.ctx` is `nil` when there is no context at all; api-check metal-setup; before 2026-11-19 the process
stopped). Sets `fusedMaxBlocks` from the device. Exact: not applicable. When: one per thread; pass
a context to choose the device. Pixel buffers you pass must belong to `ctx.device`.

```swift
import ExactJPEG

let enc = Encoder(ctx: .shared)
print(enc.ctx.device.name, enc.fusedMaxBlocks)
```

### `Encoder.encode(bytes:width:height:channels:rowBytes:quality:subsampling:icc:exif:)`

```swift
public func encode(bytes: UnsafeRawBufferPointer, width: Int, height: Int, channels: Int = 3, rowBytes: Int? = nil,
                   quality: Int = 75, subsampling: Subsampling = .s420, icc: Data? = nil, exif: Data? = nil) throws -> Data
```

Encodes pixels from ordinary memory: copies `rowBytes * (height - 1) + width * channels` bytes into a staging
buffer, then calls `encode(buffer:...)`. Parameters and defaults are those of `EncodeJob.init`. Every argument
is checked first, before the staging buffer is allocated or anything is copied, with arithmetic that cannot
overflow. Throws `InvalidInput` when `bytes` is too small, for any check listed under `EncodeJob`, or when the
staging buffer cannot be allocated. Returns the complete JPEG
file. Exact: verified (c-example goes through this function via `ejm_encode`); the copy does not change the
input, so the encode-corpus results apply. When: pixels in a Swift array, `Data` or C memory.

```swift
import Foundation
import ExactJPEG

let w = 100, h = 80, rowBytes = 104 * 4                 // RGBX with 4 pixels of row padding
var px = [UInt8](repeating: 0, count: rowBytes * h)
for y in 0..<h { for x in 0..<w { px[y * rowBytes + x * 4] = UInt8(x * 2) } }
let enc = Encoder()
let jpeg = try px.withUnsafeBytes {
    try enc.encode(bytes: $0, width: w, height: h, channels: 4, rowBytes: rowBytes, quality: 95, subsampling: .s444)
}
print(jpeg.prefix(2) == Data([0xFF, 0xD8]))
```

### `Encoder.encode(buffer:offset:width:height:channels:rowBytes:quality:subsampling:icc:exif:)`

```swift
public func encode(buffer: MTLBuffer, offset: Int = 0, width: Int, height: Int, channels: Int = 3, rowBytes: Int? = nil,
                   quality: Int = 75, subsampling: Subsampling = .s420, icc: Data? = nil, exif: Data? = nil) throws -> Data
```

Encodes pixels already in a shared `MTLBuffer`, with no copy: a one-job `encodeBatch`. Parameters, defaults and
checks as in `EncodeJob`. Exact: verified for 3 channels, all three subsamplings, q1-100, sizes 1x1 to 3840x2560
(encode-corpus, 864 files) and for 4 channels with padded rows (1 file, `EncodeBench.swift:43-47`). When: the
pixels come from the decoder (`GPUImage.buffer`) or from your own Metal kernels.

```swift
import ExactJPEG

let dec = Decoder(), enc = Encoder()
if let img = dec.decode(path: "photo.jpg", format: .rgba) {
    let jpeg = try enc.encode(buffer: img.buffer, offset: img.offset, width: img.width, height: img.height,
                              channels: 4, quality: 90, subsampling: .s422)
    print(jpeg.count)
}
```

### `Encoder.encodeBatch(_:)`

```swift
public func encodeBatch(_ jobs: [EncodeJob]) throws -> [Data]
```

Encodes several images with one command buffer and one wait per submission of at most 256 MB of scratch and
output memory (or `Encoder.maxGPUBytes`, if smaller), sized from the current output estimate; results are in
the order of `jobs`. All or nothing: it validates every job first and throws `InvalidInput` before any GPU work
if one is invalid, and any later error (an image over the memory budget or the entropy limit, a failed
allocation) throws for the whole batch with no results. In a batch of more than one job the message starts
with the job's index, "job 3: quality must be 1...100". The per-submission latency (about 0.35 ms on an M1 Max, HOW-IT-WORKS.md "Fixed costs and host overhead") is paid once per
batch, so batches of small images are much faster than single calls. Exact: verified only by the benchmark
tools (bench: `ejm perf-small` compares the first and last output of batches of 1 to 32, `PerfSmall.swift:46-48`;
`ejm throughput` compares batch outputs, `Throughput.swift:121-122`); not part of `scripts/test.sh`. When: many
images, especially below a few megapixels.

```swift
import Metal
import ExactJPEG

let enc = Encoder()
let w = 256, h = 256
let px = [UInt8](repeating: 90, count: w * h * 3)
let buf = px.withUnsafeBytes { enc.ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
let jobs = (1...8).map { EncodeJob(buffer: buf, width: w, height: h, quality: 50 + 5 * $0) }
let files = try enc.encodeBatch(jobs)
print(files.map(\.count))
```

### Encoder settings and diagnostics

#### `Encoder.fusedMaxBlocks`

`public var fusedMaxBlocks: Int`. Images of up to this many 8x8 blocks are entropy-coded in a single fused pass
(128 bytes of slots per block); larger images, and any image whose block overflowed its slot, use the two-pass
path. 0 disables the fused path. Default: `EJM_FUSED_MAX_BLOCKS` when set; else 0 (two-pass) when the device
profile's `encoderPath` is `.twoPass` (Apple9 and later, see "Device profile"); else
`min(2_000_000, recommendedMaxWorkingSetSize / 16 / 128)`, which is 2,000,000 on any device with at least about
4 GB of working set. An assignment overrides the default. Exact: both paths give identical bytes and both are
verified: `scripts/test.sh` runs the encoder corpus (every image below 2M blocks) at the default and with
`EJM_FUSED_MAX_BLOCKS=0` and `2000000`, 869 of 869 each, and the startup self-check encodes one image on each
path whatever the default. When: leave it; set it only to compare the two paths.

```swift
import ExactJPEG

let enc = Encoder()
enc.fusedMaxBlocks = 0                               // always two-pass
let px = [UInt8](repeating: 10, count: 32 * 32 * 3)
print(try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 32, height: 32) }.count)
```

#### `Encoder.maxGPUBytes`

`public var maxGPUBytes: Int? = nil`. The most GPU memory one submission's scratch and output buffers may need;
`nil` means half of the device's `recommendedMaxWorkingSetSize` (`DeviceProfile`, the decoder's default rule).
An image that alone needs more throws `InvalidInput` ("1024x1024 needs about 4 MB of GPU memory, more than
allowed (1 MB)"); a batch is split into submissions that fit. Same bytes at any value. The persistent buffers
(arena, output, staging) are reused between calls and only grow. Exact: verified (api-check encoder-limits: 8
512x512 q95 noise images in one batch under a 12 MB budget, three submissions, identical to libjpeg-turbo).
When: limiting the encoder's memory beside other GPU work.

```swift
import ExactJPEG

let enc = Encoder()
enc.maxGPUBytes = 64 << 20
let px = [UInt8](repeating: 50, count: 640 * 480 * 3)
print(try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 640, height: 480) }.count)
```

#### Encoder testing hooks (`@_spi(Testing)`)

Visible only with `@_spi(Testing) import ExactJPEG`; not a stable interface; used by `ejm api-check
encoder-limits`. `Encoder.testHooks` is an `EncoderTestHooks` (`EncoderTestHooks.init()` gives no hooks):
`EncoderTestHooks.failAllocation` ("staging", "output" or "scratch") makes that allocation fail as if
`makeBuffer` returned nil; `EncoderTestHooks.totalBitsOverride` and `EncoderTestHooks.tileBytesOverride`
replace the bit count and the stuffed byte count the GPU reports, which the encoder must reject as implausible.
`Encoder.bytesPerBlockEstimateForTesting` reads or sets the output estimate (bytes per block) the next
submission sizes its buffers from; capacity never exceeds the worst case, so any value gives the same bytes.
`Encoder.maxEntropyBitsPerBlock` (1744) is the bound on one block's entropy-coded bits (a Huffman code is at
most 16 bits, a magnitude at most 11 for 8-bit samples, 64 coefficients, plus 16 for an EOB as margin; the
standard tables' own worst case is 1676) and `Encoder.maxEntropyBits(blocks:)` an image's (blocks x 1744 + 7
for the final padding): they cap buffer sizes and reject a GPU count outside 0...bound.

```swift
@_spi(Testing) import ExactJPEG

let enc = Encoder()
enc.testHooks.failAllocation = "output"
let px = [UInt8](repeating: 10, count: 8 * 8 * 3)
do { _ = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 8, height: 8) } } catch { print(error) }
print(Encoder.maxEntropyBits(blocks: 6))              // 10471
```

#### `Encoder.profileStages` (`@_spi(Testing)`)

`@_spi(Testing) public var profileStages = Int.max`, visible only with `@_spi(Testing) import ExactJPEG` (since
2026-11-17; it was plain `public`, but it makes invalid output and nothing public needs it; for per-stage GPU
times use `Encoder.recordStages`). Profiling only: when set, each image runs only its first N GPU stages and
the call returns an empty `Data` per image. Default `Int.max` (all stages, normal output). Exact: output is
invalid by design whenever it is not `Int.max`. When: never in production; `ejm perf-small` uses it for per-stage
GPU timings (with `EJM_PROFILE=1`).

```swift
@_spi(Testing) import ExactJPEG

let enc = Encoder()
enc.profileStages = 1
let px = [UInt8](repeating: 10, count: 64 * 64 * 3)
let out = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 64, height: 64) }
print(out.isEmpty, enc.gpuSeconds)                   // true: profiling run, no file
```

#### Encoder diagnostics

| property | meaning |
|---|---|
| `Encoder.ctx` | the context given to `init(ctx:)`, or `MetalContext.shared`; `nil` only when that setup failed |
| `Encoder.setupError` | `nil` normally; why the encoder cannot run (no Metal setup, a kernel that did not build): every call then throws `Unsupported` with it |
| `Encoder.gpuSeconds` | GPU time of the last `encode` / `encodeBatch` call, summed over its submissions (including re-encodes); 0 after a call that threw before any GPU work (reset at the start of each call since 2026-11-19, as `stageTimes`) |
| `Encoder.retries` | how many images were encoded again because the output-size estimate was too small; counts up for the encoder's lifetime |
| `Encoder.fusedFallbacks` | how many images fell back from the fused pass to the two-pass path because a block overflowed its slot; counts up for the encoder's lifetime |

Exact: not applicable. When: diagnostics and benchmarks.

```swift
import ExactJPEG

let enc = Encoder()
let px = [UInt8](repeating: 77, count: 640 * 480 * 3)
_ = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 640, height: 480, quality: 100, subsampling: .s444) }
print(enc.gpuSeconds, enc.retries, enc.fusedFallbacks, enc.ctx.device.name)
```

### `EncodeJob`

```swift
public struct EncodeJob
public init(buffer: MTLBuffer, offset: Int = 0, width: Int, height: Int, channels: Int = 3, rowBytes: Int? = nil,
            quality: Int = 75, subsampling: Subsampling = .s420, icc: Data? = nil, exif: Data? = nil)
```

One image for `Encoder.encodeBatch(_:)`; the same fields are the parameters of both `encode` functions.
`EncodeJob.init(buffer:offset:width:height:channels:rowBytes:quality:subsampling:icc:exif:)` fills them, with
`rowBytes` defaulting to `width * channels`.

| field | default | meaning and checks (each failure throws `InvalidInput`) | exact |
|---|---|---|---|
| `EncodeJob.buffer` | required | shared `MTLBuffer` with the pixels; must be `.storageModeShared` on the encoder's device, else `InvalidInput` ("input buffer must be .storageModeShared" / "input buffer is from another Metal device than the encoder's") before any GPU work (api-check encoder-buffer-input; before 2026-11-19 neither was checked) | |
| `EncodeJob.offset` | 0 | byte offset of the first pixel; `offset >= 0` and the last row must fit in the buffer (`offset + rowBytes * (height - 1) + width * channels <= buffer.length`, computed without overflow) | only offset 0 verified |
| `EncodeJob.width` | required | 1...65500, and `width * height <= 2^28`; see `Encoder` for the 4 GiB pixel span and the 2^31 - 1 entropy bit limits | allowed up to 65500 (and 2^28 pixels); verified by whole-file comparison with libjpeg-turbo at widths 1 to 3840 (encode-corpus), 4032, 6000, 6720 and 8000 (ejm mixed, api-check encoder-limits) |
| `EncodeJob.height` | required | 1...65500 | allowed up to 65500; verified at heights 1 to 2560 (encode-corpus), 3024, 4480, 4500, 6000 and 8000 (ejm mixed, api-check encoder-limits) |
| `EncodeJob.channels` | 3 | 3 (RGB) or 4 (RGBA or RGBX; the 4th byte is ignored); channel order is always R, G, B first | 3 verified; 4 verified for one padded case |
| `EncodeJob.rowBytes` | `width * channels` | bytes from one row to the next; at least `width * channels`, at most 2^31 - 1 | default verified; padded verified once (4 channels) |
| `EncodeJob.quality` | 75 | 1...100, libjpeg's `jpeg_set_quality` scale | 1, 25, 50, 75, 87, 90, 95, 100 verified |
| `EncodeJob.subsampling` | `.s420` | see `Subsampling` | all three verified |
| `EncodeJob.icc` | `nil` | ICC profile, written as APP2 `ICC_PROFILE` chunks of up to 65519 bytes, at most 255 chunks (16,707,345 bytes) | verified (api-check): whole files identical to libjpeg-turbo's `jpeg_write_icc_profile` (what `tj3SetICCProfile` uses) for 560, 65519 (one full chunk), 65520 (two chunks), 200000 (4 chunks) and 16,707,345 bytes (255 chunks), 4:4:4 and 4:2:0, and the decoded pixels identical; an empty profile throws `InvalidInput` ("empty ICC profile"), as libjpeg-turbo's `jpeg_write_icc_profile` fails on a zero-length profile (before 2026-11-18 it was silently skipped); pass `nil` for none |
| `EncodeJob.exif` | `nil` | EXIF block, written verbatim as the APP1 payload (so it should start with `Exif\0\0`); at most 65533 bytes; an empty block writes an empty APP1 segment (`FF E1 00 02`), as libjpeg-turbo's `jpeg_write_marker` with length 0 does (api-check encoder-limits: whole file identical) | verified (api-check): whole files identical to libjpeg-turbo writing the block with `jpeg_write_marker(APP1)` right after `jpeg_start_compress`, for 1006 and 65533 bytes and with a 70000-byte ICC profile (EXIF first, then ICC); also the scan for 4 EXIF lengths (`EncodeBench.swift:49-58`) |

When: build a list of jobs for `encodeBatch`, or keep encode settings in one value.

```swift
import Foundation
import Metal
import ExactJPEG

let enc = Encoder()
let w = 120, h = 90, rb = 128 * 3
let buf = enc.ctx.device.makeBuffer(length: rb * h, options: .storageModeShared)!
var job = EncodeJob(buffer: buf, width: w, height: h, rowBytes: rb, quality: 92, subsampling: .s444)
job.exif = Data("Exif\0\0".utf8) + Data(repeating: 0, count: 8)
print(job.offset, job.channels, job.icc == nil, try enc.encodeBatch([job])[0].count)
print(job.buffer.length, job.width, job.height, job.rowBytes, job.quality, job.subsampling)
```

### `Subsampling`

```swift
public enum Subsampling: Sendable { case s444, s422, s420 }
```

Chroma subsampling for the encoder: luma sampling factors (1,1), (2,1) and (2,2), chroma (1,1). No raw value;
the C API maps 0, 1, 2 to these cases.

| case | meaning | C constant | exact |
|---|---|---|---|
| `Subsampling.s444` | 4:4:4, no chroma subsampling | `EJM_444` | verified (encode-corpus) |
| `Subsampling.s422` | 4:2:2, chroma halved horizontally | `EJM_422` | verified (encode-corpus) |
| `Subsampling.s420` | 4:2:0, chroma halved both ways (the default, as in Pillow) | `EJM_420` | verified (encode-corpus) |

When: `.s444` for graphics and the highest quality; `.s420` for photos and the smallest files.

```swift
import ExactJPEG

let enc = Encoder()
let px = [UInt8](repeating: 50, count: 48 * 48 * 3)
for s in [Subsampling.s444, .s422, .s420] {
    print(s, try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 48, height: 48, subsampling: s) }.count)
}
```

### `jpegHeader(width:height:quality:subsampling:icc:exif:)`

```swift
public func jpegHeader(width: Int, height: Int, quality: Int, subsampling: Subsampling, icc: Data? = nil, exif: Data? = nil) throws -> Data
```

Returns the bytes the encoder writes before the entropy-coded data: SOI, APP0 JFIF 1.01 (no density), APP1 EXIF
if given, APP2 ICC chunks if given, two DQT, SOF0 (3 components), four DHT (standard tables), SOS. Throws
`InvalidInput` with the encoder's messages for a width or height outside 1...65500, a quality outside 1...100, an
EXIF block over 65533 bytes, or an ICC profile that is empty or needs more than 255 chunks (before 2026-11-16 the
metadata limits stopped the process with a precondition failure; before 2026-11-18 a width or height above 65535
or below 0 trapped, and `quality` was clamped silently).
Exact: verified without ICC or EXIF as part of every encode-corpus file, and with them as part of api-check's
whole-file ICC / EXIF comparisons; the limits are checked by api-check. When: tests that compare headers, or to know where the scan starts
in an encoder output (`jpegHeader(...).count`).

```swift
import ExactJPEG

let h = try jpegHeader(width: 640, height: 480, quality: 90, subsampling: .s420)
print(h.count, h.suffix(10).map { String(format: "%02x", $0) }.joined())   // ends with the SOS segment
```

## Timing and tracing (Swift)

Off by default. Off, each decode and encode call reads one `Bool` (`EJM_TRACE` is read once per process, when the
first `Decoder` or `Encoder` is made) and builds nothing; measured cost against the same code without tracing (8 interleaved rounds each, M1 Max, load 7-8 with other GPU
work): 640x480 q95 4:2:2 decode +4.6 µs wall (lower in 3 of 8 rounds), 640x480 encode -4.3 µs, both within noise;
30 MP decode -0.16 and +0.09 ms wall in two runs and 30 MP encode -0.03 ms, the GPU work being identical, all
noise at 8 to 10 ms per call on this machine. Two opt-in layers:

- **Per-stage GPU times**: `Decoder.recordStages` / `Encoder.recordStages` (or `EJM_TRACE=stages`). The call
  encodes one compute encoder per stage instead of one for the whole call, with a GPU timestamp (an
  `MTLCounterSampleBuffer` sample, `.atStageBoundary`) at the start and the end of each, still in one command
  buffer with one commit and one wait. The encoders are ordered by an `MTLEvent` signalled after each and waited
  on before the next (the encoder's buffers are untracked; with `MTLFence`s instead the encoder's output differed).
  Same bytes: `scripts/test.sh` runs the whole decoder corpus (582 exact) and encoder corpus (869 identical) with
  `EJM_TRACE=stages`, and api-check `trace` compares decodes and encodes with it on against libjpeg-turbo. Cost
  on the M1 Max (interleaved A/B against the same binary with it off, load 7-10 with other GPU work): 30 MP
  q95 4:2:2 decode +0.02 and +0.17 ms of GPU (wall +0.16 and +0.30 ms) in two runs of 8 and 12 rounds; 30 MP
  encode +0.20 ms of GPU (wall +0.24 ms; 8 rounds). A stage's time runs from its
  encoder's start to its end, so the sum is a little under the command buffer's `gpuSeconds` (the gaps between
  encoders are not in it). Where the device cannot sample at stage boundaries, `stageTimes` stays empty and the
  call runs as usual, without an error.
- **One line per call**: `EJM_TRACE=1` prints it to stderr, `MetalContext.trace` hands it to the app.

### `Decoder.recordStages`, `Decoder.stageTimes`

```swift
public var recordStages: Bool                       // default false; setting it to false clears stageTimes
public private(set) var stageTimes: [StageTime]     // the last decode that recorded stages
```

Decoder stage names, in order: `unstuff` (remove byte stuffing, find restart markers), `segments`, `chunks`,
`sync0` ... `sync<n-1>` (one per synchronisation pass encoded: `eagerPasses`, 8 by default, or 64 on the retry),
`first_blocks`, `decode_write`, `dc_scan`, `idct`, `colour`. When a decode needs the 64-pass retry, `stageTimes`
describes the retry, as `gpuSeconds` does. Exact: same bytes with it on (above). When: finding which stage a
slow decode spends its GPU time in; `EJM_TRACE=stages` gets the same without code.

```swift
import ExactJPEG

let dec = Decoder()
dec.recordStages = true
if dec.decode(path: "photo.jpg") != nil {
    for s in dec.stageTimes { print(s.name, s.gpuSeconds * 1000, "ms") }
    print("sum", dec.stageTimes.reduce(0) { $0 + $1.gpuSeconds } * 1000, "of", dec.gpuSeconds * 1000, "ms")
}
```

### `Encoder.recordStages`, `Encoder.stageTimes`

```swift
public var recordStages: Bool                       // default false; setting it to false clears stageTimes
public private(set) var stageTimes: [StageTime]     // the last encode / encodeBatch call that recorded stages
```

Encoder stage names, in order, following its stages: `fill+dct` (clear the bit words, colour conversion,
downsampling, DCT and quantisation; with the dummy-block DC fix-up when the image needs one) or `fill+fused`
(the single-pass path: the same plus each block's Huffman bits), `count` or `len` (bits per block), `scan` (their
prefix sum), `write` or `compact` (the bit stream), `stuff_count` (0xFF bytes per tile), `stuff_scan`,
`stuff_scatter` (the stuffed output). A batch whose images take both paths names the first, second and fourth
`fill+dct|fill+fused`, `count|len` and `write|compact`. All images of a batch run each stage together, so a
stage's time covers every image. A call with several submissions (a retry after a too-small output estimate, a
fused-path fallback, a batch over 256 MB of scratch) sums each name over them, as `gpuSeconds` does; a later
submission with one path adds its own names. Exact: same bytes with it on (above).

```swift
import ExactJPEG

let enc = Encoder()
enc.recordStages = true
let px = [UInt8](repeating: 90, count: 640 * 480 * 3)
_ = try px.withUnsafeBytes { try enc.encode(bytes: $0, width: 640, height: 480, quality: 90) }
print(enc.stageTimes.map(\.description).joined(separator: ", "))   // "fill+dct 0.120, count 0.011, ..."
```

### `StageTime`

```swift
public struct StageTime: Equatable, Sendable, CustomStringConvertible {
    public let name: String
    public let gpuSeconds: Double
    public init(name: String, gpuSeconds: Double)
    public var description: String               // "idct 0.412": the name and the time in ms
}
```

`StageTime.name` is a stage name above, `StageTime.gpuSeconds` its GPU time in seconds,
`StageTime.init(name:gpuSeconds:)` the memberwise initialiser (for tests and tools), `StageTime.description`
the name and the time in milliseconds with three decimals. Example: see `Decoder.recordStages`.

### `MetalContext.trace`

```swift
nonisolated(unsafe) public static var trace: ((String) -> Void)?   // default nil: off
```

When set, receives one line per public decode and encode call (`Decoder.decode(...)` in every form,
`Encoder.encode(...)`, `Encoder.encodeBatch(_:)`; the C API calls through them), the same line `EJM_TRACE=1`
prints to stderr; with both, both get it. Called on the thread that made the call, after it returns its
result. The library's own decodes and encodes (the startup self-check, the device profile's routing measurement) are
not traced, and `EJM_TRACE=stages` does not switch them to per-stage encoders. Set it before starting work, not while
other threads decode or encode. The line is built only while tracing is on.

Decode: `ejm decode <w>x<h> <subsampling> <n> B <format> ok|declined (<reason>) wall <ms> prep <ms> encode <ms>
wait <ms> gpu <ms> ms passes <n> chunk <bits>/<checkpoints> route <advice>`, then ` stages <name> <ms>, ...`
when the call recorded stages. A call that declined before any GPU work says `wall <ms> ms (no GPU work)`;
`passes` is only on a success; size, subsampling and chunk settings only when the header parsed.
Encode: `ejm encode <w>x<h> <subsampling> q<quality> <channels>ch <n> B ok|failed (<error>) wall ... gpu <ms> ms
submissions <n> retries <n> fused fallbacks <n> path fused|two-pass|two-pass (fallback) route <advice>`; a batch
says `ejm encode batch of <n> (first <w>x<h> ...)` and has no path or route. `prep` for the encoder is the host
time before its first command buffer, `encode` and `wait` are summed over its submissions.
`route` is `DeviceProfile.routingDecision(width:height:operation:)` for that size and operation with the automatic
warmth, read from the device's profile as it stands (the trace does not start the profile's background
measurement): `route gpu|cpu (cpu <ms> ms, gpu <ms> ms, GPU set sporadic|warm|sustained, CPU cold|warm,
<source>[, margin])`. Advice only; the call itself ran on the GPU.

```
ejm decode 640x480 4:2:0 108532 B rgb ok wall 4.713 prep 0.089 encode 0.051 wait 4.520 gpu 4.065 ms passes 2 chunk 2048/7 route gpu (cpu 3.19 ms, gpu 2.68 ms, GPU set warm, CPU cold, estimate)
ejm encode 203x97 4:2:0 q90 3ch 11054 B ok wall 0.852 prep 0.030 encode 0.062 wait 0.746 gpu 0.482 ms submissions 1 retries 0 fused fallbacks 0 path fused route cpu (cpu 0.20 ms, gpu 0.86 ms, GPU set warm, CPU cold, estimate) stages fill+fused 0.158, len 0.012, scan 0.080, compact 0.028, stuff_count 0.022, stuff_scan 0.066, stuff_scatter 0.038
```

Exact: no effect on output. Cost: off, one `Bool` per call (above); on, a header parse, a routing decision and
the string, a few µs of host time per call, plus the stage cost when stages are recorded. When: logging in an
app (send the lines to `os_log`), or finding out why a call was slow.

```swift
import ExactJPEG

MetalContext.trace = { line in print(line) }
let dec = Decoder()
_ = dec.decode(path: "photo.jpg")      // prints one line
MetalContext.trace = nil               // off again
```

## Header parsing (Swift)

The decoder parses every header on the CPU before any GPU work. These functions and types are public so that
callers can check a file cheaply or inspect its structure.

### `parseJPEGHeader(_:)`

```swift
public func parseJPEGHeader(_ p: UnsafeRawBufferPointer) throws -> JPEGHeader
```

Parses the markers up to the first SOS and returns the frame and scan description. Throws `Unsupported` for
anything the GPU path does not decode exactly, including malformed headers: not a JPEG, progressive, lossless,
hierarchical, arithmetic coding, sample precision other than 8 bits, component counts other than 1 or 3,
RGB-coded files (JFIF absent and Adobe transform 0 or component ids "RGB"), more than one scan or a scan without
every component in frame order, fractional sampling, more than 10 blocks per MCU, width or height of 0 or above
65500, missing tables, invalid Huffman tables, unknown markers. Accepts SOF0 and SOF1, 8- and 16-bit quantisation
tables, any valid Huffman tables, and uses libjpeg's standard tables when a file defines none. It does not look
at the entropy-coded data, so a file it accepts can still be declined by `Decoder` (see
[decline reasons](#decline-reasons)). Exact: not applicable; the rules follow libjpeg-turbo 3.1.2 (`jdmarker.c`,
`jdapimin.c`, `jdhuff.c`, `jstdhuff.c`) per `Header.swift:1-6`. When: a cheap pre-check, or to read image size
and sampling without decoding. `ejm_inspect` is the C equivalent.

```swift
import Foundation
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
do {
    let h = try data.withUnsafeBytes { try parseJPEGHeader($0) }
    print(h.width, h.height, h.subsampling)
} catch let e as Unsupported {
    print("CPU path:", e.description)
}
```

### `checkTrailer(_:_:)`

```swift
public func checkTrailer(_ p: UnsafeRawBufferPointer, _ end: Int) -> String?
```

Checks what follows the entropy-coded data, which ends at byte offset `end` (a marker's 0xFF, or the end of the
data). Accepts fill bytes (0xFF), complete APPn and COM segments, then EOI, the end of the data, or a lone 0xFF as
the very last byte (libjpeg-turbo's memory source supplies a fake EOI after it); returns `nil`
when that holds, else a reason ("data after the scan", "truncated marker after the scan", "bad marker after the
scan", "marker N after the scan"). Exact: not applicable. When: rarely; the decoder calls it after every decode.
You need the scan's end offset, which only the decoder computes.

```swift
import ExactJPEG

let tail: [UInt8] = [0xFF, 0xFE, 0x00, 0x04, 0x41, 0x42, 0xFF, 0xD9]   // a COM segment, then EOI
print(tail.withUnsafeBytes { checkTrailer($0, 0) } ?? "ok")
```

### `JPEGHeader`

```swift
public struct JPEGHeader: Sendable
```

What `parseJPEGHeader(_:)` returns. It has no public initialiser; the fields are `var` but changing them affects
only your copy.

| field | meaning |
|---|---|
| `JPEGHeader.width`, `JPEGHeader.height` | image size in pixels |
| `JPEGHeader.ncomp` | 1 (grayscale) or 3 (YCbCr) |
| `JPEGHeader.samp` | per component `(h, v)` sampling factors as used for decoding; `[(1, 1)]` for a 1-component scan |
| `JPEGHeader.quant` | per component, 64 quantisation values in zig-zag order |
| `JPEGHeader.dcTabs`, `JPEGHeader.acTabs` | per scan component, the DC and AC Huffman tables (the file's, or the standard ones) |
| `JPEGHeader.td`, `JPEGHeader.ta` | per scan component, the DC and AC table ids from the SOS segment |
| `JPEGHeader.dri` | restart interval in MCUs, 0 when there is none |
| `JPEGHeader.scanStart` | byte offset of the first entropy-coded byte |
| `JPEGHeader.hmax`, `JPEGHeader.vmax` | computed: largest horizontal and vertical sampling factor |
| `JPEGHeader.subsampling` | computed: "gray", "4:4:4", "4:2:2", "4:2:0", "4:4:0", "4:1:1", or the factors such as "2x2/1x1/1x1" for other layouts |

Exact: not applicable. When: inspection and logging; `scanStart` and `dri` tell how much entropy-coded data
there is and whether restart markers speed up the decode.

```swift
import Foundation
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let h = try data.withUnsafeBytes { try parseJPEGHeader($0) }
print(h.width, h.height, h.ncomp, h.samp.map { "\($0.h)x\($0.v)" }, h.hmax, h.vmax, h.subsampling)
print(h.quant[0].prefix(4), h.dcTabs.count, h.acTabs.count, h.td, h.ta, h.dri, h.scanStart)
```

### `HuffTable`

```swift
public struct HuffTable: Hashable, Sendable
```

A Huffman table as stored in a DHT segment: `HuffTable.counts` (16 values, the number of codes of each length 1
to 16) and `HuffTable.vals` (the symbols in code order). It appears in `JPEGHeader.dcTabs` and
`JPEGHeader.acTabs`; there is no public initialiser. Exact: not applicable. When: inspecting whether a file uses
optimised or standard tables.

```swift
import Foundation
import ExactJPEG

let data = try Data(contentsOf: URL(fileURLWithPath: "photo.jpg"))
let h = try data.withUnsafeBytes { try parseJPEGHeader($0) }
let t = h.acTabs[0]
print(t.counts.count, t.vals.count, Set(h.acTabs).count)
```

## Metal context (Swift)

### `MetalContext`

```swift
public final class MetalContext: @unchecked Sendable
```

The Metal device, command queue and compiled kernels shared by decoders and encoders. The kernels are compiled
from source embedded in the library (`ShaderSource.swift`, generated from `Sources/ExactJPEG/Shaders/*.metal`)
the first time a context is created, with fast math off and Metal 3.0; pipeline states are built at first use
and cached. Safe to share between threads (pipeline creation is locked). Exact: not applicable. When: usually
never directly; `Decoder()` and `Encoder()` use `MetalContext.shared`.

```swift
import ExactJPEG

let ctx = MetalContext.shared
print(ctx.device.name, ctx.compileSeconds)
```

### `MetalContext.shared`

`public static var shared: MetalContext`. The context on the system default device, created on first use.
If no device exists or the library fails to compile, reading it stops the process with `fatalError`; check
`MetalContext.sharedSetupError` first (`nil` when `shared` is usable, else "Metal setup failed: ..."), or create a
context with `init(device:salt:)`. `Decoder()`, `Encoder()` and `ejm_decoder_create` / `ejm_encoder_create` never
read it when its setup failed: they decline, throw or return `NULL` instead. Example: see `MetalContext`.

### `MetalContext.init(device:salt:)`

```swift
public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), salt: String? = nil) throws
```

Creates a context and compiles the kernels. Throws `Unsupported("no Metal device")` when `device` is `nil`,
`Unsupported("no command queue")`, or the Metal compiler's error. `salt` is appended to the source as a comment
to force a cold compile (for measuring compile time, as `ejm compile-cost` does); default `nil`. Each context
compiles its own library (about 145 ms the first time a process sees this source, then a few ms from the OS
shader cache, HOW-IT-WORKS.md "Fixed costs and host overhead"). When: a specific GPU, or graceful handling of a missing device.

```swift
import Metal
import ExactJPEG

do {
    let ctx = try MetalContext(device: MTLCreateSystemDefaultDevice())
    let dec = Decoder(ctx: ctx)
    print(dec.ctx.device.name)
} catch {
    print("no GPU path:", error)
}
```

### Members

| member | meaning |
|---|---|
| `MetalContext.device` | the `MTLDevice` |
| `MetalContext.queue` | the command queue (created with `maxCommandBufferCount: 64`); decoders and encoders on this context submit to it |
| `MetalContext.compileSeconds` | seconds the shader library took to compile when this context was created |
| `MetalContext.kernelNames` | the 25 kernels without function constants, decoder and encoder (every kernel in the Metal source except `color_k`) |
| `MetalContext.warmUp()` | builds now, instead of at first use, the 25 pipeline states of `kernelNames` and 23 specialisations of the decoder's default colour kernel `color_k`: luma at full resolution with both chroma components full size, h2v1 fancy, h1v2 fancy, h2v2 fancy or replicated, in each of `.rgb`, `.bgr`, `.rgba`, `.bgra`, plus the three gray modes: 48 in all. Afterwards decoding the layouts libjpeg-turbo, Pillow and cameras write (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1, gray) in any format, and encoding, build no new pipeline (api-check); an unusual sampling layout builds its `color_k` at first use. Then runs both halves of the device's startup self-check if they have not run (about 29 ms the first time; see "Startup self-check"), so an app can pay that cost up front |
| `MetalContext.selfCheck(decode:encode:)` | runs the device's startup self-check if it has not run; `nil` when it passed, else the reason (see "Startup self-check") |
| `MetalContext.pipelineCount` | how many pipeline states the context has built so far (each kernel, and each `color_k` specialisation, counts once); api-check uses it to check `warmUp()` |
| `MetalContext.pipeline(_:)` | the cached pipeline state for a kernel name; stops the process with `fatalError` for an unknown name or a pipeline state that does not build (the decoder and encoder use a form that declines the call, or makes `Encoder.setupError`, instead; `warmUp()` skips such kernels) |
| `MetalContext.pipeline(_:constants:)` | the same for a kernel with int function constants 0...n-1 set to `constants`, cached per name and values |

Exact: not applicable. When: `warmUp()` before timing-sensitive work; `pipeline` is for the library and the
`ejm` tool (its `oob-selfcheck` uses `fill_u32`), not a stable interface.

```swift
import ExactJPEG

let ctx = MetalContext.shared
ctx.warmUp()
let p = ctx.pipeline("fill_u32")
let q = ctx.pipeline("color_k", constants: [0, 0, 0, 0, 3])
print(MetalContext.kernelNames.count, ctx.pipelineCount, p.maxTotalThreadsPerThreadgroup, q.threadExecutionWidth, ctx.queue.label ?? "queue")
```

## Device profile

The library configures itself per device in two layers. Nothing here changes output bytes or what is declined:
every value a setting can take gives the same bytes (`scripts/test.sh` runs the encoder corpus on both entropy
paths and the decoder corpus at three chunk settings), and the library always uses the GPU when called. The
routing numbers are advice for the caller.

**Layer 1** is deterministic: computed once per device, the first time an `Encoder` is made or the profile is read,
from what the device reports, with no timing and no table of device models.

| field | rule |
|---|---|
| `gpuName`, `family` | `MTLDevice.name`; the highest of `supportsFamily(.apple9)`, `.apple8`, else `.apple7` |
| `gpuCores` | macOS: the IORegistry entry of the device (its `registryID`, else the first `AGXAccelerator`), property `gpu-core-count`; unprivileged. iOS cannot read it: an estimate, `gpuCoresEstimated` true: 8 when the working set is over 5 GB (Apple silicon iPads), 5 for Apple9 phones, 4 for Apple7 and Apple8 phones (the smallest of those GPUs) |
| `recommendedMaxWorkingSetSize` | `MTLDevice.recommendedMaxWorkingSetSize` |
| `cpuPerformanceCores` | macOS: `hw.perflevel0.physicalcpu`. iOS: `ProcessInfo.activeProcessorCount`, which counts efficiency cores too; `cpuCoresIncludeEfficiency` is then true |
| `encoderPath` | `.twoPass` on Apple9 and later, else `.fused`. Evidence (GPU time per encode, 2026-11-17): M1 Max (Apple7, 32 cores) fused 43% faster at 1500x1000 (0.49 against 0.86 ms) and faster at batch 16, about equal at 1200x800 batch 1; M4 (Apple9, 8 cores) fused 11-23% slower at every size and batch size; iPhone 13 (Apple8, A15) near neutral, fused 4-15% faster at 1500x1000 and 2048x1365, two-pass 1-6% faster at 1200x800 and 3840x2560 |
| `suggestedInFlight` | 3 when the working set is at least 8 GB, else 2; then at most `maxGPUBytes / 360 MB` (a 30 MP decode needs about 4 x 90 MB of buffers), at least 1. Evidence (`ejm inflight`, one `Decoder` or `Encoder` per thread, 30 MP decode and 3840x2560 q95 4:4:4 encode): decode is flat from 2 to 8 on the M4 and the M1 Max; M4 two-pass encode 157, 218, 230 images/s at 1, 2, 3, flat after; M1 Max (load 26 to 35, so noisy, 3 rounds of 2 s, medians) at 2, 3, 4, 6: decode 204, 213, 218, 210, single-pass encode 297, 293, 317, 323, two-pass encode 166, 158, 200, 201. The core count does not predict more: 4x the M4's cores gained under 10% from a fourth image in single-pass, the M1 Max's default |
| `maxGPUBytes` | half of the working set: the decoder's default budget (`Decoder.maxGPUBytes` when that is `nil`) |
| `estimatedRouting`, `estimatedSporadicRouting` | the sustained routing set (an estimate, never measured) and the sporadic set's estimate until it is measured (below) |

**Layer 2** is routing: the image size below which the caller's CPU codec beats the GPU. It depends on how warm
each side is (below: the GPU in three states, the CPU in two, both tracked automatically). The GPU sets exist
because an Apple GPU under a light, bursty load settles into one of several clock states and the state depends on
how the caller feeds it: on the M4, one-at-a-time calls ran in a slow state (decode about 5.3 ms + 2.3 ms/MP,
encode 0.9 + 2.5) while a GPU kept fed ran warm (decode 1.33 + 0.50, encode 0.29 + 0.56); the iPhone 13's A15
dropped to a slow state after about 0.5 s of sequential commit-and-wait decodes (1600x1200 at 11.2 ms of GPU time)
but stayed at 2.9 ms with one command buffer always queued from 2 threads. `sporadicRouting` (also `routing`) is
what an app encoding one photo now and then sees, `sustainedRouting` what a batch export with 2 or more jobs in
flight sees, and `warmRouting` what a call shortly after another one sees;
`prefersCPU(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)` picks the set. Each set is a linear cost model
(fixed + per-megapixel wall time).

**Sustained routing is an estimate** from device-reported properties, calibrated on two Macs, and is never
measured at run time: `sustainedRouting` is `estimatedRouting`. On a Mac (core count read) it is the M4's warm
measurement (8 cores: decode 1.33 ms + 0.50 ms/MP, encode 0.29 ms + 0.56 ms/MP) with the per-MP cost scaled by
(8 / `gpuCores`)^0.25 and the fixed costs unscaled, cold start 9.6 ms (the M4's first call after 5 s idle). The
M1 Max (32 cores) settled warm once at decode 1.105 ms + 0.299 ms/MP, encode 0.227 ms + 0.382 ms/MP; the
estimate gives 1.33 + 0.354 and 0.29 + 0.396 there. On iOS (core count estimated) the iPhone 13's (A15, 4 cores)
measurement with two decoders or two encoders kept busy (wall per image, the minimum over three runs, least
squares from 0.07 to 3.2 MP): decode 0.81 ms + 0.80 ms/MP (within 15% from 0.23 to 3.1 MP), encode 1.13 ms +
1.20 ms/MP (its small sizes scatter up to 50% about the line, but each falls on the same side of the default CPU
rate as measured), per-MP scaled by (4 / `gpuCores`)^0.25, cold start 8.5 ms (measured). The earlier iOS figures
(2.9 + 1.0, 2.5 + 1.2) were single calls in the slow clock state and 2.2 to 2.7x too high. Measuring it at run time did not work: on an M4 (quiet, load
1.4-2.2) a keep-alive of back-to-back jobs never brought the GPU to the warm state that `ejm decode-ab` and
`ejm decode-profile` reach easily on the same machine (the large job stayed 2.3-2.5x the estimate after 11-18
steps).

**Sporadic routing is the cold GPU, measured**: per operation, a cold fixed cost, a short job's cold per-MP cost
and a ramp, from two isolated calls on this device: the median of 5 isolated 256x256 calls and one more isolated
call at 1600x1200. A long job warms the GPU as it runs, so the cold per-MP cost does not stay at the short-job
rate: on the M4 (2026-11-17, isolated calls after 300 ms idle) decode took about 4.1 ms at 256x256, 7.5 at
1600x1200 (1.92 MP), 8.73 at 2048x1365 (2.8 MP), 12.38 at 3840x2560 (9.8 MP) and 25.7-28.5 at 6720x4480 (30.1 MP);
encode about 1.5, 5.6-6.4, 6.48, 17.97 and 26.7-35.6. Past about 3 MP the cold decode climbs 0.5-0.65 ms/MP, the
warm slope, not the 2.0 ms/MP of its first 2 MP. The cold cost is therefore the sustained per-MP cost plus a
saturating excess, the same shape as the CPU cold model:

`cold = fixed + warm x MP + rampMs x (1 - exp(-(msPerMP - warm) x MP / rampMs))`

with `warm` the sustained per-MP cost (`Routing.decodeWarmMsPerMP`), `msPerMP` a short job's cold per-MP cost
(`Routing.decodeMsPerMP`, the slope at 0 MP) and `rampMs` the most the cold excess adds (`Routing.decodeRampMs`);
the same for encode. Two calls give two equations, so the ramp is tied to what they show: with
`D = large - small - warm x (1.92 - 0.066)`, the excess the 1600x1200 call has over the sustained slope,
`rampMs = 2.5 x D` (`gpuRampRatio`), and the curve passes through both calls. Then
`(msPerMP - warm) / rampMs` is the same constant on every device (0.28 per MP), so the fit is closed form.
Robustness: the chord (large - small) / 1.86 MP is held to at most 6x the sustained per-MP cost before the fit
(one isolated call reads high when it lands behind other work; the M4's are 3.7x decode, 4.3x encode) and
rejected over 20x; when D is under 0.05 ms (a large call no slower than the sustained slope allows) there is
nothing to ramp and the cost is the old straight line, its slope held between the sustained one and 4x it; the
fixed cost is never below 0.05 ms (`minColdFixedMs`, a round trip no Apple GPU beats). Fitting more sizes did not help: many isolated calls of several
sizes were noise between identical runs (M4: decode ms/MP 2.04, 0.085, 2.20), since each lands in a different
clock state. Until measured, `estimatedSporadicRouting` is the same fit through two calls that take the M4's
ratio of isolated to sustained time (decode 3.01x at 256x256 and 3.28x at 1600x1200, encode 4.59x and 4.40x),
so on an M4 it is the M4 fit (on iOS, the iPhone 13's isolated calls instead: decode 8.7x and 6.1x, encode 1.8x and
4.0x its sustained times, since its slow clock state costs far more): decode 3.95 ms + 2.25 ms/MP (ramp 6.18 ms, then 0.50 ms/MP), encode 1.31 ms + 3.00
ms/MP (ramp 8.65 ms, then 0.56 ms/MP). It reproduces the M4's isolated calls it was not fitted to:

| size | op | isolated (ms) | model (ms) | error |
|---|---|---|---|---|
| 2048x1365 (2.8 MP) | decode | 8.73 | 8.72 | 0% |
| 3840x2560 (9.8 MP) | decode | 12.38 | 14.67 | +18% |
| 6720x4480 (30.1 MP) | decode | 25.69 (28.5) | 25.19 | -2% (-12%) |
| 2048x1365 (2.8 MP) | encode | 6.48 | 7.59 | +17% |
| 3840x2560 (9.8 MP) | encode | 17.97 | 14.92 | -17% |
| 6720x4480 (30.1 MP) | encode | 26.65 (35.6) | 26.82 | +1% (-25%) |

(in brackets, a second run). The straight line it replaces (cold fixed + cold slope x MP, the slope held to 4x
the sustained one) predicted about 24 ms for a 9.8 MP decode and about 65 ms at 30 MP, so it put the cold-GPU / warm-CPU
crossover at 5.7 MP decode and 6.0 MP encode against a real one of about 3 and 2.5-3 MP, and sent 3-6 MP jobs to a
CPU 1.2-2x slower. With the ramp, at the default CPU rates, the M4 estimate crosses at 2.99 MP decode and 3.45 MP
encode.

**Warm routing** is the GPU shortly after this process used it (within `warmWindow`, 250 ms), but not kept fed:
`warmRouting` is the sustained per-MP costs plus `gpuWarmFixedFraction` (0.65) x the sporadic fixed costs. An
app's warm GPU is not the sustained one: on the M4, 200 ms of the same work just before brought a 256x256 decode
to 3.2-3.5 ms (3.6-4.1 cold, 1.33 + 0.03 sustained) and an encode to 0.8 ms (1.2-1.5 cold, 0.33 sustained), while
a long stream decodes 640x480 in 1.16 ms. `sustainedRouting` stays for callers that keep 2 or more jobs in flight.

**Warmth is tracked automatically.** The GPU is warm when this process had a command buffer in flight or one
finished within the last `warmWindow` (250 ms): the library already tracks its own command buffers for the busy
gate, so nothing is added to a decode or encode. The CPU is warm when the caller noted CPU codec work within the
last 250 ms, `DeviceProfile.noteCPUWork()` (call it when your CPU codec finishes a job; one lock and a clock
read), or when this process used more than half a core over the window since an earlier sample: `prefersCPU` and
`currentWarmth` read `getrusage` (process user + system time) each time they run and use a window of 0.05-0.25 s
(the reference sample restarts once it is older than `warmWindow`, so a busy second followed by idle reads cold
250 ms later); no sampling happens otherwise. The process CPU time counts every thread: the app's other work and
the GPU codec's own host-side work read as CPU activity too, while the library's CPU proxy run (below) does not
(samples taken during it are skipped and the window restarts after it). Every timestamp is monotonic (system
uptime, `DispatchTime`), including the command-buffer stamps and the busy gate's quiet waits, so a wall-clock
change does not move them; a clock reading earlier than a stamp reads as cold. `DeviceProfile.currentWarmth`
reports both, with the ages, for logging. Only a `prefersCPU` call with both `sustained` and `cpuWarm` nil uses the
detected warmth on both sides; see below for the overrides.

**The CPU cold model.** The library has no CPU codec, but a cold CPU costs the caller's codec too: its clock is
down after an idle pause. On the M4 (libjpeg-turbo 3.2.1, 1 thread), isolated calls 250-300 ms apart against back
to back: decode 256x256 0.74-1.25 ms against 0.16, 1600x1200 13.4-14.8 against 5.1-5.5, 30 MP 103 against 79.6;
encode 1024x768 7.4-9.7 against 2.0-2.1, 6720x4480 95.4 against 73.4. Short jobs ran about 4x their warm time,
long ones only 1.3x: a long job ramps the clock itself, so the penalty saturates. The model:
`cold = warm + rampMs x (1 - exp(-(ratio - 1) x warm / rampMs))`, with `ratio` the short-job ratio and `rampMs`
the most a job loses to the ramp. A saturating exponential fitted the M4's isolated calls with 5% rms error where
the piecewise form (`warm x k` up to a cap, then `warm` + a constant) left 10%, and it has no kink at the cap.
`DeviceProfile.defaultCPUColdModel`, ratio 4.0 and rampMs 18, is the M4 fit and applies until the device's own
model is measured: the M4's isolated calls alone fit ratio 3.7 and rampMs 18, and against the M4's ground truth
below every ratio from 3.5 to 4.75 with any rampMs from 10 to 30 ms passes at both CPU rates; 4.0 sits inside.

A tiny job is capped: the curve's short-job ratio overstates it. On the M4 a 256x256 encode on a cold CPU took
0.64 ms against 0.49 warm, where ratio 4-7 predicts 2-3.5x, and with the M4's measured model (ratio 7.16, rampMs
22.2) that sent the cell "256x256 encode, GPU warm 0.84 / CPU cold 0.64" to the GPU. So
`coldMs(warmMs:)` is `min(curve, warm + 0.25 ms + (ratio - 1) x max(0, warm - 0.25 ms))`
(`cpuTinyPenaltyMs`, `cpuTinyJobMs`): under 0.25 ms warm a job loses at most 0.25 ms, and past that the cap rises
at the curve's own short-job rate until it meets the curve (about 1.2-1.4 ms warm for ratio 4-7). The cap is
continuous, with a change of slope at 0.25 ms and where it meets the curve. A flat cap of warm + 0.25 ms up to 1 ms
warm was tried first and failed the ground truth: a 640x480 decode (0.8-0.9 ms warm) still took 2.6-4.0 ms cold
on the M4, and the flat cap sent "640x480 decode, GPU warm 2.54 / CPU cold 4.02" to the CPU (58% slower). The CPU
proxy is fitted to the curve alone (`rampedMs(warmMs:)`), not the cap.

The model is measured on the device with a CPU proxy the library owns, in the same background measurement, after
the GPU calls and 250 ms more of idle: an integer 8x8 DCT (libjpeg's islow butterflies) over 1024 synthetic
blocks per chunk, run on a user-initiated thread (a caller's codec runs at that QoS; utility work may land on
efficiency cores) and timed chunk by chunk. One run from idle is a cold job read at every size: chunk j of a
model CPU takes `u + rampMs (1 - e^(-l)) e^(-l j)` with `l = (ratio - 1) u / rampMs` and `u` the warm chunk time,
so a least-squares fit of the chunk times gives `u`, `ratio` and `rampMs` at once, and the run need not reach the
warm rate exactly. Each chunk time is first replaced by the median of the 9 around it, so a chunk preempted by
another thread does not read as ramp. The run stops when its chunk times have dropped by 15% or more and settled
(the last 3 ms within 3% of the 3 ms before), at 50 ms, or after 20 ms with no drop: the CPU was already warm (a
busy machine), and the fit is not used (the default model stays; `summary` says why), nor is one with ratio under
1.15 or a ramp under 1 ms. A separate warm-up to time the warm rate back to back would need about 100 ms of CPU on
the M4 (its clock reaches full speed after about that), so the run's own tail and the fit stand in for it. The
proxy costs at most 50 ms of CPU (about 44 ms for a CPU like the M4's fit; 20 ms on a busy machine). A rate the
caller passes in `cpuMsPerMP` is taken as warm; when the CPU is cold the model turns it into the cold time.

**The M4's ground truth** (2026-11-17, M4 MacBook Air, ExactJPEG and libjpeg-turbo 3.2.1 at 1 thread, decode q95
4:2:2, encode q90 4:4:4, median of 5 single calls; cold: 300 ms with no work on that side; warm: 200 ms of the
same operation on that side just before), GPU / CPU in ms, in api-check `device-profile` as the acceptance fixture
(the 3840x2560 and 6720x4480 rows and the second 2048x1365 "GPU cold, CPU warm" cells are a later run):

| size | op | cold / cold | GPU warm, CPU cold | GPU cold, CPU warm | warm / warm |
|---|---|---|---|---|---|
| 256x256 | decode | 4.11 / 0.74 | 3.24 / 1.25 | 3.63 / 0.16 | 3.45 / 0.58 |
| 256x256 | encode | 1.47 / 1.23 | 0.85 / 0.66 | 1.17 / 0.14 | 0.81 / 0.48 |
| 640x480 | decode | 3.01 / 2.61 | 2.54 / 4.02 | 4.22 / 0.82 | 4.27 / 2.11 |
| 640x480 | encode | 2.64 / 2.68 | 1.48 / 2.65 | 1.85 / 0.77 | 1.67 / 1.86 |
| 1024x768 | decode | 5.71 / 6.12 | 4.32 / 7.48 | 5.38 / 2.14 | 3.35 / 3.49 |
| 1024x768 | encode | 3.70 / 9.70 | 3.05 / 7.43 | 3.13 / 1.97 | 2.32 / 2.75 |
| 1600x1200 | decode | 7.81 / 13.37 | 3.89 / 14.75 | 7.51 / 5.07 | 4.52 / 6.12 |
| 1600x1200 | encode | 6.40 / 14.07 | 6.51 / 16.60 | 5.64 / 4.62 | 3.67 / 5.55 |
| 2048x1365 | decode | 9.30 / 19.22 | 4.66 / 20.15 | 8.74 / 7.31 | 5.31 / 7.88 |
| 2048x1365 | encode | 8.55 / 19.84 | 9.04 / 16.99 | 5.59 / 6.67 | 4.30 / 7.10 |
| 2048x1365 | decode | | | 8.73 / 7.36 | |
| 2048x1365 | encode | | | 6.48 / 6.67 | |
| 3840x2560 | decode | 12.31 / 49.69 | 8.21 / 52.55 | 12.38 / 25.26 | 9.15 / 25.04 |
| 3840x2560 | encode | 21.28 / 43.62 | 13.01 / 42.69 | 17.97 / 23.43 | 11.29 / 23.17 |
| 6720x4480 | decode | 28.50 / 101.75 | 16.06 / 107.09 | 25.69 / 75.77 | 21.47 / 74.68 |
| 6720x4480 | encode | 35.56 / 101.69 | 20.55 / 89.18 | 26.65 / 70.68 | 17.45 / 70.53 |

On an M4 profile measured from M4-like injected timings (isolated 256x256 calls around the table's cold cells,
1600x1200 calls at its cold mean, a proxy run of the M4 fit: cold GPU decode 3.74 ms + 2.50 ms/MP with a ramp of
7.08 ms, then 0.50 ms/MP; encode 1.10 + 3.16, ramp 9.20, then 0.56; warm GPU decode 2.43 + 0.50, encode 0.71 +
0.56; CPU ratio 4.00, rampMs 18.1), `prefersCPU` with the automatic state makes no wrong call where the loser is
more than 25% slower (cells within 10% count as ties) over all 58 cells, at the default CPU rates and at the M4's
measured warm rates (2.64 and 2.41 ms/MP), with the fitted CPU model and with the M4's measured one (ratio 7.16,
rampMs 22.2) alike. Every 3840x2560 and 6720x4480 cell goes to the GPU, and the new 2.8 MP decode with the GPU cold
and the CPU warm to the CPU. With the fitted CPU model two calls are wrong: a 640x480 encode warm/warm (CPU
advised, 11% slower, 0.19 ms lost; the warm/warm CPU had alternated with the GPU, so it was not fully warm) and a
2048x1365 encode with the GPU cold and the CPU warm (CPU advised, 19% slower, 1.08 ms lost; the GPU's cold cells at
that size, 8.55, 5.59 and 6.48 ms, differ by 53%). Regret: 1.27 ms over 58 calls, 0.64 ms per wrong call. With the
M4's measured CPU model a third: a 640x480 decode cold/cold (GPU advised, 15% slower, 0.40 ms lost); regret 1.67
ms, 0.56 ms per wrong call.

The first read of a profile (`MetalContext.profile` or `DeviceProfile.current`, not `Encoder.init`) starts the
sporadic measurement in the background on a `.utility` queue, never on a decode's or encode's critical path. It
runs the device's self-check if needed, makes one synthetic 256x256 image (the self-check's formula,
`SelfCheckTesting.pixels`), encodes it with the library's own encoder (q90 4:2:0) and decodes it once with a
separate decoder as the reference. Then 5 isolated decodes and 5 isolated encodes of it, interleaved, each after
at least 250 ms without this process's GPU work (if this process's own work does not pause for 250 ms within 2 s,
the measurement is not used); the first decode is on a fresh decoder and is `coldStartMs`. Each operation's cold
fixed cost is the median wall time of its 5 calls (it includes the image's 0.066 MP of per-MP work, about 0.03
ms). It must be at least 0.05 ms, which is true of every device, and at most 20x the sustained fixed cost (decode
up to 26.6 ms, encode up to 5.8 ms on a Mac); the lower bound is not the per-chip estimate, which can be above the
real cost (the iPhone 13's estimated encode fixed cost is 2.5 ms, its measured cold one 2.3 ms). Otherwise it is
rejected, nothing is cached, `measurementFailureReason` and `summary` say why ("measurement not used: implausible: ...") and the
measurement is tried again 10 minutes later. Every decode is compared with the reference, every encode with the
setup encode; a difference discards the measurement. GPU-active time is the setup encode and decode plus the 10
calls (tens of ms), then one isolated 1600x1200 decode and one encode (their setup encode and reference decode
included, about 20 ms more); the wall time is mostly the idle gaps. On the M1 Max (2026-11-17, load 6.2-6.5, the busy
gate's sample injected as idle), 3 fresh processes measured cold decode 5.94, 7.03 and 6.76 ms, cold encode 1.79,
2.04 and 1.87 ms, cold start 4.9-7.1 ms, at 3.9-4.0 s of wall time and 25-30 ms of GPU time. With the 1600x1200
calls and the CPU proxy (2026-11-17, load 9-13 on 10 cores, the sample injected as idle), 3 fresh processes: cold
decode 6.02-6.32 ms + 1.08-1.41 ms/MP (the raw slopes, up to 4.5 ms/MP on this busy GPU, held to 4x the sustained
0.354), cold encode 1.30-1.73 ms + 1.11-1.58 ms/MP, no CPU ramp seen (a busy CPU stays warm; the default model
stayed), at 3.98-3.99 s of wall time, 40-54 ms of GPU time and 6.6-20.5 ms of CPU for the proxy.

The result is saved as JSON in the Caches directory (`FileManager` `.cachesDirectory`; `Library/Caches` on iOS),
`<caches>/exact-jpeg-metal/routing-<hash>.json`, keyed by GPU name, family, core count, OS build, library
version (with a hash of the shader source) and the routing format (`routing-v5`, which adds the cold GPU ramp;
`routing-v4` added the cold per-MP costs and the CPU cold model; `routing-v4` and earlier files are ignored), so a new OS, GPU or library build measures again. A missing, corrupt,
stale or unwritable file only means the estimate is used and the measurement runs; the library works without any
cache (a sandboxed or read-only container). `EJM_PROFILE_CACHE=0` disables reading and writing it. A cached entry
whose last measurement (or attempt) is 24 hours old is re-measured once in the background the next time a profile
is read, at most once a day, and merged field by field keeping the minimum of each fixed, per-MP and cold-start
cost, so a measurement made under load never makes the numbers worse (the CPU cold model is not merged: the
newer valid fit replaces it whole, since ratio and ramp are fitted together and a pair from two runs is a model
no run produced, and a bad fit is replaced the next day; a proxy fit made while the GPU part was not used is kept
in a file of its own, the routing key plus `|cpu`, until a full measurement folds it in; the JSON records the merge count and the
last measured and attempted dates; `routingSource` stays `.cache` until the re-measure finishes, then becomes
`.measured`). The measurement describes an idle device, so it runs only when the device is idle: on macOS when
the GPU's "Device Utilization %" (IORegistry `PerformanceStatistics`, the entry that gives `gpu-core-count`) is
under 20% in two samples about 100 ms apart (after a first read that is discarded: the counter covers the time since the previous read, so the first read after a quiet stretch still shows the last busy period) and the 1-minute `getloadavg` is under the CPU core count; on iOS,
which exposes neither, unless `thermalState` is serious or worse or Low Power Mode is on. On a busy device it is
deferred (the estimate or the cache stays in use) and tried again on a later read at most once every 10 minutes.
This process's own work does not count: every `Decoder` and `Encoder` command buffer is tracked (two uncontended
lock operations per call), and utilization is sampled only after this process has had no GPU work for 1 s
(utilization is a decaying average), waiting up to 3 s, else the measurement is deferred ("this process's own GPU work did not pause"); work that
starts during the sampling defers it too;
the sample taken before a measurement is stored with it (`Routing.idleSample`, in the cache JSON) and shown in
`summary`.

### `DeviceProfile`

```swift
public final class DeviceProfile: @unchecked Sendable, CustomStringConvertible
public static var current: DeviceProfile             // MetalContext.shared.profile
```

| member | meaning |
|---|---|
| `DeviceProfile.current` | the profile of `MetalContext.shared`'s device; reading it starts the measurement |
| `DeviceProfile.gpuName` | the device's name |
| `DeviceProfile.family` | `DeviceProfile.Family`: `Family.apple7`, `Family.apple8`, `Family.apple9` (later GPUs report apple9); `Comparable` |
| `DeviceProfile.gpuCores`, `DeviceProfile.gpuCoresEstimated` | GPU core count, and whether it is an estimate (iOS) |
| `DeviceProfile.recommendedMaxWorkingSetSize` | the device's working set in bytes |
| `DeviceProfile.cpuPerformanceCores`, `DeviceProfile.cpuCoresIncludeEfficiency` | CPU performance cores; on iOS all cores, with the flag true |
| `DeviceProfile.encoderPath` | `DeviceProfile.EncoderPath`: `.fused` or `.twoPass`, the encoder's default (see `Encoder.fusedMaxBlocks`) |
| `DeviceProfile.suggestedInFlight` | images worth keeping in flight at once, one `Decoder` or `Encoder` per thread |
| `DeviceProfile.maxGPUBytes` | the decoder's default memory budget, half the working set |
| `DeviceProfile.estimatedRouting` | the sustained set, an estimate from the core count (`measured` false); also the plausibility yardstick of the sporadic measurement |
| `DeviceProfile.estimatedSporadicRouting` | the sporadic set until measured: the cold ramp through two calls at the M4's ratios of isolated to sustained time (on an M4, the M4 fit); on iOS at the iPhone 13's isolated calls (256x256 and 1600x1200: decode 7.5 and 14.4 ms, encode 2.1 and 12.1 ms) |
| `DeviceProfile.sporadicRouting` | the sporadic set, the cold GPU (single calls with the GPU idle between): pinned, else measured (now or from the cache: cold fixed and per-MP costs and the ramp), else `estimatedSporadicRouting` |
| `DeviceProfile.warmRouting` | the warm GPU (this process used it within `warmWindow`): `sustainedRouting`'s per-MP costs plus `gpuWarmFixedFraction` x `sporadicRouting`'s fixed costs (at least the sustained ones) |
| `DeviceProfile.sustainedRouting` | the sustained set (2 or more jobs in flight): pinned, else `estimatedRouting`; never measured |
| `DeviceProfile.routing` | the same as `sporadicRouting` |
| `DeviceProfile.routingSource` | `DeviceProfile.RoutingSource`: `.estimate`, `.measured`, `.cache` or `.pinned` |
| `DeviceProfile.measurementFailureReason` | why the last routing measurement was not used (implausible timings, this process's own GPU work did not pause, an output differed), while the estimate or the cached set stands because of it; nil when it was used or none has run |
| `DeviceProfile.prefersCPU(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)` | see below |
| `DeviceProfile.noteCPUWork()` | static: call when your CPU codec finishes a job; the CPU counts as warm for `warmWindow` after |
| `DeviceProfile.beginCPUWork()` | starts timing a CPU job for this profile's load correction; `CPUWork.end(width:height:operation:cpuMsPerMP:)` records it (see "Load correction") |
| `DeviceProfile.noteCPUWork(milliseconds:width:height:operation:cpuMsPerMP:startedWarm:)` | the same sample from your own timing |
| `DeviceProfile.loadFactors(width:height:operation:gpuSet:cpuWarm:)` | the load correction for that kind of call, a `DeviceProfile.LoadFactors` (`gpu`, `cpu`; 1 without recent samples) |
| `DeviceProfile.loadCorrectionEnabled` | static, settable: load awareness on (default) or off for the process; `EJM_LOAD_CORRECTION=0` starts it off |
| `DeviceProfile.loadCorrectionHalfLife` | static: 8 s, the time for a load-correction factor to fade halfway back to 1 without new samples |
| `DeviceProfile.currentWarmth` | static: a `DeviceProfile.Warmth`, whether the GPU and the CPU are warm now and why (see below) |
| `DeviceProfile.cpuColdModel` | the `DeviceProfile.CPUColdModel` in use: pinned, else measured (now or from the cache), else `defaultCPUColdModel` |
| `DeviceProfile.pinCPUColdModel(_:)` | fixes the CPU cold model; `nil`: back to measured or the default; not saved |
| `DeviceProfile.measuredRouting(timeout:)` | waits up to `timeout` seconds for the measurement (starting it if needed); the measured, cached or pinned sporadic numbers, or `nil` if it has not finished, failed or is disabled |
| `DeviceProfile.pinRouting(_:sustained:)` | fixes the sporadic set to `r` and the sustained set to `sustained` (default: `r` too); `nil`: back to measured or estimated; pinned numbers are not saved |
| `DeviceProfile.clearCache()` | deletes the saved measurements (every device); a new process measures again |
| `DeviceProfile.summary`, `DeviceProfile.description` | one line with every field |
| `DeviceProfile.dictionary` | every field as `[String: Any]` (benchmark JSON) |
| `DeviceProfile.defaultCPUDecodeMsPerMP`, `DeviceProfile.defaultCPUEncodeMsPerMP` | 3.0 and 2.5: libjpeg-turbo single-thread estimates (NEON, Apple silicon performance cores), used when `prefersCPU` gets no rate |
| `DeviceProfile.cpuPreferenceMargin` | 0.2: `prefersCPU` advises the CPU only when it is predicted at least 20% faster; closer calls go to the GPU, which frees the caller's CPU and keeps the GPU warm. On an M4 the measured winner of cells within about 20% of a crossover changed between identical runs, while every cell whose winner was more than 25% ahead was routed right in every run |
| `DeviceProfile.defaultCPUColdModel` | the CPU cold model until measured: ratio 4.0, rampMs 18 (the M4 fit) |
| `DeviceProfile.cpuTinyJobMs`, `DeviceProfile.cpuTinyPenaltyMs` | 0.25 ms and 0.25 ms: the CPU cold model's tiny-job cap, `warm + cpuTinyPenaltyMs + (ratio - 1) x max(0, warm - cpuTinyJobMs)` |
| `DeviceProfile.gpuWarmFixedFraction` | 0.65: `warmRouting`'s fixed costs as a fraction of the cold ones |
| `DeviceProfile.warmWindow` | 0.25 s: a side counts as warm when it worked this recently |
| `DeviceProfile.coldCPUFactor` | deprecated, not used: replaced by `cpuColdModel`, which `prefersCPU` applies to any warm rate when the CPU is cold |

`DeviceProfile.Operation` is `.decode` or `.encode`. Exact: not applicable; nothing here changes bytes. When:
`suggestedInFlight` to size a pool of decoders, `prefersCPU` to route small images, the rest for diagnostics.

```swift
import ExactJPEG

let p = DeviceProfile.current
print(p.summary)
let pool = (0..<p.suggestedInFlight).map { _ in Decoder() }
print(pool.count, p.encoderPath, p.routingSource)
```

### `DeviceProfile.prefersCPU(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)`

```swift
public func prefersCPU(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil, sustained: Bool? = nil,
                       cpuWarm: Bool? = nil) -> Bool
```

`true` when the caller's CPU codec is predicted to finish the image sooner than the GPU, given how warm each is.
The GPU side: `sustained` nil (the default) follows this process's own GPU work, `warmRouting` if it used the GPU
within `warmWindow` (250 ms) or has a command buffer in flight, else `sporadicRouting`; `true` means the caller
keeps 2 or more jobs in flight (a batch export, one `Decoder` or `Encoder` per thread), so `sustainedRouting`;
`false` means the GPU is cold, `sporadicRouting`. The CPU side: `cpuMsPerMP` is the codec's warm rate (default
`defaultCPUDecodeMsPerMP` / `defaultCPUEncodeMsPerMP`, 3.0 and 2.5; the M4 measured 2.64 and 2.41); `cpuWarm`
`true` or `false` says whether the CPU is warm; nil (the default) is `sustained` when that is given, so
`sustained: true` alone means both warm and `sustained: false` alone both cold, as before; with both nil it follows
`noteCPUWork()` and the process's CPU time. When the CPU is cold, `cpuColdModel` turns the warm time into the cold
one. So pass a warm rate (your codec timed back to back), call `DeviceProfile.noteCPUWork()` when your CPU codec
finishes a job, and leave both flags nil unless you know better. The library does not act on the advice: a
decode or encode called on the GPU runs on the GPU, and bytes are the same either way. Source compatible with the
earlier `sustained: Bool = false`: `sustained: true` and `sustained: false` mean what they did (the GPU and the
CPU in that state); leaving it out now follows the detected state of both instead of assuming both cold, and a
caller-passed `cpuMsPerMP` is now a warm rate.

```swift
import ExactJPEG

let p = DeviceProfile.current
if p.prefersCPU(width: 320, height: 240, operation: .decode) { print("decode this one with libjpeg-turbo") }
// after each libjpeg-turbo job:
DeviceProfile.noteCPUWork()
print(DeviceProfile.currentWarmth)
print(p.prefersCPU(width: 6000, height: 4000, operation: .encode, cpuMsPerMP: 2.2, sustained: true, cpuWarm: true))
```

### `DeviceProfile.routingDecision(width:height:operation:cpuMsPerMP:sustained:cpuWarm:)`

```swift
public func routingDecision(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil,
                            sustained: Bool? = nil, cpuWarm: Bool? = nil) -> RoutingDecision
public enum GPUSet: String, Sendable { case sporadic, warm, sustained }
public struct RoutingDecision: Equatable, Sendable {
    public var prefersCPU: Bool
    public var predictedCPUms: Double, predictedGPUms: Double
    public var gpuSet: GPUSet
    public var cpuCold: Bool
    public var warmth: Warmth?
    public var source: RoutingSource
    public var marginApplied: Bool
    public var loadFactors: LoadFactors
}
```

A `DeviceProfile.RoutingDecision`: the decision `prefersCPU` makes, with what it was made from; same arguments and defaults. `prefersCPU` is now
`routingDecision(...).prefersCPU`. Advice only: the decoder and the encoder always use the GPU when called.
`RoutingDecision.prefersCPU` the answer; `RoutingDecision.predictedCPUms` the predicted CPU time (the cold time
when `cpuCold`); `RoutingDecision.predictedGPUms` the predicted GPU time from the set used;
`RoutingDecision.gpuSet` that set, a `DeviceProfile.GPUSet`: `sporadic` (`sporadicRouting`, the cold GPU), `warm`
(`warmRouting`) or `sustained` (`sustainedRouting`); `RoutingDecision.cpuCold` whether the CPU was taken as cold
(`cpuColdModel` applied); `RoutingDecision.warmth` the detected `Warmth` when it was used (`sustained` nil),
else nil; `RoutingDecision.source` the profile's `routingSource`; `RoutingDecision.marginApplied` true when the
CPU was predicted faster but by less than `cpuPreferenceMargin`, so the advice is the GPU;
`RoutingDecision.loadFactors` the load correction both predictions were multiplied by (see "Load correction"). `prefersCPU` is
`predictedCPUms * (1 + cpuPreferenceMargin) < predictedGPUms`. api-check `trace` checks it against `prefersCPU`
for 120 argument sets. The trace line's `route` is this with the automatic warmth. When: logging why a call was
routed one way.

```swift
import ExactJPEG

let r = DeviceProfile.current.routingDecision(width: 640, height: 480, operation: .decode)
print(r.prefersCPU, r.predictedCPUms, r.predictedGPUms, r.gpuSet, r.cpuCold, r.source, r.marginApplied, r.warmth.map(String.init(describing:)) ?? "-")
```

### `DeviceProfile.Warmth`

```swift
public struct Warmth: Equatable, Sendable, CustomStringConvertible
public init(gpuWarm: Bool, cpuWarm: Bool, gpuInFlight: Bool = false, gpuIdleSeconds: Double? = nil,
            cpuIdleSeconds: Double? = nil, processCPUCores: Double? = nil, deviceGPUPercent: Int? = nil)
```

What `DeviceProfile.currentWarmth` returns. `Warmth.gpuWarm`: this process had a command buffer in flight
(`Warmth.gpuInFlight`) or one finished within `warmWindow`; `Warmth.gpuIdleSeconds` is the time since the last one
finished (0 while one is in flight, `nil` if none ran yet). `Warmth.cpuWarm`: `noteCPUWork()` within `warmWindow`
(`Warmth.cpuIdleSeconds` is the time since, `nil` if never called), or `Warmth.processCPUCores`, the process's CPU
use in cores over the window since the reference sample (`nil` without a window of 0.05-0.25 s, or while the CPU
proxy runs), over 0.5. On macOS, `Warmth.gpuWarm` is also true when `Warmth.deviceGPUPercent` is 25% or more.
That value is the share of GPU work outside this library's own calls (other apps, or your app's own rendering):
IORegistry "Device Utilization %", which covers the time since the previous read by any process. Activity Monitor
and other apps using this library read it too, so a read is used only when this library had no GPU work in this
process during its interval; then, however long the interval was, the value is that outside share. Another app keeping the GPU busy keeps it clocked up, so the cold-GPU penalty does not
apply. On an M4 with another process decoding in a loop, the cold set's prediction had sent work to the CPU that
the GPU did 1.8-2x faster.
- Reads run on a background thread every 0.25 s, for 5 s after the warmth was last read for advice
  (`currentWarmth`, or `prefersCPU` / `routingDecision` when they detect the warmth themselves and this process's
  own recent GPU work does not already make the GPU warm), then stop. A decode or encode uses the latest value but
  never starts them, nor does the trace line of a traced call (`MetalContext.trace`, `EJM_TRACE`: its route
  advice reads a snapshot; before 2026-11-19 it started them). Turning load correction off
  (`loadCorrectionEnabled = false`) stops reads already running after their current one (before 2026-11-19 they
  ran on for up to 5 s) and forgets the request, so turning it on again does not restart them. The first read after they start is a baseline, so an app that asks less often than every 5 s,
  or whose own GPU work fills most 0.25 s intervals, gets no value: the advice then follows this process's own
  warmth only, as without this reading.
- A read cost 0.2-1.7 ms on an M4, never on a call's path. A value older than 1 s counts as unknown.
- It is `nil` when this process's own work already made the GPU warm, when no usable read is recent, on iOS, and
  when load awareness is off. The counter read is the default Metal device's; Apple silicon has one GPU.

`Warmth.description` is one line, e.g. "GPU warm (idle 0.012 s), CPU cold (noted 3.100 s ago, process 0.02
cores)". `Warmth.init(gpuWarm:cpuWarm:gpuInFlight:gpuIdleSeconds:cpuIdleSeconds:processCPUCores:deviceGPUPercent:)` is for tests.
Exact: not applicable. When: logging why a call was routed.

### Load correction

```swift
public func beginCPUWork() -> CPUWork
public struct CPUWork: Sendable {
    public let startedWarm: Bool
    public func end(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil)
}
public func noteCPUWork(milliseconds: Double, width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil,
                        startedWarm: Bool)
public struct LoadFactors: Equatable, Sendable, CustomStringConvertible { public var gpu: Double, cpu: Double; public init(gpu: Double, cpu: Double) }
public func loadFactors(width: Int, height: Int, operation: Operation, gpuSet: GPUSet, cpuWarm: Bool) -> LoadFactors
public static var loadCorrectionEnabled: Bool          // default true; EJM_LOAD_CORRECTION=0 starts it false
public static let loadCorrectionHalfLife: Double      // 8 s
```

The routing numbers describe an idle device. Another app on the CPU or the GPU, thermal throttling or Low Power
Mode moves the real costs away from them. The library follows that from calls on this device:

- **GPU samples.** A public single-image decode or encode is a sample: its wall time against the profile's
  prediction for the GPU state it started in (cold or warm).
  - Not samples: a call that overlapped other GPU work of this process at any point (another public call, an
    encode batch, the library's own calibration), since threads sharing the GPU see each other's latency, not
    load; a call that did setup work (a pipeline built, the
    self-check run, a buffer allocated or grown); a failed call; a call that retried inside (a decode's 64-pass
    second attempt, an encode resubmitted for capacity or after a fused-path fallback: its time is not one
    attempt's; since 2026-11-19); the library's own calibration calls. Repeat decodes from a packed copy are not
    samples but count as GPU work of this process that other calls overlap (since 2026-11-19).
  - The sustained set is never corrected.
- **CPU samples.** `DeviceProfile.beginCPUWork()` before your CPU job (a `DeviceProfile.CPUWork`) and
  `CPUWork.end(width:height:operation:cpuMsPerMP:)` after it add one, timed by the library, against the
  prediction at the warm rate you pass to `prefersCPU` (cold from `cpuColdModel` when the CPU started cold).
  - `CPUWork.startedWarm` is the CPU's warmth at the start; a job makes the CPU warm by its end, so taking it
    afterwards files cold jobs as warm.
  - `noteCPUWork(milliseconds:width:height:operation:cpuMsPerMP:startedWarm:)` adds the same sample from your
    own timing.
  - Both also do what `noteCPUWork()` does, and neither touches Metal.
- **When factors apply.** No factor applies until your app has reported at least one timed CPU job on this
  device. An app that times only the GPU side would otherwise get advice skewed by GPU-side error alone, such as
  content unlike the profile's synthetic q90 4:2:0 image.
- **Kinds of call.** Samples are kept per device and kind of call: side, operation, starting state, and size
  (under or at least 1 MP). A correction learned on small cold calls does not change advice for large warm ones,
  and a profile for another device (or a what-if from the layer-1 rules) is not corrected.
- **The estimate.** Each sample is log(observed / predicted), clamped to 0.5x-4x. Per kind, the estimate is
  their weighted mean, and one sample counts a third. The weight halves every `loadCorrectionHalfLife` (8 s)
  without new samples, and the clock includes sleep.
- **The factor.** Only the part beyond a 1.25x dead zone is applied, which keeps idle noise out: noise moved the
  raw ratios by 20-50% on an M4. So the applied factor ranges from 0.625x to 3.2x.
- **Using the factors.** `prefersCPU` multiplies its two predictions by the factors for the call it is asked
  about (`RoutingDecision.loadFactors`): `LoadFactors.gpu` for the GPU prediction and `LoadFactors.cpu` for the
  CPU one. `LoadFactors.description` reads e.g. "GPU 1.00x, CPU 2.14x"; `LoadFactors.init(gpu:cpu:)` is for
  comparisons in tests.
- **Limits.**
  - Under steady load the slow side stops being chosen, so it gets no new samples. Its factor fades back toward
    1 over roughly 10-30 s, a few calls go there, and the factor is relearned. The cost is bounded and brief.
  - Once a CPU job has been reported, GPU samples also absorb content unlike the profile's synthetic q90 4:2:0
    image (4:4:4, q100, gray). Most of that difference is inside the dead zone.
  - A call that waits on setup work started just before it (a pipeline another thread is building) can still be
    a sample.
- **Turning it off.** `DeviceProfile.loadCorrectionEnabled = false` (or `EJM_LOAD_CORRECTION=0` at start) turns
  load awareness off for the process: every factor is 1, and other processes' GPU use is not read.

Advice only: the factors never change bytes, and nothing is saved.

On an M4 MacBook Air, the 40-cell routing acceptance gave the results below. It covers 5 sizes, decode and encode,
and each mix of cold and warm GPU and CPU, with isolated calls and every call's truth timed live. Without is
`EJM_LOAD_CORRECTION=0`, run in the same session and alternated with with. Values are ms lost to wrong advice over
the 40 cells, with the number of wrong cells:

| condition | without | with |
|---|---|---|
| idle, run 1 | 1.59 ms (3) | 0.56 ms (2) |
| idle, run 2 | 1.40 ms (4) | 0.59 ms (2) |
| 8 of 10 cores busy (another process) | 10.8 ms (8) | 1.1 ms (4) |
| GPU busy (another process decoding and encoding 30 MP in a loop) | 11.6 ms (10) | 0.8 ms (5) |

When: always, if your app runs the CPU path. Time each CPU job with `beginCPUWork()`, not just `noteCPUWork()`.

```swift
import ExactJPEG

let p = DeviceProfile.current
if p.prefersCPU(width: w, height: h, operation: .decode, cpuMsPerMP: 2.6) {
    let job = p.beginCPUWork()
    // ... libjpeg-turbo decode ...
    job.end(width: w, height: h, operation: .decode, cpuMsPerMP: 2.6)
} else {
    _ = Decoder().decode(jpeg)          // a sample by itself
}
print(p.loadFactors(width: w, height: h, operation: .decode, gpuSet: .warm, cpuWarm: true))
```

### `DeviceProfile.CPUColdModel`

```swift
public struct CPUColdModel: Codable, Equatable, Sendable
public init(ratio: Double, rampMs: Double, measured: Bool = false, measurementMs: Double = 0)
```

The caller's CPU codec when the CPU is cold (see "The CPU cold model" above). `CPUColdModel.ratio` is a short
job's cold time over its warm time, `CPUColdModel.rampMs` the most a job loses to the clock ramp;
`CPUColdModel.rampedMs(warmMs:)` is the curve, `warm + rampMs x (1 - exp(-(ratio - 1) x warm / rampMs))`, and
`CPUColdModel.coldMs(warmMs:)`, what `prefersCPU` uses, is the curve with the tiny-job cap:
`min(curve, warm + cpuTinyPenaltyMs + (ratio - 1) x max(0, warm - cpuTinyJobMs))`.
`CPUColdModel.measured` is true when fitted from the proxy on this device and `CPUColdModel.measurementMs` the
proxy's CPU time. `CPUColdModel.init(ratio:rampMs:measured:measurementMs:)` is for `pinCPUColdModel(_:)`.

```swift
import ExactJPEG

let m = DeviceProfile.current.cpuColdModel
print(m.ratio, m.rampMs, m.coldMs(warmMs: 5.5))       // the default: 4.0, 18.0, about 16.3
```

### `DeviceProfile.Routing`

```swift
public struct Routing: Codable, Equatable, Sendable
public init(decodeFixedMs: Double, decodeMsPerMP: Double, encodeFixedMs: Double, encodeMsPerMP: Double,
            coldStartMs: Double, measured: Bool, measurementMs: Double = 0, measurementGPUMs: Double = 0,
            idleSample: IdleSample? = nil, measurementRounds: Int? = nil,
            decodeRampMs: Double? = nil, decodeWarmMsPerMP: Double? = nil,
            encodeRampMs: Double? = nil, encodeWarmMsPerMP: Double? = nil)
```

Without a ramp, `Routing.decodeFixedMs` + `Routing.decodeMsPerMP` x megapixels is the predicted wall time of a
decode, and `Routing.encodeFixedMs` + `Routing.encodeMsPerMP` x megapixels of an encode (the sustained and warm
sets). With one (the sporadic set, measured or estimated: `Routing.decodeRampMs` and `Routing.decodeWarmMsPerMP`
both set, likewise `Routing.encodeRampMs` and `Routing.encodeWarmMsPerMP` for encode), the decode is `decodeFixedMs + decodeWarmMsPerMP x MP + decodeRampMs x (1 -
exp(-(decodeMsPerMP - decodeWarmMsPerMP) x MP / decodeRampMs))`: `decodeMsPerMP` is a short job's cold per-MP
cost, falling to `decodeWarmMsPerMP` as the job warms the GPU (see "Sporadic routing" above).
`Routing.gpuMs(megapixels:operation:)` computes either; `Routing.ramp(_:)` gives an operation's `(rampMs,
warmMsPerMP)` or nil, and `Routing.costDescription` one line, e.g. "decode 3.954 ms + 2.245 ms/MP (ramp 6.18 ms,
then 0.500 ms/MP), encode ...". `Routing.coldStartMs` is the wall time of a new decoder's first decode after the self-check (its
buffers are allocated then, and the GPU clock is whatever the device was doing; an idle GPU costs more: the M4 took
9.6 ms after 5 s idle against 1.9 ms of GPU time). `Routing.measured` is true for numbers timed on this device.
`Routing.measurementMs` and `Routing.measurementGPUMs` are the measurement's own wall and GPU time (0 for an
estimate); `Routing.idleSample` is how busy the device was just before it and `Routing.measurementRounds` how
many isolated calls per operation the cold fixed costs are the median of (both nil for an estimate). The
`Routing.init(decodeFixedMs:decodeMsPerMP:encodeFixedMs:encodeMsPerMP:coldStartMs:measured:measurementMs:measurementGPUMs:idleSample:measurementRounds:decodeRampMs:decodeWarmMsPerMP:encodeRampMs:encodeWarmMsPerMP:)`
initialiser is for `pinRouting(_:)`. The daily re-measure's merge keeps the minimum of each ramp field too (the
cost rises with each of them, so the merged curve is never above either).

```swift
import ExactJPEG

let p = DeviceProfile.current
p.pinRouting(DeviceProfile.Routing(decodeFixedMs: 1, decodeMsPerMP: 0.2, encodeFixedMs: 0.5, encodeMsPerMP: 0.4,
                                   coldStartMs: 5, measured: false))
print(p.routingSource, p.routing.gpuMs(megapixels: 12, operation: .decode), p.sustainedRouting == p.routing)
p.pinRouting(nil)
```

### `DeviceProfile.IdleSample`

```swift
public struct IdleSample: Codable, Equatable, Sendable
public init(gpuUtilization: [Int], loadAverage: Double?, cpuCores: Int, thermalSerious: Bool = false, lowPowerMode: Bool = false)
```

How busy the device was when sampled. `IdleSample.gpuUtilization` holds the utilization samples in percent
(empty on iOS), `IdleSample.loadAverage` the 1-minute load average (nil on iOS), `IdleSample.cpuCores` the CPU
core count it is compared with, `IdleSample.thermalSerious` and `IdleSample.lowPowerMode` the iOS signals.
`IdleSample.idle` is true when every utilization sample is under 20%, the load is under the core count, and
neither iOS signal is set; `IdleSample.summary` is one line. `IdleSample.init(gpuUtilization:loadAverage:cpuCores:thermalSerious:lowPowerMode:)` is for tests that inject samples. A summary reads "GPU 3%/4%, load 1.00 of 10 cores". Exact: not
applicable. When: diagnostics; read it from `routing.idleSample`.

### `MetalContext.profile`

`public var profile: DeviceProfile`. This context's device's profile (one per device in the process). The first
read on a device starts the background measurement unless the cache has it. `Encoder.init(ctx:)` uses layer 1
without reading it, so an app that never reads a profile runs no measurement and its per-call costs are
unchanged.

### `DeviceProfileTesting`

```swift
@_spi(Testing) public enum DeviceProfileTesting
```

Hooks for `ejm`, visible only with `@_spi(Testing) import ExactJPEG`; not a stable interface.
`DeviceProfileTesting.cacheDirectory` redirects the cache (set before the first read). `DeviceProfileTesting.cacheEnabled`
is false under `EJM_PROFILE_CACHE=0`. `DeviceProfileTesting.cacheFile(_:)`, `DeviceProfileTesting.loadCache(_:)` and
`DeviceProfileTesting.saveCache(_:_:)` reach a profile's cache file. `DeviceProfileTesting.fresh(_:)` computes layer 1
afresh for a device; `DeviceProfileTesting.derive(name:family:gpuCores:workingSet:cpuCores:)` applies the layer-1 rules
to given properties (`gpuCores` nil: estimated as on iOS). `DeviceProfileTesting.measure(_:)` runs the measurement on
the calling thread, without the cache. For the daily re-measure: `DeviceProfileTesting.clock` replaces the clock
of the 24-hour gate, `DeviceProfileTesting.merge(_:_:)` is the field-by-field minimum,
`DeviceProfileTesting.saveEntry(_:_:merges:lastMeasured:lastAttempt:)` writes an entry with given dates,
`DeviceProfileTesting.entry(_:)` reads one back (routing, merges, dates), `DeviceProfileTesting.remeasureDue(_:)`
applies the gate, and `DeviceProfileTesting.waitForRemeasure(_:timeout:)` waits for a running re-measure. For the busy gate:
`DeviceProfileTesting.loadCorrectionClock`, `DeviceProfileTesting.resetLoadCorrection()`,
`DeviceProfileTesting.loadSampleCount`, `DeviceProfileTesting.addLoadSample(_:cpu:_:state:megapixels:observedMs:predictedMs:)`,
`DeviceProfileTesting.otherGPUPercent(devicePercent:ownBusySeconds:)`, `DeviceProfileTesting.deviceActivityRead`,
`DeviceProfileTesting.deviceActivityPolling`, `DeviceProfileTesting.stopDeviceActivityPolling()`,
`DeviceProfileTesting.simulateCall(_:width:height:ms:trackedInside:setupInside:overlappingCall:)`,
`DeviceProfileTesting.deviceActivityReadNow(thenAfter:)`,
`DeviceProfileTesting.resetDeviceActivity()` and
`DeviceProfileTesting.deviceGPUPercentRead` drive the load correction and the device-wide GPU read in tests;
`DeviceProfileTesting.idleSampler` replaces the sampler (nil: the real one), `DeviceProfileTesting.utilizationRead` replaces the macOS utilization read inside the real sampler, `DeviceProfileTesting.sampleRaw(_:)` runs the real sampler at once, `DeviceProfileTesting.gateChecks(_:)`
counts a profile's gate samples, and `DeviceProfileTesting.sampleNow(_:quiet:)` takes one real sample after waiting for
this process's own GPU work to pause for `quiet` seconds (default 0.3, waiting up to `quiet` + 2 s; GPU
utilization is a decaying average, so `ejm profile` passes 1);
`DeviceProfileTesting.runGate(_:)` runs a profile's gate now and `DeviceProfileTesting.ownGPUQuietSeconds` is the
time since this process's last command buffer completed. For the measurement:
`DeviceProfileTesting.timingOverride` replaces its GPU work with a `DeviceProfileTesting.MeasurementTimings`:
`MeasurementTimings.decode` and `MeasurementTimings.encode`, the wall ms of each isolated call in call order (the
first decode is the cold start), built with `MeasurementTimings.init(decode:encode:)`.
`DeviceProfileTesting.measure(_:estimate:)` runs the measurement alone against a given sustained estimate and
`DeviceProfileTesting.measureDetailed(_:)` runs it on a context's own estimate (no cache); both return a
`DeviceProfileTesting.Measurement`: `Measurement.sporadic` (nil when not used), `Measurement.reason` (why not),
`Measurement.decodeMs` and `Measurement.encodeMs` (each call's wall ms), `Measurement.wallMs` and
`Measurement.gpuMs` (its cost), `Measurement.decodeLargeMs` and `Measurement.encodeLargeMs` (the 1600x1200
calls), `Measurement.cpu` (the fitted CPU cold model, nil when not used), `Measurement.cpuReason` (why not) and
`Measurement.cpuChunksMs` (the proxy's chunk times). `DeviceProfileTesting.estimate(gpuCores:coresEstimated:)` and `DeviceProfileTesting.sporadicEstimate(_:ios:)` give
the estimates for any core count. `DeviceProfileTesting.minColdFixedMs` is the plausibility
floor for a cold fixed cost (0.05 ms). `DeviceProfileTesting.failureReason(_:)` is why a profile's
last attempt was not used, `DeviceProfileTesting.cpuFailureReason(_:)` why its last proxy fit was not.
`MeasurementTimings.decodeLarge` and `MeasurementTimings.encodeLarge` inject the 1600x1200 calls (nil: the
estimate's per-MP costs) and `MeasurementTimings.cpuChunks` the proxy's chunk times (nil: not measured), through
`MeasurementTimings.init(decode:encode:decodeLarge:encodeLarge:cpuChunks:)`;
`DeviceProfileTesting.measure(_:estimate:timings:)` runs the measurement on given timings.
For the CPU proxy: `DeviceProfileTesting.fitCPUProxy(_:)` fits chunk times, `DeviceProfileTesting.simulateCPUProxy(_:chunkMs:)`
gives the chunk times of a CPU that follows a model exactly, `DeviceProfileTesting.runCPUProxy()` runs it for real.
For warmth: `DeviceProfileTesting.warmthClock` replaces the tracker's clock (monotonic seconds, the base of
`DeviceProfileTesting.monotonicNow`), `DeviceProfileTesting.proxyRunBegin()` and `DeviceProfileTesting.proxyRunEnd()`
bracket a pretend proxy run,
`DeviceProfileTesting.processCPUTime` the process CPU time it reads, `DeviceProfileTesting.gpuActivity` the GPU
activity (commands in flight, last completion); `DeviceProfileTesting.realGPUActivity` reads the real one,
`DeviceProfileTesting.gpuWorkBegin()` and `DeviceProfileTesting.gpuWorkEnd()` bracket pretend GPU work as the codec
does, and `DeviceProfileTesting.resetWarmth()` forgets `noteCPUWork` and the CPU-time reference. For the cache:
`DeviceProfileTesting.cacheKey(_:)`, `DeviceProfileTesting.saveCache(_:cpu:_:)`, `DeviceProfileTesting.loadCPUCache(_:)`
`DeviceProfileTesting.loadCPUOnlyCache(_:)` (a CPU model saved on its own) and `DeviceProfileTesting.mergeCPU(_:_:)`
(the newer valid fit, else the older).

## Startup self-check

The library's output is byte-identical to libjpeg-turbo on every GPU and OS it has been tested on, but a future
GPU, OS release or Metal shader compiler could change that silently. So before a device's first decode, the
library decodes seven small built-in JPEGs on that GPU, and before its first encode, it encodes two synthetic
images. It then compares the SHA-256 of each output with the hash libjpeg-turbo 3.2.0 produced, never the GPU. If
any output differs, or a case declines or reports a GPU error, the library treats that device as broken for the
rest of the process: every later decode declines and every later encode fails, on every `Decoder`, `Encoder` and
C handle on that device. Callers then fall back to their CPU codec, as for any declined file.

| when | runs |
|---|---|
| first decode on a device (`Decoder.decode` in any form, `ejm_decode`, `ejm_decode_view`) | the decode half |
| first encode on a device (`Encoder.encode` in either form, `Encoder.encodeBatch(_:)`, `ejm_encode`) | the encode half |
| `MetalContext.warmUp()` | both halves |

A decode-only process never builds the encoder's pipelines or runs the encode half. Each half runs once per
process per `MTLDevice`, shared by every `MetalContext` on that device. Concurrent first calls run it once and
the other threads wait (api-check: 10 threads making their first decode at the same time, then 10 making their
first encode, run each half exactly once). After a half has passed, the cost per call is one flag check (behind its own uncontended lock since 2026-11-19, so concurrent first calls on other threads never read it in a data race). A
failure in either half is recorded and never retried, and it fails both kinds of call: a GPU path that is broken
for one operation is not trusted for the other. The result is not stored on disk; each process checks again.

The cases, built into the library source (`Sources/ExactJPEG/SelfCheckData.swift`, 15,094 bytes of JPEG data).
Each decode case is decoded at the chunk size the decoder picks by default for its stream (2048 bits, as every
stream here is under 256 KB):

| case | input | checked |
|---|---|---|
| `decode 4:2:0 with restart markers` | 61x45 (odd size), q90, restart every 2 MCUs | SHA-256 of the `.rgb` output |
| `decode 4:2:0 without restarts` | 80x64, q90, one segment of 3,825 bytes of entropy-coded data: 15 Huffman chunks at the default 2048 bits, so the chunks really resynchronise; decoded a second time in 4096-bit chunks (8 chunks; the default for streams of 256 KB and more; a failure there is reported as `decode 4:2:0 without restarts, 4096-bit chunks`) and a third time in 64-bit chunks (479 chunks over several threadgroups, 2 synchronisation passes), so the work between passes runs too (`decode 4:2:0 without restarts, small chunks`) | `.rgb` |
| `decode 4:2:2` | 48x32, q90 | `.bgr` |
| `decode 4:4:4` | 40x24, q85 | `.rgba` |
| `decode gray` | gray JPEG, 37x29, q80 | `.gray` |
| `decode 4:4:0` | 40x48, q90, 4:4:0 (luma 1x2) | `.rgb` |
| `decode 16-bit quantisation tables` | 40x32, 4:2:0, q8 encoded without `force_baseline`: quantisers up to 756, which libjpeg-turbo writes as a 16-bit DQT (SOF1) | `.bgra` |
| `encode fused` | 64x48 RGB, q90, 4:2:0, the fused small-image entropy path | SHA-256 of the whole JPEG file |
| `encode two-pass` | 45x31 RGBX with 12 bytes of row padding, q75, 4:4:4, encoded with `fusedMaxBlocks` 0 so the image is above it (the two-pass entropy path) | the whole file |

Every image is synthetic, from one integer formula (`SelfCheckTesting.pixels(width:height:channels:rowBytes:)`,
the same as the CUDA sibling library's self-check): for pixel (x, y) and channel c (0 R, 1 G, 2 B),
v = (x*7 + y*13 + c*61 + ((x*y) >> 3)) & 255, plus 40 where ((x >> 4) + (y >> 4)) is even and minus 40
elsewhere, clamped to 0...255; a gray source uses c = 0. The decode sources are libjpeg-turbo encodes of it.
The self-check decodes with the default chunk size for each stream (and 4096 and 64 bits for the no-restart case)
and `checkpoints` 7, whatever `EJM_CHUNK_BITS` and `EJM_NCP` say.
`ejm selfcheck-gen` rebuilds the file with libjpeg-turbo and `scripts/test.sh` fails if the committed file differs
from a fresh regeneration (as for `ShaderSource.swift`); see [CLI.md](CLI.md).

On a failure the reason is "self-check failed on <GPU name>, <OS version>: <case>", for example
"self-check failed on Apple M1 Max, macOS 27.2 (26B123): decode 4:2:0 with restart markers (output differs)". The
case is the first one that failed, by the names above, or "forced by EJM_SELFCHECK_FAIL=1"; the bracket says how:
"(output differs)", "(declined: <the decoder's reason>)" or, for an encode, "(<error type>: <message>)". The prefix
is the same as in the CUDA sibling library's self-check. It appears as:

- Swift decode: `nil`, with this text in `Decoder.reason`; the output buffer is untouched;
- Swift encode: `SelfCheckFailed` is thrown, `description` this text;
- `ejm_decode` and `ejm_decode_view`: `EJM_DECLINED`, this text in `ejm_decoder_reason`, `out` untouched;
- `ejm_encode`: `EJM_ERROR`, this text in `ejm_encoder_error`.

`EJM_SELFCHECK_FAIL=1` forces a failure (after the cases run), to test the fallback. There is no switch to skip
the self-check.

Time (M1 Max, macOS 27.2, background load average 11 to 13; medians of 10 fresh processes each, interleaved,
against a build with the self-check switched off; 1200x800 images; measured with the five decode cases of before
2026-11-18: the two cases and two decodes added then took the decode half from 12.1 to 18.1 ms (median 16.9) to
13.1 to 23.9 ms (median 19.2) in 5 runs of `ejm selfcheck` each, on a noisy machine, so roughly 2 ms more):

| | without | with | added |
|---|---|---|---|
| first decode | 13.3 ms | 24.1 ms | about 11 ms |
| first encode | 19.5 ms | 21.6 ms | about 2 ms (the encoder's pipeline builds and first submission move into the check) |
| `warmUp()` | 2.7 ms | 31.5 ms | about 29 ms (both halves, on an idle GPU) |
| each later call | | | one flag check: 6720x4480 decodes unchanged within noise (minimum wall over 3 interleaved rounds 5.683 / 5.243 / 6.221 ms before, 5.715 / 5.226 / 6.249 ms after) |

The shader library compile when the context is created (about 30 ms from the OS cache) is not part of these
numbers. `ejm selfcheck` prints the time of each half on your machine.

### `MetalContext.selfCheck(decode:encode:)`

```swift
public func selfCheck(decode: Bool = true, encode: Bool = true) -> String?
```

Runs the decode half and / or the encode half of this device's self-check, unless that half already ran in this
process, and returns `nil` when everything run so far passed, else the failure reason. A failure in either half
is returned for both. Decoders, encoders and the C API call it for you; call it yourself to find out up front
whether the GPU path will be used (or call `warmUp()`, which also builds the pipelines). Thread-safe. Exact: the
check itself compares against libjpeg-turbo; api-check runs it normally (passes) and forced (fails).

```swift
import ExactJPEG

if let why = MetalContext.shared.selfCheck() {
    print("GPU path disabled, using the CPU codec:", why)
}
```

### `SelfCheckTesting`

```swift
@_spi(Testing) public enum SelfCheckTesting
```

Hooks for `ejm`, visible only with `@_spi(Testing) import ExactJPEG`; not a stable interface.
`SelfCheckTesting.decodeRuns` and `SelfCheckTesting.encodeRuns` count how many times each half has run in this
process (api-check checks that concurrent first calls run each once). `SelfCheckTesting.smallChunkPasses` is the
number of synchronisation passes the decode half's 64-bit-chunk decode took (0 before it has run; api-check requires 2
or more, so the work between passes is covered). `SelfCheckTesting.chunkBitsUsed` lists the chunk size of each of
the decode half's decodes, in order, and `SelfCheckTesting.decodeCases` the built-in decode cases (name and JPEG);
api-check uses both to check the half's coverage (2048, 4096 and 64-bit chunks, 4:4:0, a 16-bit DQT).
`SelfCheckTesting.encodeCases` lists the built-in encode cases (name, size, layout, quality, subsampling, two-pass
flag); api-check selfcheck-cases checks that every decode case's JPEG markers and every encode case's settings
match its name.
`SelfCheckTesting.pixels(width:height:channels:rowBytes:)` returns the synthetic image of the built-in cases
(formula above; with `channels` 4 the fourth byte and any row padding are 0x5A), which `ejm selfcheck-gen` feeds to
libjpeg-turbo.

## Errors (Swift)

### `Unsupported`

```swift
public struct Unsupported: Error, CustomStringConvertible { public let description: String }
```

Thrown by `parseJPEGHeader(_:)` and `MetalContext.init(device:salt:)`. `Unsupported.description` is the reason,
the same text `Decoder.reason` shows when the header is the cause. There is no public initialiser. When: catch
it to route a file to a CPU decoder.

```swift
import ExactJPEG

let notJPEG: [UInt8] = [0, 1, 2, 3]
do { _ = try notJPEG.withUnsafeBytes { try parseJPEGHeader($0) } }
catch let e as Unsupported { print(e.description) }                  // "not a JPEG"
```

### `InvalidInput`

```swift
public struct InvalidInput: Error, CustomStringConvertible { public let description: String }
```

Thrown by the encoder for invalid arguments (the checks under `EncodeJob`, "buffer too small for the image", "input buffer must be .storageModeShared", "input buffer is from another Metal device than the encoder's") and
for GPU failures ("no Metal command buffer", "GPU error: ..."). `InvalidInput.description` is the message. No
public initialiser. When: catch it around `encode` and `encodeBatch`.

```swift
import ExactJPEG

let px = [UInt8](repeating: 0, count: 12)
do { _ = try px.withUnsafeBytes { try Encoder().encode(bytes: $0, width: 2, height: 2, quality: 0) } }
catch let e as InvalidInput { print(e.description) }                 // "quality must be 1...100"
```

### `SelfCheckFailed`

```swift
public struct SelfCheckFailed: Error, CustomStringConvertible { public let description: String }
```

Thrown by `Encoder.encode` (both forms) and `Encoder.encodeBatch(_:)` when the device's startup self-check failed
(see "Startup self-check"): the encoder declines all work, before validating the arguments.
`SelfCheckFailed.description` is "self-check failed on <GPU name>, <OS version>: <case>", the same text decoders
give in `Decoder.reason`. A separate type from `InvalidInput`, so a `catch let e as InvalidInput` does not catch
it. No public initialiser. When: catch it (or any error) and encode on the CPU.

```swift
import ExactJPEG

let px = [UInt8](repeating: 0, count: 8 * 8 * 3)
do { _ = try px.withUnsafeBytes { try Encoder().encode(bytes: $0, width: 8, height: 8) } }
catch let e as SelfCheckFailed { print("CPU fallback:", e.description) }
catch { print(error) }
```

## C API

`include/exact_jpeg.h`, implemented in `Sources/ExactJPEGC/CAPI.swift` with `@_cdecl` and built as
`libExactJPEGC.dylib` (`swift build -c release --product ExactJPEGC`). All functions are safe to call from C,
C++, Rust or Python (ctypes). Thread safety: one decoder and one encoder per thread. Strings returned by the
library are owned by it.

### `EXACT_JPEG_H`

The include guard of `exact_jpeg.h`. The header also wraps its declarations in `extern "C"` for C++.

### Types: `ejm_decoder`, `ejm_encoder`

```c
typedef struct ejm_decoder ejm_decoder;
typedef struct ejm_encoder ejm_encoder;
```

Opaque handles to a Swift `Decoder` and `Encoder` (on `MetalContext.shared`). Create with `ejm_decoder_create` /
`ejm_encoder_create`, free with `ejm_decoder_destroy` / `ejm_encoder_destroy`.

### Result codes: `EJM_OK`, `EJM_DECLINED`, `EJM_ERROR`

```c
enum { EJM_OK = 0, EJM_DECLINED = 1, EJM_ERROR = -1 };
```

`EJM_OK` (0) success; `EJM_DECLINED` (1) the decoder declined the file, see `ejm_decoder_reason`, decode it on the
CPU instead; `EJM_ERROR` (-1) bad arguments, buffer too small, or an encoder failure.

### Output formats: `EJM_RGB`, `EJM_BGR`, `EJM_GRAY`, `EJM_RGBA`, `EJM_BGRA`

```c
enum { EJM_RGB = 0, EJM_BGR = 1, EJM_GRAY = 2, EJM_RGBA = 4, EJM_BGRA = 5 };
```

The `format` argument of `ejm_decode` and `ejm_decode_view`: the same values and layouts as `PixelFormat`
(`EJM_RGB` = `.rgb` and so on). All five verified through the C entry points by api-check (`ejm_decode` on the
zero-copy and copy paths and `ejm_decode_view`, 30 files each), `EJM_RGB` also by c-example. A grayscale JPEG
gives Y replicated in every colour format, with alpha 255 in `EJM_RGBA` / `EJM_BGRA`. Any other value returns
`EJM_ERROR`.

### Encoder subsampling: `EJM_444`, `EJM_422`, `EJM_420`

```c
enum { EJM_444 = 0, EJM_422 = 1, EJM_420 = 2 };
```

The `subsampling` argument of `ejm_encode`: `Subsampling.s444`, `.s422`, `.s420`. Any other value returns
`EJM_ERROR` with the error "subsampling must be 0, 1 or 2". All three verified by encode-corpus through the
Swift API; `EJM_420` also by c-example.

### `ejm_version`

```c
const char *ejm_version(void);
```

Returns the static string "exact-jpeg-metal 0.1.0". Never `NULL`; do not free it.

```c
#include <stdio.h>
#include "exact_jpeg.h"
int main(void) { puts(ejm_version()); return 0; }
```

### `ejm_inspect`

```c
int ejm_inspect(const uint8_t *jpeg, size_t len, int *width, int *height, int *components);
```

Runs the strict header check (`parseJPEGHeader`) without decoding. Returns 0 and fills `width`, `height` and
`components` (1 or 3; each pointer may be `NULL`) when the GPU path would try the file, 1 otherwise (also for a
`NULL` pointer or `len` 0). A 0 does not guarantee the decode succeeds: the entropy-coded data, `maxPixels`, the
memory budget, the trailer after the scan and the startup self-check are checked only by the decoder (`ejm_inspect`
does no GPU work, so it does not run the self-check). When: size the output buffer before
`ejm_decode`, or route files before creating a decoder.

```c
#include <stdio.h>
#include "exact_jpeg.h"
int check(const uint8_t *jpeg, size_t n) {
    int w, h, c;
    if (ejm_inspect(jpeg, n, &w, &h, &c) != 0) return -1;            /* CPU path */
    printf("%dx%d, %d components\n", w, h, c);
    return 0;
}
```

### `ejm_decoder_create`, `ejm_decoder_destroy`

```c
ejm_decoder *ejm_decoder_create(void);
void ejm_decoder_destroy(ejm_decoder *d);
```

`ejm_decoder_create` returns a new decoder, or `NULL` if there is no Metal device or the kernels do not compile
(`MetalContext.sharedSetupError`; before 2026-11-19 a compile failure stopped the process). The first decoder or
encoder of the process compiles the kernels. A kernel whose pipeline state does not build makes the calls that
need it decline (the startup self-check then fails, naming it). Default settings
as in the Swift `Decoder`; the C API cannot change them (only the environment variables apply).
`ejm_decoder_destroy` frees it; `NULL` is ignored.

```c
#include "exact_jpeg.h"
int main(void) {
    ejm_decoder *d = ejm_decoder_create();
    if (!d) return 1;
    ejm_decoder_destroy(d);
    return 0;
}
```

### `ejm_decode`

```c
int ejm_decode(ejm_decoder *d, const uint8_t *jpeg, size_t len, int format, uint8_t *out, size_t capacity,
               int *width, int *height);
```

Decodes into `out` (rows of `width * channels` bytes, no padding). Returns:

- `EJM_OK`, with `*width` and `*height` set (each pointer may be `NULL`);
- `EJM_DECLINED` when the device failed its startup self-check (checked first, before the header; see "Startup
  self-check"), or the header check or the decoder declines; `ejm_decoder_reason` says why. When `capacity` is
  too small, the checks that need no GPU memory (`Decoder.declineReason(bytes:format:)`) run first, so a file
  that would be declined anyway gets `EJM_DECLINED` with its reason (since 2026-11-19; before, `EJM_ERROR`
  "output buffer too small");
- `EJM_ERROR` when `d`, `jpeg` or `out` is `NULL`, `format` is not a valid value, or `len` or `capacity` is above
  `SIZE_MAX / 2` (the reason is left as it was; before 2026-11-19 such a `len` was passed on as a negative count,
  which a debug build traps on), or when `capacity` is smaller than `width * height * channels` for a file
  those checks accept (reason "output buffer too small (N bytes needed)").

If `out` is page-aligned and `capacity` a multiple of the page size (16 KB on Apple silicon; use
`getpagesize()`), the GPU writes straight into `out`; otherwise it decodes into the decoder's buffer and copies.
`out` is untouched on `EJM_DECLINED`, on both paths. On the zero-copy path the GPU would write `out` in the same
command buffer that finds corrupt data, so the error checks (including the trailer check and the convergence of
the synchronisation passes) set a flag on the GPU before the colour kernel, and the colour kernel writes nothing
when it is set (fixed 2026-11-16; before, a decline found during the GPU run could leave partial output). The
exception is a Metal command-buffer failure ("GPU error: ..."), after which the contents of `out` are unspecified.
api-check fills `out` with a sentinel and decodes 9 declined files (trailer markers, corrupt entropy-coded data, a
renumbered restart marker) in three formats on both paths. Exact: verified on both paths in all five formats
(api-check, 30 files), and `EJM_RGB` on the copy path by c-example. When: you
own the output memory.

```c
#include <stdlib.h>
#include <unistd.h>
#include "exact_jpeg.h"
/* zero-copy: page-aligned memory, capacity rounded up to whole pages */
uint8_t *decode_rgb(ejm_decoder *d, const uint8_t *jpeg, size_t n, int *w, int *h) {
    int c;
    if (ejm_inspect(jpeg, n, w, h, &c) != 0) return NULL;
    size_t page = (size_t)getpagesize(), need = (size_t)*w * *h * 3, cap = (need + page - 1) / page * page;
    void *out = NULL;
    if (posix_memalign(&out, page, cap) != 0) return NULL;
    if (ejm_decode(d, jpeg, n, EJM_RGB, out, cap, w, h) != EJM_OK) { free(out); return NULL; }
    return out;
}
```

### `ejm_decode_view`

```c
int ejm_decode_view(ejm_decoder *d, const uint8_t *jpeg, size_t len, int format, const uint8_t **pixels,
                    int *width, int *height, int *channels);
```

Zero-copy variant: on `EJM_OK`, `*pixels` points into the decoder's own output buffer, valid until the next call
on this decoder or its destruction; `width`, `height` and `channels` (each may be `NULL`) describe it. Returns
`EJM_DECLINED` with a reason, or `EJM_ERROR` for a `NULL` `d`, `jpeg` or `pixels`, a bad `format` or a `len`
above `SIZE_MAX / 2`. Exact:
verified in all five formats on 30 files (api-check). When: you only read the
pixels (hash them, hand them to another library) before the next decode.

```c
#include <stdio.h>
#include "exact_jpeg.h"
int show(ejm_decoder *d, const uint8_t *jpeg, size_t n) {
    const uint8_t *px; int w, h, c;
    if (ejm_decode_view(d, jpeg, n, EJM_GRAY, &px, &w, &h, &c) != EJM_OK) { puts(ejm_decoder_reason(d)); return 1; }
    printf("%dx%d x%d, first byte %u\n", w, h, c, px[0]);
    return 0;
}
```

### `ejm_decoder_reason`

```c
const char *ejm_decoder_reason(const ejm_decoder *d);
```

Why the last decode on `d` declined or failed, or `NULL` after a success (and for a `NULL` `d`). The string is
owned by the decoder: the pointer is valid until the next `ejm_decode` or `ejm_decode_view` on this decoder (from
any thread) or `ejm_decoder_destroy` (copy the string to keep it; a call from another thread that finds the handle
busy does not change it). On a thread whose last call on `d` returned `EJM_DECLINED` at once because another
thread's call was running, it returns the static string "decoder used from two threads at once", valid for the
life of the process, until that thread's next call on `d`. Safe to call from any thread at any time: the string is
replaced under a lock (api-check c-reason-race; before 2026-11-19 the busy thread read the other call's string,
which that call could free while it was read, or `NULL`). See
[decline reasons](#decline-reasons). Example: see `ejm_decode_view`.

### `ejm_encoder_create`, `ejm_encoder_destroy`

```c
ejm_encoder *ejm_encoder_create(void);
void ejm_encoder_destroy(ejm_encoder *e);
```

`ejm_encoder_create` returns a new encoder, or `NULL` if there is no Metal device or the kernels do not compile;
a kernel whose pipeline state does not build makes `ejm_encode` return `EJM_ERROR` with the reason; `ejm_encoder_destroy` frees it
(`NULL` is ignored). Default settings as in the Swift `Encoder`.

```c
#include "exact_jpeg.h"
int main(void) { ejm_encoder *e = ejm_encoder_create(); if (!e) return 1; ejm_encoder_destroy(e); return 0; }
```

### `ejm_encode`

```c
int ejm_encode(ejm_encoder *e, const uint8_t *pixels, int width, int height, int channels, size_t row_bytes,
               int quality, int subsampling, uint8_t **jpeg, size_t *jpeg_len);
```

Encodes RGB (`channels` 3) or RGBA/RGBX (`channels` 4, the 4th byte ignored) pixels, rows `row_bytes` apart,
with `quality` 1...100 and `subsampling` `EJM_444` / `EJM_422` / `EJM_420`. On `EJM_OK`, `*jpeg` is a `malloc`ed
complete JPEG file of `*jpeg_len` bytes; free it with `ejm_free`. Returns `EJM_ERROR` for `NULL` arguments (no
message), a bad `subsampling` or a non-positive size or row pitch, `channels` other than 3 or 4, a
`row_bytes * (height - 1) + width * channels` that overflows (checked before the pixel pointer is used; before
2026-11-18 these trapped), for every `InvalidInput` of the Swift encoder (message in `ejm_encoder_error`), and when the device failed its startup self-check (checked first;
`ejm_encoder_error` gives "self-check failed on ...", see "Startup self-check"). No ICC or EXIF parameters: use the Swift API for those. Exact: verified
(c-example for q90 4:2:0; the other settings through the Swift encode-corpus, which runs the same encoder). When:
encoding from C.

```c
#include <stdio.h>
#include <stdlib.h>
#include "exact_jpeg.h"
int main(void) {
    int w = 64, h = 64;
    uint8_t *rgb = calloc((size_t)w * h, 3);
    ejm_encoder *e = ejm_encoder_create();
    uint8_t *jpg; size_t n;
    if (!e || ejm_encode(e, rgb, w, h, 3, (size_t)w * 3, 85, EJM_444, &jpg, &n) != EJM_OK) return 1;
    printf("%zu bytes\n", n);
    ejm_free(jpg); free(rgb); ejm_encoder_destroy(e);
    return 0;
}
```

### `ejm_encoder_error`

```c
const char *ejm_encoder_error(const ejm_encoder *e);
```

The message for the last failed `ejm_encode`, or `NULL` after a success (and for a `NULL` `e`). Owned by the
encoder: the pointer is valid until the next `ejm_encode` on this encoder (from any thread) or `ejm_encoder_destroy`
(copy the string to keep it; a call from another thread that finds the handle busy does not change it). On a
thread whose last `ejm_encode` on `e` returned `EJM_ERROR` at once because another thread's call was running, it
returns the static "encoder used from two threads at once" (valid for the life of the process) until that
thread's next call on `e`. Safe to call from any thread at any time (api-check c-reason-race). A failure caused by `NULL` arguments does not set it. Example:
see `ejm_encode`.

### `ejm_free`

```c
void ejm_free(void *p);
```

Frees memory the library allocated (the `*jpeg` of `ejm_encode`); it calls `free`. Example: see `ejm_encode`.

## Environment variables

Read with `ProcessInfo.processInfo.environment`, each once per process (none is read per call: that rebuilds the
whole environment dictionary, about 22 µs with 48 variables and 88 µs with 248), so set them before the process
starts. They are for testing and tuning; production code should not need them.

### `EJM_CHUNK_BITS`

Decoder: bits per Huffman chunk when `Decoder.chunkBits` is `nil`. Read once per process, the first time any
decoder needs it (`Decoder.swift:372`); a value that is not an integer is ignored. Default: unset (2048 bits below
256 KB of entropy-coded data, else 4096; see `Decoder.chunkBits`); minimum 64.
Exact: `scripts/test.sh` runs the whole decoder corpus at 2048 (with `EJM_NCP=3`) and 8192 (with `EJM_NCP=15`),
582 exact each with the same declined set as the default; earlier env-runs verified 1024 and 8192;
`Decoder.chunkBits` feeds the same function and is verified for 64 to 65536 (api-check). The default is a size
rule, the same on every device: below 256 KB of entropy-coded data 2048 bits were 5-17% faster on the M1 Max and the
iPhone 13 (A15); for larger files an M4 sweep of 30 MP decodes found 4096/7 within 3.3% of the best setting.
Applies to the C API too.

```sh
EJM_CHUNK_BITS=8192 EJM_NCP=1 Tools/.build/release/ejm corpus | tail -1
```

### `EJM_NCP`

Decoder: checkpoints per chunk when `Decoder.checkpoints` is `nil`. Read once per process (`Decoder.swift:373`).
Default 7; clamped to `1...(chunk bits / 8 - 1)`. Exact: verified for 3 and 15 (test.sh, with chunk bits 2048 and
8192) and 1 (env-runs); `Decoder.checkpoints`
feeds the same function and is verified for 1 to 31 (api-check). Example: see
`EJM_CHUNK_BITS`.

### `EJM_COLOR_SPEC`

Decoder: `0` selects the generic colour-conversion kernel `color`; unset or any other value selects the default,
a `color_k` pipeline specialised by function constants for each component's upsampling kind and the output
format (`Decoder.swift:540-552`). Read once per process, the first time a decode reaches the colour stage
(`Decoder.envColorSpec`; until 2026-11-17 it was read on every decode, which rebuilt the whole environment
dictionary each time: about 22 µs per decode with 48 variables, 88 µs with 248). Set it before the process starts. Exact: both verified (corpus for the default; env-runs
for `0`). When: A/B timing of the specialisation, or to rule it out while debugging.

```sh
EJM_COLOR_SPEC=0 Tools/.build/release/ejm corpus | tail -1
```

### `EJM_TEST_METAL_SETUP`

Library, testing only: simulates a Metal setup failure. `nodevice`: `MetalContext.shared` finds no device;
`compile`: every context's shader library fails to compile; `pipeline:<kernel>` (e.g. `pipeline:idct_islow`):
that kernel's pipeline state fails to build. Read once per process. api-check metal-setup runs a child process
with each (`ejm usage-child setup-failed:...`): nothing traps, every decode declines and every encode throws with
the error, the C create functions return `NULL` for the first two.

### `EJM_TEST_TURBO_RUNTIME`

The `ejm` tool, testing only: makes the tool report this libjpeg-turbo run-time version instead of the loaded
one, but only a version other than 3.2.0 (empty: unknown), so it can make a 3.2.0 machine look like another version
and never the reverse. api-check device-refs uses it to check that `ejm export-corpus` refuses to write the iOS
check's `refs.json` with another libjpeg-turbo than 3.2.0.

### `EJM_TEST_NO_SPARSE`

The `ejm` tool, testing only: `1` makes the encoder-limits case span-real fail to map its 6 GB sparse buffer, as
on a machine without the address space, so api-check can check that the case then reports SKIPPED (counted apart,
not as a pass).

### `EJM_SELFCHECK_FAIL`

Library: `1` makes the startup self-check report a failure ("self-check failed on <GPU name>, <OS version>:
forced by EJM_SELFCHECK_FAIL=1") after its cases run, so every decode declines and every encode fails; any other
value, or unset, has no effect. Read once per process, the first time a half of the self-check runs. Applies to the C API too. When: testing
an application's CPU fallback. api-check runs a child process with it (`ejm selfcheck-child forced`). There is
no variable to skip the self-check.

```sh
EJM_SELFCHECK_FAIL=1 Tools/.build/release/ejm selfcheck
```

### `EJM_FUSED_MAX_BLOCKS`

Encoder: the default of `Encoder.fusedMaxBlocks` for every encoder made afterwards (an integer; negative counts as
0; anything else is ignored). Read once per process, the first time an encoder is made (`Encoder.swift`,
`envFusedMaxBlocks`). Unset: the device profile's choice. `0` forces the two-pass path, a large value (2000000)
the single-pass path up to that many blocks. An explicit `fusedMaxBlocks` assignment still wins. Exact: test.sh
runs the encoder corpus at 0 and 2000000, 869 of 869 each. Applies to the C API too.

```sh
EJM_FUSED_MAX_BLOCKS=0 Tools/.build/release/ejm encode-corpus | tail -1
```

### `EJM_TRACE`

Library: `1` (any value but empty, `0` and `stages`) prints one line per decode and encode call to stderr (see
`MetalContext.trace` for the format); `stages` also records per-stage GPU times on every call, as
`recordStages` does, and appends them to the line. Unset or `0`: off. Read once per process, when the first
`Decoder` or `Encoder` is made. Applies to the C API and `ejm` too. Exact: same bytes (test.sh runs both corpora
with `EJM_TRACE=stages`). Cost: see "Timing and tracing".

```sh
EJM_TRACE=stages Tools/.build/release/ejm quick 5 2>&1 | grep '^ejm decode' | tail -1
```

### `EJM_PROFILE_CACHE`

Library: `0` disables reading and writing the routing cache (see "Device profile"), so every process that reads
a profile measures again; any other value, or unset, uses it. Read once per process. api-check runs a child
process with it (`ejm profile-child nocache:...`) and checks that a valid seeded file is neither read nor
rewritten.

```sh
EJM_PROFILE_CACHE=0 Tools/.build/release/ejm profile
```

### `EJM_LOAD_CORRECTION`

Read by the library once at start. `0` starts load awareness off ("Load correction"): every factor is 1, and
other processes' GPU use is not read (`Warmth.deviceGPUPercent` stays nil). `DeviceProfile.loadCorrectionEnabled`
changes it at run time. Default: on. Advice only; bytes are the same either way.

```sh
EJM_LOAD_CORRECTION=0 Tools/.build/release/ejm profile
```

### `EJM_PROFILE`

Not read by the library: only `ejm perf-small` reads it (`Tools/Sources/ejm/PerfSmall.swift:60`). `1` adds a per-stage
GPU-time profile of batch-16 encodes (using `Encoder.profileStages`) before the normal results. Default: off.

```sh
EJM_PROFILE=1 Tools/.build/release/ejm perf-small 4
```

### Apple's `MTL_*` variables

`MTL_SHADER_VALIDATION=1`, `MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1` and `MTL_DEBUG_LAYER=1` are Metal's own
switches, not this project's. `scripts/test.sh` sets them for the shader-validated fuzz run and for
`ejm oob-selfcheck`; `ejm fuzz` records `MTL_SHADER_VALIDATION` in its summary. See [CLI.md](CLI.md).

## Behaviour notes

- Declining is part of the contract: a `nil` / `EJM_DECLINED` result is never a crash and the caller is expected
  to decode the file on the CPU. Progressive, arithmetic, lossless, hierarchical, 12-bit, CMYK, YCCK, RGB-coded
  and multi-scan files are always declined, as are corrupt files libjpeg-turbo would repair with a warning.
- A device that fails the startup self-check declines every decode and fails every encode for the rest of the
  process ("self-check failed on ..."); see "Startup self-check".
- A grayscale JPEG decodes to every format: `.gray`, or Y replicated in `.rgb`, `.bgr`, `.rgba` and `.bgra`
  (alpha 255), as libjpeg-turbo does. Until 2026-11-16 `.rgba` and `.bgra` declined it.
- A declined decode never writes the caller's output (`output:`, or `out` of `ejm_decode` on either path), except
  after a Metal command-buffer failure. See [CHANGES.md](CHANGES.md) for the 2026-11-16 fixes.
- Each call waits for its command buffer; there is no asynchronous API yet (README "Limitations").
- iOS 16+ is a declared platform; the only iOS device it has run on is an iPhone 13 (A15) (README "Limitations").
- Metal resources passed in (`decode(buffer:...)`, `output:`, `EncodeJob.buffer`) must use shared storage, since
  the library reads results through `contents()`.
