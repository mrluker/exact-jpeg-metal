/*
 * exact_jpeg.h: C API of exact-jpeg-metal (libExactJPEGC.dylib).
 *
 * JPEG decoding and encoding on Apple GPUs (Metal), byte-identical to libjpeg-turbo:
 *   decode = libjpeg-turbo with JDCT_ISLOW and fancy upsampling (its defaults; Pillow's and TurboJPEG's too);
 *   encode = libjpeg-turbo baseline with standard Huffman tables, islow DCT, jpeg_set_quality (Pillow's settings).
 * A JPEG the GPU path cannot decode exactly (progressive, arithmetic, CMYK, 12-bit, corrupt, ...) is declined with
 * a reason, so the caller can fall back to a CPU decoder. Thread safety: one decoder / encoder per thread. A call
 * made while another thread's call on the same handle is running returns at once without touching the handle:
 * EJM_DECLINED from ejm_decode / ejm_decode_view, EJM_ERROR from ejm_encode. On that thread, until its next call
 * on the handle, ejm_decoder_reason / ejm_encoder_error then return the static string "decoder used from two
 * threads at once" / "encoder used from two threads at once" (never freed). ejm_decoder_reason and
 * ejm_encoder_error themselves may be called from any thread at any time.
 */
#ifndef EXACT_JPEG_H
#define EXACT_JPEG_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ejm_decoder ejm_decoder;
typedef struct ejm_encoder ejm_encoder;

enum { EJM_OK = 0, EJM_DECLINED = 1, EJM_ERROR = -1 };
enum { EJM_RGB = 0, EJM_BGR = 1, EJM_GRAY = 2, EJM_RGBA = 4, EJM_BGRA = 5 };   /* output formats */
enum { EJM_444 = 0, EJM_422 = 1, EJM_420 = 2 };                                /* encoder subsampling */

const char *ejm_version(void);

/* Strict header check without decoding: 0 if the GPU path would try this file (sizes filled in), else 1. */
int ejm_inspect(const uint8_t *jpeg, size_t len, int *width, int *height, int *components);

ejm_decoder *ejm_decoder_create(void);   /* NULL if no Metal device or the GPU kernels do not compile */
void ejm_decoder_destroy(ejm_decoder *d);
/* Decode into out (capacity bytes, rows of width * channels). Returns EJM_OK, EJM_DECLINED (see
 * ejm_decoder_reason) or EJM_ERROR (bad arguments, len or capacity above SIZE_MAX / 2, or out too small for a file
 * that would not be declined: the cheap decline checks run first). If out is
 * page-aligned and capacity a multiple of the page size, the GPU writes straight into it; otherwise the result is
 * copied. On EJM_DECLINED and EJM_ERROR out is untouched, on both paths, with one exception: after a Metal
 * command-buffer failure (reason "GPU error: ...") on the zero-copy path its contents are unspecified. A grayscale
 * JPEG gives Y replicated in the colour formats (alpha 255 in EJM_RGBA / EJM_BGRA). */
int ejm_decode(ejm_decoder *d, const uint8_t *jpeg, size_t len, int format, uint8_t *out, size_t capacity,
               int *width, int *height);
/* Zero-copy variant: *pixels points into the decoder's own buffer, valid until the next call on this decoder or
 * ejm_decoder_destroy. EJM_ERROR also for a len above SIZE_MAX / 2. */
int ejm_decode_view(ejm_decoder *d, const uint8_t *jpeg, size_t len, int format, const uint8_t **pixels,
                    int *width, int *height, int *channels);
/* Why the last decode declined or failed; NULL after a success. Owned by the decoder: valid until the next call
 * on this decoder (ejm_decode, ejm_decode_view, from any thread) or ejm_decoder_destroy; copy it to keep it. On a
 * thread whose last call on this decoder returned at once because another thread's call was running: the static
 * "decoder used from two threads at once", valid for the life of the process. */
const char *ejm_decoder_reason(const ejm_decoder *d);

ejm_encoder *ejm_encoder_create(void);   /* NULL if no Metal device or the GPU kernels do not compile */
void ejm_encoder_destroy(ejm_encoder *e);
/* Encode RGB (channels 3) or RGBA/RGBX (channels 4, alpha ignored) pixels, rows row_bytes apart. On EJM_OK,
 * *jpeg is malloc'ed (free with ejm_free) and *jpeg_len its size. */
int ejm_encode(ejm_encoder *e, const uint8_t *pixels, int width, int height, int channels, size_t row_bytes,
               int quality, int subsampling, uint8_t **jpeg, size_t *jpeg_len);
/* Why the last ejm_encode failed; NULL after a success. Owned by the encoder: valid until the next ejm_encode on
 * this encoder (from any thread) or ejm_encoder_destroy; copy it to keep it. On a thread whose last ejm_encode on
 * this encoder returned at once because another thread's call was running: the static "encoder used from two
 * threads at once", valid for the life of the process. */
const char *ejm_encoder_error(const ejm_encoder *e);
void ejm_free(void *p);

#ifdef __cplusplus
}
#endif
#endif
