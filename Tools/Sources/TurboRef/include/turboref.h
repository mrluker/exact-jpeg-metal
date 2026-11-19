// libjpeg-turbo (Homebrew build) as the exactness reference and CPU baseline. macOS tooling only.
#pragma once
#include <stddef.h>
#include <stdint.h>

// Header only: size and component count. Returns 0 on success.
int tr_info(const uint8_t *data, size_t n, int *w, int *h, int *ncomp);

// Decode with libjpeg-turbo's defaults (JDCT_ISLOW, fancy upsampling) to RGB (out: w*h*3) or, with gray=1,
// the luminance (w*h). Returns 0 on success, 1 if libjpeg-turbo warned (corrupt data), -1 on error.
int tr_decode(const uint8_t *data, size_t n, uint8_t *out, int gray);

// Encode RGB (or 1-channel when gray) with the settings Pillow uses: baseline, standard tables unless optimize,
// islow DCT, JFIF header. samp: 0 = 4:4:4, 1 = 4:2:2, 2 = 4:2:0, 3 = 4:4:0, 4 = 4:1:1.
// *out is malloc'ed (free with tr_free). Returns 0 on success.
int tr_encode(const uint8_t *rgb, int w, int h, int gray, int quality, int samp, int restart_mcus,
              int restart_rows, int optimize, int progressive, uint8_t **out, size_t *outlen);
// tr_encode's jpeg_set_quality force_baseline (default 1). 0: quantisers above 255 are kept, and libjpeg-turbo
// writes them as a 16-bit DQT (and SOF1).
void tr_set_force_baseline(int on);
// Decode like tr_decode, to an output format given by this library's PixelFormat raw value: 0 RGB, 1 BGR, 2 gray,
// 4 RGBA, 5 BGRA (JCS_RGB, JCS_EXT_BGR, JCS_GRAYSCALE, JCS_EXT_RGBA, JCS_EXT_BGRA; the same colour spaces
// TurboJPEG's TJPF_RGB/BGR/GRAY/RGBA/BGRA select). out: w*h*channels. Returns as tr_decode.
int tr_decode_fmt(const uint8_t *data, size_t n, uint8_t *out, int format);
// tr_encode (3-channel RGB, no restarts) plus an optional APP1 block written with jpeg_write_marker and an optional
// ICC profile written with jpeg_write_icc_profile (what tj3SetICCProfile + tj3Compress8 do), both right after
// jpeg_start_compress, EXIF first.
int tr_encode_meta(const uint8_t *rgb, int w, int h, int quality, int samp, const uint8_t *exif, size_t exif_len,
                   const uint8_t *icc, size_t icc_len, uint8_t **out, size_t *outlen);
void tr_free(void *p);
// libjpeg message code of the first warning in the last call (0: none); e.g. JWRN_EXTRANEOUS_DATA
int tr_last_warning(void);
const char *tr_message(int code);
// LIBJPEG_TURBO_VERSION of the headers ejm was compiled against, e.g. "3.2.0"
const char *tr_header_version(void);
// the version of the libjpeg the process loaded at run time, from its resolved file path (Homebrew's
// Cellar/jpeg-turbo/<version>/lib/...); "" when the path does not name a version. tr_runtime_path: that path.
const char *tr_runtime_version(void);
const char *tr_runtime_path(void);

// Options of tr_encode_ex, for files libjpeg-turbo can write but this library declines (or might): CMYK, YCCK,
// RGB colour space, arithmetic coding, 12-bit, lossless, scan scripts with one component per scan.
typedef struct {
    int in_components;      // 1 gray, 3 RGB, 4 CMYK input
    int jpeg_colorspace;    // -1 libjpeg's default; 0 gray, 1 YCbCr, 2 RGB, 3 CMYK, 4 YCCK (jpeg_set_colorspace)
    int quality, force_baseline;
    int h[4], v[4];         // sampling factors per component (h[k] == 0: libjpeg's default)
    int arith, progressive;
    int precision;          // 0 or 8: 8-bit; 12: 12-bit samples (input bytes b scaled to b << 4 | b >> 4)
    int lossless_psv, lossless_pt;  // psv != 0: jpeg_enable_lossless(psv, pt)
    int scan_mode;          // 0 libjpeg's default; 1 one component per scan; 2 Y alone, then the others together
    int write_jfif, write_adobe;    // -1 libjpeg's default, else 0 / 1
    int restart_mcus;
} tr_enc_opts;
// Encode with the options above (islow DCT, standard Huffman tables). *out is malloc'ed (tr_free). 0 on success.
int tr_encode_ex(const uint8_t *px, int w, int h, const tr_enc_opts *o, uint8_t **out, size_t *outlen);
