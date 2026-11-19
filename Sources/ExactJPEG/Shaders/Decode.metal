// ExactJPEG decoder kernels (Metal port of exact-gpu-jpeg's _kernels.cu).
//
// The pixel stage ports libjpeg-turbo 3.1.2 (jidctint.c jpeg_idct_islow, jdsample.c fancy upsampling,
// jdcolor.c ycc_rgb_convert), based on the Independent JPEG Group's software (IJG License). The Huffman stage
// follows Weissenberger & Schmidt, "Massively Parallel Huffman Decoding on GPUs" (ICPP 2018).
//
// Every kernel bounds its reads and writes by sizes it is given; bad input sets bits in *err, it never makes a
// kernel read or write outside its buffers or loop without bound. (Common.metal is prepended.)
//
// Portions are derived from libjpeg-turbo 3.1.2 (see THIRD_PARTY_NOTICES.md for the routines and changes):
//   Copyright (C) 1991-1998, Thomas G. Lane. Modifications by Guido Vollbeding.
//   libjpeg-turbo Modifications: Copyright (C) 2009-2025, D. R. Commander, and the other contributors named
//   in the original file headers.
// Re-implemented and modified by Luke Riley, 2026. Those portions remain under the IJG License
// (licenses/README.ijg); the rest is MIT (LICENSE).

#define LB 10                          // Huffman lookup-table bits; longer codes take the canonical slow path
#define NT 6                           // table slots: up to 3 DC + 3 AC tables

#define ERR_HUFF 1
#define ERR_SHORT 2
#define ERR_COEF 4
#define ERR_OVERRUN 8
#define ERR_RST 16
#define ERR_RANGE 32
#define ERR_DC 64
#define ERR_TRAILER 128                // the bytes after the scan decline the file (Header.swift checkTrailer)
#define ERR_SYNC 256                   // the synchronisation passes encoded did not reach the fixed point
#define ERR_PACKED 512                 // packed_unpack: an index word failed a memory-safety check (Packed.swift)

// The tables buffer: a header (bpm, dct[10], act[10], pad[3]: the MCU's table assignment, read into registers by
// hpack) and then only the k table slots this image uses (k <= NT), as 32-bit words: lut[k][1 << LB] (16-bit
// sym_entry() of codes up to LB bits, 0 = longer than LB bits or invalid), maxc[k][18], voff[k][18], hv[k][256]
// (bytes). Every Huffman kernel copies the k slots to threadgroup memory (sized by the host): fewer slots, less
// threadgroup memory per threadgroup, more threadgroups in flight.
#define HDRW 24                                          // header words
#define TABW ((1 << LB) / 2 + 18 + 18 + 64)              // words per slot
struct Tabs { threadgroup const u32* h; int k; };

inline Tabs load_tabs(threadgroup u32* sh, device const u32* g, int k, u32 tid, u32 nth) {
    for (u32 i = tid; i < (u32)k * TABW; i += nth) sh[i] = g[HDRW + i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    Tabs T; T.h = sh; T.k = k;
    return T;
}

inline u32 bswap32(u32 x) { return (x >> 24) | ((x >> 8) & 0xFF00u) | ((x << 8) & 0xFF0000u) | (x << 24); }

// decoder state: bit position << 16 | block within the MCU << 8 | coefficient index (0 = DC next)
inline u64 pk(u32 pos, int c, int z) { return ((u64)pos << 16) | ((u64)c << 8) | (u64)z; }

// Big-endian bit reader over the unstuffed stream (nw words); reads past nw return zeros.
struct Rd {
    device const u32* W; u32 nw; u32 wi; u32 a, b;
    inline u32 word(u32 i) { return i < nw ? bswap32(W[i]) : 0u; }
    inline void seek(u32 pos) { wi = pos >> 5; a = word(wi); b = word(wi + 1); }
    inline u32 peek(u32 pos) {
        u32 w = pos >> 5;
        while (wi != w) { a = b; wi++; b = word(wi + 1); }
        u32 s = pos & 31;
        return s ? (a << s) | (b >> (32 - s)) : a;
    }
};

// A code longer than LB bits: returns the symbol (-1 if invalid) and its length.
inline int huff_slow(thread const Tabs& T, int t, u32 bits, thread int& len) {
    threadgroup const int* maxc = (threadgroup const int*)(T.h + T.k * ((1 << LB) / 2)) + t * 18;
    threadgroup const int* voff = maxc + T.k * 18;
    threadgroup const uchar* hv = (threadgroup const uchar*)(T.h + T.k * ((1 << LB) / 2 + 36)) + t * 256;
    int l = LB + 1;
    int code = (int)(bits >> (32 - l));
    while (l <= 16 && code > maxc[l]) { l++; code = (int)(bits >> (32 - l)); }
    if (l > 16) { len = 16; return -1; }
    len = l;
    return hv[code + voff[l]];
}

// A decoded symbol: (code length + value bits) | value bits s << 5 | z step << 9 (DC: 1; AC: run + 1 with a value,
// 16 for ZRL, 64 for EOB and other value-less runs), bit 16 = not a valid code (then: length 16, no value, and the
// step DC 1 / AC 64, as before). Codes up to LB bits come straight from the LUT (built the same way on the host,
// DecodeLayout); longer ones from the canonical tables.
inline int sym_entry(int sym, int l, bool dc) {
    int s = sym & 15, r = sym >> 4;
    int za = dc ? 1 : s ? r + 1 : r == 15 ? 16 : 64;
    return (l + s) | (s << 5) | (za << 9);
}
inline int hent(thread const Tabs& T, int t, u32 bits, bool dc) {
    int e = ((threadgroup const ushort*)T.h)[(t << LB) | (bits >> (32 - LB))];
    if (e) return e;
    int len;
    int sym = huff_slow(T, t, bits, len);
    return sym < 0 ? (16 | ((dc ? 1 : 64) << 9) | (1 << 16)) : sym_entry(sym, len, dc);
}

inline int extend(u32 v, int s) { return (int)v < (1 << (s - 1)) ? (int)v + (int)(0xFFFFFFFFu << s) + 1 : (int)v; }

// Writes one block's coefficients in zig-zag order: the 16 coefficients of zig-zag positions 16q..16q+15 are
// stored as one 32-byte piece when z moves past them, so the buffer needs no clearing; finish() returns how
// many pieces were written (0..4) and the IDCT reads only those.
struct Zw {
    device uint4* dst; int q; bool has; u32 w0, w1, w2, w3, w4, w5, w6, w7;
    inline void clear() { w0 = w1 = w2 = w3 = w4 = w5 = w6 = w7 = 0; }
    inline void start(device uint4* d) { dst = d; q = 0; has = false; clear(); }
    inline void store() { dst[2 * q] = uint4(w0, w1, w2, w3); dst[2 * q + 1] = uint4(w4, w5, w6, w7); }
    inline void flush_to(int qn) { while (q < qn) { store(); clear(); q++; } }
    inline void put(int zi, int v) {
        if ((zi >> 4) != q) flush_to(zi >> 4);
        has = true;
        u32 x = (u32)(ushort)(short)v << ((zi & 1) * 16);
        int k = (zi >> 1) & 7;
        w0 |= k == 0 ? x : 0u; w1 |= k == 1 ? x : 0u; w2 |= k == 2 ? x : 0u; w3 |= k == 3 ? x : 0u;
        w4 |= k == 4 ? x : 0u; w5 |= k == 5 ? x : 0u; w6 |= k == 6 ? x : 0u; w7 |= k == 7 ? x : 0u;
    }
    inline int finish() { if (!has) return 0; store(); return q + 1; }
};

// The table slot of each block of the MCU, 3 bits per block, in registers: no threadgroup load per symbol.
struct HP { int bpm; u32 dcp, acp; };
inline HP hpack(device const u32* tabs) {
    device const int* hd = (device const int*)tabs;          // bpm, dct[10], act[10]
    HP p; p.bpm = hd[0]; p.dcp = 0; p.acp = 0;
    for (int k = 0; k < p.bpm; k++) { p.dcp |= (u32)hd[1 + k] << (3 * k); p.acp |= (u32)hd[11 + k] << (3 * k); }
    return p;
}

// One symbol and its value bits at state (pos, c, z). Returns an ERR_* mask. WRITE: AC coefficients go to the
// block writer, the DC difference to dcv. The caller handles the end of a block (z >= 64).
template <bool WRITE>
inline int unit(thread const Tabs& T, thread Rd& r, thread u32& pos, int c, thread int& z, u32 dcp, u32 acp,
                thread Zw& row, thread int& dcv) {
    u32 bits = r.peek(pos);
    bool dc = z == 0;
    int h = hent(T, (int)(((dc ? dcp : acp) >> (3 * c)) & 7), bits, dc);
    int e = (h >> 16) ? ERR_HUFF : 0;
    int tot = h & 31, s = (h >> 5) & 15, za = (h >> 9) & 127;
    if (WRITE && s) {
        int v = extend((bits << (tot - s)) >> (32 - s), s);
        int zi = z + za - 1;
        if (dc) dcv = v;
        else if (zi < 64) row.put(zi, v);
        else e |= ERR_COEF;
    }
    pos += (u32)tot;
    z += za;                              // >= 64: end of block (the caller resets it)
    return e;
}

// Decode from (pos, c, z) to `end`, recording the state at the first symbol boundary past each mark (cps) and
// the blocks finished by then (cpc); n = blocks finished. With cmp, stops as soon as the state at a mark equals
// the one recorded by this chunk's previous decode: from there the two decodes are the same.
// NCP: checkpoints per chunk (chosen per image by the host, with the chunk size S).
inline bool run_cp(thread const Tabs& T, thread const HP& h, thread Rd& r, thread u32& pos, thread int& c, thread int& z, u32 base,
                   int S, u32 end, device u64* cps, device int* cpc, thread int& n, bool cmp, int NCP) {
    int done = 0;
    const int bpm = h.bpm;
    Zw dummy; int dv;
    for (int j = 0; j <= NCP; j++) {
        u32 mark = j < NCP ? min(base + (u32)((j + 1) * (S / (NCP + 1))), end) : end;
        while (pos < mark) {
            unit<false>(T, r, pos, c, z, h.dcp, h.acp, dummy, dv);
            if (z >= 64) { z = 0; c = (c + 1 == bpm) ? 0 : c + 1; done++; }
        }
        if (j == NCP) break;
        u64 st = pk(pos, c, z);
        if (cmp && st == cps[j]) {
            int shift = done - cpc[j];
            for (int k = j; k < NCP; k++) cpc[k] += shift;
            n += shift;
            return true;
        }
        cps[j] = st; cpc[j] = done;
    }
    n = done;
    return false;
}

// ---- unstuffing: drop the 0x00 after each 0xFF and (with restart intervals) the RSTn markers ----
#define TILE 4096

struct Bytes16 { uchar v[18]; };   // v[0] = b[i0 - 1] (0 if none), v[1..16] = b[i0..], v[17] = b[i0 + 16]
inline void load16(device const uchar* b, int n, int i0, thread Bytes16& x) {
    x.v[0] = i0 > 0 && i0 - 1 < n ? b[i0 - 1] : 0;
    for (int k = 0; k < 16; k++) x.v[1 + k] = i0 + k < n ? b[i0 + k] : 0;
    x.v[17] = i0 + 16 < n ? b[i0 + 16] : 0;
}
// True when the thread's 16 bytes are all inside the buffer and neither they nor the byte before is 0xFF: then all
// 16 are kept, none starts an RST or another marker (the common case, a few 0xFF per 1000 bytes).
inline bool plain16(thread const Bytes16& x, int n, int i0) {
    if (i0 + 16 > n) return false;
    bool ff = false;
    for (int k = 0; k <= 16; k++) ff |= x.v[k] == 0xFF;
    return !ff;
}
inline bool rst16(thread const Bytes16& x, int n, int i, int k, int dri) {
    return dri && i + 1 < n && x.v[k + 1] == 0xFF && (x.v[k + 2] & 0xF8) == 0xD0;
}
inline bool kept16(thread const Bytes16& x, int n, int i, int k, int dri) {
    if (i >= n) return false;
    uchar c = x.v[k + 1];
    if (i > 0 && x.v[k] == 0xFF && (c == 0 || (dri && (c & 0xF8) == 0xD0))) return false;
    return !rst16(x, n, i, k, dri);
}

// exclusive sum over a threadgroup of 256 threads; *tot = total
inline int tg_sum_excl(int v, u32 tid, u32 lane, u32 sg, threadgroup int* ws, thread int& tot) {
    int ex = simd_prefix_exclusive_sum(v);
    if (lane == 31) ws[sg] = ex + v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) { int a = 0; for (int k = 0; k < 8; k++) { int t = ws[k]; ws[k] = a; a += t; } ws[8] = a; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int r = ws[sg] + ex;
    tot = ws[8];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return r;
}

struct UnstuffArgs { int n; int dri; int nseg; };

// per tile: kept bytes (tilecnt) and RST markers (tilerst); end = offset of the first other marker's 0xFF (or n;
// a 0xFF as the last byte counts as a marker's).
// tilecnt / tilerst have a leading 0 element (index 0), tile t writes index t + 1.
kernel void unstuff_count(device const uchar* b [[buffer(0)]], constant UnstuffArgs& A [[buffer(1)]],
                          device int* tilecnt [[buffer(2)]], device int* tilerst [[buffer(3)]],
                          device atomic_int* end [[buffer(4)]], uint tid [[thread_index_in_threadgroup]],
                          uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                          uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup int ws[9];
    int n = A.n, dri = A.dri;
    int i0 = (int)tg * TILE + (int)tid * 16, c = 0, r = 0;
    Bytes16 x;
    load16(b, n, i0, x);
    int first_marker = n;
    if (plain16(x, n, i0)) c = 16;
    else for (int k = 0; k < 16; k++) {
        int i = i0 + k;
        if (i >= n) break;
        c += kept16(x, n, i, k, dri);
        bool rr = rst16(x, n, i, k, dri);
        r += rr;
        // a 0xFF followed by a nonzero byte starts a marker; so does a 0xFF that is the last byte: libjpeg-turbo's
        // memory source supplies a fake EOI after it (Header.swift checkTrailer accepts it as the end)
        if (x.v[k + 1] == 0xFF && (i + 1 >= n || x.v[k + 2] != 0) && !rr && first_marker == n) first_marker = i;
    }
    if (first_marker < n) atomic_fetch_min_explicit(end, first_marker, memory_order_relaxed);
    int tot;
    tg_sum_excl(c, tid, lane, sg, ws, tot);
    if (tid == 0) tilecnt[tg + 1] = tot;
    tg_sum_excl(r, tid, lane, sg, ws, tot);
    if (tid == 0) tilerst[tg + 1] = tot;
}

// toff / roff = exclusive scans of the tile counts. Writes the kept bytes before the end marker, nbits = 8 * their
// count, seg[r + 1] = bit offset of RST number r (r < nseg - 1), found = RSTs before the end marker.
kernel void unstuff_scatter(device const uchar* b [[buffer(0)]], constant UnstuffArgs& A [[buffer(1)]],
                            device const int* toff [[buffer(2)]], device const int* roff [[buffer(3)]],
                            device const int* endp [[buffer(4)]], device uchar* out [[buffer(5)]],
                            device u32* nbits [[buffer(6)]], device u32* seg [[buffer(7)]],
                            device atomic_int* found [[buffer(8)]], device atomic_int* err [[buffer(9)]],
                            uint tid [[thread_index_in_threadgroup]], uint tg [[threadgroup_position_in_grid]],
                            uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup int ws[9];
    threadgroup uchar sb[TILE];                    // the tile's kept bytes before the end marker, in order
    threadgroup atomic_int kw;                     // how many
    if (tid == 0) atomic_store_explicit(&kw, 0, memory_order_relaxed);
    int n = A.n, dri = A.dri, nseg = A.nseg;
    int i0 = (int)tg * TILE + (int)tid * 16;
    Bytes16 x;
    load16(b, n, i0, x);
    u32 kmask = 0, rmask = 0;
    if (plain16(x, n, i0)) kmask = 0xFFFF;
    else for (int k = 0; k < 16; k++) {
        int i = i0 + k;
        if (i >= n) break;
        if (kept16(x, n, i, k, dri)) kmask |= 1u << k;
        if (rst16(x, n, i, k, dri)) rmask |= 1u << k;
    }
    int tot;
    // (the barriers in tg_sum_excl also order kw = 0 before the atomic max below)
    int ol = tg_sum_excl(popcount(kmask), tid, lane, sg, ws, tot);   // offset within the tile
    int r = roff[tg] + tg_sum_excl(popcount(rmask), tid, lane, sg, ws, tot);
    const int g0 = toff[tg];
    int e = *endp;
    int last = 0;
    for (int k = 0; k < 16; k++) {
        int i = i0 + k;
        if (i == e) *nbits = (u32)(g0 + ol) * 8u;
        if (i >= n) break;
        if ((rmask >> k) & 1) {
            if (i < e) {
                if (r < nseg - 1) seg[r + 1] = (u32)(g0 + ol) * 8u;
                if ((x.v[k + 2] & 7) != (r & 7) || r >= nseg - 1) atomic_fetch_or_explicit(err, ERR_RST, memory_order_relaxed);
                atomic_fetch_max_explicit(found, r + 1, memory_order_relaxed);
            }
            r++;
        }
        if ((kmask >> k) & 1) { if (i < e) { sb[ol] = x.v[k + 1]; last = ol + 1; } ol++; }
    }
    if (last) atomic_fetch_max_explicit(&kw, last, memory_order_relaxed);   // the kept bytes before e: a prefix
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // write sb[0..K) to out[g0..): single bytes up to a 4-byte boundary and after the last whole word, whole words
    // between (no other tile writes those bytes)
    const int K = atomic_load_explicit(&kw, memory_order_relaxed);
    int head = min((int)((4 - (g0 & 3)) & 3), K);
    if ((int)tid < head) out[g0 + (int)tid] = sb[tid];
    int nw = (K - head) >> 2;
    device u32* dw = (device u32*)(out + g0 + head);
    for (int k = (int)tid; k < nw; k += 256) {
        threadgroup const uchar* sp = sb + head + 4 * k;
        dw[k] = sp[0] | (sp[1] << 8) | (sp[2] << 16) | ((u32)sp[3] << 24);
    }
    int t0 = head + 4 * nw;
    if ((int)tid < K - t0) out[g0 + t0 + (int)tid] = sb[t0 + (int)tid];
}

// intervals whose marker was not found get length 0 (then ERR_SHORT); seg[nseg] = nbits. Also the number of
// chunks per interval, written to cfirst[k + 1] (scanned afterwards; cfirst[0] = 0).
struct SegArgs { int nseg; int S; };
kernel void fix_segs(device u32* seg [[buffer(0)]], constant SegArgs& A [[buffer(1)]],
                     device const int* found [[buffer(2)]], device const u32* nbits [[buffer(3)]],
                     device atomic_int* err [[buffer(4)]], uint k [[thread_position_in_grid]]) {
    int nseg = A.nseg;
    if ((int)k > nseg || k == 0) return;
    if ((int)k == nseg || (int)k > *found) seg[k] = *nbits;
    if (k == 1 && *found != nseg - 1) atomic_fetch_or_explicit(err, ERR_RST, memory_order_relaxed);
}
kernel void seg_chunks(device const u32* seg [[buffer(0)]], constant SegArgs& A [[buffer(1)]],
                       device int* cfirst [[buffer(2)]], uint k [[thread_position_in_grid]]) {
    if ((int)k > A.nseg) return;
    if (k == 0) { cfirst[0] = 0; return; }
    u32 len = seg[k] >= seg[k - 1] ? seg[k] - seg[k - 1] : 0;
    cfirst[k] = max((int)((len + (u32)A.S - 1) / (u32)A.S), 1);
}

// ---- chunk table: chunks of S bits that never cross a restart interval ----
struct ChunkArgs { int nseg; int S; int nmax; };
kernel void make_chunks(device const u32* seg [[buffer(0)]], constant ChunkArgs& A [[buffer(1)]],
                        device const int* cfirst [[buffer(2)]], device u32* cstart [[buffer(3)]],
                        device u32* cend [[buffer(4)]], device int* cseg [[buffer(5)]],
                        uint i [[thread_position_in_grid]]) {
    int nseg = A.nseg;
    int nch = cfirst[nseg];
    if ((int)i >= nch || (int)i >= A.nmax) return;
    int lo = 0, hi = nseg - 1;
    while (lo < hi) { int mid = (lo + hi + 1) >> 1; if (cfirst[mid] <= (int)i) lo = mid; else hi = mid - 1; }
    u32 a = seg[lo] + (u32)((int)i - cfirst[lo]) * (u32)A.S;
    cstart[i] = a;
    cend[i] = min(a + (u32)A.S, seg[lo + 1]);
    cseg[i] = lo;
}

// One synchronisation pass over all chunks (SB threads per threadgroup, one chunk each). See exact-gpu-jpeg's
// docs/huffman-sync.md. pass 0 decodes every chunk from a guessed state; later passes exit at once when the
// previous one changed nothing, else re-decode from the predecessor's exit until no exit changes inside the
// threadgroup. changed[pass] = 1 if a threadgroup's last exit changed (or on pass 0 of a multi-group grid).
#define SB 128
struct SyncArgs { u32 nw; int S; int nmax; int pass; int ncp; };
kernel void sync_pass(device const u32* W [[buffer(0)]], constant SyncArgs& A [[buffer(1)]],
                      device const u32* tabs [[buffer(2)]], device const int* cfirst_end [[buffer(3)]],
                      device const u32* cstart [[buffer(4)]], device const u32* cend [[buffer(5)]],
                      device const int* cseg [[buffer(6)]], device const u32* seg [[buffer(7)]],
                      device u64* st_in [[buffer(8)]], device u64* st_out [[buffer(9)]],
                      device int* cnt [[buffer(10)]], device u64* cps [[buffer(11)]], device int* cpc [[buffer(12)]],
                      device int* changed [[buffer(13)]], constant int& ntab [[buffer(14)]],
                      threadgroup u32* htab [[threadgroup(0)]],
                      uint tid [[thread_index_in_threadgroup]], uint tg [[threadgroup_position_in_grid]],
                      uint ntg [[threadgroups_per_grid]], uint lane [[thread_index_in_simdgroup]],
                      uint sgi [[simdgroup_index_in_threadgroup]]) {
    bool first = A.pass == 0;
    if (!first && changed[A.pass - 1] == 0) return;
    threadgroup u64 so[SB];
    threadgroup bool anyf[2][SB / 32];
    const Tabs T = load_tabs(htab, tabs, ntab, tid, SB);
    const HP hp = hpack(tabs);
    int S = A.S, NCP = A.ncp;
    int i = (int)tg * SB + (int)tid;
    int nch = *cfirst_end;
    bool valid = i < nch && i < A.nmax;
    bool fixed = !valid || i == 0 || cstart[i] == seg[cseg[i]];
    u64 myin = 0, myout = 0, out0 = 0;
    int n = 0;
    Rd r; r.W = W; r.nw = A.nw;
    if (valid) {
        if (first) {
            u32 pos = cstart[i]; int c = 0, z = 0;
            myin = pk(pos, c, z);
            r.seek(pos);
            run_cp(T, hp, r, pos, c, z, cstart[i], S, cend[i], cps + (u32)i * NCP, cpc + (u32)i * NCP, n, false, NCP);
            myout = pk(pos, c, z);
        } else {
            myin = st_in[i];
            myout = st_out[i];
            n = cnt[i];
        }
    }
    out0 = myout;
    u64 glob_prev = (!first && valid && tid == 0 && !fixed) ? st_out[i - 1] : 0;
    so[tid] = myout;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (int it = 0; it <= SB; it++) {
        bool ch = false;
        if (valid && !fixed && (tid > 0 || !first)) {
            u64 want = tid == 0 ? glob_prev : so[tid - 1];
            if (want != myin) {
                myin = want;
                u32 pos = (u32)(want >> 16); int c = (int)((want >> 8) & 255), z = (int)(want & 255);
                r.seek(pos);
                bool same = run_cp(T, hp, r, pos, c, z, cstart[i], S, cend[i], cps + (u32)i * NCP, cpc + (u32)i * NCP, n, true, NCP);
                u64 e = same ? myout : pk(pos, c, z);
                if (e != myout) { myout = e; ch = true; }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        so[tid] = myout;
        bool sany = simd_any(ch);
        if (lane == 0) anyf[it & 1][sgi] = sany;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        bool any = false;
        for (int k = 0; k < SB / 32; k++) any = any || anyf[it & 1][k];
        if (!any) break;
    }
    if (valid) { st_in[i] = myin; st_out[i] = myout; cnt[i] = n; }
    int last = min(SB, nch - (int)tg * SB) - 1;
    if ((int)tid == last && (myout != out0 || (first && ntg > 1))) changed[A.pass] = 1;
}

// first[i] = number of the first block chunk i writes: cseg * seglen + excl[i] - excl[cfirst[cseg]]
// (excl = exclusive scan of the per-chunk block counts)
// Thread 0 also sets ERR_SYNC if the last encoded pass still changed a state, and ERR_TRAILER if the bytes after the
// scan would make the host decline (the rules of Header.swift checkTrailer: 0xFF fill, APPn and COM segments, then
// EOI, the end of the data, or a lone 0xFF as the last byte). With either bit or any other error set, the colour kernel writes nothing, so a
// declined decode leaves the output buffer untouched. The host still runs checkTrailer for the reason text.
struct FirstArgs { int nmax; int seglen; };
struct TrailerArgs { int n; int lastPass; };
kernel void first_blocks(device const int* excl [[buffer(0)]], constant FirstArgs& A [[buffer(1)]],
                         device const int* cseg [[buffer(2)]], device const int* cfirst [[buffer(3)]],
                         device int* first [[buffer(4)]], constant int& nseg [[buffer(5)]],
                         device const uchar* b [[buffer(6)]], constant TrailerArgs& T [[buffer(7)]],
                         device const int* endp [[buffer(8)]], device const int* changed [[buffer(9)]],
                         device atomic_int* err [[buffer(10)]], uint i [[thread_position_in_grid]]) {
    if (i == 0) {
        int n = T.n, e = 0;
        if (changed[T.lastPass] != 0) e |= ERR_SYNC;
        for (int p = min(max(*endp, 0), n); p < n;) {
            if (b[p] != 0xFF) { e |= ERR_TRAILER; break; }
            if (p + 1 >= n) break;                                 // a lone 0xFF at the end: libjpeg-turbo's fake EOI
            int m = b[p + 1];
            if (m == 0xFF) { p += 1; continue; }
            if (m == 0xD9) break;
            if ((m >= 0xE0 && m <= 0xEF) || m == 0xFE) {
                if (p + 4 > n) { e |= ERR_TRAILER; break; }
                int L = ((int)b[p + 2] << 8) | (int)b[p + 3];
                if (L < 2 || p + 2 + L > n) { e |= ERR_TRAILER; break; }
                p += 2 + L;
                continue;
            }
            e |= ERR_TRAILER;
            break;
        }
        if (e) atomic_fetch_or_explicit(err, e, memory_order_relaxed);
    }
    if ((int)i >= A.nmax || (int)i >= cfirst[nseg]) return;     // cseg is only written for real chunks
    int k = cseg[i];
    first[i] = k * A.seglen + excl[i] - excl[cfirst[k]];
}

// Write pass from the true states, (NCP + 1) threads per chunk (one per piece between checkpoints).
struct WriteArgs { u32 nw; int S; int nmax; int seglen; int nblk; int ncp; };
kernel void decode_write(device const u32* W [[buffer(0)]], constant WriteArgs& A [[buffer(1)]],
                         device const u32* tabs [[buffer(2)]], device const int* cfirst [[buffer(3)]],
                         device const u32* cstart [[buffer(4)]], device const u32* cend [[buffer(5)]],
                         device const int* cseg [[buffer(6)]], device const u32* seg [[buffer(7)]],
                         device const u64* st_in [[buffer(8)]], device const u64* cps [[buffer(9)]],
                         device const int* cpc [[buffer(10)]], device const int* first [[buffer(11)]],
                         device short* coef [[buffer(12)]], device int* dcd [[buffer(13)]],
                         device uchar* nq [[buffer(14)]], device atomic_int* err [[buffer(15)]],
                         constant int& nseg [[buffer(16)]], constant int& ntab [[buffer(17)]],
                         threadgroup u32* htab [[threadgroup(0)]],
                         uint tid [[thread_index_in_threadgroup]], uint gi [[thread_position_in_grid]],
                         uint nth [[threads_per_threadgroup]]) {
    const Tabs T = load_tabs(htab, tabs, ntab, tid, nth);
    const int NCP = A.ncp;
    int i = (int)gi / (NCP + 1), piece = (int)gi % (NCP + 1);
    if (i >= cfirst[nseg] || i >= A.nmax) return;
    int S = A.S;
    int k = cseg[i];
    int lim = min((k + 1) * A.seglen, A.nblk);
    u32 send = seg[k + 1];
    u64 s = piece == 0 ? st_in[i] : cps[(u32)i * NCP + piece - 1];
    u32 pos = (u32)(s >> 16); int c = (int)((s >> 8) & 255), z = (int)(s & 255);
    int B = first[i] + (piece == 0 ? 0 : cpc[(u32)i * NCP + piece - 1]);
    u32 base = cstart[i];
    u32 end = piece < NCP ? min(base + (u32)((piece + 1) * (S / (NCP + 1))), cend[i]) : cend[i];
    Rd r; r.W = W; r.nw = A.nw; r.seek(pos);
    const HP hp = hpack(tabs);
    const int bpm = hp.bpm;
    int e = 0;
    Zw row; int dcv = 0;
    if (z != 0) {                                          // tail of the previous piece's block
        while (z < 64) unit<false>(T, r, pos, c, z, hp.dcp, hp.acp, row, dcv);
        z = 0; c = (c + 1 == bpm) ? 0 : c + 1; B++;
    }
    while (pos < end && B < lim) {
        if (B < 0) { e |= ERR_SHORT; break; }
        row.start((device uint4*)(coef + (u32)B * 64));
        dcv = 0;
        do { e |= unit<true>(T, r, pos, c, z, hp.dcp, hp.acp, row, dcv); } while (z < 64);
        nq[B] = (uchar)row.finish();
        z = 0; c = (c + 1 == bpm) ? 0 : c + 1;
        dcd[B] = dcv;
        if (pos > send) e |= ERR_OVERRUN;
        B++;
    }
    if (piece == NCP && i == cfirst[k + 1] - 1 && B < lim) e |= ERR_SHORT;
    if (e) atomic_fetch_or_explicit(err, e, memory_order_relaxed);
}

// ---- pixels ----
#define CONST_BITS 13
#define PASS1_BITS 2
#define F_0_298 2446
#define F_0_390 3196
#define F_0_541 4433
#define F_0_765 6270
#define F_0_899 7373
#define F_1_175 9633
#define F_1_501 12299
#define F_1_847 15137
#define F_1_961 16069
#define F_2_053 16819
#define F_2_562 20995
#define F_3_072 25172
#define NOT16(v) ((u32)((v) + 32768) > 65535u)

// jidctint.c jpeg_idct_islow, one 8-point pass. Also flags the 16-bit sums libjpeg-turbo's SIMD IDCTs form; when
// one of them, an input or an output leaves int16 the SIMD and C versions can differ, and we decline.
inline bool idct8(int i0, int i1, int i2, int i3, int i4, int i5, int i6, int i7, thread int* o, int shift) {
    bool bad = NOT16(i0 + i4) | NOT16(i0 - i4) | NOT16(i1 + i5) | NOT16(i3 + i7);
    u32 z2 = i2, z3 = i6;
    u32 z1 = (z2 + z3) * F_0_541;
    u32 tmp2 = z1 + z3 * (u32)(-F_1_847);
    u32 tmp3 = z1 + z2 * F_0_765;
    z2 = i0; z3 = i4;
    u32 tmp0 = (z2 + z3) << CONST_BITS;
    u32 tmp1 = (z2 - z3) << CONST_BITS;
    u32 tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
    tmp0 = i7; tmp1 = i5; tmp2 = i3; tmp3 = i1;
    z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2; u32 z4 = tmp1 + tmp3;
    u32 z5 = (z3 + z4) * F_1_175;
    tmp0 = tmp0 * F_0_298; tmp1 = tmp1 * F_2_053; tmp2 = tmp2 * F_3_072; tmp3 = tmp3 * F_1_501;
    z1 = z1 * (u32)(-F_0_899); z2 = z2 * (u32)(-F_2_562); z3 = z3 * (u32)(-F_1_961); z4 = z4 * (u32)(-F_0_390);
    z3 += z5; z4 += z5;
    tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4;
    u32 rnd = 1u << (shift - 1);
    o[0] = (int)(tmp10 + tmp3 + rnd) >> shift; o[7] = (int)(tmp10 - tmp3 + rnd) >> shift;
    o[1] = (int)(tmp11 + tmp2 + rnd) >> shift; o[6] = (int)(tmp11 - tmp2 + rnd) >> shift;
    o[2] = (int)(tmp12 + tmp1 + rnd) >> shift; o[5] = (int)(tmp12 - tmp1 + rnd) >> shift;
    o[3] = (int)(tmp13 + tmp0 + rnd) >> shift; o[4] = (int)(tmp13 - tmp0 + rnd) >> shift;
    return bad;
}

constant uchar ZZ[64] = {0,1,5,6,14,15,27,28,2,4,7,13,16,26,29,42,3,8,12,17,25,30,41,43,9,11,18,24,31,40,44,53,
    10,19,23,32,39,45,52,54,20,22,33,38,46,51,55,60,21,34,37,47,50,56,59,61,35,36,48,49,57,58,62,63};

// blk: per block-in-MCU (component, dx, dy); hs/vs per component; planes: per component offset and pitch
struct Pix { int bpm; int comp[10], dx[10], dy[10]; int hs[3], vs[3]; u32 off[3]; int pitch[3]; int mcux; int nblk; };

// one threadgroup = 32 JPEG blocks x 8 threads
kernel void idct_islow(device const short* coef [[buffer(0)]], device const uchar* nq [[buffer(1)]],
                       device const int* dc [[buffer(2)]], constant int* q [[buffer(3)]],
                       constant Pix& P [[buffer(4)]], device uchar* planes [[buffer(5)]],
                       device atomic_int* err [[buffer(6)]], uint tid [[thread_index_in_threadgroup]],
                       uint tg [[threadgroup_position_in_grid]]) {
    threadgroup int ws[32][64];
    int t = (int)tid & 7, lb = (int)tid >> 3;
    int g = (int)tg * 32 + lb;
    bool ok = g < P.nblk;
    int j = ok ? g % P.bpm : 0;
    int m = ok ? g / P.bpm : 0;
    int comp = P.comp[j];
    constant int* qq = q + comp * 64;
    bool bad = false, dcbad = false;
    if (ok) {
        device const short* cf = coef + (u32)g * 64;
        int in[8];
        int np = min((int)nq[g], 4);
        for (int k = 0; k < 8; k++) { int zi = ZZ[k * 8 + t]; in[k] = (zi >> 4) < np ? (int)cf[zi] * qq[k * 8 + t] : 0; }
        if (t == 0) { int d = dc[g]; dcbad = NOT16(d); bad |= dcbad; in[0] = d * qq[0]; }
        for (int k = 0; k < 8; k++) bad |= NOT16(in[k]);
        int o[8];
        if (in[1] == 0 && in[2] == 0 && in[3] == 0 && in[4] == 0 && in[5] == 0 && in[6] == 0 && in[7] == 0) {
            for (int k = 0; k < 8; k++) o[k] = in[0] * (1 << PASS1_BITS);
        } else if (!bad) {
            bad |= idct8(in[0], in[1], in[2], in[3], in[4], in[5], in[6], in[7], o, CONST_BITS - PASS1_BITS);
        } else {
            for (int k = 0; k < 8; k++) o[k] = 0;
        }
        for (int k = 0; k < 8; k++) { bad |= NOT16(o[k]); ws[lb][k * 8 + t] = o[k]; }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    bool warp_bad = simd_any(bad);
    if (!ok) return;
    threadgroup const int* w = &ws[lb][t * 8];
    int o[8];
    if (!warp_bad) bad |= idct8(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], o, CONST_BITS + PASS1_BITS + 3);
    else for (int k = 0; k < 8; k++) o[k] = 0;
    uchar px[8];
    for (int k = 0; k < 8; k++) {
        bad |= o[k] < -512 || o[k] > 511;
        px[k] = (uchar)(min(max(o[k], -128), 127) + 128);
    }
    // a DC outside int16 is reported as such (it also puts the column outside the range; one reason is enough)
    if (bad) atomic_fetch_or_explicit(err, dcbad ? ERR_DC : ERR_RANGE, memory_order_relaxed);
    int by = (m / P.mcux) * P.vs[comp] + P.dy[j], bx = (m % P.mcux) * P.hs[comp] + P.dx[j];
    device uchar* dst = planes + P.off[comp] + (u32)(by * 8 + t) * (u32)P.pitch[comp] + (u32)bx * 8;
    uint2 v;
    v.x = px[0] | (px[1] << 8) | (px[2] << 16) | ((u32)px[3] << 24);
    v.y = px[4] | (px[5] << 8) | (px[6] << 16) | ((u32)px[7] << 24);
    *(device uint2*)dst = v;
}

// ---- packed coefficients (Packed.swift: Decoder.decodeAndPack, Decoder.decode(packed:)) ----
// A repeat decode reads the coefficients the Huffman stage produced from a packed copy instead of the JPEG. The
// payload is an index word per block (offset bits 0..27, quad count n bits 28..30, wide bit 31) and the data; per
// block at its offset: int16 DC, n uint16 masks (bit i of mask q: zig-zag position 16q + i is nonzero), the
// nonzero values in position order as int8 (int16 when wide), a pad byte to even length. At least PACK_TAIL zero
// bytes follow the data (dlen bytes), so that any block whose offset is at most dlen stays inside the buffer: a
// block reads at most 2 + 8 + 128 = 138 bytes from its offset.
#define PACK_TAIL 160
struct PackArgs { u32 nblk; u32 dlen; };

// One thread per (block, quad): b = t >> 2, q = t & 3. Writes the arrays idct_islow reads: dc[b] (absolute DC),
// nq[b] = n, and the 16 coefficients of quad q < n (quads >= n are not written; the IDCT does not read them).
// nblk comes from the image's frame (DecodeLayout), never from the payload.
kernel void packed_unpack(device const u32* idx [[buffer(0)]], device const uchar* data [[buffer(1)]],
                          device short* coef [[buffer(2)]], device int* dc [[buffer(3)]], device uchar* nq [[buffer(4)]],
                          constant PackArgs& A [[buffer(5)]], device atomic_int* err [[buffer(6)]],
                          uint t [[thread_position_in_grid]]) {
    u32 b = t >> 2, q = t & 3;
    if (b >= A.nblk) return;
    u32 h = idx[b];
    u32 o = h & 0x0fffffffu;
    int n = (int)((h >> 28) & 7u);
    bool wide = (h >> 31) != 0;
    // Memory-safety checks, always on, before any load through the index word:
    //   (a) o <= dlen: every load below stays inside the data and its zero tail (at most 138 bytes from o);
    //   (b) o is even: the DC, the masks and wide values are 16-bit loads. In MSL a device pointer must be aligned
    //       to its type; a misaligned load, like a load outside the buffer, is undefined behaviour (what a given
    //       Apple GPU returns, or whether the command buffer faults, is not something to rely on; on CUDA a
    //       misaligned 16-bit load ended the context);
    //   (c) n <= 4: the mask loop runs at most 4 times and the value count is at most 64.
    // A failed check writes only this block's dc and nq (0, so the IDCT reads no coefficient of it) and sets
    // ERR_PACKED; the host then decodes the original JPEG instead, and the colour kernel writes no pixels.
    if (o > A.dlen || (o & 1u) != 0 || n > 4) {
        if (q == 0) {
            dc[b] = 0; nq[b] = 0;
            atomic_fetch_or_explicit(err, ERR_PACKED, memory_order_relaxed);
        }
        return;
    }
    device const ushort* p16 = (device const ushort*)(data + o);
    if (q == 0) { dc[b] = (int)(short)p16[0]; nq[b] = (uchar)n; }
    if ((int)q >= n) return;
    int base = 0;
    for (int j = 0; j < (int)q; j++) base += popcount((u32)p16[1 + j]);
    u32 m = p16[1 + q];
    u32 vo = o + 2 + 2 * (u32)n + (wide ? 2 * (u32)base : (u32)base);
    device const uchar* v = data + vo;
    device const short* v16 = (device const short*)v;          // vo is even when wide (o even, 2-byte steps)
    u32 w[8];
    for (int k = 0; k < 8; k++) {
        u32 x = 0;
        for (int s = 0; s < 2; s++) {
            int i = 2 * k + s;
            if ((m >> i) & 1u) {
                int r = popcount(m & ((1u << i) - 1u));
                short val = wide ? v16[r] : (short)(char)v[r];
                x |= (u32)(ushort)val << (16 * s);
            }
        }
        w[k] = x;
    }
    device uint4* d = (device uint4*)(coef + b * 64 + q * 16);
    d[0] = uint4(w[0], w[1], w[2], w[3]); d[1] = uint4(w[4], w[5], w[6], w[7]);
}

// ---- upsampling (jdsample.c) + colour conversion (jdcolor.c) ----
struct Up { int fh[3], fv[3], dw[3], dh[3], fancy[3]; };

struct RowCtx { device const uchar* r0; device const uchar* r1; int kind, fh, dw, bias; };

inline RowCtx row_ctx(device const uchar* base, int pitch, constant Up& U, int ci, int y) {
    RowCtx R;
    int fh = U.fh[ci], fv = U.fv[ci], dh = U.dh[ci];
    R.fh = fh; R.dw = U.dw[ci]; R.bias = 0;
    if (fh == 1 && fv == 1) { R.kind = 0; R.r0 = base + (u32)y * (u32)pitch; R.r1 = R.r0; return R; }
    if (!U.fancy[ci]) { R.kind = 4; R.r0 = base + (u32)(y / fv) * (u32)pitch; R.r1 = R.r0; return R; }
    if (fv == 1) { R.kind = 1; R.r0 = base + (u32)y * (u32)pitch; R.r1 = R.r0; return R; }
    int k = y >> 1;
    int nb = (y & 1) ? min(k + 1, dh - 1) : max(k - 1, 0);
    R.r0 = base + (u32)k * (u32)pitch; R.r1 = base + (u32)nb * (u32)pitch;
    R.bias = (y & 1) ? 2 : 1;
    R.kind = fh == 1 ? 2 : 3;
    return R;
}

inline void up2(thread const RowCtx& R, int x, bool two, thread int& v0, thread int& v1) {
    device const uchar* a = R.r0;
    device const uchar* b = R.r1;
    v1 = 0;
    switch (R.kind) {
    case 0: v0 = a[x]; if (two) v1 = a[x + 1]; return;
    case 4: v0 = a[x / R.fh]; if (two) v1 = a[(x + 1) / R.fh]; return;
    case 2:
        v0 = (3 * a[x] + b[x] + R.bias) >> 2;
        if (two) v1 = (3 * a[x + 1] + b[x + 1] + R.bias) >> 2;
        return;
    case 1: {
        int j = x >> 1, c = a[j];
        int l = j > 0 ? a[j - 1] : 0, r = j < R.dw - 1 ? a[j + 1] : 0;
        v0 = j == 0 ? c : (3 * c + l + 1) >> 2;
        v1 = j == R.dw - 1 ? c : (3 * c + r + 2) >> 2;
        return;
    }
    default: {
        int j = x >> 1;
        int cs = 3 * a[j] + b[j];
        int cl = j > 0 ? 3 * a[j - 1] + b[j - 1] : 0;
        int cn = j < R.dw - 1 ? 3 * a[j + 1] + b[j + 1] : 0;
        v0 = j == 0 ? (cs * 4 + 8) >> 4 : (cs * 3 + cl + 8) >> 4;
        v1 = j == R.dw - 1 ? (cs * 4 + 7) >> 4 : (cs * 3 + cn + 7) >> 4;
        return;
    }
    }
}

inline uchar cl8(int v) { return (uchar)min(max(v, 0), 255); }

// mode: 0 RGB, 1 BGR, 2 GRAY (Y only), 3 gray JPEG to RGB/BGR, 4 RGBA (alpha 255), 5 BGRA,
// 6 gray JPEG to RGBA/BGRA (Y replicated, alpha 255: jdcolor.c gray_rgb_convert for the 4-byte layouts)
inline void put_px(threadgroup uchar* o, int Y, int cb, int cr, int mode) {
    if (mode == 2) { o[0] = (uchar)Y; return; }
    if (mode == 3) { o[0] = o[1] = o[2] = (uchar)Y; return; }
    if (mode == 6) { o[0] = o[1] = o[2] = (uchar)Y; o[3] = 255; return; }
    cb -= 128; cr -= 128;
    uchar r = cl8(Y + ((91881 * cr + 32768) >> 16));
    uchar g = cl8(Y + ((-22554 * cb + 32768 - 46802 * cr) >> 16));
    uchar b = cl8(Y + ((116130 * cb + 32768) >> 16));
    if (mode == 1 || mode == 5) { uchar t = r; r = b; b = t; }
    o[0] = r; o[1] = g; o[2] = b;
    if (mode >= 4) o[3] = 255;
}

#define CPX 1024
struct ColorArgs { int W; int H; int mode; int C; };
kernel void color(device const uchar* planes [[buffer(0)]], constant Pix& P [[buffer(1)]],
                  constant Up& U [[buffer(2)]], constant ColorArgs& A [[buffer(3)]], device uchar* out [[buffer(4)]],
                  device const int* err [[buffer(5)]],
                  uint tid [[thread_index_in_threadgroup]], uint2 tg [[threadgroup_position_in_grid]]) {
    if (*err != 0) return;                         // a declined decode writes nothing to out (first_blocks)
    threadgroup uint4 sh4[CPX * 4 / 16];            // 16-byte aligned
    threadgroup uchar* sh = (threadgroup uchar*)sh4;
    int x0 = (int)tg.x * CPX, y = (int)tg.y;
    int W = A.W, mode = A.mode, C = A.C;
    int nc = (mode == 2 || mode == 3 || mode == 6) ? 1 : 3;
    RowCtx r0 = row_ctx(planes + P.off[0], P.pitch[0], U, 0, y), r1 = r0, r2 = r0;
    if (nc == 3) { r1 = row_ctx(planes + P.off[1], P.pitch[1], U, 1, y); r2 = row_ctx(planes + P.off[2], P.pitch[2], U, 2, y); }
    for (int k = 0; k < CPX / 256; k++) {
        int i = 2 * ((int)tid + 128 * k), x = x0 + i;
        if (x >= W) break;
        bool two = x + 1 < W;
        int y0, y1, b0 = 0, b1 = 0, c0 = 0, c1 = 0;
        up2(r0, x, two, y0, y1);
        if (nc == 3) { up2(r1, x, two, b0, b1); up2(r2, x, two, c0, c1); }
        put_px(sh + i * C, y0, b0, c0, mode);
        if (two) put_px(sh + (i + 1) * C, y1, b1, c1, mode);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int nb = min(CPX, W - x0) * C;
    u32 o = ((u32)y * (u32)W + (u32)x0) * (u32)C;   // the output is bound at offset 0 (Decoder.run)
    device uchar* dst = out + o;
    // the row segment leaves threadgroup memory in 16- or 4-byte words when its offset allows (same bytes)
    int done = 0;
    if ((o & 15) == 0) {
        int n16 = nb >> 4;
        for (int k = (int)tid; k < n16; k += 128) ((device uint4*)dst)[k] = sh4[k];
        done = n16 << 4;
    } else if ((o & 3) == 0) {
        int n4 = nb >> 2;
        for (int k = (int)tid; k < n4; k += 128) ((device u32*)dst)[k] = ((threadgroup const u32*)sh)[k];
        done = n4 << 2;
    }
    for (int k = done + (int)tid; k < nb; k += 128) dst[k] = sh[k];
}

// color_k: the colour kernel with the layout and output mode compiled in (function constants: the upsampling kind
// of each component as row_ctx gives it, the output mode and channels). The same arithmetic as color.
constant int CK0 [[function_constant(0)]];
constant int CK1 [[function_constant(1)]];
constant int CK2 [[function_constant(2)]];
constant int CMODE [[function_constant(3)]];
constant int CC [[function_constant(4)]];
kernel void color_k(device const uchar* planes [[buffer(0)]], constant Pix& P [[buffer(1)]],
                  constant Up& U [[buffer(2)]], constant ColorArgs& A [[buffer(3)]], device uchar* out [[buffer(4)]],
                  device const int* err [[buffer(5)]],
                  uint tid [[thread_index_in_threadgroup]], uint2 tg [[threadgroup_position_in_grid]]) {
    if (*err != 0) return;                         // a declined decode writes nothing to out (first_blocks)
    threadgroup uint4 sh4[CPX * 4 / 16];            // 16-byte aligned
    threadgroup uchar* sh = (threadgroup uchar*)sh4;
    int x0 = (int)tg.x * CPX, y = (int)tg.y;
    int W = A.W; const int mode = CMODE, C = CC;
    int nc = (mode == 2 || mode == 3 || mode == 6) ? 1 : 3;
    RowCtx r0 = row_ctx(planes + P.off[0], P.pitch[0], U, 0, y), r1 = r0, r2 = r0;
    if (nc == 3) { r1 = row_ctx(planes + P.off[1], P.pitch[1], U, 1, y); r2 = row_ctx(planes + P.off[2], P.pitch[2], U, 2, y); }
    // the upsampling kind of each component is fixed when the pipeline is built (the host derives it the way
    // row_ctx does), so the compiler keeps only that case of up2 for each component: no per-pixel switch
    r0.kind = CK0; r1.kind = CK1; r2.kind = CK2;
    for (int k = 0; k < CPX / 256; k++) {
        int i = 2 * ((int)tid + 128 * k), x = x0 + i;
        if (x >= W) break;
        bool two = x + 1 < W;
        int y0, y1, b0 = 0, b1 = 0, c0 = 0, c1 = 0;
        up2(r0, x, two, y0, y1);
        if (nc == 3) { up2(r1, x, two, b0, b1); up2(r2, x, two, c0, c1); }
        put_px(sh + i * C, y0, b0, c0, mode);
        if (two) put_px(sh + (i + 1) * C, y1, b1, c1, mode);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int nb = min(CPX, W - x0) * C;
    u32 o = ((u32)y * (u32)W + (u32)x0) * (u32)C;   // the output is bound at offset 0 (Decoder.run)
    device uchar* dst = out + o;
    // the row segment leaves threadgroup memory in 16- or 4-byte words when its offset allows (same bytes)
    int done = 0;
    if ((o & 15) == 0) {
        int n16 = nb >> 4;
        for (int k = (int)tid; k < n16; k += 128) ((device uint4*)dst)[k] = sh4[k];
        done = n16 << 4;
    } else if ((o & 3) == 0) {
        int n4 = nb >> 2;
        for (int k = (int)tid; k < n4; k += 128) ((device u32*)dst)[k] = ((threadgroup const u32*)sh)[k];
        done = n4 << 2;
    }
    for (int k = done + (int)tid; k < nb; k += 128) dst[k] = sh[k];
}
