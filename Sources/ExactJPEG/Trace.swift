// Opt-in timing: per-stage GPU times (Decoder.recordStages, Encoder.recordStages) and one trace line per call
// (EJM_TRACE, MetalContext.trace). Off by default; off costs one Bool check per call.

import Foundation
import Metal

/// One stage of a decode or encode and its GPU time: from the start to the end of the stage's compute encoder
/// (counter samples at encoder boundaries).
public struct StageTime: Equatable, Sendable, CustomStringConvertible {
    public let name: String
    public let gpuSeconds: Double
    public init(name: String, gpuSeconds: Double) { self.name = name; self.gpuSeconds = gpuSeconds }
    /// e.g. "idct 0.412"
    public var description: String { "\(name) \(String(format: "%.3f", gpuSeconds * 1000))" }
}

extension MetalContext {
    /// Receives one line per decode and per encode call (the same lines EJM_TRACE=1 prints to stderr), on the
    /// thread that made the call. nil (the default) means off. Set it before starting work, not while other
    /// threads decode or encode.
    nonisolated(unsafe) public static var trace: ((String) -> Void)? {
        didSet { TraceState.enabled = trace != nil || TraceState.env != .off }
    }
}

enum TraceMode { case off, line, stages }

enum TraceState {
    /// the one flag a call reads when tracing is off: EJM_TRACE was set, or MetalContext.trace is not nil
    nonisolated(unsafe) static var enabled = false
    /// EJM_TRACE, read once: "stages" also records the stages; any other value but "" and "0" prints the line
    static let env: TraceMode = {
        switch ProcessInfo.processInfo.environment["EJM_TRACE"] ?? "" {
        case "", "0": return .off
        case "stages": return .stages
        default: return .line
        }
    }()
    /// called when a decoder or encoder is made, so EJM_TRACE is read once, before the first call
    static func noteEnv() { if env != .off { enabled = true } }
    /// recordStages on, or EJM_TRACE=stages (read only when enabled)
    @inline(__always) static func stages(_ own: Bool) -> Bool { own || (enabled && env == .stages) }

    static func emit(_ line: String) {
        if env != .off { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        MetalContext.trace?(line)
    }

    static func ms(_ s: Double) -> String { String(format: "%.3f", s * 1000) }

    /// " route gpu (cpu 3.1 ms, gpu 4.2 ms, GPU warm, CPU cold, estimate)": the advice for this size and operation
    /// with the automatic warmth, from the profile as it stands (reading it here does not start the measurement, nor
    /// the background device reads, nor move the CPU-time window)
    static func route(_ ctx: MetalContext, _ w: Int, _ h: Int, _ op: DeviceProfile.Operation) -> String {
        let r = DeviceProfileRegistry.shared.profile(ctx.device).routingDecisionSnapshot(width: w, height: h, operation: op)
        return " route \(r.prefersCPU ? "cpu" : "gpu") (cpu \(String(format: "%.2f", r.predictedCPUms)) ms, gpu "
            + "\(String(format: "%.2f", r.predictedGPUms)) ms, GPU set \(r.gpuSet), CPU \(r.cpuCold ? "cold" : "warm"), "
            + "\(r.source)\(r.marginApplied ? ", margin" : ""))"
    }

    static func stageList(_ s: [StageTime]) -> String {
        s.isEmpty ? "" : " stages " + s.map(\.description).joined(separator: ", ")
    }
}

/// Per-stage timing of one command buffer: a compute encoder per stage, a counter sample at the start and the end
/// of each, and an MTLEvent between consecutive encoders (the encoder's buffers are untracked, so nothing else
/// orders them). nil where the device cannot sample at stage boundaries.
final class StageRecorder {
    static let maxStages = 128
    let sampleBuffer: MTLCounterSampleBuffer
    let device: MTLDevice
    private var names: [String] = []
    private var cpu0: MTLTimestamp = 0, gpu0: MTLTimestamp = 0
    let event: MTLEvent
    private var eventValue: UInt64 = 0        // only grows: a wait passes once the event reaches its value

    init?(device: MTLDevice) {
        guard device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else { return nil }
        let d = MTLCounterSampleBufferDescriptor()
        d.counterSet = set
        d.storageMode = .shared
        d.sampleCount = 2 * StageRecorder.maxStages
        guard let sb = try? device.makeCounterSampleBuffer(descriptor: d), let ev = device.makeEvent() else { return nil }
        sampleBuffer = sb
        event = ev
        self.device = device
    }

    func reset() { names.removeAll(keepingCapacity: true); (cpu0, gpu0) = device.sampleTimestamps() }

    /// a new compute encoder for stage `name`, after `previous` (ended here; the new one waits for it)
    func encoder(_ cb: MTLCommandBuffer, _ name: String, _ type: MTLDispatchType,
                 after previous: MTLComputeCommandEncoder?) -> MTLComputeCommandEncoder? {
        if let previous {
            // an event, not a fence: with MTLFence updates and waits between these encoders the encoder's output
            // differed (tested 2026-11-17 on the M1 Max); an event signalled after one encoder and waited on before
            // the next orders them
            previous.endEncoding()
            eventValue += 1
            cb.encodeSignalEvent(event, value: eventValue)
            cb.encodeWaitForEvent(event, value: eventValue)
        }
        let k = names.count
        guard k < StageRecorder.maxStages else { return nil }
        let pd = MTLComputePassDescriptor()
        pd.dispatchType = type
        let a = pd.sampleBufferAttachments[0]!
        a.sampleBuffer = sampleBuffer
        a.startOfEncoderSampleIndex = 2 * k
        a.endOfEncoderSampleIndex = 2 * k + 1
        guard let enc = cb.makeComputeCommandEncoder(descriptor: pd) else { return nil }
        names.append(name)
        return enc
    }

    /// after the command buffer completed: each encoder's GPU time, summed by name (in order of first use)
    func times() -> [StageTime] {
        let (cpu1, gpu1) = device.sampleTimestamps()
        // GPU ticks to seconds: the CPU timestamps are nanoseconds, the GPU's ticks are calibrated against them
        let scale = gpu1 > gpu0 && cpu1 > cpu0 ? Double(cpu1 - cpu0) / Double(gpu1 - gpu0) * 1e-9 : 1e-9
        guard !names.isEmpty, let data = try? sampleBuffer.resolveCounterRange(0..<(2 * names.count)) else { return [] }
        var out: [StageTime] = [], index: [String: Int] = [:]
        data.withUnsafeBytes { raw in
            let t = raw.bindMemory(to: MTLCounterResultTimestamp.self)
            for (k, n) in names.enumerated() {
                let a = t[2 * k].timestamp, b = t[2 * k + 1].timestamp
                let s = a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a ? 0 : Double(b - a) * scale
                if let i = index[n] { out[i] = StageTime(name: n, gpuSeconds: out[i].gpuSeconds + s) }
                else { index[n] = out.count; out.append(StageTime(name: n, gpuSeconds: s)) }
            }
        }
        return out
    }
}
