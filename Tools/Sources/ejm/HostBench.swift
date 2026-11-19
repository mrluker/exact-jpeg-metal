import Foundation
import Metal
import ExactJPEG
import HostBenchObjC

/// Host-side overhead: the same dispatch sequence encoded from Swift and from Objective-C++ (the calls metal-cpp
/// wraps), with a trivial kernel so the GPU time is negligible.
func runHostBench() {
    let ctx = MetalContext.shared
    let pso = ctx.pipeline("fill_u32")
    let buf = ctx.device.makeBuffer(length: 1 << 16, options: .storageModeShared)!
    for dispatches in [45, 200] {
        var enc: [Double] = [], rt: [Double] = []
        for _ in 0..<300 {
            autoreleasepool {
                let t0 = now()
                let cb = ctx.queue.makeCommandBufferWithUnretainedReferences()!
                let e = cb.makeComputeCommandEncoder(dispatchType: .serial)!
                for d in 0..<dispatches {
                    e.setComputePipelineState(pso)
                    e.setBuffer(buf, offset: 256 * (d & 7), index: 0)
                    var z: UInt32 = 0; e.setBytes(&z, length: 4, index: 1)
                    e.setBytes(&z, length: 4, index: 2)
                    e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
                }
                e.endEncoding()
                let t1 = now()
                cb.commit(); cb.waitUntilCompleted()
                enc.append(t1 - t0); rt.append(now() - t1)
            }
        }
        var rtc = 0.0
        let c = hb_encode_objcpp(Unmanaged.passUnretained(ctx.queue).toOpaque(), Unmanaged.passUnretained(pso).toOpaque(),
                                 Unmanaged.passUnretained(buf).toOpaque(), Int32(dispatches), 300, &rtc)
        print("\(dispatches) dispatches: encode Swift \(fmt(median(enc) * 1e6, 1)) us, Objective-C++ \(fmt(c * 1e6, 1)) us; commit->done Swift \(fmt(median(rt) * 1e6, 0)) us, ObjC++ \(fmt(rtc * 1e6, 0)) us")
    }
}
