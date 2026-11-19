// C example: decode a JPEG with the GPU (exact libjpeg-turbo output), then re-encode it.
//   ./scripts/c-example.sh            builds and runs it on a synthetic JPEG
#include <stdio.h>
#include <stdlib.h>
#include "exact_jpeg.h"

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s in.jpg out.jpg\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *jpeg = malloc((size_t)n);
    if (fread(jpeg, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 1; }
    fclose(f);

    int w, h, c;
    if (ejm_inspect(jpeg, (size_t)n, &w, &h, &c) != 0) { fprintf(stderr, "not decodable on the GPU path\n"); return 1; }
    ejm_decoder *dec = ejm_decoder_create();
    size_t cap = (size_t)w * h * 3;
    uint8_t *rgb = malloc(cap);
    if (ejm_decode(dec, jpeg, (size_t)n, EJM_RGB, rgb, cap, &w, &h) != EJM_OK) {
        fprintf(stderr, "declined: %s\n", ejm_decoder_reason(dec)); return 1;
    }
    printf("%s: decoded %dx%d (%s)\n", ejm_version(), w, h, c == 1 ? "gray" : "colour");

    ejm_encoder *enc = ejm_encoder_create();
    uint8_t *out; size_t outlen;
    if (ejm_encode(enc, rgb, w, h, 3, (size_t)w * 3, 90, EJM_420, &out, &outlen) != EJM_OK) {
        fprintf(stderr, "encode failed: %s\n", ejm_encoder_error(enc)); return 1;
    }
    f = fopen(argv[2], "wb"); fwrite(out, 1, outlen, f); fclose(f);
    printf("encoded %zu bytes to %s\n", outlen, argv[2]);
    ejm_free(out); free(rgb); free(jpeg);
    ejm_encoder_destroy(enc); ejm_decoder_destroy(dec);
    return 0;
}
