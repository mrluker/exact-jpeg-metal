# Third-party notices

**This software is based in part on the work of the Independent JPEG Group.**

exact-jpeg-metal's own code is under the MIT license (`LICENSE`). Several algorithms are ported from
libjpeg-turbo 3.1.2 (which includes the Independent JPEG Group's libjpeg) so that the output matches
libjpeg-turbo byte for byte; the output is verified against libjpeg-turbo 3.2.0. Those ported portions remain covered by the IJG License, under which
libjpeg-turbo distributes them:

- `licenses/README.ijg`: the IJG README with its copyright, no-warranty notice and license terms,
  included unaltered as IJG condition (1) requires;
- `licenses/libjpeg-turbo-LICENSE.md`: libjpeg-turbo's license summary and its Modified (3-clause) BSD
  License, included unaltered.

Neither the Independent JPEG Group nor the libjpeg-turbo Project endorses this software.

## What is ported, and what was changed

As IJG condition (1) asks, the changes to the original code are listed here. No file of libjpeg-turbo is
copied; the routines below were re-implemented from the libjpeg-turbo 3.1.2 sources, first for CUDA (in
exact-gpu-jpeg, by the same author) and then for Metal and Swift.

| Here | From libjpeg-turbo 3.1.2 | Changes |
|---|---|---|
| `Decode.metal`: `idct8`, `idct_islow` | `src/jidctint.c` `jpeg_idct_islow` (Thomas G. Lane, Guido Vollbeding; libjpeg-turbo modifications D. R. Commander) | One 8-point pass per GPU thread, columns then rows through threadgroup memory; dequantisation from zig-zag order; unsigned 32-bit intermediates; outputs clamped by saturation (as libjpeg-turbo's SIMD code does) instead of the range-limit table; added checks that flag inputs where libjpeg-turbo's SIMD and C versions could differ. |
| `Decode.metal`: `huff_slow`, `extend` | `src/jdhuff.c` `jpeg_huff_decode` (slow path for long codes), `src/jdhuff.h` `HUFF_EXTEND` | Re-implemented per GPU thread over 32-bit bit windows. |
| `Decode.metal`: `row_ctx`, `up2`, `put_px`, `color`, `color_k` | `src/jdsample.c` (`h2v1_fancy_upsample`, `h1v2_fancy_upsample`, `h2v2_fancy_upsample`, `h2v1_upsample`, `h2v2_upsample`, `int_upsample`, `jinit_upsampler`), `src/jdmainct.c` (edge context rows), `src/jdcolor.c` (`ycc_rgb_convert`, `build_ycc_rgb_table`, `grayscale_convert`, `gray_rgb_convert`) | Computed per output pixel instead of per row; the colour tables are evaluated inline from the same fixed-point constants; RGBA/BGRA outputs added. |
| `Decoder.swift`: `DecodeLayout` | `src/jdhuff.c` `jpeg_make_d_derived_tbl` | Lookup table of 10 bits instead of 8; arrays laid out for the GPU. |
| `Header.swift`: standard tables, `checkHuffman`, colour-space rules | `src/jstdhuff.c` (standard tables, from the JPEG standard Annex K), `src/jdhuff.c` and `src/jdmarker.c` (table checks; `examine_app0`, `examine_app14` for the JFIF and Adobe markers), `src/jdapimin.c` `default_decompress_parms` | Re-implemented in Swift; stricter than libjpeg-turbo (anything unusual is declined). |
| `Encode.metal`: `conv`, `comp_sample` | `src/jccolor.c` `rgb_ycc_convert`, `src/jcsample.c` (`fullsize_downsample`, `h2v1_downsample`, `h2v2_downsample`, `expand_right_edge`), `src/jcprepct.c` (bottom-edge padding) | Computed per sample instead of per row; colour tables evaluated inline. |
| `Encode.metal`: `fdct8`, `quant`, `enc_dct` | `src/jfdctint.c` `jpeg_fdct_islow`, `src/jcdctmgr.c` (`quantize`, `compute_reciprocal`), `src/jdct.h` (16-bit `DCTELEM`) | One 8-point pass per thread; 16-bit DCTELEM and reciprocal quantisation as in libjpeg-turbo's SIMD builds. |
| `Encode.metal`: `enc_dummy_dc`, `enc_dummy_dcq`, `encode_block`, `enc_write`, `enc_fused`, `enc_compact`; `Encoder.swift`: `quantTables`, `reciprocals`, `huffmanCodes`, `jpegHeader` | `src/jccoefct.c` (dummy blocks), `src/jchuff.c` (`encode_one_block`, `jpeg_make_c_derived_tbl`, `flush_bits`), `src/jcparam.c` (`jpeg_set_quality`, standard quantisation tables, from the JPEG standard Annex K.1), `src/jcmarker.c` (marker order) | Each block's bits counted, prefix-summed and written in parallel at their offsets; byte stuffing as a separate parallel pass. |
| `Encoder.swift`: `jpegHeader` (ICC APP2 chunks) | `src/jcicc.c` `jpeg_write_icc_profile` (Thomas G. Lane, Todd Newman; D. R. Commander) | Re-implemented in Swift; same 65519-byte chunks and `ICC_PROFILE` tag. |
| `NAT` in `Decoder.swift` | `src/jutils.c` `jpeg_natural_order` | Without the 16 guard entries. |
| `ZZ` in `Decode.metal` | `src/jutils.c` `jpeg_zigzag_order` (disabled there with `#if 0`; also ITU-T T.81 Figure A.6) | Unchanged values. |

libjpeg-turbo's SIMD code (`simd/arm/jidctint-neon.c`, `simd/arm/jfdctint-neon.c`, `simd/arm/jquanti-neon.c` and
`simd/x86_64/jidctint-*.asm`, under the zlib License) was read to find where it uses 16-bit arithmetic and
saturation, so that the checks above decline exactly the inputs where it and the C code differ; no code was
taken from it.

Each ported source file (`Decode.metal`, `Encode.metal`, `Decoder.swift`, `Encoder.swift`, `Header.swift`)
carries a header naming the upstream copyright holders and stating that it was re-implemented and modified.

## If you redistribute this library

The Metal shaders, which contain the ported routines, are compiled into every binary as source text
(`ShaderSource.swift`). Apps and libraries that include exact-jpeg-metal should therefore ship
`licenses/README.ijg` and this file, and state in their documentation that "this software is based in part on
the work of the Independent JPEG Group".

## Algorithms from papers

The Huffman stage implements the self-synchronising parallel decoding of André Weißenberger and Bertil
Schmidt, "Massively Parallel Huffman Decoding on GPUs", Proceedings of the 47th International Conference on
Parallel Processing (ICPP 2018), doi:10.1145/3225058.3225076. The method is theirs; the code is our own (see
`docs/huffman-sync.md` for what we added: restart intervals, checkpointed re-decoding, error detection).

## Not legal advice

This summary records what was checked (the libjpeg-turbo 3.1.2 `LICENSE.md` and `README.ijg`, the copyright
headers of the files above). Check it yourself before publishing.
