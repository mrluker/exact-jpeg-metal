// Shared helpers for the ExactJPEG kernels: a segmented inclusive prefix sum over int32 that runs in three
// dispatches (per-threadgroup totals, carries between threadgroups, apply), used for every prefix sum the
// decoder and encoder need (tile offsets, chunk numbering, block counts, DC prediction).
//
// The array is a strided view: element i lives at base + (i / w) * stride + (i % w), so one scan can run over
// the blocks of one component inside interleaved MCUs (DC prediction). Segments: with L > 0 the sum restarts
// at every i that is a multiple of L (restart intervals). Metal GPU family Apple7 or later (M1, A14+).
#include <metal_stdlib>
using namespace metal;

typedef uint u32;
typedef ulong u64;

#define SCAN_TG 256
#define SCAN_PER 16
#define SCAN_SPAN (SCAN_TG * SCAN_PER)

struct ScanView { u32 base, w, stride, n, L; };

struct SP { int v; bool f; };                     // value since the last segment start; f: a start was seen

inline SP sp_combine(SP a, SP b) { return SP{b.f ? b.v : a.v + b.v, a.f || b.f}; }

inline u32 sv_addr(constant ScanView& s, u32 i) { return s.base + (i / s.w) * s.stride + (i % s.w); }
inline bool sv_start(constant ScanView& s, u32 i) { return s.L != 0 && i % s.L == 0; }

// exclusive scan of one SP per thread over a threadgroup of SCAN_TG threads; *total = the inclusive total
inline SP tg_excl_scan(SP x, u32 tid, u32 lane, u32 sg, threadgroup SP* sgs, thread SP& total) {
    SP inc = x;
    for (ushort o = 1; o < 32; o <<= 1) {
        SP y = SP{simd_shuffle_up(inc.v, o), (bool)simd_shuffle_up((ushort)inc.f, o)};
        if (lane >= o) inc = sp_combine(y, inc);
    }
    SP ex = SP{simd_shuffle_up(inc.v, (ushort)1), (bool)simd_shuffle_up((ushort)inc.f, (ushort)1)};
    if (lane == 0) ex = SP{0, false};
    if (lane == 31) sgs[sg] = inc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        SP a = SP{0, false};
        for (u32 k = 0; k < SCAN_TG / 32; k++) { SP t = sgs[k]; sgs[k] = a; a = sp_combine(a, t); }
        sgs[SCAN_TG / 32] = a;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    SP r = sp_combine(sgs[sg], ex);
    total = sgs[SCAN_TG / 32];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return r;
}

// phase 1: aux[tg] = this threadgroup's (value since its last start, has a start)
kernel void scan_up(device const int* a [[buffer(0)]], constant ScanView& s [[buffer(1)]],
                    device SP* aux [[buffer(2)]], uint tid [[thread_index_in_threadgroup]],
                    uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                    uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup SP sgs[SCAN_TG / 32 + 1];
    u32 i0 = tg * SCAN_SPAN + tid * SCAN_PER;
    SP x = SP{0, false};
    for (u32 k = 0; k < SCAN_PER; k++) {
        u32 i = i0 + k;
        if (i >= s.n) break;
        int v = a[sv_addr(s, i)];
        if (sv_start(s, i)) x = SP{v, true}; else x.v += v;
    }
    SP tot;
    tg_excl_scan(x, tid, lane, sg, sgs, tot);
    if (tid == 0) aux[tg] = tot;
}

// phase 2 (one threadgroup): aux[t] becomes the carry into threadgroup t (exclusive)
kernel void scan_mid(device SP* aux [[buffer(0)]], constant u32& nt [[buffer(1)]],
                     uint tid [[thread_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                     uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup SP sgs[SCAN_TG / 32 + 1];
    SP carry = SP{0, false};
    for (u32 base = 0; base < nt; base += SCAN_SPAN) {
        u32 i0 = base + tid * SCAN_PER;
        SP x = SP{0, false};
        for (u32 k = 0; k < SCAN_PER && i0 + k < nt; k++) x = sp_combine(x, aux[i0 + k]);
        SP tot;
        SP ex = sp_combine(carry, tg_excl_scan(x, tid, lane, sg, sgs, tot));
        for (u32 k = 0; k < SCAN_PER && i0 + k < nt; k++) { SP t = aux[i0 + k]; aux[i0 + k] = ex; ex = sp_combine(ex, t); }
        carry = sp_combine(carry, tot);
        threadgroup_barrier(mem_flags::mem_device);
    }
}

// phase 3: inclusive segmented sums written in place
kernel void scan_down(device int* a [[buffer(0)]], constant ScanView& s [[buffer(1)]],
                      device const SP* aux [[buffer(2)]], uint tid [[thread_index_in_threadgroup]],
                      uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                      uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup SP sgs[SCAN_TG / 32 + 1];
    u32 i0 = tg * SCAN_SPAN + tid * SCAN_PER;
    int v[SCAN_PER];
    SP x = SP{0, false};
    for (u32 k = 0; k < SCAN_PER; k++) {
        u32 i = i0 + k;
        v[k] = i < s.n ? a[sv_addr(s, i)] : 0;
        if (i < s.n && sv_start(s, i)) x = SP{v[k], true}; else x.v += v[k];
    }
    SP tot;
    SP ex = sp_combine(aux[tg], tg_excl_scan(x, tid, lane, sg, sgs, tot));
    int run = ex.v;
    for (u32 k = 0; k < SCAN_PER; k++) {
        u32 i = i0 + k;
        if (i >= s.n) break;
        run = sv_start(s, i) ? v[k] : run + v[k];
        a[sv_addr(s, i)] = run;
    }
}

// small helpers
kernel void fill_u32(device u32* a [[buffer(0)]], constant u32& v [[buffer(1)]], constant u32& n [[buffer(2)]],
                     uint i [[thread_position_in_grid]]) {
    if (i < n) a[i] = v;
}
