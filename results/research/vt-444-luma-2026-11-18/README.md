# VideoToolbox decodes the same luma differently at 4:4:4 (2026-11-18, M1 Max, macOS 27.2)

Photo: `deer` from imagecompression.info rgb8bit, encoded by cjpeg 3.2.0 at quality 95 as 4:2:0 and as 4:4:4
(4043x2641, odd width; hashes in the public-bench results). Both files carry the same Y data: libjpeg-turbo 3.2.0's
grayscale decode (`djpeg -grayscale`) of the two files is byte-identical.

| Decode of the Y plane | Max difference from libjpeg-turbo's Y |
|---|---|
| VideoToolbox hardware, 4:2:0 file, `420f` output | 1 level |
| VideoToolbox hardware, 4:4:4 file, `444f` output | 92 to 133 levels; about 88% of samples differ |
| VideoToolbox 4:2:0 Y against VideoToolbox 4:4:4 Y (same Y data) | 92 levels |

Checks that rule out a reading error: plane 0 reports 4043x2641 with a 4096-byte stride (other strides, 4043 to 4064,
match far worse); shifting by 1 or 2 pixels in either direction matches worse; two decodes are byte-identical; the
difference is centred on 0 (mean +0.009) and spread over 79,561 of 166,650 8x8 blocks; downscaled renders of the two Y
planes look alike. `bridge` (2749x4049, also odd width) showed the same at 4:4:4 in two of three runs (max 75).
Whether odd width triggers it was not tested.

`vt-y-plane-dump.swift`: decodes a JPEG with the VideoToolbox hardware decoder to `420f` or `444f` and writes plane 0
as PGM (`swiftc -O vt-y-plane-dump.swift -o vty; ./vty in.jpg out.pgm 444 <width> <height>`).
