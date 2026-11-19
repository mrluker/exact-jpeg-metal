#import <Metal/Metal.h>
#include "hostbench.h"
#include <algorithm>
#include <mach/mach_time.h>
#include <vector>

static double secs() {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9;
}

double hb_encode_objcpp(void *q, void *p, void *b, int dispatches, int iters, double *rt) {
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)q;
    id<MTLComputePipelineState> pso = (__bridge id<MTLComputePipelineState>)p;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)b;
    std::vector<double> enc, rtt;
    for (int it = 0; it < iters; it++) {
        @autoreleasepool {
            double t0 = secs();
            id<MTLCommandBuffer> cb = [queue commandBufferWithUnretainedReferences];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
            for (int d = 0; d < dispatches; d++) {
                [e setComputePipelineState:pso];
                [e setBuffer:buf offset:256 * (d & 7) atIndex:0];
                unsigned v[4] = {0, 0, 0, 0};
                [e setBytes:&v[1] length:4 atIndex:1];
                [e setBytes:&v[2] length:4 atIndex:2];
                [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
            }
            [e endEncoding];
            double t1 = secs();
            [cb commit];
            [cb waitUntilCompleted];
            double t2 = secs();
            enc.push_back(t1 - t0); rtt.push_back(t2 - t1);
        }
    }
    std::sort(enc.begin(), enc.end()); std::sort(rtt.begin(), rtt.end());
    *rt = rtt[rtt.size() / 2];
    return enc[enc.size() / 2];
}
