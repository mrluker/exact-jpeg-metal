#include "turboref.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include "../CJPEGTurbo/shim.h"


struct err { struct jpeg_error_mgr pub; jmp_buf jb; int warned; int code; };
static int last_warn_code = 0;
int tr_last_warning(void) { return last_warn_code; }
static void on_error(j_common_ptr c) { longjmp(((struct err *)c->err)->jb, 1); }
static void on_message(j_common_ptr c, int level) {
    if (level < 0) { struct err *e = (struct err *)c->err; if (!e->warned) last_warn_code = c->err->msg_code; e->warned = 1; }
}
static void silent(j_common_ptr c) { (void)c; }

static void setup(struct err *e) {
    jpeg_std_error(&e->pub);
    e->pub.error_exit = on_error;
    e->pub.emit_message = on_message;
    e->pub.output_message = silent;
    e->warned = 0;
    last_warn_code = 0;
}

int tr_info(const uint8_t *data, size_t n, int *w, int *h, int *ncomp) {
    struct jpeg_decompress_struct d;
    struct err e;
    setup(&e);
    d.err = &e.pub;
    if (setjmp(e.jb)) { jpeg_destroy_decompress(&d); return -1; }
    jpeg_create_decompress(&d);
    jpeg_mem_src(&d, data, (unsigned long)n);
    jpeg_read_header(&d, TRUE);
    *w = (int)d.image_width; *h = (int)d.image_height; *ncomp = d.num_components;
    jpeg_destroy_decompress(&d);
    return 0;
}

int tr_decode(const uint8_t *data, size_t n, uint8_t *out, int gray) {
    struct jpeg_decompress_struct d;
    struct err e;
    setup(&e);
    d.err = &e.pub;
    if (setjmp(e.jb)) { jpeg_destroy_decompress(&d); return -1; }
    jpeg_create_decompress(&d);
    jpeg_mem_src(&d, data, (unsigned long)n);
    jpeg_read_header(&d, TRUE);
    d.dct_method = JDCT_ISLOW;
    d.do_fancy_upsampling = TRUE;
    d.out_color_space = gray ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_start_decompress(&d);
    size_t stride = (size_t)d.output_width * d.output_components;
    while (d.output_scanline < d.output_height) {
        JSAMPROW row = out + (size_t)d.output_scanline * stride;
        jpeg_read_scanlines(&d, &row, 1);
    }
    jpeg_finish_decompress(&d);
    jpeg_destroy_decompress(&d);
    return e.warned ? 1 : 0;
}

static int force_baseline = 1;
void tr_set_force_baseline(int on) { force_baseline = on; }

int tr_encode(const uint8_t *rgb, int w, int h, int gray, int quality, int samp, int restart_mcus,
              int restart_rows, int optimize, int progressive, uint8_t **out, size_t *outlen) {
    struct jpeg_compress_struct c;
    struct err e;
    setup(&e);
    c.err = &e.pub;
    unsigned char *buf = NULL;
    unsigned long len = 0;
    if (setjmp(e.jb)) { jpeg_destroy_compress(&c); free(buf); return -1; }
    jpeg_create_compress(&c);
    jpeg_mem_dest(&c, &buf, &len);
    c.image_width = (JDIMENSION)w;
    c.image_height = (JDIMENSION)h;
    c.input_components = gray ? 1 : 3;
    c.in_color_space = gray ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_set_defaults(&c);
    jpeg_set_quality(&c, quality, force_baseline ? TRUE : FALSE);
    if (!gray) {
        static const int hv[5][2] = {{1, 1}, {2, 1}, {2, 2}, {1, 2}, {4, 1}};
        c.comp_info[0].h_samp_factor = hv[samp][0];
        c.comp_info[0].v_samp_factor = hv[samp][1];
        for (int k = 1; k < 3; k++) c.comp_info[k].h_samp_factor = c.comp_info[k].v_samp_factor = 1;
    }
    c.dct_method = JDCT_ISLOW;
    c.optimize_coding = optimize ? TRUE : FALSE;
    c.restart_interval = (unsigned int)restart_mcus;
    c.restart_in_rows = restart_rows;
    if (progressive) jpeg_simple_progression(&c);
    jpeg_start_compress(&c, TRUE);
    size_t stride = (size_t)w * (gray ? 1 : 3);
    while (c.next_scanline < c.image_height) {
        JSAMPROW row = (JSAMPROW)(rgb + (size_t)c.next_scanline * stride);
        jpeg_write_scanlines(&c, &row, 1);
    }
    jpeg_finish_compress(&c);
    jpeg_destroy_compress(&c);
    *out = buf;
    *outlen = len;
    return 0;
}

int tr_decode_fmt(const uint8_t *data, size_t n, uint8_t *out, int format) {
    J_COLOR_SPACE cs;
    switch (format) {
    case 0: cs = JCS_RGB; break;
    case 1: cs = JCS_EXT_BGR; break;
    case 2: cs = JCS_GRAYSCALE; break;
    case 4: cs = JCS_EXT_RGBA; break;
    case 5: cs = JCS_EXT_BGRA; break;
    default: return -1;
    }
    struct jpeg_decompress_struct d;
    struct err e;
    setup(&e);
    d.err = &e.pub;
    if (setjmp(e.jb)) { jpeg_destroy_decompress(&d); return -1; }
    jpeg_create_decompress(&d);
    jpeg_mem_src(&d, data, (unsigned long)n);
    jpeg_read_header(&d, TRUE);
    d.dct_method = JDCT_ISLOW;
    d.do_fancy_upsampling = TRUE;
    d.out_color_space = cs;
    jpeg_start_decompress(&d);
    size_t stride = (size_t)d.output_width * d.output_components;
    while (d.output_scanline < d.output_height) {
        JSAMPROW row = out + (size_t)d.output_scanline * stride;
        jpeg_read_scanlines(&d, &row, 1);
    }
    jpeg_finish_decompress(&d);
    jpeg_destroy_decompress(&d);
    return e.warned ? 1 : 0;
}

int tr_encode_meta(const uint8_t *rgb, int w, int h, int quality, int samp, const uint8_t *exif, size_t exif_len,
                   const uint8_t *icc, size_t icc_len, uint8_t **out, size_t *outlen) {
    struct jpeg_compress_struct c;
    struct err e;
    setup(&e);
    c.err = &e.pub;
    unsigned char *buf = NULL;
    unsigned long len = 0;
    if (setjmp(e.jb)) { jpeg_destroy_compress(&c); free(buf); return -1; }
    jpeg_create_compress(&c);
    jpeg_mem_dest(&c, &buf, &len);
    c.image_width = (JDIMENSION)w;
    c.image_height = (JDIMENSION)h;
    c.input_components = 3;
    c.in_color_space = JCS_RGB;
    jpeg_set_defaults(&c);
    jpeg_set_quality(&c, quality, TRUE);
    static const int hv[3][2] = {{1, 1}, {2, 1}, {2, 2}};
    c.comp_info[0].h_samp_factor = hv[samp][0];
    c.comp_info[0].v_samp_factor = hv[samp][1];
    for (int k = 1; k < 3; k++) c.comp_info[k].h_samp_factor = c.comp_info[k].v_samp_factor = 1;
    c.dct_method = JDCT_ISLOW;
    jpeg_start_compress(&c, TRUE);
    if (exif) jpeg_write_marker(&c, JPEG_APP0 + 1, exif, (unsigned int)exif_len);
    if (icc) jpeg_write_icc_profile(&c, icc, (unsigned int)icc_len);
    size_t stride = (size_t)w * 3;
    while (c.next_scanline < c.image_height) {
        JSAMPROW row = (JSAMPROW)(rgb + (size_t)c.next_scanline * stride);
        jpeg_write_scanlines(&c, &row, 1);
    }
    jpeg_finish_compress(&c);
    jpeg_destroy_compress(&c);
    *out = buf;
    *outlen = len;
    return 0;
}

void tr_free(void *p) { free(p); }

#define STR2(x) #x
#define STR(x) STR2(x)
const char *tr_header_version(void) { return STR(LIBJPEG_TURBO_VERSION); }

// The libjpeg API has no run-time version call (LIBJPEG_TURBO_VERSION is a header macro, fixed when ejm was
// compiled). The loaded image's path is the run-time evidence: dladdr on a libjpeg symbol gives the file the
// process actually linked, and realpath resolves Homebrew's opt/ link to Cellar/jpeg-turbo/<version>/lib/... .
static char rt_path[4096], rt_version[64];
static int rt_done = 0;
static void runtime_probe(void) {
    if (rt_done) return;
    rt_done = 1;
    Dl_info info;
    if (!dladdr((const void *)&jpeg_std_error, &info) || !info.dli_fname) return;
    if (!realpath(info.dli_fname, rt_path)) { strncpy(rt_path, info.dli_fname, sizeof rt_path - 1); }
    const char *k = strstr(rt_path, "/jpeg-turbo/");
    if (!k) k = strstr(rt_path, "/libjpeg-turbo/");
    if (!k) return;
    k = strchr(k + 1, '/') + 1;
    size_t n = 0;
    while (k[n] && k[n] != '/' && n + 1 < sizeof rt_version) { rt_version[n] = k[n]; n++; }
    rt_version[n] = 0;
    // Homebrew revisions (3.2.0_1) are the same upstream release
    char *u = strchr(rt_version, '_'); if (u) *u = 0;
}
const char *tr_runtime_version(void) { runtime_probe(); return rt_version; }
const char *tr_runtime_path(void) { runtime_probe(); return rt_path; }

const char *tr_message(int code) {
    static struct jpeg_error_mgr m;
    static int init = 0;
    if (!init) { jpeg_std_error(&m); init = 1; }
    if (code < 0 || code > m.last_jpeg_message) return "?";
    return m.jpeg_message_table[code];
}

int tr_encode_ex(const uint8_t *px, int w, int h, const tr_enc_opts *o, uint8_t **out, size_t *outlen) {
    struct jpeg_compress_struct c;
    struct err e;
    setup(&e);
    c.err = &e.pub;
    unsigned char *buf = NULL;
    unsigned long len = 0;
    J12SAMPLE *row12 = NULL;
    static jpeg_scan_info scans[4];
    if (setjmp(e.jb)) { jpeg_destroy_compress(&c); free(buf); free(row12); return -1; }
    jpeg_create_compress(&c);
    jpeg_mem_dest(&c, &buf, &len);
    c.image_width = (JDIMENSION)w;
    c.image_height = (JDIMENSION)h;
    c.input_components = o->in_components;
    c.in_color_space = o->in_components == 1 ? JCS_GRAYSCALE : o->in_components == 4 ? JCS_CMYK : JCS_RGB;
    if (o->precision) c.data_precision = o->precision;
    jpeg_set_defaults(&c);
    if (o->precision) c.data_precision = o->precision;
    static const J_COLOR_SPACE css[] = {JCS_GRAYSCALE, JCS_YCbCr, JCS_RGB, JCS_CMYK, JCS_YCCK};
    if (o->jpeg_colorspace >= 0) jpeg_set_colorspace(&c, css[o->jpeg_colorspace]);
    jpeg_set_quality(&c, o->quality, o->force_baseline ? TRUE : FALSE);
    for (int k = 0; k < c.num_components && k < 4; k++)
        if (o->h[k]) { c.comp_info[k].h_samp_factor = o->h[k]; c.comp_info[k].v_samp_factor = o->v[k]; }
    c.dct_method = JDCT_ISLOW;
    c.arith_code = o->arith ? TRUE : FALSE;
    c.optimize_coding = FALSE;
    c.restart_interval = (unsigned int)o->restart_mcus;
    if (o->write_jfif >= 0) c.write_JFIF_header = o->write_jfif ? TRUE : FALSE;
    if (o->write_adobe >= 0) c.write_Adobe_marker = o->write_adobe ? TRUE : FALSE;
    if (o->progressive) jpeg_simple_progression(&c);
    if (o->lossless_psv) jpeg_enable_lossless(&c, o->lossless_psv, o->lossless_pt);
    if (o->scan_mode == 1 || o->scan_mode == 2) {     // sequential, not fully interleaved
        int n = 0;
        if (o->scan_mode == 1) {
            for (int k = 0; k < c.num_components; k++) { scans[n].comps_in_scan = 1; scans[n].component_index[0] = k; n++; }
        } else {
            scans[n].comps_in_scan = 1; scans[n].component_index[0] = 0; n++;
            scans[n].comps_in_scan = c.num_components - 1;
            for (int k = 1; k < c.num_components; k++) scans[n].component_index[k - 1] = k;
            n++;
        }
        for (int k = 0; k < n; k++) { scans[k].Ss = 0; scans[k].Se = 63; scans[k].Ah = 0; scans[k].Al = 0; }
        c.scan_info = scans;
        c.num_scans = n;
    }
    jpeg_start_compress(&c, TRUE);
    size_t stride = (size_t)w * o->in_components;
    if (o->precision == 12) {
        row12 = malloc(stride * sizeof(J12SAMPLE));
        while (c.next_scanline < c.image_height) {
            const uint8_t *s = px + (size_t)c.next_scanline * stride;
            for (size_t i = 0; i < stride; i++) row12[i] = (J12SAMPLE)((s[i] << 4) | (s[i] >> 4));
            J12SAMPROW r = row12;
            jpeg12_write_scanlines(&c, &r, 1);
        }
    } else {
        while (c.next_scanline < c.image_height) {
            JSAMPROW row = (JSAMPROW)(px + (size_t)c.next_scanline * stride);
            jpeg_write_scanlines(&c, &row, 1);
        }
    }
    jpeg_finish_compress(&c);
    jpeg_destroy_compress(&c);
    free(row12);
    *out = buf;
    *outlen = len;
    return 0;
}
