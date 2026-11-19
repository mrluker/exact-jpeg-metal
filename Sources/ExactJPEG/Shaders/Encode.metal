// ExactJPEG encoder kernels (Metal port of exact-gpu-jpeg's _enc_kernels.cu).
//
// Byte-identical to libjpeg-turbo's baseline compressor as Pillow drives it (islow DCT, no smoothing, standard
// Huffman tables). Ported from libjpeg-turbo 3.1.2 (jccolor.c rgb_ycc_convert, jcsample.c fullsize/h2v1/h2v2
// downsampling and edge expansion, jcprepct.c bottom-edge padding, jfdctint.c jpeg_fdct_islow, jcdctmgr.c
// quantisation by reciprocals with 16-bit DCTELEM as in SIMD builds, jccoefct.c dummy blocks, jchuff.c
// encode_one_block); based on the Independent JPEG Group's software (IJG License). The output target is
// libjpeg-turbo 3.2.0 (whole files byte-identical, verified by ejm encode-corpus and the 3.2.0 manifest).
// (Common.metal and Decode.metal are prepended: u32, ZZ, CONST_BITS and the F_* constants come from there.)
//
// Portions are derived from libjpeg-turbo 3.1.2 (see THIRD_PARTY_NOTICES.md for the routines and changes):
//   Copyright (C) 1991-1998, Thomas G. Lane. Modifications by Guido Vollbeding.
//   libjpeg-turbo Modifications: Copyright (C) 2009-2025, D. R. Commander, and the other contributors named
//   in the original file headers.
// Re-implemented and modified by Luke Riley, 2026. Those portions remain under the IJG License
// (licenses/README.ijg); the rest is MIT (LICENSE).

// bpm, comp[10], dx[10], dy[10], hs[3], vs[3], hmax, vmax, mcux, wib[3], hib[3], W, H, firstj[3], lastj[3], tq[3],
// C (input bytes per pixel), rowBytes, nblk, nmcu
struct EL {
    int bpm; int comp[10], dx[10], dy[10]; int hs[3], vs[3]; int hmax, vmax, mcux; int wib[3], hib[3]; int W, H;
    int firstj[3], lastj[3], tq[3]; int C, rowBytes, nblk, nmcu;
};

// jccolor.c rgb_ycc_convert (fixed point, SCALEBITS 16)
inline int conv(device const uchar* rgb, constant EL& L, int x, int y, int ci) {
    x = min(x, L.W - 1); y = min(y, L.H - 1);                      // jcsample/jcprepct edge expansion
    device const uchar* p = rgb + (u32)y * (u32)L.rowBytes + (u32)x * (u32)L.C;
    int r = p[0], g = p[1], b = p[2];
    if (ci == 0) return (19595 * r + 38470 * g + 7471 * b + 32768) >> 16;
    if (ci == 1) return (-11059 * r - 21709 * g + 32768 * b + (128 << 16) + 32767) >> 16;
    return (32768 * r - 27439 * g - 5329 * b + (128 << 16) + 32767) >> 16;
}

// component ci's sample (sx, sy) after downsampling (jcsample.c, no smoothing) and edge padding
inline int comp_sample(device const uchar* rgb, constant EL& L, int ci, int sx, int sy) {
    int fh = L.hmax / L.hs[ci], fv = L.vmax / L.vs[ci];
    if (fh == 1 && fv == 1) return conv(rgb, L, sx, sy, ci);
    if (fh == 2 && fv == 1) {                                        // h2v1_downsample: bias 0, 1, 0, 1, ...
        return (conv(rgb, L, 2 * sx, sy, ci) + conv(rgb, L, 2 * sx + 1, sy, ci) + (sx & 1)) >> 1;
    }
    int cy = min(sy, (L.H + 1) / 2 - 1);                             // h2v2_downsample: bias 1, 2, 1, 2, ...
    return (conv(rgb, L, 2 * sx, 2 * cy, ci) + conv(rgb, L, 2 * sx + 1, 2 * cy, ci) +
            conv(rgb, L, 2 * sx, 2 * cy + 1, ci) + conv(rgb, L, 2 * sx + 1, 2 * cy + 1, ci) + ((sx & 1) ? 2 : 1)) >> 2;
}

#define DESCALE(x, n) (((x) + (1 << ((n) - 1))) >> (n))

// jfdctint.c jpeg_fdct_islow, one 8-point pass
inline void fdct8(thread const int* d, thread int* o, bool pass1) {
    int tmp0 = d[0] + d[7], tmp7 = d[0] - d[7], tmp1 = d[1] + d[6], tmp6 = d[1] - d[6];
    int tmp2 = d[2] + d[5], tmp5 = d[2] - d[5], tmp3 = d[3] + d[4], tmp4 = d[3] - d[4];
    int tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
    int sh = pass1 ? CONST_BITS - PASS1_BITS : CONST_BITS + PASS1_BITS;
    if (pass1) { o[0] = (tmp10 + tmp11) * (1 << PASS1_BITS); o[4] = (tmp10 - tmp11) * (1 << PASS1_BITS); }
    else { o[0] = DESCALE(tmp10 + tmp11, PASS1_BITS); o[4] = DESCALE(tmp10 - tmp11, PASS1_BITS); }
    int z1 = (tmp12 + tmp13) * F_0_541;
    o[2] = DESCALE(z1 + tmp13 * F_0_765, sh);
    o[6] = DESCALE(z1 + tmp12 * (-F_1_847), sh);
    z1 = tmp4 + tmp7; int z2 = tmp5 + tmp6, z3 = tmp4 + tmp6, z4 = tmp5 + tmp7;
    int z5 = (z3 + z4) * F_1_175;
    tmp4 *= F_0_298; tmp5 *= F_2_053; tmp6 *= F_3_072; tmp7 *= F_1_501;
    z1 *= -F_0_899; z2 *= -F_2_562; z3 *= -F_1_961; z4 *= -F_0_390;
    z3 += z5; z4 += z5;
    o[7] = DESCALE(tmp4 + z1 + z3, sh);
    o[5] = DESCALE(tmp5 + z2 + z4, sh);
    o[3] = DESCALE(tmp6 + z2 + z3, sh);
    o[1] = DESCALE(tmp7 + z1 + z4, sh);
}

// jcdctmgr.c quantize() with divisors from compute_reciprocal(q << 3) for a 16-bit DCTELEM (SIMD builds)
inline int quant(int v, constant int* dv, int i) {
    short t = (short)v;
    u32 recip = (u32)dv[i], corr = (u32)dv[64 + i];
    int shift = dv[128 + i];
    if (t < 0) {
        ushort a = (ushort)(-t);
        u32 p = (u32)(ushort)(a + corr) * recip;
        return -(int)(short)(p >> (shift + 16));
    }
    u32 p = (u32)(ushort)((ushort)t + corr) * recip;
    return (int)(short)(p >> (shift + 16));
}

// colour conversion + downsampling + forward DCT + quantisation; one threadgroup = 32 JPEG blocks x 8 threads.
// Dummy blocks (past a component's real blocks, in partial MCUs) are zero; enc_dummy_dc sets their DC.
kernel void enc_dct(device const uchar* rgb [[buffer(0)]], constant EL& L [[buffer(1)]],
                    constant int* div [[buffer(2)]], device short* coef [[buffer(3)]],
                    uint tid [[thread_index_in_threadgroup]], uint tgp [[threadgroup_position_in_grid]]) {
    threadgroup int ws[32][64];
    int t = (int)tid & 7, lb = (int)tid >> 3;
    int g = (int)tgp * 32 + lb;
    bool ok = g < L.nblk;
    int j = ok ? g % L.bpm : 0;
    int m = ok ? g / L.bpm : 0;
    int ci = L.comp[j];
    int by = (m / L.mcux) * L.vs[ci] + L.dy[j], bx = (m % L.mcux) * L.hs[ci] + L.dx[j];
    bool real = ok && bx < L.wib[ci] && by < L.hib[ci];
    if (real) {
        int d[8], o[8];
        for (int k = 0; k < 8; k++) d[k] = comp_sample(rgb, L, ci, bx * 8 + k, by * 8 + t) - 128;
        fdct8(d, o, true);
        for (int k = 0; k < 8; k++) ws[lb][t * 8 + k] = (int)(short)o[k];      // DCTELEM is 16-bit
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!ok) return;
    device short* cf = coef + (u32)g * 64;
    if (!real) {
        for (int k = 0; k < 8; k++) cf[ZZ[k * 8 + t]] = 0;
        return;
    }
    int d[8], o[8];
    for (int k = 0; k < 8; k++) d[k] = ws[lb][k * 8 + t];
    fdct8(d, o, false);
    constant int* dv = div + L.tq[ci] * 192;
    for (int k = 0; k < 8; k++) cf[ZZ[k * 8 + t]] = (short)quant(o[k], dv, k * 8 + t);
}

// jccoefct.c compress_data: a dummy block at the right edge takes the DC of the block to its left, a row of dummy
// blocks at the bottom the DC of the MCU's previous block. One thread per MCU, blocks in MCU order.
kernel void enc_dummy_dc(constant EL& L [[buffer(0)]], device short* coef [[buffer(1)]], uint m [[thread_position_in_grid]]) {
    if ((int)m >= L.nmcu) return;
    for (int j = 0; j < L.bpm; j++) {
        int ci = L.comp[j];
        int by = ((int)m / L.mcux) * L.vs[ci] + L.dy[j], bx = ((int)m % L.mcux) * L.hs[ci] + L.dx[j];
        u32 g = m * (u32)L.bpm + (u32)j;
        if (by >= L.hib[ci]) coef[g * 64] = coef[(g - (u32)L.dx[j] - 1) * 64];
        else if (bx >= L.wib[ci]) coef[g * 64] = coef[(g - 1) * 64];
    }
}

// Huffman tables: code[4][256], size[4][256]: 0 DC luminance, 1 AC luminance, 2 DC chroma, 3 AC chroma
struct HT { ushort code[4][256]; uchar size[4][256]; };
#define HT_WORDS ((u32)(sizeof(HT) / 4))

inline int nbits_of(int v) { v = v < 0 ? -v : v; return v ? 32 - (int)clz((u32)v) : 0; }

inline int prev_block(constant EL& L, int g) {          // previous block of the same component, or -1
    int j = g % L.bpm, ci = L.comp[j];
    if (j > L.firstj[ci]) return g - 1;
    int m = g / L.bpm;
    return m > 0 ? (m - 1) * L.bpm + L.lastj[ci] : -1;
}

// bit sink: counts bits, or ORs them into the output words at pos (bit 31 of word 0 is the first bit)
struct BitSink {
    bool write; device atomic_uint* buf; u32 cap; u32 pos; u32 n;
    inline void put(u32 c, int len) {
        if (len == 0) return;
        if (!write) { n += (u32)len; return; }
        u64 bits = (u64)(c & (u32)((1ull << len) - 1)) << (64 - len);
        u32 w = pos >> 5;
        int sh = (int)(pos & 31);
        u64 x = bits >> sh;
        u32 hi = (u32)(x >> 32), lo = (u32)x;
        if (hi && w < cap) atomic_fetch_or_explicit(buf + w, hi, memory_order_relaxed);
        if (lo && w + 1 < cap) atomic_fetch_or_explicit(buf + w + 1, lo, memory_order_relaxed);
        pos += (u32)len;
    }
};

// jchuff.c encode_one_block
inline void encode_block(device const short* cf, int dcdiff, threadgroup const HT& T, int tdc, int tac, thread BitSink& o) {
    int s = nbits_of(dcdiff);
    int v = dcdiff < 0 ? dcdiff - 1 : dcdiff;
    o.put(((u32)T.code[tdc][s] << s) | ((u32)v & ((1u << s) - 1)), T.size[tdc][s] + s);
    int r = 0;
    for (int k = 1; k < 64; k++) {
        int c = cf[k];
        if (c == 0) { r++; continue; }
        while (r > 15) { o.put(T.code[tac][0xF0], T.size[tac][0xF0]); r -= 16; }
        s = nbits_of(c);
        v = c < 0 ? c - 1 : c;
        int sym = (r << 4) + s;
        o.put(((u32)T.code[tac][sym] << s) | ((u32)v & ((1u << s) - 1)), T.size[tac][sym] + s);
        r = 0;
    }
    if (r > 0) o.put(T.code[tac][0], T.size[tac][0]);
}

inline void load_ht(threadgroup HT& sh, device const u32* g, u32 tid, u32 nth) {
    threadgroup u32* d = (threadgroup u32*)&sh;
    for (u32 i = tid; i < HT_WORDS; i += nth) d[i] = g[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
}

// Adds this SIMD group's block bits to the image's exact 64-bit total (tot[0] the low word, tot[1] its carries;
// unsigned atomics wrap by definition). The scans that turn nb into offsets are 32-bit signed: the host accepts
// an image only when this total is at most 2^31 - 1, so no partial sum can have overflowed. A SIMD group's sum
// is at most 32 x 1744 bits. Every thread of the dispatch calls it (bits 0 past the last block).
inline void add_total(device atomic_uint* tot, u32 bits) {
    u32 s = simd_sum(bits);
    if (simd_is_first()) {
        u32 old = atomic_fetch_add_explicit(tot, s, memory_order_relaxed);
        if (old + s < old) atomic_fetch_add_explicit(tot + 1, 1u, memory_order_relaxed);
    }
}

// nb[g + 1] = bits of block g (nb[0] = 0; an inclusive scan then gives each block's bit offset)
kernel void enc_count(device const short* coef [[buffer(0)]], constant EL& L [[buffer(1)]],
                      device const u32* ht [[buffer(2)]], device int* nb [[buffer(3)]],
                      device atomic_uint* tot [[buffer(4)]],
                      uint g [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                      uint nth [[threads_per_threadgroup]]) {
    threadgroup HT T;
    load_ht(T, ht, tid, nth);
    u32 bits = 0;
    if ((int)g < L.nblk) {
        if (g == 0) nb[0] = 0;
        int ci = L.comp[g % (u32)L.bpm];
        int p = prev_block(L, (int)g);
        int dcdiff = coef[g * 64] - (p >= 0 ? coef[(u32)p * 64] : 0);
        BitSink o; o.write = false; o.n = 0; o.pos = 0; o.cap = 0; o.buf = 0;
        encode_block(coef + g * 64, dcdiff, T, ci ? 2 : 0, ci ? 3 : 1, o);
        nb[g + 1] = (int)o.n;
        bits = o.n;
    }
    add_total(tot, bits);
}

// writes each block's bits at its offset; skipped entirely if the output would not fit (the host retries)
kernel void enc_write(device const short* coef [[buffer(0)]], constant EL& L [[buffer(1)]],
                      device const u32* ht [[buffer(2)]], device const int* off [[buffer(3)]],
                      device atomic_uint* buf [[buffer(4)]], constant u32& capWords [[buffer(5)]],
                      uint g [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                      uint nth [[threads_per_threadgroup]]) {
    threadgroup HT T;
    load_ht(T, ht, tid, nth);
    if ((int)g >= L.nblk) return;
    u32 total = (u32)off[L.nblk];
    if ((total + 31) / 32 + 2 > capWords) return;
    int ci = L.comp[g % (u32)L.bpm];
    int p = prev_block(L, (int)g);
    int dcdiff = coef[g * 64] - (p >= 0 ? coef[(u32)p * 64] : 0);
    BitSink o; o.write = true; o.buf = buf; o.cap = capWords; o.pos = (u32)off[g]; o.n = 0;
    encode_block(coef + g * 64, dcdiff, T, ci ? 2 : 0, ci ? 3 : 1, o);
    if ((int)g == L.nblk - 1) {                            // jchuff.c flush_bits: pad with ones
        int pad = (int)((8 - (total & 7)) & 7);
        if (pad) { o.pos = total; o.put((1u << pad) - 1, pad); }
    }
}

// ---- byte stuffing: a 0x00 after every 0xFF ----
inline int byte_at(device const u32* buf, u32 i) { return (int)((buf[i >> 2] >> (24 - 8 * (i & 3))) & 0xFF); }

// A thread's 16 bytes (i0 a multiple of 16: four whole words, bytes in big-endian order within each word).
inline uint4 load16w(device const u32* buf, u32 i0) { return *(device const uint4*)(buf + (i0 >> 2)); }
inline bool zbyte(u32 v) { return ((v - 0x01010101u) & ~v & 0x80808080u) != 0; }   // v has a zero byte
inline bool has_ff(uint4 v) { return zbyte(~v.x) || zbyte(~v.y) || zbyte(~v.z) || zbyte(~v.w); }
inline int byte16(uint4 v, int k) { u32 w = k < 8 ? (k < 4 ? v.x : v.y) : (k < 12 ? v.z : v.w); return (int)((w >> (24 - 8 * (k & 3))) & 0xFF); }

// tilecnt[t + 1] = output bytes of tile t (tilecnt[0] = 0). Plain 16-byte runs (no 0xFF) skip the per-byte loop.
// When the bits did not fit capWords (enc_write / enc_compact wrote nothing; the host encodes the image again),
// both stuffing kernels return at once: n would reach past the bit words.
kernel void stuff_count(device const u32* buf [[buffer(0)]], device const int* off [[buffer(1)]],
                        constant int& nblk [[buffer(2)]], device int* tilecnt [[buffer(3)]],
                        constant u32& capWords [[buffer(4)]],
                        uint tid [[thread_index_in_threadgroup]], uint tg [[threadgroup_position_in_grid]],
                        uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup int ws[9];
    if (((u32)off[nblk] + 31) / 32 + 2 > capWords) return;     // the same for every thread
    u32 n = ((u32)off[nblk] + 7) / 8;
    u32 i0 = tg * TILE + tid * 16;
    int c = 0;
    if (i0 + 16 <= n) {
        uint4 v = load16w(buf, i0);
        c = 16;
        if (has_ff(v)) for (int k = 0; k < 16; k++) c += byte16(v, k) == 0xFF;
    } else {
        for (u32 k = 0; k < 16; k++) if (i0 + k < n) c += 1 + (byte_at(buf, i0 + k) == 0xFF);
    }
    int tot;
    tg_sum_excl(c, tid, lane, sg, ws, tot);
    if (tid == 0) { tilecnt[tg + 1] = tot; if (tg == 0) tilecnt[0] = 0; }
}

// out[outOff + ...] = stuffed bytes, if they fit in outCap. The tile's bytes are stuffed into threadgroup memory,
// then written out as whole words (single bytes up to a 4-byte boundary and after the last word). phase = the
// output's byte offset in its buffer, mod 4 (word stores must be 4-byte aligned in the buffer).
kernel void stuff_scatter(device const u32* buf [[buffer(0)]], device const int* off [[buffer(1)]],
                          constant int& nblk [[buffer(2)]], device const int* toff [[buffer(3)]],
                          device uchar* out [[buffer(4)]], constant u32& outCap [[buffer(5)]],
                          constant u32& ntile [[buffer(6)]], constant u32& phase [[buffer(7)]],
                          constant u32& capWords [[buffer(8)]],
                          uint tid [[thread_index_in_threadgroup]], uint tg [[threadgroup_position_in_grid]],
                          uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup int ws[9];
    threadgroup uchar sb[2 * TILE];                // the tile's output bytes
    if (((u32)off[nblk] + 31) / 32 + 2 > capWords) return;     // the same for every thread
    u32 n = ((u32)off[nblk] + 7) / 8;
    if ((u32)toff[ntile] > outCap) return;         // the same for every thread
    if (tg * TILE >= n) return;                    // the same for every thread of the threadgroup
    u32 i0 = tg * TILE + tid * 16;
    bool whole = i0 + 16 <= n, ff = true;
    uint4 v = uint4(0);
    int c = 0;
    if (whole) {
        v = load16w(buf, i0);
        ff = has_ff(v);
        c = 16;
        if (ff) for (int k = 0; k < 16; k++) c += byte16(v, k) == 0xFF;
    } else {
        for (u32 k = 0; k < 16; k++) if (i0 + k < n) c += 1 + (byte_at(buf, i0 + k) == 0xFF);
    }
    int tot;
    int ol = tg_sum_excl(c, tid, lane, sg, ws, tot);
    for (int k = 0; k < 16; k++) {
        if (i0 + (u32)k >= n) break;
        int b = whole ? byte16(v, k) : byte_at(buf, i0 + (u32)k);
        sb[ol++] = (uchar)b;
        if (ff && b == 0xFF) sb[ol++] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const int K = tot;
    const u32 g0 = (u32)toff[tg];
    int head = min((int)((4 - ((g0 + phase) & 3)) & 3), K);
    if ((int)tid < head) out[g0 + tid] = sb[tid];
    int nw = (K - head) >> 2;
    device u32* dw = (device u32*)(out + g0 + (u32)head);
    for (int k = (int)tid; k < nw; k += 256) {
        threadgroup const uchar* sp = sb + head + 4 * k;
        dw[k] = sp[0] | (sp[1] << 8) | (sp[2] << 16) | ((u32)sp[3] << 24);
    }
    int t0 = head + 4 * nw;
    if ((int)tid < K - t0) out[g0 + (u32)t0 + tid] = sb[t0 + (int)tid];
}

// ---- single-pass entropy coding (small and medium images) ----
// enc_fused: colour + downsample + FDCT + quantise (as enc_dct), then, in the same dispatch, the Huffman coding of
// each block's AC coefficients into its own slot of SLOTW words (only the non-zero coefficients are visited, via a
// 64-bit mask). The quantised DC goes to dc[g]; the DC code, which needs the previous block's DC, is added later.
// A block whose AC bits do not fit its slot sets *overflow; the host then encodes that image with the two-pass path.
#define SLOTW 32

struct SlotWriter {
    device u32* w; u64 acc; int n; int words; bool over;
    inline void put(u32 c, int len) {
        if (len == 0) return;
        acc = (acc << len) | (u64)(c & (u32)((1ull << len) - 1));
        n += len;
        if (n >= 32) {
            if (words < SLOTW) w[words] = (u32)(acc >> (n - 32)); else over = true;
            words++; n -= 32;
        }
    }
    inline void finish() { if (n > 0) { if (words < SLOTW) w[words] = (u32)(acc << (32 - n)); else over = true; } }
};

kernel void enc_fused(device const uchar* rgb [[buffer(0)]], constant EL& L [[buffer(1)]],
                      constant int* div [[buffer(2)]], device const u32* ht [[buffer(3)]],
                      device short* dcq [[buffer(4)]], device int* aclen [[buffer(5)]], device u32* slots [[buffer(6)]],
                      device atomic_int* overflow [[buffer(7)]],
                      uint tid [[thread_index_in_threadgroup]], uint tgp [[threadgroup_position_in_grid]]) {
    threadgroup int ws[32][64];
    threadgroup short qz[32][64];                 // quantised coefficients, zig-zag order
    threadgroup HT T;
    load_ht(T, ht, tid, 256);
    int t = (int)tid & 7, lb = (int)tid >> 3;
    int g = (int)tgp * 32 + lb;
    bool ok = g < L.nblk;
    int j = ok ? g % L.bpm : 0;
    int m = ok ? g / L.bpm : 0;
    int ci = L.comp[j];
    int by = (m / L.mcux) * L.vs[ci] + L.dy[j], bx = (m % L.mcux) * L.hs[ci] + L.dx[j];
    bool real = ok && bx < L.wib[ci] && by < L.hib[ci];
    if (real) {
        int d[8], o[8];
        for (int k = 0; k < 8; k++) d[k] = comp_sample(rgb, L, ci, bx * 8 + k, by * 8 + t) - 128;
        fdct8(d, o, true);
        for (int k = 0; k < 8; k++) ws[lb][t * 8 + k] = (int)(short)o[k];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (real) {
        int d[8], o[8];
        for (int k = 0; k < 8; k++) d[k] = ws[lb][k * 8 + t];
        fdct8(d, o, false);
        constant int* dv = div + L.tq[ci] * 192;
        for (int k = 0; k < 8; k++) qz[lb][ZZ[k * 8 + t]] = (short)quant(o[k], dv, k * 8 + t);
    } else {
        for (int k = 0; k < 8; k++) qz[lb][k * 8 + t] = 0;       // dummy block: all zero (its DC is set later)
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // entropy coding: one full SIMD group, one block per lane (the other seven SIMD groups retire)
    if (tid >= 32) return;
    lb = (int)tid;
    g = (int)tgp * 32 + lb;
    if (g >= L.nblk) return;
    j = g % L.bpm;
    ci = L.comp[j];
    dcq[g] = qz[lb][0];
    u64 mask = 0;
    for (int k = 1; k < 64; k++) mask |= (u64)(qz[lb][k] != 0) << k;
    int tac = ci ? 3 : 1;
    SlotWriter sw; sw.w = slots + (u32)g * SLOTW; sw.acc = 0; sw.n = 0; sw.words = 0; sw.over = false;
    int last = 0;
    while (mask) {
        int k = (int)ctz(mask);
        mask &= mask - 1;
        int r = k - last - 1;
        while (r > 15) { sw.put(T.code[tac][0xF0], T.size[tac][0xF0]); r -= 16; }
        int c = qz[lb][k];
        int s = nbits_of(c);
        int v = c < 0 ? c - 1 : c;
        int sym = (r << 4) + s;
        sw.put(((u32)T.code[tac][sym] << s) | ((u32)v & ((1u << s) - 1)), T.size[tac][sym] + s);
        last = k;
    }
    if (last < 63) sw.put(T.code[tac][0], T.size[tac][0]);
    int bits = sw.words * 32 + sw.n;
    sw.finish();
    aclen[g] = bits;
    if (sw.over) atomic_store_explicit(overflow, 1, memory_order_relaxed);
}

// dummy blocks' DC (jccoefct.c), on the dcq array (one thread per MCU, in MCU order)
kernel void enc_dummy_dcq(constant EL& L [[buffer(0)]], device short* dcq [[buffer(1)]], uint m [[thread_position_in_grid]]) {
    if ((int)m >= L.nmcu) return;
    for (int j = 0; j < L.bpm; j++) {
        int ci = L.comp[j];
        int by = ((int)m / L.mcux) * L.vs[ci] + L.dy[j], bx = ((int)m % L.mcux) * L.hs[ci] + L.dx[j];
        u32 g = m * (u32)L.bpm + (u32)j;
        if (by >= L.hib[ci]) dcq[g] = dcq[g - (u32)L.dx[j] - 1];
        else if (bx >= L.wib[ci]) dcq[g] = dcq[g - 1];
    }
}

inline int dc_bits(constant EL& L, device const short* dcq, device const u32* htw, int g, thread int& diff) {
    int p = prev_block(L, g);
    diff = dcq[g] - (p >= 0 ? dcq[p] : 0);
    int s = nbits_of(diff);
    int ci = L.comp[g % L.bpm];
    device const uchar* size = (device const uchar*)(htw + 512);   // after code[4][256] (2048 bytes = 512 words)
    return size[(ci ? 2 : 0) * 256 + s] + s;
}

// nb[g + 1] = DC bits + AC bits of block g (nb[0] = 0); the exact total as in enc_count
kernel void enc_len(constant EL& L [[buffer(0)]], device const short* dcq [[buffer(1)]], device const int* aclen [[buffer(2)]],
                    device const u32* ht [[buffer(3)]], device int* nb [[buffer(4)]], device atomic_uint* tot [[buffer(5)]],
                    uint g [[thread_position_in_grid]]) {
    u32 bits = 0;
    if ((int)g < L.nblk) {
        if (g == 0) nb[0] = 0;
        int diff;
        int n = dc_bits(L, dcq, ht, (int)g, diff) + aclen[g];
        nb[g + 1] = n;
        bits = (u32)n;
    }
    add_total(tot, bits);
}

// One block's bits gathered in a 64-bit accumulator and written a word at a time: words wholly inside the block with
// plain stores (no other block writes them), its first and last words, which it may share with its neighbours, with
// atomic ORs (the output words are zeroed beforehand). Before: two atomic ORs per code.
struct WordSink {
    device atomic_uint* buf; u32 cap; u32 w; int fill; bool shared_first; u64 acc;
    inline void start(u32 pos) { w = pos >> 5; fill = (int)(pos & 31); shared_first = fill != 0; acc = 0; }
    inline void put(u32 c, int len) {                // len <= 32; fill < 32 on entry
        if (len == 0) return;
        acc |= ((u64)c & ((1ull << len) - 1)) << (64 - fill - len);
        fill += len;
        if (fill >= 32) {
            u32 x = (u32)(acc >> 32);
            if (w < cap) {
                if (shared_first) atomic_fetch_or_explicit(buf + w, x, memory_order_relaxed);
                else atomic_store_explicit(buf + w, x, memory_order_relaxed);
            }
            shared_first = false;
            acc <<= 32; fill -= 32; w++;
        }
    }
    inline void finish() { if (fill > 0 && w < cap) atomic_fetch_or_explicit(buf + w, (u32)(acc >> 32), memory_order_relaxed); }
};

// each block's DC code, then its AC bits copied from its slot, at its offset (output words zeroed beforehand)
kernel void enc_compact(constant EL& L [[buffer(0)]], device const short* dcq [[buffer(1)]], device const int* aclen [[buffer(2)]],
                        device const u32* slots [[buffer(3)]], device const u32* ht [[buffer(4)]], device const int* off [[buffer(5)]],
                        device atomic_uint* buf [[buffer(6)]], constant u32& capWords [[buffer(7)]],
                        uint g [[thread_position_in_grid]]) {
    if ((int)g >= L.nblk) return;
    u32 total = (u32)off[L.nblk];
    if ((total + 31) / 32 + 2 > capWords) return;
    WordSink o; o.buf = buf; o.cap = capWords; o.start((u32)off[g]);
    int diff;
    dc_bits(L, dcq, ht, (int)g, diff);
    int s = nbits_of(diff);
    int v = diff < 0 ? diff - 1 : diff;
    int ci = L.comp[g % L.bpm];
    device const ushort* code = (device const ushort*)ht;
    device const uchar* size = (device const uchar*)(ht + 512);
    int tdc = ci ? 2 : 0;
    o.put(((u32)code[tdc * 256 + s] << s) | ((u32)v & ((1u << s) - 1)), size[tdc * 256 + s] + s);
    int bits = aclen[g];
    device const u32* sl = slots + g * SLOTW;
    int k = 0;
    for (; bits >= 32; bits -= 32) o.put(sl[k++], 32);
    if (bits > 0) o.put(sl[k] >> (32 - bits), bits);
    o.finish();
    if ((int)g == L.nblk - 1) {                              // jchuff.c flush_bits: pad with ones
        int pad = (int)((8 - (total & 7)) & 7);
        BitSink p; p.write = true; p.buf = buf; p.cap = capWords; p.pos = total; p.n = 0;
        if (pad) p.put((1u << pad) - 1, pad);
    }
}
