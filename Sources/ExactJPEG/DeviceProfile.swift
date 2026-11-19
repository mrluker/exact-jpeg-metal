// How the library configures itself per device. Two layers:
//
// 1. Deterministic, from what the device reports (no timing): GPU name and family, GPU core count, the GPU working
//    set, CPU performance cores. From these: the encoder's entropy path, how many images to keep in flight, the
//    memory budget. Computed once per device, the first time an Encoder is made or the profile is read.
// 2. Routing advice (when a small image is faster on the CPU). The GPU in three states. Sustained (a GPU kept fed):
//    an estimate from the core count, calibrated on warm measurements of an M4 and an M1 Max, never measured at run
//    time. Cold (single calls with the GPU idle between, the sporadic set): a cold fixed cost, a short job's cold
//    per-MP cost and a ramp to the sustained per-MP cost (a long job warms the GPU), per operation, measured.
//    Warm (this process used the GPU in the last 250 ms): the sustained per-MP cost plus 0.65x the cold fixed cost. The caller's CPU codec in two states: warm (its rate) and cold (the warm time plus a
//    ramp penalty, from a CPU proxy the library times). Which states apply is tracked automatically: the library's
//    own command buffers for the GPU, DeviceProfile.noteCPUWork() and the process's CPU time for the CPU. The
//    first read of a profile (MetalContext.profile, DeviceProfile.current) starts a short background measurement
//    (utility QoS, never on a decode's or encode's path) whose result is saved in the Caches directory, keyed by
//    GPU, OS build and library version.
//
// Nothing here changes output bytes or what is declined: every value a setting can take gives the same bytes (the
// test suite runs both encoder paths and three decoder chunk settings), and the library always uses the GPU when
// called. Routing is advice for the caller.

import CryptoKit
import Foundation
import Metal
#if os(macOS)
import IOKit
#endif

/// What the library knows about one Metal device and the settings it derives from that. See docs/API.md,
/// "Device profile".
public final class DeviceProfile: @unchecked Sendable, CustomStringConvertible {
    /// The Metal GPU family the device supports (the highest of these three; later families report apple9).
    public enum Family: Int, Sendable, Comparable {
        case apple7 = 7, apple8 = 8, apple9 = 9
        public static func < (a: Family, b: Family) -> Bool { a.rawValue < b.rawValue }
    }
    /// The encoder's entropy-coding path: `fused` (single-pass kernel) or `twoPass` (count, then write).
    /// Both give identical bytes.
    public enum EncoderPath: String, Sendable { case fused, twoPass }
    /// The operation a routing question is about.
    public enum Operation: Sendable { case decode, encode }
    /// Where the current routing numbers come from.
    public enum RoutingSource: String, Sendable { case estimate, measured, cache, pinned }

    /// Wall-clock cost model of one GPU call: fixed + per-megapixel milliseconds, for decode and encode.
    public struct Routing: Codable, Equatable, Sendable {
        public var decodeFixedMs: Double
        public var decodeMsPerMP: Double
        public var encodeFixedMs: Double
        public var encodeMsPerMP: Double
        /// wall time of a first call (see API.md: a new decoder's first decode after the self-check)
        public var coldStartMs: Double
        /// true when the numbers were timed on this device (now or in an earlier run, from the cache)
        public var measured: Bool
        /// the measurement's own cost: wall time and GPU time (0 for an estimate)
        public var measurementMs: Double
        public var measurementGPUMs: Double
        /// how busy the device was just before the measurement (nil for an estimate)
        public var idleSample: IdleSample?
        /// isolated calls per operation the measured cold fixed costs are the median of (nil for an estimate)
        public var measurementRounds: Int?
        /// The cold GPU's ramp (nil: a straight line, fixed + per-MP). A long job warms the GPU as it runs, so the
        /// per-MP cost starts at decodeMsPerMP (a short job's) and falls to decodeWarmMsPerMP (the sustained one);
        /// decodeRampMs is the most the excess over the warm per-MP cost adds:
        /// fixed + warm x MP + ramp x (1 - exp(-(msPerMP - warm) x MP / ramp)). The same for encode.
        public var decodeRampMs: Double?, decodeWarmMsPerMP: Double?
        public var encodeRampMs: Double?, encodeWarmMsPerMP: Double?
        public init(decodeFixedMs: Double, decodeMsPerMP: Double, encodeFixedMs: Double, encodeMsPerMP: Double,
                    coldStartMs: Double, measured: Bool, measurementMs: Double = 0, measurementGPUMs: Double = 0,
                    idleSample: IdleSample? = nil, measurementRounds: Int? = nil,
                    decodeRampMs: Double? = nil, decodeWarmMsPerMP: Double? = nil,
                    encodeRampMs: Double? = nil, encodeWarmMsPerMP: Double? = nil) {
            self.decodeFixedMs = decodeFixedMs; self.decodeMsPerMP = decodeMsPerMP
            self.encodeFixedMs = encodeFixedMs; self.encodeMsPerMP = encodeMsPerMP
            self.coldStartMs = coldStartMs; self.measured = measured
            self.measurementMs = measurementMs; self.measurementGPUMs = measurementGPUMs
            self.idleSample = idleSample; self.measurementRounds = measurementRounds
            self.decodeRampMs = decodeRampMs; self.decodeWarmMsPerMP = decodeWarmMsPerMP
            self.encodeRampMs = encodeRampMs; self.encodeWarmMsPerMP = encodeWarmMsPerMP
        }
        /// predicted GPU wall time in ms for an image of `megapixels` (with the ramp when there is one)
        public func gpuMs(megapixels: Double, operation: Operation) -> Double {
            operation == .decode
                ? Routing.cost(decodeFixedMs, decodeMsPerMP, decodeRampMs, decodeWarmMsPerMP, megapixels)
                : Routing.cost(encodeFixedMs, encodeMsPerMP, encodeRampMs, encodeWarmMsPerMP, megapixels)
        }
        static func cost(_ f: Double, _ s: Double, _ ramp: Double?, _ w: Double?, _ mp: Double) -> Double {
            guard let r = ramp, let w, r > 0, s > w else { return f + mp * s }
            return f + w * mp + r * (1 - exp(-(s - w) * mp / r))
        }
        /// the ramp and warm per-MP cost of `operation` (nil: a straight line)
        public func ramp(_ operation: Operation) -> (rampMs: Double, warmMsPerMP: Double)? {
            let (r, w) = operation == .decode ? (decodeRampMs, decodeWarmMsPerMP) : (encodeRampMs, encodeWarmMsPerMP)
            guard let r, let w else { return nil }
            return (r, w)
        }
        /// e.g. "decode 3.954 ms + 2.245 ms/MP (ramp about 6.2 ms, then 0.500 ms/MP), encode ..."; the ramp is printed
        /// to one decimal as approximate: it is fitted from two isolated calls and varies between processes
        public var costDescription: String {
            func one(_ name: String, _ f: Double, _ s: Double, _ op: Operation) -> String {
                String(format: "%@ %.3f ms + %.3f ms/MP", name as NSString, f, s)
                    + (ramp(op).map { String(format: " (ramp about %.1f ms, then %.3f ms/MP)", $0.rampMs, $0.warmMsPerMP) } ?? "")
            }
            return one("decode", decodeFixedMs, decodeMsPerMP, .decode) + ", " + one("encode", encodeFixedMs, encodeMsPerMP, .encode)
        }
        var valid: Bool {
            [decodeFixedMs, decodeMsPerMP, encodeFixedMs, encodeMsPerMP, coldStartMs].allSatisfy { $0.isFinite && $0 >= 0 && $0 < 10_000 }
                && [decodeRampMs, decodeWarmMsPerMP, encodeRampMs, encodeWarmMsPerMP].allSatisfy { $0.map { $0.isFinite && $0 >= 0 && $0 < 10_000 } ?? true }
                && (decodeRampMs == nil) == (decodeWarmMsPerMP == nil) && (encodeRampMs == nil) == (encodeWarmMsPerMP == nil)
        }
    }

    /// How busy the device is, sampled before a routing measurement: the measurement runs only on an idle device.
    /// macOS: the GPU's "Device Utilization %" (IORegistry PerformanceStatistics, two samples about 100 ms apart)
    /// and the 1-minute load average against the CPU core count. iOS exposes neither: thermal state and Low Power
    /// Mode instead.
    public struct IdleSample: Codable, Equatable, Sendable {
        /// GPU utilization samples in percent (empty when not readable, as on iOS)
        public var gpuUtilization: [Int]
        /// 1-minute load average (nil on iOS)
        public var loadAverage: Double?
        public var cpuCores: Int
        /// iOS: thermalState serious or critical
        public var thermalSerious: Bool
        /// iOS: Low Power Mode on
        public var lowPowerMode: Bool
        public init(gpuUtilization: [Int], loadAverage: Double?, cpuCores: Int, thermalSerious: Bool = false, lowPowerMode: Bool = false) {
            self.gpuUtilization = gpuUtilization; self.loadAverage = loadAverage; self.cpuCores = cpuCores
            self.thermalSerious = thermalSerious; self.lowPowerMode = lowPowerMode
        }
        /// every utilization sample under 20%, load average under the core count, not hot, not in Low Power Mode
        public var idle: Bool {
            !thermalSerious && !lowPowerMode && gpuUtilization.allSatisfy { $0 < 20 }
                && (loadAverage.map { $0 < Double(cpuCores) } ?? true)
        }
        /// e.g. "GPU 3%/5%, load 2.10 of 10 cores"
        public var summary: String {
            var parts: [String] = []
            if !gpuUtilization.isEmpty { parts.append("GPU " + gpuUtilization.map { "\($0)%" }.joined(separator: "/")) }
            if let l = loadAverage { parts.append(String(format: "load %.2f of %d cores", l, cpuCores)) }
            if thermalSerious { parts.append("thermal serious") }
            if lowPowerMode { parts.append("Low Power Mode") }
            return parts.isEmpty ? "no busy signals" : parts.joined(separator: ", ")
        }
    }

    /// libjpeg-turbo's single-thread warm rates the routing advice assumes when the caller passes none (NEON
    /// builds on Apple silicon performance cores; an M4 measured 2.64 and 2.41 ms/MP warm, 2026-11-17).
    public static let defaultCPUDecodeMsPerMP = 3.0
    public static let defaultCPUEncodeMsPerMP = 2.5
    /// How much faster the CPU must be predicted before prefersCPU advises it (0.2: at least 20% faster); within
    /// that margin the GPU is advised. On an M4 the measured winner of cells within about 20% of a crossover
    /// changed between identical runs, while every cell with a winner more than 25% ahead was routed right.
    public static let cpuPreferenceMargin = 0.2
    /// Replaced by the CPU cold model (cpuColdModel), which prefersCPU applies to any warm rate, the caller's too,
    /// when the CPU is cold. Not used.
    @available(*, deprecated, message: "prefersCPU now applies cpuColdModel when the CPU is cold; see API.md")
    public static let coldCPUFactor = 3.0

    /// The caller's CPU codec when the CPU is cold (its clock not yet ramped up): the warm time w plus a ramp
    /// penalty that saturates, cold = w + rampMs x (1 - exp(-(ratio - 1) x w / rampMs)). A short job runs about
    /// `ratio` x its warm time; a long one loses at most `rampMs` to the ramp. A tiny job (warm under
    /// cpuTinyJobMs) loses at most cpuTinyPenaltyMs (see coldMs).
    public struct CPUColdModel: Codable, Equatable, Sendable {
        /// k: a short job's cold time over its warm time
        public var ratio: Double
        /// the most a job loses to the clock ramp, in ms (reached by long jobs)
        public var rampMs: Double
        /// true when fitted from the library's CPU proxy timed on this device (now or from the cache)
        public var measured: Bool
        /// the proxy's own CPU time in ms (0 when not measured)
        public var measurementMs: Double
        public init(ratio: Double, rampMs: Double, measured: Bool = false, measurementMs: Double = 0) {
            self.ratio = ratio; self.rampMs = rampMs; self.measured = measured; self.measurementMs = measurementMs
        }
        /// predicted cold wall time of a job that takes `warmMs` warm: the ramp curve (rampedMs), capped for tiny
        /// jobs at w + cpuTinyPenaltyMs + (ratio - 1) x max(0, w - cpuTinyJobMs) (continuous; the slope changes at
        /// cpuTinyJobMs and where the cap meets the curve)
        public func coldMs(warmMs w: Double) -> Double {
            let m = rampedMs(warmMs: w)
            return min(m, w + DeviceProfile.cpuTinyPenaltyMs + max(ratio - 1, 0) * max(w - DeviceProfile.cpuTinyJobMs, 0))
        }
        /// the ramp curve alone, w + rampMs x (1 - exp(-(ratio - 1) x w / rampMs)), without the tiny-job floor
        /// (the CPU proxy is fitted to it)
        public func rampedMs(warmMs w: Double) -> Double {
            guard w > 0, ratio > 1, rampMs > 0 else { return max(w, 0) }
            return w + rampMs * (1 - exp(-(ratio - 1) * w / rampMs))
        }
        var valid: Bool { ratio.isFinite && rampMs.isFinite && ratio >= 1 && ratio <= 10 && rampMs >= 0 && rampMs <= 500 }
    }
    /// The CPU cold model until measured: the M4 fit (libjpeg-turbo 3.2.1, 1 thread, isolated calls 250-300 ms
    /// apart against back to back; see API.md "CPU cold model"): ratio 4.0, rampMs 18.
    public static let defaultCPUColdModel = CPUColdModel(ratio: 4.0, rampMs: 18)
    /// A cold CPU's tiny job loses at most cpuTinyPenaltyMs while its warm time is under cpuTinyJobMs; past that
    /// the cap rises at the model's short-job rate, ratio - 1 ms per warm ms, until it meets the ramp curve (about
    /// 1.2-1.4 ms warm for ratio 4-7). M4, 2026-11-17: a 256x256 encode on a cold CPU took 0.64 ms against 0.49
    /// warm, where ratio 4-7 would predict 2-3.5x; a 640x480 decode (0.8-0.9 ms warm) still took 2.6-4.0 ms cold,
    /// so a flat 0.25 ms cap up to 1 ms would send it to a CPU 58% slower than the warm GPU.
    public static let cpuTinyJobMs = 0.25
    public static let cpuTinyPenaltyMs = 0.25
    /// warmRouting's fixed costs as a fraction of the cold (sporadic) ones (M4, 2026-11-17: the GPU 200 ms after
    /// the same work ran a 256x256 decode in 3.2-3.5 ms against 3.6-4.1 cold, an encode in 0.8 against 1.2-1.5)
    public static let gpuWarmFixedFraction = 0.65
    /// a side is warm when it worked within this many seconds
    public static let warmWindow: Double = 0.25

    /// Whether the GPU and the CPU are warm now, as prefersCPU sees it when not told.
    public struct Warmth: Equatable, Sendable, CustomStringConvertible {
        /// this process had GPU work in flight, or one finished within warmWindow
        public var gpuWarm: Bool
        /// noteCPUWork() within warmWindow, or the process used more than half a core over the last sampled window
        public var cpuWarm: Bool
        /// a command buffer of this process is in flight
        public var gpuInFlight: Bool
        /// seconds since this process's last command buffer completed (0 while one is in flight; nil: none yet)
        public var gpuIdleSeconds: Double?
        /// seconds since the last noteCPUWork() (nil: never called)
        public var cpuIdleSeconds: Double?
        /// this process's CPU use in cores over the window since an earlier sample (nil: no window of 0.05-0.25 s)
        public var processCPUCores: Double?
        /// macOS: the share of GPU work outside this library's own calls in percent (other apps, or the app's own
        /// rendering) over the last usable read interval (nil: not known, or iOS); at 25% or more the GPU counts as
        /// warm (that work keeps it clocked up)
        public var deviceGPUPercent: Int?
        public init(gpuWarm: Bool, cpuWarm: Bool, gpuInFlight: Bool = false, gpuIdleSeconds: Double? = nil,
                    cpuIdleSeconds: Double? = nil, processCPUCores: Double? = nil, deviceGPUPercent: Int? = nil) {
            self.gpuWarm = gpuWarm; self.cpuWarm = cpuWarm; self.gpuInFlight = gpuInFlight
            self.gpuIdleSeconds = gpuIdleSeconds; self.cpuIdleSeconds = cpuIdleSeconds; self.processCPUCores = processCPUCores
            self.deviceGPUPercent = deviceGPUPercent
        }
        /// e.g. "GPU warm (idle 0.012 s), CPU cold (noted 3.100 s ago, process 0.02 cores)"
        public var description: String {
            func age(_ v: Double?) -> String { v.map { String(format: "%.3f s", $0) } ?? "never" }
            let g = "GPU \(gpuWarm ? "warm" : "cold") (" + (gpuInFlight ? "in flight" : "idle \(age(gpuIdleSeconds))")
                + (deviceGPUPercent.map { ", device \($0)%" } ?? "") + ")"
            let c = "CPU \(cpuWarm ? "warm" : "cold") (noted \(age(cpuIdleSeconds))\(cpuIdleSeconds == nil ? "" : " ago")"
                + (processCPUCores.map { String(format: ", process %.2f cores", $0) } ?? "") + ")"
            return g + ", " + c
        }
    }

    /// Call when your CPU codec finishes a job (a decode or encode with libjpeg-turbo, say): for warmWindow
    /// seconds after, prefersCPU treats the CPU as warm. One lock and a clock read.
    public static func noteCPUWork() { WarmthTracker.noteCPU() }
    /// Starts timing a CPU job for this profile's load correction: call it just before your CPU codec runs, then
    /// end(width:height:operation:cpuMsPerMP:) on the result just after. It records whether the CPU was warm when
    /// the job started (a job makes the CPU warm by its end, so asking afterwards files cold jobs as warm). No GPU
    /// or Metal work: a CPU-only path can use it.
    public func beginCPUWork() -> CPUWork { CPUWork(profile: self, startedWarm: WarmthTracker.current(deviceRead: false, moveWindow: false).cpuWarm, t0: LoadCorrection.realClock()) }
    /// A CPU job being timed (beginCPUWork()).
    public struct CPUWork: Sendable {
        let profile: DeviceProfile
        /// whether the CPU was warm when the job started
        public let startedWarm: Bool
        let t0: Double
        /// The job is done: one load-correction sample against the prediction at the warm rate `cpuMsPerMP` (the
        /// rate you pass to prefersCPU; default the same defaults), cold from cpuColdModel when the CPU started
        /// cold. Also does what noteCPUWork() does.
        public func end(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil) {
            profile.noteCPUWork(milliseconds: (LoadCorrection.realClock() - t0) * 1000, width: width, height: height,
                                operation: operation, cpuMsPerMP: cpuMsPerMP, startedWarm: startedWarm)
        }
    }
    /// The same sample from your own timing: `milliseconds` for a width x height job that started with the CPU
    /// warm or not (`startedWarm`, taken before the job: currentWarmth.cpuWarm). Also does what noteCPUWork() does.
    public func noteCPUWork(milliseconds: Double, width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil,
                            startedWarm: Bool) {
        WarmthTracker.noteCPU()
        let mp = Double(max(width, 0)) * Double(max(height, 0)) / 1e6
        let rate = cpuMsPerMP ?? (operation == .decode ? DeviceProfile.defaultCPUDecodeMsPerMP : DeviceProfile.defaultCPUEncodeMsPerMP)
        let warmMs = mp * rate
        let predicted = startedWarm ? warmMs : cpuColdModel.coldMs(warmMs: warmMs)
        LoadCorrection.add(LoadCorrection.key(registryID, cpu: true, operation, state: startedWarm ? 1 : 0, megapixels: mp),
                           observedMs: milliseconds, predictedMs: predicted)
    }
    /// The load correction prefersCPU applies for one kind of call on this profile's device: observed / predicted
    /// for recent calls of that kind (gpu, cpu), 1 when there are none. Kinds are side, operation, the state the call
    /// starts in (GPU cold or warm; CPU cold or warm) and the size (under or at least 1 MP); the sustained GPU set
    /// is not corrected (overlapping calls are never samples). No factor applies until this device's caller has
    /// reported a timed CPU job (beginCPUWork / noteCPUWork(milliseconds:...)), or while loadCorrectionEnabled is
    /// false. Factors fade back to 1 (half-life loadCorrectionHalfLife seconds, sleep included) and range 0.625x-3.2x.
    public struct LoadFactors: Equatable, Sendable, CustomStringConvertible {
        public var gpu: Double, cpu: Double
        public init(gpu: Double, cpu: Double) { self.gpu = gpu; self.cpu = cpu }
        public var description: String { String(format: "GPU %.2fx, CPU %.2fx", gpu, cpu) }
    }
    public func loadFactors(width: Int, height: Int, operation: Operation, gpuSet: GPUSet, cpuWarm: Bool) -> LoadFactors {
        let mp = Double(max(width, 0)) * Double(max(height, 0)) / 1e6
        let g = gpuSet == .sustained ? 1 : LoadCorrection.factor(LoadCorrection.key(registryID, cpu: false, operation, state: gpuSet == .warm ? 1 : 0, megapixels: mp))
        return LoadFactors(gpu: g, cpu: LoadCorrection.factor(LoadCorrection.key(registryID, cpu: true, operation, state: cpuWarm ? 1 : 0, megapixels: mp)))
    }
    /// Load awareness on or off for the whole process (the load correction and other processes' GPU use): on by
    /// default, off when the environment has EJM_LOAD_CORRECTION=0. Off, every factor is 1. Advice only.
    public static var loadCorrectionEnabled: Bool {
        get { LoadCorrection.isEnabled }
        set { LoadCorrection.isEnabled = newValue }
    }
    /// seconds for a load-correction factor to fade halfway back to 1 without new samples
    public static let loadCorrectionHalfLife = LoadCorrection.halfLife
    /// The GPU's and the CPU's warmth now (what prefersCPU uses when `sustained` / `cpuWarm` are nil).
    public static var currentWarmth: Warmth { WarmthTracker.current() }

    public let gpuName: String
    public let family: Family
    public let gpuCores: Int
    /// true when gpuCores is an estimate (iOS cannot read it; see API.md)
    public let gpuCoresEstimated: Bool
    public let recommendedMaxWorkingSetSize: UInt64
    /// performance-core count (macOS: hw.perflevel0.physicalcpu). On iOS this is activeProcessorCount, all cores
    /// including efficiency cores, and cpuCoresIncludeEfficiency is true.
    public let cpuPerformanceCores: Int
    public let cpuCoresIncludeEfficiency: Bool
    /// the encoder's default path: twoPass on Apple9 and later, fused before
    public let encoderPath: EncoderPath
    /// images worth keeping in flight at once (one Decoder or Encoder per thread): more gives no more throughput
    public let suggestedInFlight: Int
    /// the decoder's default memory budget (half the working set), Decoder.maxGPUBytes when that is nil
    public let maxGPUBytes: Int
    /// the sustained (warm GPU) routing: an estimate from the core count (measured = false), calibrated on warm
    /// measurements of an M4 and an M1 Max; never measured at run time. Also the yardstick of the sporadic
    /// measurement's plausibility check.
    public let estimatedRouting: Routing
    /// the sporadic (cold GPU) routing until it is measured: the cold ramp fitted to two isolated calls at the
    /// M4's ratios of cold to sustained time (see sporadicEstimate), so on an M4 the M4 fit
    public let estimatedSporadicRouting: Routing

    let registryID: UInt64
    fileprivate let lock = NSLock()
    private var current: Routing                // sporadic
    private var source: RoutingSource = .estimate
    private var pinned: Routing?, pinnedSustained: Routing?
    private var cpuModel: CPUColdModel?, pinnedCPU: CPUColdModel?
    private var cpuFailure: String?             // why the last CPU proxy fit was not used
    private enum Phase { case idle, running, settled }
    private var phase = Phase.idle
    private var attempt = DispatchGroup()       // the current first attempt; left when it settles or defers
    private var deferredAt: Date?               // the last busy gate (first measurement or re-measure)
    private var pendingEntry: DeviceProfileCache.Entry?   // a cached entry whose daily re-measure was deferred
    private var remeasureRunning = false
    private var lastGateSample: IdleSample?
    private var lastFailure: String?            // why the last attempt was deferred or its result not used
    private(set) var gateChecks = 0
    let remeasuring = DispatchGroup()           // a daily re-measure of a cached entry, while it runs
    static let retryAfterBusy: TimeInterval = 600

    init(name: String, registryID: UInt64, family: Family, gpuCores: Int, gpuCoresEstimated: Bool, workingSet: UInt64,
         cpuCores: Int, cpuCoresIncludeEfficiency: Bool) {
        gpuName = name; self.registryID = registryID; self.family = family
        self.gpuCores = max(gpuCores, 1); self.gpuCoresEstimated = gpuCoresEstimated
        recommendedMaxWorkingSetSize = workingSet
        cpuPerformanceCores = cpuCores; self.cpuCoresIncludeEfficiency = cpuCoresIncludeEfficiency
        encoderPath = DeviceProfile.encoderPath(family)
        maxGPUBytes = DeviceProfile.gpuBudget(workingSet)
        suggestedInFlight = DeviceProfile.inFlight(gpuCores: self.gpuCores, workingSet: workingSet)
        estimatedRouting = DeviceProfile.estimate(gpuCores: self.gpuCores, coresEstimated: gpuCoresEstimated)
        estimatedSporadicRouting = DeviceProfile.sporadicEstimate(estimatedRouting, ios: gpuCoresEstimated)
        current = estimatedSporadicRouting
    }

    // MARK: layer 1 rules

    /// Fused against two-pass, GPU time per encode (2026-11-17): M1 Max (Apple7, 32 cores) fused 43% faster at
    /// 1500x1000; M4 (Apple9, 8 cores) fused 11-23% slower at every size and batch; iPhone 13 (Apple8) within
    /// -6...+15%. So two-pass on Apple9 and later.
    static func encoderPath(_ f: Family) -> EncoderPath { f >= .apple9 ? .twoPass : .fused }

    /// half the GPU working set (the decoder's default budget)
    @inline(__always) static func gpuBudget(_ workingSet: UInt64) -> Int { Int(Double(workingSet) * 0.5) }

    /// Images in flight (one Decoder or Encoder per thread, `ejm inflight`, 30 MP decode and 3840x2560 encode):
    /// decode is flat from 2 to 8 on the M4 (8 cores) and the M1 Max (32 cores); encode gains a little past 2 on
    /// both (M4 two-pass 157, 218, 230/s at 1, 2, 3, flat after; M1 Max 4-9% above 2). Two overlap one image's host
    /// work with another's GPU work, a third keeps an encoder's queue full. So 3 with at least 8 GB of working set,
    /// else 2; the core count does not predict more (see API.md for the M1 Max table). Capped by memory.
    static let largeWorkingSet: UInt64 = 8 << 30
    /// working set one large image in flight may need: a 30 MP decode uses about 4 x 90 MB of buffers
    static let bytesPerImageInFlight = 360 << 20

    static func inFlight(gpuCores: Int, workingSet: UInt64) -> Int {
        let want = workingSet >= largeWorkingSet ? 3 : 2
        let byMemory = gpuBudget(workingSet) / bytesPerImageInFlight
        return max(min(want, byMemory), 1)
    }

    /// The sustained routing, from the core count; the sporadic measurement's plausibility yardstick. Mac (core
    /// count read): the M4's warm measurement (8 cores: decode 1.33 ms + 0.50 ms/MP, encode 0.29 ms + 0.56 ms/MP),
    /// the per-MP cost scaled by (8 / cores)^0.25: small images do not fill a large GPU. The M1 Max (32 cores) settled
    /// warm once at decode 1.105 ms + 0.299 ms/MP, encode 0.227 ms + 0.382 ms/MP; this gives 1.33 + 0.354 and
    /// 0.29 + 0.396 there. Fixed costs are not scaled. Cold start 9.6 ms (M4, first call after 5 s idle). iOS (core
    /// count estimated): the iPhone 13 (A15, 4 cores) with two decoders or two encoders kept busy, wall ms per image,
    /// the minimum over three runs on 2026-11-18 from 0.07 to 3.2 MP (least squares): decode 0.81 ms + 0.80 ms/MP
    /// (within 15% from 0.23 to 3.1 MP), encode 1.13 ms + 1.20 ms/MP (its small sizes scatter up to 50% about the
    /// line, but the line puts each size on the same side of the default CPU rate as the measurement); cold start
    /// 8.5 ms (its measured first call). The earlier 2.9 + 1.0 and 2.5 + 1.2 came from single calls in the slow clock
    /// state and were 2.2 to 2.7x too high.
    static func estimate(gpuCores: Int, coresEstimated: Bool) -> Routing {
        let s = pow(8.0 / Double(max(gpuCores, 1)), 0.25)
        let si = pow(4.0 / Double(max(gpuCores, 1)), 0.25)
        return coresEstimated
            ? Routing(decodeFixedMs: 0.81, decodeMsPerMP: 0.80 * si, encodeFixedMs: 1.13, encodeMsPerMP: 1.20 * si, coldStartMs: 8.5, measured: false)
            : Routing(decodeFixedMs: 1.33, decodeMsPerMP: 0.50 * s, encodeFixedMs: 0.29, encodeMsPerMP: 0.56 * s, coldStartMs: 9.6, measured: false)
    }

    /// The M4's isolated (GPU cold) calls, ms, against its sustained estimate (decode 1.33 + 0.50 ms/MP, encode
    /// 0.29 + 0.56): 256x256 decode 4.1, 1600x1200 decode 7.5; encode 1.5 and 6.0 (5.6-6.4). Their ratios to the
    /// sustained times give the sporadic estimate on any device.
    static let m4IsolatedMs = (decodeSmall: 4.1, decodeLarge: 7.5, encodeSmall: 1.5, encodeLarge: 6.0)
    static let m4Sustained = Routing(decodeFixedMs: 1.33, decodeMsPerMP: 0.50, encodeFixedMs: 0.29, encodeMsPerMP: 0.56, coldStartMs: 9.6, measured: false)
    /// The iPhone 13's (A15) isolated calls, ms: its four accepted routing measurements on 2026-11-18 evaluated at
    /// 256x256 and 1600x1200, medians (decode 7.3-7.6 and 13.9-18.6, encode 1.9-2.3 and 8.6-15.3); with its
    /// sustained estimate they give the sporadic estimate on iOS. Its slow clock state costs far more than the
    /// M4's (decode 8.7x and 6.1x sustained, against 3.0x and 3.3x), so the M4's ratios understated it there.
    static let a15IsolatedMs = (decodeSmall: 7.5, decodeLarge: 14.4, encodeSmall: 2.1, encodeLarge: 12.1)
    static let a15Sustained = Routing(decodeFixedMs: 0.81, decodeMsPerMP: 0.80, encodeFixedMs: 1.13, encodeMsPerMP: 1.20, coldStartMs: 8.5, measured: false)

    /// sporadic estimate: the cold ramp (coldFit) through a 256x256 and a 1600x1200 call that take the M4's ratio of
    /// isolated to sustained time (decode 3.01x and 3.28x, encode 4.59x and 4.40x)
    static func sporadicEstimate(_ r: Routing, ios: Bool = false) -> Routing {
        let mpS = RoutingMeasurement.smallMP, mpL = RoutingMeasurement.largeMP
        let m = ios ? a15Sustained : m4Sustained, i = ios ? a15IsolatedMs : m4IsolatedMs
        func at(_ u: Routing, _ mp: Double, _ op: Operation) -> Double { u.gpuMs(megapixels: mp, operation: op) }
        let d = coldFit(small: i.decodeSmall / at(m, mpS, .decode) * at(r, mpS, .decode), large: i.decodeLarge / at(m, mpL, .decode) * at(r, mpL, .decode),
                        fixedFloor: r.decodeFixedMs, sustainedMsPerMP: r.decodeMsPerMP)
        let e = coldFit(small: i.encodeSmall / at(m, mpS, .encode) * at(r, mpS, .encode), large: i.encodeLarge / at(m, mpL, .encode) * at(r, mpL, .encode),
                        fixedFloor: r.encodeFixedMs, sustainedMsPerMP: r.encodeMsPerMP)
        return Routing(decodeFixedMs: d.fixedMs, decodeMsPerMP: d.msPerMP, encodeFixedMs: e.fixedMs, encodeMsPerMP: e.msPerMP,
                       coldStartMs: r.coldStartMs, measured: false, decodeRampMs: d.ramp?.rampMs, decodeWarmMsPerMP: d.ramp?.warmMsPerMP,
                       encodeRampMs: e.ramp?.rampMs, encodeWarmMsPerMP: e.ramp?.warmMsPerMP)
    }

    /// The cold GPU's ramp as a multiple of the excess a 1600x1200 call shows over the sustained per-MP cost (the
    /// M4: 2.5 reproduces its isolated 2.8, 9.8 and 30 MP calls within 20%; see API.md "Sporadic routing").
    static let gpuRampRatio = 2.5
    /// The cold GPU's cost of one operation from an isolated small (256x256) and large (1600x1200) call and the
    /// sustained per-MP cost w: fixed + w x MP + ramp x (1 - exp(-a x MP / ramp)), through both calls, with ramp =
    /// gpuRampRatio x D, D = large - small - w x (1.92 - 0.066 MP) the excess the large call shows. Since the ramp is
    /// a multiple of D, a / ramp is the same for every device (it solves e^(-y 0.066) - e^(-y 1.92) = 1 / ratio).
    /// Degenerate (D under 0.05 ms: no excess to ramp, or the large call faster than the line allows): the old
    /// straight line, slope (large - small) / 1.86 MP held between w and maxSlopeRatio x w. The fixed cost is never
    /// below `fixedFloor`.
    static func coldFit(small s: Double, large l: Double, fixedFloor: Double, sustainedMsPerMP w: Double)
        -> (fixedMs: Double, msPerMP: Double, ramp: (rampMs: Double, warmMsPerMP: Double)?) {
        let mpS = RoutingMeasurement.smallMP, mpL = RoutingMeasurement.largeMP
        let d = l - s - w * (mpL - mpS)
        if d >= 0.05, let y = rampDecay(gpuRampRatio) {
            let r = gpuRampRatio * d, slope = w + y * r
            return (max(s - w * mpS - r * (1 - exp(-y * mpS)), fixedFloor), slope, (r, w))
        }
        let slope = min(max((l - s) / (mpL - mpS), w), RoutingMeasurement.maxSlopeRatio * w)
        return (max(s - mpS * slope, fixedFloor), slope, nil)
    }
    /// y with e^(-y 0.066) - e^(-y 1.92) = 1 / ratio, on the rising side (nil: none, ratio too small)
    static func rampDecay(_ ratio: Double) -> Double? {
        let mpS = RoutingMeasurement.smallMP, mpL = RoutingMeasurement.largeMP
        let top = log(mpL / mpS) / (mpL - mpS), t = 1 / ratio
        func g(_ y: Double) -> Double { exp(-y * mpS) - exp(-y * mpL) }
        guard ratio > 1, g(top) >= t else { return nil }
        var lo = 0.0, hi = top
        for _ in 0..<80 { let m = (lo + hi) / 2; if g(m) < t { lo = m } else { hi = m } }
        return (lo + hi) / 2
    }

    /// the warm set from a cold and a sustained one: the sustained per-MP costs, gpuWarmFixedFraction x the cold
    /// fixed costs (never below the sustained ones)
    static func warm(cold c: Routing, sustained u: Routing) -> Routing {
        let f = gpuWarmFixedFraction
        return Routing(decodeFixedMs: max(u.decodeFixedMs, f * c.decodeFixedMs), decodeMsPerMP: u.decodeMsPerMP,
                       encodeFixedMs: max(u.encodeFixedMs, f * c.encodeFixedMs), encodeMsPerMP: u.encodeMsPerMP,
                       coldStartMs: c.coldStartMs, measured: c.measured)
    }

    /// iOS cannot read the GPU core count: a conservative estimate from the family and the working set. Apple
    /// silicon iPads (more than 5 GB of working set) 8; Apple9 phones (A17 Pro, A18) 5; Apple7 / Apple8 phones
    /// (A14, A15, A16) 4, the smallest of those GPUs.
    static func estimatedCores(family: Family, workingSet: UInt64) -> Int {
        if workingSet > 5_000_000_000 { return 8 }
        return family >= .apple9 ? 5 : 4
    }

    // MARK: routing

    /// The sporadic routing numbers, the cold GPU (single calls with the GPU idle in between): pinned, else
    /// measured (now or from the cache), else estimatedSporadicRouting. Same as `routing`.
    public var sporadicRouting: Routing { lock.lock(); defer { lock.unlock() }; return pinned ?? current }
    /// the sporadic set (see sporadicRouting)
    public var routing: Routing { sporadicRouting }
    /// The sustained routing numbers (2 or more jobs in flight, the GPU kept fed and warm): pinned, else
    /// estimatedRouting (never measured at run time).
    public var sustainedRouting: Routing { lock.lock(); defer { lock.unlock() }; return pinnedSustained ?? estimatedRouting }
    public var routingSource: RoutingSource { lock.lock(); defer { lock.unlock() }; return pinned != nil ? .pinned : source }
    /// The warm GPU (this process used it within warmWindow, but it is not kept fed): sustainedRouting's per-MP
    /// costs plus gpuWarmFixedFraction x sporadicRouting's fixed costs.
    public var warmRouting: Routing { DeviceProfile.warm(cold: sporadicRouting, sustained: sustainedRouting) }
    /// The CPU cold model: pinned, else measured (now or from the cache), else defaultCPUColdModel.
    public var cpuColdModel: CPUColdModel { lock.lock(); defer { lock.unlock() }; return pinnedCPU ?? cpuModel ?? DeviceProfile.defaultCPUColdModel }
    /// Fix the CPU cold model (nil: back to measured or the default). Not saved.
    public func pinCPUColdModel(_ m: CPUColdModel?) { lock.lock(); pinnedCPU = m; lock.unlock() }

    /// Which GPU cost set a routing decision used: the cold GPU (sporadicRouting), the warm one (warmRouting) or
    /// the kept-fed one (sustainedRouting).
    public enum GPUSet: String, Sendable { case sporadic, warm, sustained }

    /// Everything behind one prefersCPU answer, for logging and diagnostics. Advice only: the decoder and the
    /// encoder always use the GPU when called.
    public struct RoutingDecision: Equatable, Sendable {
        /// the answer prefersCPU gives
        public var prefersCPU: Bool
        /// the predicted CPU time (cold when cpuCold) and the predicted GPU time for the chosen set, in ms
        public var predictedCPUms: Double, predictedGPUms: Double
        /// the GPU cost set used
        public var gpuSet: GPUSet
        /// the CPU was taken as cold (cpuColdModel applied to the warm rate)
        public var cpuCold: Bool
        /// the detected warmth (DeviceProfile.currentWarmth), when it was used: `sustained` nil; else nil
        public var warmth: Warmth?
        /// where the sporadic numbers came from (routingSource)
        public var source: RoutingSource
        /// the CPU was predicted faster, but by less than cpuPreferenceMargin, so the advice is the GPU
        public var marginApplied: Bool
        /// the load correction applied to both predictions (loadFactors at the time)
        public var loadFactors: LoadFactors
    }

    /// Advice: true when the caller's CPU codec is predicted to finish this image sooner than the GPU, given how
    /// warm each is. The library itself still uses the GPU when called; bytes are the same either way.
    /// `cpuMsPerMP`: the CPU codec's warm rate (default defaultCPUDecodeMsPerMP / defaultCPUEncodeMsPerMP); when the
    /// CPU is cold, cpuColdModel turns the warm time into the cold one, so pass a warm rate.
    /// `sustained`: true: the caller keeps 2 or more jobs in flight (sustainedRouting); false: the GPU is cold
    /// (sporadicRouting); nil (the default) follows this process's own GPU work: warmRouting if it used the GPU
    /// within warmWindow, else sporadicRouting.
    /// `cpuWarm`: true or false says whether the CPU is warm; nil (the default) is `sustained` when that is given
    /// (sustained: both warm; sporadic: both cold, as before), else follows noteCPUWork() and the process's CPU time.
    /// So only a call with both nil uses the detected warmth on both sides.
    /// The same as routingDecision(...).prefersCPU.
    public func prefersCPU(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil, sustained: Bool? = nil,
                           cpuWarm: Bool? = nil) -> Bool {
        routingDecision(width: width, height: height, operation: operation, cpuMsPerMP: cpuMsPerMP, sustained: sustained,
                        cpuWarm: cpuWarm).prefersCPU
    }

    /// The decision prefersCPU makes, with its inputs and predictions (same arguments and defaults). Advice only:
    /// the decoder and the encoder always use the GPU.
    public func routingDecision(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double? = nil,
                                sustained: Bool? = nil, cpuWarm: Bool? = nil) -> RoutingDecision {
        routingDecision(width: width, height: height, operation: operation, cpuMsPerMP: cpuMsPerMP, sustained: sustained,
                        cpuWarm: cpuWarm, warmth: { DeviceProfile.currentWarmth })
    }

    /// The same advice from a read-only snapshot of the warmth, which neither starts the background device reads
    /// nor moves the CPU-time window: for the trace line of a decode or encode, which is not a routing query
    func routingDecisionSnapshot(width: Int, height: Int, operation: Operation) -> RoutingDecision {
        routingDecision(width: width, height: height, operation: operation, cpuMsPerMP: nil, sustained: nil, cpuWarm: nil,
                        warmth: { WarmthTracker.current(moveWindow: false, startPolling: false) })
    }

    private func routingDecision(width: Int, height: Int, operation: Operation, cpuMsPerMP: Double?, sustained: Bool?,
                                 cpuWarm: Bool?, warmth: () -> Warmth) -> RoutingDecision {
        let mp = Double(max(width, 0)) * Double(max(height, 0)) / 1e6
        let cpuWarm = cpuWarm ?? sustained
        let auto = sustained == nil || cpuWarm == nil ? warmth() : nil
        let gpu: Routing, set: GPUSet
        switch sustained {
        case .some(true): gpu = sustainedRouting; set = .sustained
        case .some(false): gpu = sporadicRouting; set = .sporadic
        case .none: (gpu, set) = auto!.gpuWarm ? (warmRouting, .warm) : (sporadicRouting, .sporadic)
        }
        let rate = cpuMsPerMP ?? (operation == .decode ? DeviceProfile.defaultCPUDecodeMsPerMP : DeviceProfile.defaultCPUEncodeMsPerMP)
        let warmCPU = mp * rate
        let warm = cpuWarm ?? auto!.cpuWarm
        let lf = loadFactors(width: width, height: height, operation: operation, gpuSet: set, cpuWarm: warm)
        let cpu = (warm ? warmCPU : cpuColdModel.coldMs(warmMs: warmCPU)) * lf.cpu
        let gpuMs = gpu.gpuMs(megapixels: mp, operation: operation) * lf.gpu
        // near a crossover the measured winner flips from run to run (M4: cells within about 20% swapped sides
        // between identical runs), so the CPU must be predicted clearly faster; a tie goes to the GPU, which frees
        // the caller's CPU and keeps the GPU warm for the next call
        let prefers = cpu * (1 + DeviceProfile.cpuPreferenceMargin) < gpuMs
        return RoutingDecision(prefersCPU: prefers, predictedCPUms: cpu, predictedGPUms: gpuMs, gpuSet: set, cpuCold: !warm,
                               warmth: auto, source: routingSource, marginApplied: !prefers && cpu < gpuMs, loadFactors: lf)
    }

    /// Fix the routing numbers: `r` the sporadic set, `sustained` the sustained one (default: the same as `r`);
    /// nil: back to measured or estimated. Pinned numbers are not saved.
    public func pinRouting(_ r: Routing?, sustained: Routing? = nil) {
        lock.lock(); pinned = r; pinnedSustained = r == nil ? nil : (sustained ?? r); lock.unlock()
    }

    /// Waits up to `timeout` seconds for the background measurement (starting it if needed) and returns the
    /// measured sporadic numbers, or nil if it has not finished, failed, or is disabled. Cached and pinned numbers
    /// return at once.
    public func measuredRouting(timeout: Double) -> Routing? {
        startMeasurement(MetalContext.sharedIfAvailable.flatMap { $0.device.registryID == registryID ? $0 : nil })
        lock.lock()
        if let p = pinned { lock.unlock(); return p }
        let g = attempt
        lock.unlock()
        _ = g.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return current.measured ? current : nil
    }

    /// one line: everything this profile holds
    public var summary: String {
        let r = sporadicRouting, u = sustainedRouting, c = cpuColdModel
        return "\(gpuName), \(family), \(gpuCores) GPU cores\(gpuCoresEstimated ? " (estimated)" : ""), working set "
            + "\(recommendedMaxWorkingSetSize >> 20) MB, \(cpuPerformanceCores) \(cpuCoresIncludeEfficiency ? "CPU cores (all)" : "CPU performance cores"), "
            + "encoder \(encoderPath.rawValue), in flight \(suggestedInFlight), maxGPUBytes \(maxGPUBytes >> 20) MB; routing (\(routingSource.rawValue)): "
            + "sporadic (cold GPU) " + r.costDescription + String(format: ", cold start %.2f ms", r.coldStartMs)
            + String(format: "; sustained (%@) decode %.3f ms + %.3f ms/MP, encode %.3f ms + %.3f ms/MP",
                     (pinnedSustainedSet ? "pinned" : "estimate") as NSString, u.decodeFixedMs, u.decodeMsPerMP, u.encodeFixedMs, u.encodeMsPerMP)
            + (r.idleSample.map { "; measured idle (\($0.summary))" } ?? "")
            + (r.measured ? String(format: ", measurement %.0f ms wall, %.1f ms GPU", r.measurementMs, r.measurementGPUMs) : "")
            + String(format: "; CPU cold model (%@) ratio %.2f, ramp %.1f ms", (pinnedCPUSet ? "pinned" : c.measured ? "measured" : "default") as NSString,
                     c.ratio, c.rampMs)
            + (c.measured ? String(format: ", proxy %.1f ms CPU", c.measurementMs) : "")
            + (cpuFailureReason.map { " (proxy not used: \($0))" } ?? "")
            + (deferredSample.map { "; measurement deferred, busy (\($0.summary))" } ?? "")
            + (failureReason.map { "; measurement not used: \($0)" } ?? "")
    }

    private var pinnedCPUSet: Bool { lock.lock(); defer { lock.unlock() }; return pinnedCPU != nil }
    /// why the last CPU proxy fit was not used (nil: used, or not run)
    var cpuFailureReason: String? { lock.lock(); defer { lock.unlock() }; return cpuModel == nil ? cpuFailure : nil }

    private var pinnedSustainedSet: Bool { lock.lock(); defer { lock.unlock() }; return pinnedSustained != nil }

    /// why the last attempt's result was not used (implausible, our own GPU work, an output differed), while it stands
    var failureReason: String? { lock.lock(); defer { lock.unlock() }; return deferredAt != nil ? lastFailure : nil }
    /// Why the last routing measurement was not used (for example "implausible: cold encode fixed cost ..." or this
    /// process's own GPU work did not pause), while the estimate or the cached set stands because of it; nil when the
    /// last attempt was used or none has run. Also at the end of `summary`.
    public var measurementFailureReason: String? { failureReason }

    /// the busy sample of the last deferral, while a measurement is deferred
    var deferredSample: IdleSample? {
        lock.lock(); defer { lock.unlock() }
        guard let s = lastGateSample, !s.idle, deferredAt != nil else { return nil }
        return s
    }
    public var description: String { summary }

    /// a dictionary of every field (for benchmark JSON)
    public var dictionary: [String: Any] {
        let r = sporadicRouting, u = sustainedRouting, c = cpuColdModel
        return ["gpu": gpuName, "family": "\(family)", "gpu_cores": gpuCores, "gpu_cores_estimated": gpuCoresEstimated,
                "working_set_bytes": recommendedMaxWorkingSetSize, "cpu_cores": cpuPerformanceCores,
                "cpu_cores_include_efficiency": cpuCoresIncludeEfficiency, "encoder_path": encoderPath.rawValue,
                "suggested_in_flight": suggestedInFlight, "max_gpu_bytes": maxGPUBytes,
                "routing_source": routingSource.rawValue, "decode_fixed_ms": r.decodeFixedMs, "decode_ms_per_mp": r.decodeMsPerMP,
                "encode_fixed_ms": r.encodeFixedMs, "encode_ms_per_mp": r.encodeMsPerMP, "cold_start_ms": r.coldStartMs,
                "measured": r.measured, "measurement_ms": r.measurementMs, "measurement_gpu_ms": r.measurementGPUMs,
                "idle_sample": r.idleSample?.summary ?? "", "deferred_busy": deferredSample?.summary ?? "",
                "sustained_measured": u.measured, "sustained_decode_fixed_ms": u.decodeFixedMs, "sustained_decode_ms_per_mp": u.decodeMsPerMP,
                "sustained_encode_fixed_ms": u.encodeFixedMs, "sustained_encode_ms_per_mp": u.encodeMsPerMP,
                "decode_ramp_ms": r.decodeRampMs ?? 0, "decode_warm_ms_per_mp": r.decodeWarmMsPerMP ?? 0,
                "encode_ramp_ms": r.encodeRampMs ?? 0, "encode_warm_ms_per_mp": r.encodeWarmMsPerMP ?? 0,
                "cpu_cold_ratio": c.ratio, "cpu_ramp_ms": c.rampMs, "cpu_cold_measured": c.measured, "cpu_proxy_ms": c.measurementMs]
    }

    /// The profile of MetalContext.shared's device (reading it starts the measurement; see MetalContext.profile).
    public static var current: DeviceProfile { MetalContext.shared.profile }

    // MARK: measurement

    /// Starts the background measurement, unless the cache has the numbers (then a daily re-measure when due).
    /// Every measurement first samples how busy the device is; on a busy device it is deferred and tried again on
    /// a later read, at most once every 10 minutes. ctx: the context to time on (nil: a new one on the device).
    func startMeasurement(_ ctx: MetalContext?) {
        lock.lock()
        let retryOK = deferredAt.map { DeviceProfileCache.clock().timeIntervalSince($0) >= DeviceProfile.retryAfterBusy } ?? true
        switch phase {
        case .running:
            lock.unlock(); return
        case .settled:
            guard let e = pendingEntry, !remeasureRunning, retryOK else { lock.unlock(); return }
            remeasureRunning = true; remeasuring.enter()
            lock.unlock()
            launchRemeasure(e, ctx)
            return
        case .idle:
            guard retryOK else { lock.unlock(); return }
            phase = .running
            attempt = DispatchGroup(); attempt.enter()
            lock.unlock()
        }
        let key = cacheKey
        if let entry = DeviceProfileCache.loadEntry(key: key) {
            settle(entry.routing, entry.cpu ?? DeviceProfileCache.loadCPU(key: key), .cache, save: false)
            if DeviceProfileCache.remeasureDue(entry, now: DeviceProfileCache.clock()) {
                // once a day at most: re-measure in the background and keep the best of old and new
                lock.lock(); remeasureRunning = true; remeasuring.enter(); lock.unlock()
                launchRemeasure(entry, ctx)
            }
            return
        }
        if let c = DeviceProfileCache.loadCPU(key: key) { lock.lock(); cpuModel = c; lock.unlock() }   // a CPU model kept on its own
        DispatchQueue.global(qos: .utility).async { [self] in
            guard gate() else {
                lock.lock(); phase = .idle; let g = attempt; lock.unlock()
                g.leave()
                return
            }
            let out = measure(ctx)
            if var r = out.sporadic {
                r.idleSample = lastSample()
                lock.lock(); cpuFailure = out.cpuReason; let kept = cpuModel; lock.unlock()
                settle(r, out.cpu ?? kept, .measured, save: true)
            } else {
                // GPU part not used: keep the estimate, cache no routing, retry at the next allowed time; a
                // CPU fit that worked is kept and saved on its own
                if let c = out.cpu { DeviceProfileCache.saveCPU(c, key: key) }
                lock.lock()
                if let c = out.cpu { cpuModel = c }
                cpuFailure = out.cpuReason
                lastFailure = out.reason ?? "no Metal context"; deferredAt = DeviceProfileCache.clock(); phase = .idle
                let g = attempt
                lock.unlock()
                g.leave()
            }
        }
    }

    /// the measurement on ctx (nil: a new context on this profile's device)
    private func measure(_ ctx: MetalContext?) -> RoutingMeasurement.Outcome {
        guard let c = ctx ?? DeviceProfile.device(registryID).flatMap({ try? MetalContext(device: $0) }) else {
            return RoutingMeasurement.Outcome(reason: "no Metal context")
        }
        return RoutingMeasurement.run(c, estimate: estimatedRouting)
    }

    /// samples how busy the device is (about 100 ms); false, and the deferral recorded, when busy
    /// First waits (up to 3 s) until this process has had no GPU work for 1 s (Device Utilization % covers the time since the previous read, so a read soon after our work still shows it), so its own self-check or
    /// warm-up does not read as a busy GPU; if none of our work started while sampling, the sample decides.
    func gate() -> Bool {
        let quiet = GPUActivity.waitForQuiet(quiet: GPUActivity.quietSeconds, timeout: GPUActivity.quietTimeout)
        let sampleStart = GPUActivity.now()
        let s = quiet ? IdleSampler.sample(registryID) : nil
        let ours = !quiet || GPUActivity.workSince(sampleStart)      // our own work started while sampling
        lock.lock(); defer { lock.unlock() }
        gateChecks += 1
        if let s { lastGateSample = s }
        if let s, s.idle, !ours { deferredAt = nil; lastFailure = nil; return true }
        deferredAt = DeviceProfileCache.clock()
        lastFailure = s == nil || ours ? "this process's own GPU work did not pause for 1 s within 3 s" : nil
        if s == nil || ours { lastGateSample = nil }
        return false
    }
    private func lastSample() -> IdleSample? { lock.lock(); defer { lock.unlock() }; return lastGateSample }

    private func launchRemeasure(_ entry: DeviceProfileCache.Entry, _ ctx: MetalContext?) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard gate() else {
                lock.lock(); pendingEntry = entry; remeasureRunning = false; lock.unlock()
                remeasuring.leave()
                return
            }
            let out = measure(ctx)
            var r = out.sporadic
            r?.idleSample = lastSample()
            if r == nil { lock.lock(); lastFailure = out.reason ?? "no Metal context"; lock.unlock() }
            lock.lock(); cpuFailure = out.cpuReason; lock.unlock()
            remeasured(entry, r, out.cpu)
            lock.lock(); pendingEntry = nil; remeasureRunning = false; lock.unlock()
            remeasuring.leave()
        }
    }

    static func device(_ id: UInt64) -> MTLDevice? {
        #if os(macOS)
        return MTLCopyAllDevices().first { $0.registryID == id }
        #else
        return MTLCreateSystemDefaultDevice().flatMap { $0.registryID == id ? $0 : nil }
        #endif
    }

    /// a re-measure finished (fresh nil: it failed): merge, record the attempt, and switch to .measured
    private func remeasured(_ entry: DeviceProfileCache.Entry, _ fresh: Routing?, _ freshCPU: CPUColdModel?) {
        let now = DeviceProfileCache.iso(DeviceProfileCache.clock())
        var e = entry
        if let fresh {
            let merged = DeviceProfileCache.merge(entry.routing, fresh)
            let cpu = DeviceProfileCache.mergeCPU(entry.cpu, freshCPU)
            e = DeviceProfileCache.Entry(key: entry.key, routing: merged, written: now, merges: (entry.merges ?? 0) + 1,
                                         lastMeasured: now, lastAttempt: now, cpu: cpu)
            lock.lock(); current = merged; cpuModel = cpu; source = .measured; lock.unlock()
        } else {
            e.lastAttempt = now
            if let c = DeviceProfileCache.mergeCPU(entry.cpu, freshCPU), c != entry.cpu {   // a CPU fit without the GPU part
                e.cpu = c
                lock.lock(); cpuModel = c; lock.unlock()
            }
        }
        DeviceProfileCache.write(e)
    }

    /// the first attempt is over: these numbers, no further first attempts
    private func settle(_ r: Routing, _ cpu: CPUColdModel?, _ s: RoutingSource, save: Bool) {
        lock.lock()
        current = r; source = s; cpuModel = cpu
        phase = .settled
        let g = attempt
        lock.unlock()
        if save { DeviceProfileCache.save(r, cpu: cpu, key: cacheKey) }
        g.leave()
    }

    /// GPU name, family, core count, OS build, library version (with a hash of the shader source) and the routing
    /// format (v5: the sporadic set's measured cold fixed and per-MP costs with the cold ramp, and the CPU cold model;
    /// earlier files are ignored)
    var cacheKey: String { "\(gpuName)|\(family)|\(gpuCores)|\(osBuild)|\(libraryVersion)|routing-v5" }
}

/// keep in step with ExactJPEGC's ejm_version
let libraryVersion: String = {
    let h = SHA256.hash(data: Data((ShaderSource.common + ShaderSource.decode + ShaderSource.encode).utf8))
    return "0.1.0+" + h.prefix(6).map { String(format: "%02x", $0) }.joined()
}()

/// kern.osversion, e.g. "26B123"
let osBuild: String = {
    var buf = [CChar](repeating: 0, count: 64), n = 64
    return sysctlbyname("kern.osversion", &buf, &n, nil, 0) == 0
        ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "unknown build"
}()

/// Layer-1 profiles, one per device in the process.
final class DeviceProfileRegistry: @unchecked Sendable {
    static let shared = DeviceProfileRegistry()
    private let lock = NSLock()
    private var profiles: [UInt64: DeviceProfile] = [:]

    func profile(_ device: MTLDevice) -> DeviceProfile {
        lock.lock(); defer { lock.unlock() }
        if let p = profiles[device.registryID] { return p }
        let p = DeviceProfileRegistry.make(device)
        profiles[device.registryID] = p
        return p
    }

    static func make(_ d: MTLDevice) -> DeviceProfile {
        let family: DeviceProfile.Family = d.supportsFamily(.apple9) ? .apple9 : d.supportsFamily(.apple8) ? .apple8 : .apple7
        let ws = d.recommendedMaxWorkingSetSize
        var cores = readGPUCores(d), estimated = false
        if cores == nil { cores = DeviceProfile.estimatedCores(family: family, workingSet: ws); estimated = true }
        #if os(macOS)
        var n: Int32 = 0, sz = MemoryLayout<Int32>.size
        let perf = sysctlbyname("hw.perflevel0.physicalcpu", &n, &sz, nil, 0) == 0 && n > 0 ? Int(n) : nil
        let cpu = perf ?? ProcessInfo.processInfo.activeProcessorCount, all = perf == nil
        #else
        let cpu = ProcessInfo.processInfo.activeProcessorCount, all = true
        #endif
        return DeviceProfile(name: d.name, registryID: d.registryID, family: family, gpuCores: cores!, gpuCoresEstimated: estimated,
                             workingSet: ws, cpuCores: cpu, cpuCoresIncludeEfficiency: all)
    }

    /// macOS: the IORegistry entry of the device's accelerator (its registryID, else the first AGXAccelerator),
    /// property gpu-core-count. Unprivileged. iOS: nil.
    static func readGPUCores(_ d: MTLDevice) -> Int? {
        #if os(macOS)
        func cores(_ s: io_service_t) -> Int? {
            guard s != 0 else { return nil }
            defer { IOObjectRelease(s) }
            let v = IORegistryEntryCreateCFProperty(s, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            return (v as? NSNumber)?.intValue
        }
        if let c = cores(IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(d.registryID))), c > 0 { return c }
        if let c = cores(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))), c > 0 { return c }
        return nil
        #else
        return nil
        #endif
    }
}

/// This process's own GPU work, so the busy gate does not mistake it for someone else's: every Decoder and
/// Encoder submission brackets its command buffer with begin() and end() (two uncontended lock operations).
final class GPUActivity: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var lastBeginT = 0.0, lastEndT = 0.0
    /// this process's total GPU-busy seconds (time with at least one of its command buffers in flight)
    nonisolated(unsafe) private static var busyTotal = 0.0, busyFrom = 0.0
    static let quietSeconds = 1.0, quietTimeout = 3.0   // a utilization read covers the time since the previous one

    /// monotonic seconds (system uptime; not the wall clock, which can step)
    @inline(__always) static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    @inline(__always) static func begin() {
        let t = now(); lock.lock(); if inFlight == 0 { busyFrom = t }; inFlight += 1; lastBeginT = t; lock.unlock()
    }
    @inline(__always) static func end() {
        let t = now(); lock.lock(); inFlight -= 1; if inFlight == 0 { busyTotal += t - busyFrom }; lastEndT = t; lock.unlock()
    }
    /// this process's GPU-busy seconds so far (DeviceActivity subtracts them from the device's utilization)
    static func busySeconds() -> Double {
        let t = now(); lock.lock(); defer { lock.unlock() }
        return busyTotal + (inFlight > 0 ? t - busyFrom : 0)
    }

    /// seconds since our last command buffer completed (0 while one is in flight; large if none ever ran)
    static var quietFor: Double {
        lock.lock(); defer { lock.unlock() }
        return inFlight > 0 ? 0 : now() - lastEndT
    }
    /// commands in flight and when the last one completed (monotonic seconds, GPUActivity.now; 0: none yet), for
    /// the warmth tracker
    static func snapshot() -> (inFlight: Int, lastEnd: Double) {
        lock.lock(); defer { lock.unlock() }
        return (inFlight, lastEndT)
    }
    /// whether any of our work was in flight, started or finished at or after t
    static func workSince(_ t: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight > 0 || lastBeginT >= t || lastEndT >= t
    }
    /// waits until we have submitted no GPU work for `quiet` seconds; false if that does not happen in `timeout`
    static func waitForQuiet(quiet: Double, timeout: Double) -> Bool {
        let t0 = now()
        while true {
            let q = quietFor
            if q >= quiet { return true }
            let left = timeout - (now() - t0)
            if left <= 0 { return false }
            Thread.sleep(forTimeInterval: min(max(quiet - q, 0.01), left, 0.05))
        }
    }
}

/// How busy the device is right now (DeviceProfile.IdleSample).
enum IdleSampler {
    nonisolated(unsafe) static var override: (() -> DeviceProfile.IdleSample)?

    /// testing: replaces the IORegistry read of Device Utilization % (macOS), one value per call
    nonisolated(unsafe) static var readOverride: (() -> Int?)?

    static func sample(_ registryID: UInt64) -> DeviceProfile.IdleSample {
        if let o = override { return o() }
        #if os(macOS)
        // Device Utilization % covers the time since the previous read, so the first read after a quiet stretch
        // still reports the last busy period (on an M4, 48-89% read 1.2 s after GPU work, then 0-11%): it is
        // discarded, and the two reads after it are the sample
        let read = readOverride ?? { utilization(registryID) }
        _ = read()
        var u: [Int] = []
        Thread.sleep(forTimeInterval: 0.1)
        if let a = read() { u.append(a) }
        Thread.sleep(forTimeInterval: 0.1)
        if let b = read() { u.append(b) }
        var l = [Double](repeating: 0, count: 3)
        let load: Double? = getloadavg(&l, 3) >= 1 ? l[0] : nil
        return DeviceProfile.IdleSample(gpuUtilization: u, loadAverage: load, cpuCores: ProcessInfo.processInfo.activeProcessorCount)
        #else
        let pi = ProcessInfo.processInfo
        return DeviceProfile.IdleSample(gpuUtilization: [], loadAverage: nil, cpuCores: pi.activeProcessorCount,
                                        thermalSerious: pi.thermalState == .serious || pi.thermalState == .critical,
                                        lowPowerMode: pi.isLowPowerModeEnabled)
        #endif
    }

    #if os(macOS)
    /// PerformanceStatistics["Device Utilization %"] of the device's IORegistry entry (as for gpu-core-count)
    static func utilization(_ registryID: UInt64) -> Int? {
        for match in [IORegistryEntryIDMatching(registryID), IOServiceMatching("AGXAccelerator")] {
            let s = IOServiceGetMatchingService(kIOMainPortDefault, match)
            guard s != 0 else { continue }
            defer { IOObjectRelease(s) }
            if let d = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let v = (d["Device Utilization %"] as? NSNumber)?.intValue { return v }
        }
        return nil
    }
    #endif
}

extension MetalContext {
    /// This device's profile. The first read on a device starts the background routing measurement (unless the
    /// cache has it); Encoder uses the profile's layer-1 settings without starting it.
    public var profile: DeviceProfile {
        let p = DeviceProfileRegistry.shared.profile(device)
        p.startMeasurement(self)
        return p
    }
}

extension DeviceProfile {
    /// Deletes the saved routing measurements (every device). The next first read of a profile in a new process
    /// measures again.
    public static func clearCache() { DeviceProfileCache.clear() }
}

/// The routing cache: JSON files in the Caches directory (Library/Caches on iOS),
/// <caches>/exact-jpeg-metal/routing-<hash of key>.json. A missing, corrupt, stale or unwritable file only means
/// the estimate is used and the measurement runs; EJM_PROFILE_CACHE=0 disables reading and writing.
enum DeviceProfileCache {
    static let enabled = ProcessInfo.processInfo.environment["EJM_PROFILE_CACHE"] != "0"
    nonisolated(unsafe) static var directoryOverride: URL?
    static var directory: URL? {
        directoryOverride ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("exact-jpeg-metal")
    }
    /// key, routing, when the file was written; how many measurements were merged into it, when it was last
    /// measured and when a measurement was last tried (both ISO 8601). Files written before these three existed
    /// read as 0 merges, measured when written.
    struct Entry: Codable {
        let key: String; let routing: DeviceProfile.Routing; let written: String
        var merges: Int?; var lastMeasured: String?; var lastAttempt: String?
        /// the measured CPU cold model (nil: not measured, the default applies)
        var cpu: DeviceProfile.CPUColdModel? = nil
    }
    /// the clock the 24-hour gate reads (testing replaces it)
    nonisolated(unsafe) static var clock: () -> Date = { Date() }
    static let remeasureAfter: TimeInterval = 24 * 3600
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    /// a re-measure is due when the last attempt (else the last measurement, else the write) is 24 hours old or
    /// more, or its date cannot be read; never more than once a day, since every attempt is recorded
    static func remeasureDue(_ e: Entry, now: Date) -> Bool {
        guard let last = date(e.lastAttempt) ?? date(e.lastMeasured) ?? date(e.written) else { return true }
        return now.timeIntervalSince(last) >= remeasureAfter
    }
    /// field by field, the minimum of old and new costs, so a measurement made under load never makes the numbers
    /// worse; the measurement's own cost is the new one's
    /// (the cost rises with each of the fixed cost, both per-MP costs and the ramp, so the minimum of each is never
    /// above either; a set without a ramp, a straight line, keeps the other's ramp: a ramp never rises above its
    /// own straight start)
    static func merge(_ old: DeviceProfile.Routing, _ new: DeviceProfile.Routing) -> DeviceProfile.Routing {
        if !old.measured { return new }         // an unmeasured placeholder set
        func both(_ a: Double?, _ b: Double?) -> Double? { if let a, let b { return min(a, b) }; return a ?? b }
        return DeviceProfile.Routing(decodeFixedMs: min(old.decodeFixedMs, new.decodeFixedMs), decodeMsPerMP: min(old.decodeMsPerMP, new.decodeMsPerMP),
                              encodeFixedMs: min(old.encodeFixedMs, new.encodeFixedMs), encodeMsPerMP: min(old.encodeMsPerMP, new.encodeMsPerMP),
                              coldStartMs: min(old.coldStartMs, new.coldStartMs), measured: true,
                              measurementMs: new.measurementMs, measurementGPUMs: new.measurementGPUMs, idleSample: new.idleSample,
                              measurementRounds: new.measurementRounds,
                              decodeRampMs: both(old.decodeRampMs, new.decodeRampMs), decodeWarmMsPerMP: both(old.decodeWarmMsPerMP, new.decodeWarmMsPerMP),
                              encodeRampMs: both(old.encodeRampMs, new.encodeRampMs), encodeWarmMsPerMP: both(old.encodeWarmMsPerMP, new.encodeWarmMsPerMP))
    }

    /// the CPU cold model on a re-measure: the newer valid fit replaces the older one whole (ratio and ramp are
    /// fitted together; a pair from two runs is a model no run produced, and a bad fit is replaced the next day);
    /// nil keeps the other
    static func mergeCPU(_ old: DeviceProfile.CPUColdModel?, _ new: DeviceProfile.CPUColdModel?) -> DeviceProfile.CPUColdModel? {
        if let n = new, n.valid { return n }
        return old
    }

    /// A CPU cold model measured while the GPU part was not used (deferred to its own file, so it is kept): the
    /// key's file with "|cpu" appended. The next full measurement folds it into the routing entry.
    struct CPUEntry: Codable { let key: String; let cpu: DeviceProfile.CPUColdModel; let written: String }
    static func cpuKey(_ key: String) -> String { key + "|cpu" }
    static func loadCPU(key: String) -> DeviceProfile.CPUColdModel? {
        guard enabled, let f = file(cpuKey(key)), let d = try? Data(contentsOf: f),
              let e = try? JSONDecoder().decode(CPUEntry.self, from: d), e.key == cpuKey(key), e.cpu.valid, e.cpu.measured else { return nil }
        return e.cpu
    }
    static func saveCPU(_ c: DeviceProfile.CPUColdModel, key: String) {
        guard enabled, let dir = directory, let f = file(cpuKey(key)),
              let d = try? JSONEncoder().encode(CPUEntry(key: cpuKey(key), cpu: c, written: iso(clock()))) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: f, options: .atomic)
    }

    static func file(_ key: String) -> URL? {
        let h = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent("routing-\(h).json")
    }

    static func loadEntry(key: String) -> Entry? {
        guard enabled, let f = file(key), let d = try? Data(contentsOf: f),
              let e = try? JSONDecoder().decode(Entry.self, from: d), e.key == key, e.routing.valid, e.routing.measured,
              (e.merges ?? 0) >= 0, e.cpu?.valid ?? true else { return nil }
        return e
    }
    static func load(key: String) -> DeviceProfile.Routing? { loadEntry(key: key)?.routing }

    /// a first measurement (merges 0, measured and attempted now)
    static func save(_ r: DeviceProfile.Routing, cpu: DeviceProfile.CPUColdModel? = nil, key: String) {
        let now = iso(clock())
        write(Entry(key: key, routing: r, written: now, merges: 0, lastMeasured: now, lastAttempt: now, cpu: cpu))
    }

    static func write(_ e: Entry) {
        guard enabled, let dir = directory, let f = file(e.key) else { return }
        guard let d = try? JSONEncoder().encode(e) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: f, options: .atomic)
    }

    static func clear() {
        guard let dir = directory, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where n.hasPrefix("routing-") && n.hasSuffix(".json") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }
}

/// The background timing of the sporadic (cold GPU) set and the CPU cold model. GPU: isolated decodes and encodes
/// of a 256x256 SelfCheckTesting.pixels image (its JPEG made by the library's own encoder, q90 4:2:0), each after
/// at least 250 ms without this process's GPU work, 5 per operation interleaved (decode first, on a fresh decoder:
/// that one is coldStartMs), then one isolated 1600x1200 decode and one encode. The median of each operation's 5
/// small calls and its large call give the cold fixed and per-MP costs and the ramp (DeviceProfile.coldFit). Every decode is checked against a second
/// decoder's decode of the same file, every encode against the setup encode; any difference, decline or error
/// discards the measurement. CPU: after 250 ms more, one run of the CPU proxy (CPUProxy), fitted to the cold
/// model; a proxy that shows no ramp is not used (the default model stays) but does not discard the GPU numbers.
enum RoutingMeasurement {
    static let size = (256, 256), large = (1600, 1200)
    static let smallMP = Double(size.0 * size.1) / 1e6, largeMP = Double(large.0 * large.1) / 1e6
    /// isolated calls per operation, and the GPU idle before each
    static let calls = 5, idleBefore = 0.25
    /// plausible cold fixed cost: from minColdFixedMs (true of every device) to 20x the sustained estimate's fixed
    /// cost; cold per-MP cost: up to 20x the sustained one, else rejected. The lower bound is not the estimate: a
    /// per-chip estimate can be above the real cold cost (the iPhone 13's A15 encode: estimate 2.5 ms, measured 2.305).
    static let maxRatio = 20.0
    /// the smallest plausible cold fixed cost (one commit-and-wait of a 256x256 job): no Apple GPU completes a command
    /// buffer round trip faster (the fastest seen, the M4 sustained encode, is 0.29 ms), so below this the timing is broken
    static let minColdFixedMs = 0.05
    /// a degenerate fit's straight line (no excess to ramp; DeviceProfile.coldFit) has a per-MP cost between the
    /// sustained one and 4x it
    static let maxSlopeRatio = 4.0
    /// the chord (large - small) / 1.86 MP the ramp is fitted to is held to at most this x the sustained per-MP
    /// cost: one isolated call reads high when it lands behind other work (the M4: decode 3.7x, encode 4.3x)
    static let maxChordRatio = 6.0

    /// testing: the calls' wall times instead of GPU work
    nonisolated(unsafe) static var timingOverride: DeviceProfileTesting.MeasurementTimings?

    struct Outcome {
        var sporadic: DeviceProfile.Routing?
        /// nil when measured, else why not
        var reason: String?
        var decodeMs: [Double] = [], encodeMs: [Double] = []
        var decodeLargeMs: Double?, encodeLargeMs: Double?
        var wallMs = 0.0, gpuMs = 0.0
        var cpu: DeviceProfile.CPUColdModel?
        var cpuReason: String?
        var cpuChunksMs: [Double] = []
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// nil when each cold fixed cost lies between minColdFixedMs and maxRatio x the estimate's fixed cost, else why not
    static func implausible(decode d: Double, encode e: Double, _ est: DeviceProfile.Routing) -> String? {
        for (name, v, f) in [("decode", d, est.decodeFixedMs), ("encode", e, est.encodeFixedMs)] where !(v >= minColdFixedMs && v <= maxRatio * f) {
            return String(format: "implausible: cold %@ fixed cost %.3f ms is outside %.3f-%.3f ms (%.2f ms floor to %.0fx the sustained fixed cost)",
                          name as NSString, v, minColdFixedMs, maxRatio * f, minColdFixedMs, maxRatio)
        }
        return nil
    }

    /// the large call the ramp is fitted to: as timed, but its chord to the small median held to maxChordRatio x
    /// the sustained per-MP cost; not timed: the small median plus the estimate's rise from 0.066 to 1.92 MP;
    /// nil when the chord is over maxRatio x the sustained per-MP cost (rejected)
    static func largeForFit(small: Double, large: Double?, sustained: Double, estimateRise: Double) -> Double? {
        guard let large else { return small + estimateRise }
        let s = (large - small) / (largeMP - smallMP)
        guard s <= maxRatio * sustained else { return nil }
        return small + min(s, maxChordRatio * sustained) * (largeMP - smallMP)
    }

    static func run(_ ctx: MetalContext, estimate est: DeviceProfile.Routing) -> Outcome {
        let t0 = CFAbsoluteTimeGetCurrent()
        var out = Outcome()
        if let o = timingOverride {
            out.decodeMs = o.decode; out.encodeMs = o.encode
            out.decodeLargeMs = o.decodeLarge; out.encodeLargeMs = o.encodeLarge
            if let c = o.cpuChunks { out.cpuChunksMs = c } else { out.cpuReason = "not timed" }
        } else {
            if ctx.selfCheck() != nil { out.reason = "self-check failed"; return out }
            let (w, h) = size, (wl, hl) = large
            let enc = Encoder(ctx: ctx), check = Decoder(ctx: ctx)
            enc.internalUse = true; check.internalUse = true        // not traced: the trace would be timed too
            let px = SelfCheckTesting.pixels(width: w, height: h, channels: 3, rowBytes: w * 3)
            let pxl = SelfCheckTesting.pixels(width: wl, height: hl, channels: 3, rowBytes: wl * 3)
            func buffer(_ p: [UInt8]) -> MTLBuffer? {
                p.withUnsafeBytes { ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            }
            guard let buf = buffer(px), let bufl = buffer(pxl),
                  let jpeg = try? enc.encode(buffer: buf, width: w, height: h, quality: 90, subsampling: .s420) else {
                out.reason = "setup encode failed"; return out
            }
            var gpu = enc.gpuSeconds
            guard let jpegl = try? enc.encode(buffer: bufl, width: wl, height: hl, quality: 90, subsampling: .s420) else {
                out.reason = "setup encode failed"; return out
            }
            gpu += enc.gpuSeconds
            guard let refImg = check.decode(jpeg) else { out.reason = "setup decode failed"; return out }
            let ref = Data(refImg.bytes)
            gpu += check.gpuSeconds
            guard let refImgL = check.decode(jpegl) else { out.reason = "setup decode failed"; return out }
            let refl = Data(refImgL.bytes)
            gpu += check.gpuSeconds
            let dec = Decoder(ctx: ctx)
            dec.internalUse = true
            func quiet() -> Bool { GPUActivity.waitForQuiet(quiet: idleBefore, timeout: GPUActivity.quietTimeout) }
            let notQuiet = "this process's own GPU work did not pause for 250 ms within 3 s"
            for _ in 0..<calls {
                for op in 0..<2 {
                    guard quiet() else { out.reason = notQuiet; return out }
                    let tc = CFAbsoluteTimeGetCurrent()
                    if op == 0 {
                        let img = dec.decode(jpeg)
                        out.decodeMs.append((CFAbsoluteTimeGetCurrent() - tc) * 1000)
                        gpu += dec.gpuSeconds
                        if !(img.map { same($0, ref) } ?? false) { out.reason = "a decode differed"; return out }
                    } else {
                        let j = try? enc.encode(buffer: buf, width: w, height: h, quality: 90, subsampling: .s420)
                        out.encodeMs.append((CFAbsoluteTimeGetCurrent() - tc) * 1000)
                        gpu += enc.gpuSeconds
                        if j != jpeg { out.reason = "an encode differed"; return out }
                    }
                }
            }
            // the large calls (this decoder's first 1600x1200 decode may allocate larger buffers, as an app's first
            // large decode does)
            guard quiet() else { out.reason = notQuiet; return out }
            var tc = CFAbsoluteTimeGetCurrent()
            let imgl = dec.decode(jpegl)
            out.decodeLargeMs = (CFAbsoluteTimeGetCurrent() - tc) * 1000
            gpu += dec.gpuSeconds
            if !(imgl.map { same($0, refl) } ?? false) { out.reason = "a decode differed"; return out }
            guard quiet() else { out.reason = notQuiet; return out }
            tc = CFAbsoluteTimeGetCurrent()
            let jl = try? enc.encode(buffer: bufl, width: wl, height: hl, quality: 90, subsampling: .s420)
            out.encodeLargeMs = (CFAbsoluteTimeGetCurrent() - tc) * 1000
            gpu += enc.gpuSeconds
            if jl != jpegl { out.reason = "an encode differed"; return out }
            out.gpuMs = gpu * 1000
            // the CPU proxy, after 250 ms with nothing from this thread
            Thread.sleep(forTimeInterval: idleBefore)
            out.cpuChunksMs = CPUProxy.run()
        }
        out.wallMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if out.cpuReason == nil {
            let f = CPUProxy.fit(out.cpuChunksMs)
            out.cpu = f.model; out.cpuReason = f.reason
        }
        guard !out.decodeMs.isEmpty, !out.encodeMs.isEmpty else { out.reason = "no timings"; return out }
        let d = median(out.decodeMs), e = median(out.encodeMs)
        if let why = implausible(decode: d, encode: e, est) { out.reason = why; return out }
        let se = DeviceProfile.sporadicEstimate(est)
        func rise(_ op: DeviceProfile.Operation) -> Double { se.gpuMs(megapixels: largeMP, operation: op) - se.gpuMs(megapixels: smallMP, operation: op) }
        guard let dl = largeForFit(small: d, large: out.decodeLargeMs, sustained: est.decodeMsPerMP, estimateRise: rise(.decode)),
              let el = largeForFit(small: e, large: out.encodeLargeMs, sustained: est.encodeMsPerMP, estimateRise: rise(.encode)) else {
            out.reason = String(format: "implausible: cold per-MP cost over %.0fx the sustained one (1600x1200 decode %.2f ms, encode %.2f ms)",
                                maxRatio, out.decodeLargeMs ?? 0, out.encodeLargeMs ?? 0)
            return out
        }
        // the ramp through the small median and the large call (the fixed cost is the median less the small
        // image's 0.066 MP of per-MP work)
        // the fitted fixed costs are floored at minColdFixedMs, not at the estimate's (which can be above the real cost)
        let df = DeviceProfile.coldFit(small: d, large: dl, fixedFloor: minColdFixedMs, sustainedMsPerMP: est.decodeMsPerMP)
        let ef = DeviceProfile.coldFit(small: e, large: el, fixedFloor: minColdFixedMs, sustainedMsPerMP: est.encodeMsPerMP)
        let r = DeviceProfile.Routing(decodeFixedMs: df.fixedMs, decodeMsPerMP: df.msPerMP, encodeFixedMs: ef.fixedMs, encodeMsPerMP: ef.msPerMP,
                                      coldStartMs: out.decodeMs[0], measured: true, measurementMs: out.wallMs, measurementGPUMs: out.gpuMs,
                                      measurementRounds: min(out.decodeMs.count, out.encodeMs.count),
                                      decodeRampMs: df.ramp?.rampMs, decodeWarmMsPerMP: df.ramp?.warmMsPerMP,
                                      encodeRampMs: ef.ramp?.rampMs, encodeWarmMsPerMP: ef.ramp?.warmMsPerMP)
        if r.valid { out.sporadic = r } else { out.reason = "invalid timings" }
        return out
    }

    static func same(_ img: GPUImage, _ ref: Data) -> Bool {
        let b = img.bytes
        return b.count == ref.count && ref.withUnsafeBytes { memcmp($0.baseAddress!, b.baseAddress!, b.count) == 0 }
    }
}

/// The library's own stand-in for a CPU codec, to measure how the CPU's clock ramps up from idle: an integer
/// 8x8 DCT (libjpeg's islow butterflies, rows then columns) over 1024 blocks per chunk, run on a user-initiated
/// thread (the QoS a caller's codec runs at; utility work may land on efficiency cores) and timed chunk by chunk.
/// One run, started after 250 ms of idle, is one cold job read at every size: the time to the end of chunk j is
/// what a job of j chunks costs cold. The run goes on until its chunk times have dropped and settled (the clock
/// is up; the last 3 ms of chunks are the warm rate), or 20 ms without a drop (already warm: not used), or 50 ms.
/// The fit reads it at two sizes: the first 0.5 ms (a short job: ratio) and the whole run (rampMs).
enum CPUProxy {
    static let blocksPerChunk = 1024
    static let maxRunMs = 50.0, noRampMs = 20.0, settleMs = 3.0, smallMs = 0.5
    /// a drop of at least this much from the first chunks to the last counts as a ramp
    static let minSpeedup = 1.15
    /// the fastest decay per chunk the fit considers (a time constant of 5 chunks): a faster one is a few slow
    /// first chunks (thread start), not the clock
    static let maxDecay = 0.2
    /// a fit below minSpeedup or under this ramp is no ramp (a few preempted chunks)
    static let minRampMs = 1.0
    /// rampMs when the run shows no curvature (the penalty still growing linearly at its end)
    static let maxRampMs = 200.0
    /// the fitted warm chunk time is at least this fraction of the fastest smoothed chunk the run saw (a warm CPU is
    /// not much faster than the fastest sustained chunk it measured)
    static let warmFloor = 0.85
    nonisolated(unsafe) static var sink: Int32 = 0

    /// one 1-D islow pass over 8 values at stride s
    @inline(__always) static func pass(_ p: UnsafeMutablePointer<Int32>, _ s: Int) {
        let x0 = p[0], x1 = p[s], x2 = p[2 * s], x3 = p[3 * s], x4 = p[4 * s], x5 = p[5 * s], x6 = p[6 * s], x7 = p[7 * s]
        let t0 = x0 &+ x7, t7 = x0 &- x7, t1 = x1 &+ x6, t6 = x1 &- x6, t2 = x2 &+ x5, t5 = x2 &- x5, t3 = x3 &+ x4, t4 = x3 &- x4
        let t10 = t0 &+ t3, t13 = t0 &- t3, t11 = t1 &+ t2, t12 = t1 &- t2
        p[0] = (t10 &+ t11) &<< 2; p[4 * s] = (t10 &- t11) &<< 2
        let z1 = (t12 &+ t13) &* 4433
        p[2 * s] = (z1 &+ t13 &* 6270) >> 11; p[6 * s] = (z1 &- t12 &* 15137) >> 11
        let z5 = (t4 &+ t5 &+ t6 &+ t7) &* 9633
        p[s] = (t7 &* 12299 &+ z5) >> 11; p[3 * s] = (t6 &* 25172 &- z5) >> 11
        p[5 * s] = (t5 &* 16819 &+ z5) >> 11; p[7 * s] = (t4 &* 2446 &- z5) >> 11
    }

    /// one chunk: load each block from src, transform it, fold it into a checksum
    static func chunk(_ src: UnsafePointer<Int16>, _ blk: UnsafeMutablePointer<Int32>) -> Int32 {
        var acc: Int32 = 0
        for b in 0..<blocksPerChunk {
            let s = src + b * 64
            for i in 0..<64 { blk[i] = Int32(s[i]) }
            for r in 0..<8 { pass(blk + r * 8, 1) }
            for c in 0..<8 { pass(blk + c, 8) }
            for i in 0..<64 { acc = acc &+ (blk[i] ^ Int32(i)) }
        }
        return acc
    }

    /// the chunk times of one run, in ms (on a user-initiated thread; the caller waits)
    private final class Times: @unchecked Sendable { var v: [Double] = [] }   // written by the thread, read after done

    static func run() -> [Double] {
        let out = Times()
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            var rng: UInt32 = 0x1234_5678
            let src = UnsafeMutablePointer<Int16>.allocate(capacity: blocksPerChunk * 64)
            let blk = UnsafeMutablePointer<Int32>.allocate(capacity: 64)
            defer { src.deallocate(); blk.deallocate() }
            for i in 0..<(blocksPerChunk * 64) { rng = rng &* 1_664_525 &+ 1_013_904_223; src[i] = Int16(truncatingIfNeeded: Int32(rng >> 16) - 32768) >> 4 }
            var times: [Double] = []
            times.reserveCapacity(2048)
            var acc: Int32 = 0
            WarmthTracker.proxyBegin()
            defer { WarmthTracker.proxyEnd() }
            var last = DispatchTime.now().uptimeNanoseconds
            while true {
                acc = acc &+ chunk(src, blk)
                let now = DispatchTime.now().uptimeNanoseconds
                times.append(Double(now - last) / 1e6); last = now
                if stop(times) != nil { break }
            }
            sink = acc
            out.v = times
            done.signal()
        }
        t.qualityOfService = .userInitiated
        t.start()
        done.wait()
        return out.v
    }

    static func median(_ v: ArraySlice<Double>) -> Double { RoutingMeasurement.median(Array(v)) }
    /// each chunk time replaced by the median of the 9 around it: a preempted chunk (another thread ran) is not
    /// clock ramp
    static func smooth(_ d: [Double]) -> [Double] {
        d.indices.map { i in median(d[max(i - 4, 0)...min(i + 4, d.count - 1)]) }
    }
    /// chunks from the start covering at least ms
    static func head(_ d: [Double], _ ms: Double) -> Int { var s = 0.0; for (i, x) in d.enumerated() { s += x; if s >= ms { return i + 1 } }; return d.count }
    /// chunks from the end covering at least ms
    static func tail(_ d: [Double], _ ms: Double) -> Int { var s = 0.0; for (i, x) in d.reversed().enumerated() { s += x; if s >= ms { return i + 1 } }; return d.count }

    /// nil: keep going; else why the run is over: "settled", "no ramp", "cap"
    static func stop(_ d: [Double]) -> String? {
        let total = d.reduce(0, +)
        guard total >= smallMs + 2 * settleMs else { return nil }
        let early = median(d.prefix(head(d, smallMs)))
        let n = tail(d, settleMs), last = median(d.suffix(n))
        let before = median(d.dropLast(n).suffix(tail(Array(d.dropLast(n)), settleMs)))
        if early >= minSpeedup * last && abs(before - last) <= 0.03 * last { return "settled" }
        if total >= noRampMs && early < minSpeedup * last { return "no ramp" }
        return total >= maxRunMs ? "cap" : nil
    }

    /// k (ratio) and the saturated penalty (rampMs) from one run's chunk times
    static func fit(_ d: [Double]) -> (model: DeviceProfile.CPUColdModel?, reason: String?) {
        guard !d.isEmpty, d.allSatisfy({ $0.isFinite && $0 > 0 }) else { return (nil, "no proxy timings") }
        let total = d.reduce(0, +)
        let why = stop(d)
        let d = smooth(d)
        switch why {
        case "no ramp"?: return (nil, String(format: "no clock ramp seen in %.1f ms (the CPU was already warm)", total))
        case nil: return (nil, "proxy run too short")
        default: break
        }
        // Under the model a job's cold time is c(w) = w + P(1 - e^(-a w / P)), a = k - 1, so chunk j (warm u each)
        // takes u + P e^(-a j u / P)(1 - e^(-a u / P)): d_j = u + A e^(-l j). For each decay l the best u and A are
        // a linear least-squares fit; search l (log scale) for the least error. Every chunk counts, so the run need
        // not reach the warm rate exactly. In a run that settled (it reached its warm rate), the warm time u is held
        // at or above warmFloor x the fastest smoothed chunk: a weak ramp otherwise fits a slow decay towards u near
        // 0, and k = 1 + l P / u runs into the thousands. A run cut at the cap may still be ramping, so no floor.
        let uMin = why == "settled" ? warmFloor * (d.min() ?? 0) : 0
        func lsq(_ l: Double) -> (u: Double, A: Double, err: Double) {
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            let n = Double(d.count)
            for (j, y) in d.enumerated() { let x = exp(-l * Double(j)); sx += x; sy += y; sxx += x * x; sxy += x * y }
            let den = n * sxx - sx * sx
            guard abs(den) > 1e-12 else { return (0, 0, .infinity) }
            var A = (n * sxy - sx * sy) / den, u = (sy - A * sx) / n
            if u < uMin { u = uMin; A = (sxy - u * sx) / sxx }      // the best A with u fixed at the floor
            var err = 0.0
            for (j, y) in d.enumerated() { let r = y - u - A * exp(-l * Double(j)); err += r * r }
            return (u, A, err)
        }
        var best = (l: 0.0, u: 0.0, A: 0.0, err: Double.infinity)
        var lo = log(1e-5), hi = log(maxDecay)
        for _ in 0..<3 {                                        // a grid, then two finer grids around its best
            let steps = 60
            for i in 0...steps {
                let l = exp(lo + (hi - lo) * Double(i) / Double(steps)), f = lsq(l)
                if f.err < best.err, f.u > 0, f.A > 0 { best = (l, f.u, f.A, f.err) }
            }
            guard best.err.isFinite else { break }
            let span = (hi - lo) / Double(steps) * 2
            lo = max(log(best.l) - span, log(1e-5)); hi = min(log(best.l) + span, log(maxDecay))
        }
        guard best.err.isFinite else { return (nil, "no clock ramp seen") }
        let P = min(best.A / (1 - exp(-best.l)), maxRampMs), a = best.l * P / best.u
        let model = DeviceProfile.CPUColdModel(ratio: 1 + a, rampMs: P, measured: true, measurementMs: total)
        if model.ratio < minSpeedup || model.rampMs < minRampMs {
            return (nil, String(format: "no clock ramp seen (fit ratio %.2f, ramp %.2f ms in %.1f ms)", model.ratio, model.rampMs, total))
        }
        return model.valid ? (model, nil) : (nil, String(format: "implausible: ratio %.2f, ramp %.1f ms", model.ratio, model.rampMs))
    }

    /// testing: the chunk times a CPU following `model` exactly would give (chunkMs warm per chunk), up to stop()
    static func simulate(_ model: DeviceProfile.CPUColdModel, chunkMs u: Double) -> [Double] {
        var d: [Double] = []
        var j = 0.0
        repeat {
            d.append(model.rampedMs(warmMs: (j + 1) * u) - model.rampedMs(warmMs: j * u)); j += 1
        } while stop(d) == nil && d.count < 100_000
        return d
    }
}

/// When this process last used the CPU codec (noteCPUWork) and its CPU time, for DeviceProfile.currentWarmth.
/// The GPU side reads GPUActivity, which the codec already updates. Times are monotonic (GPUActivity.now); a clock
/// reading earlier than a stamp (only an injected clock can give one) reads as cold, not warm.
/// The process CPU time counts every thread of the process: other host-side work (the app's own, the GPU
/// codec's host side) reads as CPU activity too, but the library's own CPU proxy run does not (samples taken
/// while it runs are skipped and the window restarts after it).
enum WarmthTracker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastCPUNote = -Double.infinity
    nonisolated(unsafe) private static var ref: (t: Double, cpu: Double)?
    nonisolated(unsafe) private static var proxyRunning = 0
    /// testing: the clock (monotonic seconds), the process CPU time (seconds), the GPU activity
    nonisolated(unsafe) static var clock: () -> Double = { GPUActivity.now() }
    nonisolated(unsafe) static var cpuTime: () -> Double = processCPUSeconds
    nonisolated(unsafe) static var gpuOverride: (() -> (inFlight: Int, lastEnd: Double))?
    /// the process counts as keeping the CPU warm above this many cores
    static let busyCores = 0.5
    /// a CPU-time window counts from 0.05 s to warmWindow long; the reference restarts once older than that,
    /// and moves on once a window of half that has been read
    static let minWindow = 0.05

    static func processCPUSeconds() -> Double {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func noteCPU() { let t = clock(); lock.lock(); lastCPUNote = t; lock.unlock() }

    static func reset() { lock.lock(); lastCPUNote = -.infinity; ref = nil; proxyRunning = 0; lock.unlock() }

    /// the CPU proxy runs: CPU-time samples are skipped until it ends, then the window restarts
    static func proxyBegin() { lock.lock(); proxyRunning += 1; ref = nil; lock.unlock() }
    static func proxyEnd() { lock.lock(); proxyRunning = max(proxyRunning - 1, 0); ref = nil; lock.unlock() }

    /// moveWindow false: a read-only snapshot (the call path's; it must not move the CPU-time reference that a
    /// prefersCPU query reads)
    static func current(deviceRead: Bool = true, moveWindow: Bool = true, startPolling: Bool = true) -> DeviceProfile.Warmth {
        let now = clock(), cpu = cpuTime()
        let g = gpuOverride?() ?? GPUActivity.snapshot()
        let w = DeviceProfile.warmWindow
        lock.lock()
        var cores: Double?
        if proxyRunning == 0 {
            if let r = ref, now - r.t >= 0, now - r.t <= w {
                let age = now - r.t
                if age >= minWindow { cores = max(cpu - r.cpu, 0) / age }
                if age >= w / 2 && moveWindow { ref = (now, cpu) }
            } else if moveWindow {
                ref = (now, cpu)                     // none yet, older than warmWindow, or the clock went back
            }
        }
        let note = lastCPUNote
        lock.unlock()
        let gAge = g.lastEnd > 0 ? now - g.lastEnd : nil, cAge = note.isFinite ? now - note : nil
        let gpuIdle: Double? = g.inFlight > 0 ? 0 : gAge.flatMap { $0 >= 0 ? $0 : nil }
        let cpuIdle: Double? = cAge.flatMap { $0 >= 0 ? $0 : nil }
        let ownWarm = g.inFlight > 0 || (gpuIdle.map { $0 < w } ?? false)
        // not our own work, but another app's keeps the GPU clocked up too (macOS only; not with an injected GPU
        // state unless the device read is injected as well)
        let device: Int? = ownWarm || !deviceRead || !LoadCorrection.isEnabled || (gpuOverride != nil && DeviceActivity.override == nil)
            ? nil : DeviceActivity.percent(startPolling: startPolling)
        return DeviceProfile.Warmth(gpuWarm: ownWarm || (device.map { $0 >= DeviceActivity.warmPercent } ?? false),
                                    cpuWarm: (cpuIdle.map { $0 < w } ?? false) || (cores.map { $0 > busyCores } ?? false),
                                    gpuInFlight: g.inFlight > 0, gpuIdleSeconds: gpuIdle, cpuIdleSeconds: cpuIdle, processCPUCores: cores,
                                    deviceGPUPercent: device)
    }
}

/// Hooks for `ejm` (tests), not a stable interface.
@_spi(Testing) public enum DeviceProfileTesting {
    /// redirect the routing cache (nil: the Caches directory)
    public static var cacheDirectory: URL? {
        get { DeviceProfileCache.directoryOverride ?? DeviceProfileCache.directory }
        set { DeviceProfileCache.directoryOverride = newValue }
    }
    public static var cacheEnabled: Bool { DeviceProfileCache.enabled }
    public static func cacheFile(_ p: DeviceProfile) -> URL? { DeviceProfileCache.file(p.cacheKey) }
    public static func loadCache(_ p: DeviceProfile) -> DeviceProfile.Routing? { DeviceProfileCache.load(key: p.cacheKey) }
    public static func saveCache(_ r: DeviceProfile.Routing, _ p: DeviceProfile) { DeviceProfileCache.save(r, key: p.cacheKey) }
    /// a layer-1 profile computed afresh from this device's properties (not the shared one)
    public static func fresh(_ d: MTLDevice) -> DeviceProfile { DeviceProfileRegistry.make(d) }
    /// the layer-1 rules applied to given properties
    public static func derive(name: String, family: DeviceProfile.Family, gpuCores: Int?, workingSet: UInt64, cpuCores: Int) -> DeviceProfile {
        DeviceProfile(name: name, registryID: 0, family: family, gpuCores: gpuCores ?? DeviceProfile.estimatedCores(family: family, workingSet: workingSet),
                      gpuCoresEstimated: gpuCores == nil, workingSet: workingSet, cpuCores: cpuCores, cpuCoresIncludeEfficiency: false)
    }
    /// the clock of the 24-hour re-measure gate
    public static var clock: () -> Date {
        get { DeviceProfileCache.clock }
        set { DeviceProfileCache.clock = newValue }
    }
    /// field-by-field minimum, as a re-measure merges
    public static func merge(_ old: DeviceProfile.Routing, _ new: DeviceProfile.Routing) -> DeviceProfile.Routing { DeviceProfileCache.merge(old, new) }
    /// write a cache entry with the given merge count and dates
    public static func saveEntry(_ r: DeviceProfile.Routing, _ p: DeviceProfile, merges: Int, lastMeasured: Date, lastAttempt: Date? = nil) {
        DeviceProfileCache.write(DeviceProfileCache.Entry(key: p.cacheKey, routing: r, written: DeviceProfileCache.iso(lastMeasured), merges: merges,
                                                          lastMeasured: DeviceProfileCache.iso(lastMeasured),
                                                          lastAttempt: DeviceProfileCache.iso(lastAttempt ?? lastMeasured)))
    }
    /// a profile's cache entry: routing, merges, last measured, last attempt (nil: missing, corrupt or stale)
    public static func entry(_ p: DeviceProfile) -> (routing: DeviceProfile.Routing, merges: Int, lastMeasured: Date?, lastAttempt: Date?)? {
        DeviceProfileCache.loadEntry(key: p.cacheKey).map { ($0.routing, $0.merges ?? 0, DeviceProfileCache.date($0.lastMeasured), DeviceProfileCache.date($0.lastAttempt)) }
    }
    /// whether a re-measure is due for this profile's entry at the clock's time (nil: no valid entry)
    public static func remeasureDue(_ p: DeviceProfile) -> Bool? {
        DeviceProfileCache.loadEntry(key: p.cacheKey).map { DeviceProfileCache.remeasureDue($0, now: DeviceProfileCache.clock()) }
    }
    /// replace the busy sampler (nil: the real one)
    public static var idleSampler: (() -> DeviceProfile.IdleSample)? {
        get { IdleSampler.override }
        set { IdleSampler.override = newValue }
    }
    /// the load correction's clock (seconds; nil: the real one, monotonic including sleep)
    public static var loadCorrectionClock: (() -> Double)? {
        get { LoadCorrection.clockOverride }
        set { LoadCorrection.clockOverride = newValue }
    }
    /// forget every load-correction sample, and which devices reported CPU jobs
    public static func resetLoadCorrection() { LoadCorrection.reset() }
    /// how many load-correction samples were taken since the last reset
    public static var loadSampleCount: Int { LoadCorrection.sampleCount }
    /// one load-correction sample for this profile's device, as a finished call would add (state: 0 cold, 1 warm)
    public static func addLoadSample(_ p: DeviceProfile, cpu: Bool, _ op: DeviceProfile.Operation, state: Int, megapixels: Double,
                                     observedMs: Double, predictedMs: Double) {
        LoadCorrection.add(LoadCorrection.key(p.registryID, cpu: cpu, op, state: state, megapixels: megapixels), observedMs: observedMs, predictedMs: predictedMs)
    }
    /// other processes' GPU share from one read as DeviceActivity computes it (nil: this process was busy)
    public static func otherGPUPercent(devicePercent: Int, ownBusySeconds: Double) -> Int? {
        DeviceActivity.others(devicePercent: devicePercent, ownBusySeconds: ownBusySeconds)
    }
    /// replaces the counter read of the device-activity reads (one value per call; nil: the real one)
    public static var deviceActivityRead: (() -> Int?)? {
        get { DeviceActivity.readOverride }
        set { DeviceActivity.readOverride = newValue }
    }
    /// whether the background device-activity reads are running now
    public static var deviceActivityPolling: Bool { DeviceActivity.polling }
    /// stops the background device-activity reads and waits (up to 2 s) until they have; true when stopped
    public static func stopDeviceActivityPolling() -> Bool { DeviceActivity.stop(timeout: 2) }
    /// one public call as the decoder and encoder record it, without GPU work: start, optionally untracked work of
    /// this process (as an encode batch or a calibration call would run) or setup work inside it, then finish for a
    /// width x height decode taking `ms`; how many load samples it added (0 or 1)
    public static func simulateCall(_ d: MTLDevice, width: Int, height: Int, ms: Double, trackedInside: Bool = false,
                                    setupInside: Bool = false, overlappingCall: Bool = false) -> Int {
        let n0 = LoadCorrection.sampleCount
        let s = LoadCorrection.start()
        let other = overlappingCall ? LoadCorrection.start() : nil
        if trackedInside { LoadCorrection.track { } }
        if setupInside { SetupWork.bump() }
        Thread.sleep(forTimeInterval: ms / 1000)
        if let other { LoadCorrection.finish(other, gpu: .decode, d, width: nil, height: nil) }
        LoadCorrection.finish(s, gpu: .decode, d, width: width, height: height)
        return LoadCorrection.sampleCount - n0
    }
    /// one device-activity read now on this thread (with utilizationRead as the read when set); then the value a
    /// warmth query would see `after` seconds later (nil: older than 1 s, or none)
    public static func deviceActivityReadNow(thenAfter after: Double = 0) -> Int? {
        DeviceActivity.readNow()
        return DeviceActivity.cached(at: GPUActivity.now() + after)
    }
    /// forget the device-activity readings
    public static func resetDeviceActivity() { DeviceActivity.reset() }
    /// replaces the device-wide GPU utilization read behind Warmth.deviceGPUPercent (one value per call; it is
    /// read on every warmth query while set; nil: the real one, refreshed every 0.25 s)
    public static var deviceGPUPercentRead: (() -> Int?)? {
        get { DeviceActivity.override }
        set { DeviceActivity.override = newValue }
    }
    /// replaces the macOS Device Utilization % read inside the real sampler (one value per call; nil: the real one)
    public static var utilizationRead: (() -> Int?)? {
        get { IdleSampler.readOverride }
        set { IdleSampler.readOverride = newValue }
    }
    /// the real sampler (macOS: three utilization reads, the first discarded, and the load), with idleSampler bypassed
    public static func sampleRaw(_ d: MTLDevice) -> DeviceProfile.IdleSample {
        let o = IdleSampler.override; IdleSampler.override = nil; defer { IdleSampler.override = o }
        return IdleSampler.sample(d.registryID)
    }
    /// how many times this profile has sampled the busy gate
    public static func gateChecks(_ p: DeviceProfile) -> Int { p.lock.lock(); defer { p.lock.unlock() }; return p.gateChecks }
    /// one real sample of this device (about 100 ms on macOS) after this process has had no GPU work for `quiet`
    /// seconds (waiting up to `quiet` + 2 s; read ownGPUQuietSeconds to see whether it got there); swaps out
    /// idleSampler meanwhile, so call it while no measurement is running
    public static func sampleNow(_ d: MTLDevice, quiet: Double = 1.0) -> DeviceProfile.IdleSample {
        _ = GPUActivity.waitForQuiet(quiet: quiet, timeout: quiet + GPUActivity.quietTimeout)   // not our own work
        let o = IdleSampler.override; IdleSampler.override = nil; defer { IdleSampler.override = o }
        return IdleSampler.sample(d.registryID)
    }
    /// waits for a running re-measure; false on timeout
    public static func waitForRemeasure(_ p: DeviceProfile, timeout: Double) -> Bool { p.remeasuring.wait(timeout: .now() + timeout) == .success }
    /// run the routing measurement now on this thread (no cache)
    public static func measure(_ ctx: MetalContext) -> DeviceProfile.Routing? { measureDetailed(ctx).sporadic }
    /// the measurement on the calling thread, without the cache, against the context's own estimate
    public static func measureDetailed(_ ctx: MetalContext) -> Measurement {
        Measurement(RoutingMeasurement.run(ctx, estimate: ctx.profile.estimatedRouting))
    }
    /// the measurement alone against this (sustained) estimate; with timingOverride set it does no GPU work
    /// the measurement on injected timings against this estimate (timingOverride set for the call)
    public static func measure(_ ctx: MetalContext, estimate: DeviceProfile.Routing, timings: MeasurementTimings) -> Measurement {
        let o = RoutingMeasurement.timingOverride
        RoutingMeasurement.timingOverride = timings
        defer { RoutingMeasurement.timingOverride = o }
        return Measurement(RoutingMeasurement.run(ctx, estimate: estimate))
    }
    public static func measure(_ ctx: MetalContext, estimate: DeviceProfile.Routing) -> Measurement {
        Measurement(RoutingMeasurement.run(ctx, estimate: estimate))
    }
    /// a measurement's result: the sporadic set (nil: not used, see reason), each isolated call's wall ms, and
    /// the measurement's own wall and GPU time
    public struct Measurement {
        public let sporadic: DeviceProfile.Routing?
        public let reason: String?
        public let decodeMs: [Double], encodeMs: [Double]
        public let decodeLargeMs: Double?, encodeLargeMs: Double?
        public let wallMs: Double, gpuMs: Double
        /// the CPU cold model fitted from the proxy (nil: not used, see cpuReason), and the proxy's chunk times
        public let cpu: DeviceProfile.CPUColdModel?
        public let cpuReason: String?
        public let cpuChunksMs: [Double]
        init(_ o: RoutingMeasurement.Outcome) {
            sporadic = o.sporadic; reason = o.reason; decodeMs = o.decodeMs; encodeMs = o.encodeMs; wallMs = o.wallMs; gpuMs = o.gpuMs
            decodeLargeMs = o.decodeLargeMs; encodeLargeMs = o.encodeLargeMs
            cpu = o.cpu; cpuReason = o.cpuReason; cpuChunksMs = o.cpuChunksMs
        }
    }
    /// Injected measurement timings (no GPU or CPU proxy work): the wall ms of each isolated 256x256 decode and
    /// encode, in call order (the first decode is the cold start); of the isolated 1600x1200 decode and encode
    /// (nil: the rise from 256x256 to 1600x1200 is the estimate's); the CPU proxy's chunk times (nil:
    /// the CPU cold model is not measured).
    public struct MeasurementTimings {
        public var decode: [Double], encode: [Double]
        public var decodeLarge: Double?, encodeLarge: Double?
        public var cpuChunks: [Double]?
        public init(decode: [Double], encode: [Double], decodeLarge: Double? = nil, encodeLarge: Double? = nil, cpuChunks: [Double]? = nil) {
            self.decode = decode; self.encode = encode; self.decodeLarge = decodeLarge; self.encodeLarge = encodeLarge; self.cpuChunks = cpuChunks
        }
    }
    /// the CPU proxy's fit of chunk times: the model, or why not
    public static func fitCPUProxy(_ chunksMs: [Double]) -> (model: DeviceProfile.CPUColdModel?, reason: String?) { CPUProxy.fit(chunksMs) }
    /// the chunk times a CPU following `model` exactly would give, `chunkMs` warm per chunk, up to the proxy's stop rule
    public static func simulateCPUProxy(_ model: DeviceProfile.CPUColdModel, chunkMs: Double) -> [Double] { CPUProxy.simulate(model, chunkMs: chunkMs) }
    /// one real proxy run now on this thread's caller (chunk times in ms)
    public static func runCPUProxy() -> [Double] { CPUProxy.run() }
    /// the warmth tracker's clock (monotonic seconds, as monotonicNow; nil: the real one)
    public static var warmthClock: (() -> Double)? {
        get { nil }
        set { WarmthTracker.clock = newValue ?? { GPUActivity.now() } }
    }
    /// the monotonic clock the tracker and the GPU activity stamps use (seconds of system uptime)
    public static var monotonicNow: Double { GPUActivity.now() }
    /// bracket a pretend CPU proxy run (CPU-time samples skipped meanwhile, the window restarted after)
    public static func proxyRunBegin() { WarmthTracker.proxyBegin() }
    public static func proxyRunEnd() { WarmthTracker.proxyEnd() }
    /// the process CPU time the tracker reads, in seconds (nil: getrusage)
    public static var processCPUTime: (() -> Double)? {
        get { nil }
        set { WarmthTracker.cpuTime = newValue ?? WarmthTracker.processCPUSeconds }
    }
    /// replace the GPU activity the tracker reads: commands in flight and the last completion (monotonic seconds;
    /// 0: none yet); nil: the real one
    public static var gpuActivity: (() -> (inFlight: Int, lastEnd: Double))? {
        get { WarmthTracker.gpuOverride }
        set { WarmthTracker.gpuOverride = newValue }
    }
    /// forget noteCPUWork and the CPU-time reference
    public static func resetWarmth() { WarmthTracker.reset() }
    /// bracket pretend GPU work as the codec does (begin without end: a command buffer in flight)
    public static func gpuWorkBegin() { GPUActivity.begin() }
    public static func gpuWorkEnd() { GPUActivity.end() }
    /// the real GPU activity: in flight and the last completion time
    public static var realGPUActivity: (inFlight: Int, lastEnd: Double) { GPUActivity.snapshot() }
    /// the profile's cache key
    public static func cacheKey(_ p: DeviceProfile) -> String { p.cacheKey }
    /// save routing and a CPU cold model as a first measurement; read the CPU model back
    public static func saveCache(_ r: DeviceProfile.Routing, cpu: DeviceProfile.CPUColdModel?, _ p: DeviceProfile) {
        DeviceProfileCache.save(r, cpu: cpu, key: p.cacheKey)
    }
    public static func loadCPUCache(_ p: DeviceProfile) -> DeviceProfile.CPUColdModel? { DeviceProfileCache.loadEntry(key: p.cacheKey)?.cpu }
    /// the CPU cold model saved on its own (the GPU part not used)
    public static func loadCPUOnlyCache(_ p: DeviceProfile) -> DeviceProfile.CPUColdModel? { DeviceProfileCache.loadCPU(key: p.cacheKey) }
    /// a re-measure's CPU model: the newer valid fit whole, else the older
    public static func mergeCPU(_ old: DeviceProfile.CPUColdModel?, _ new: DeviceProfile.CPUColdModel?) -> DeviceProfile.CPUColdModel? {
        DeviceProfileCache.mergeCPU(old, new)
    }
    /// why the profile's last CPU proxy fit was not used
    public static func cpuFailureReason(_ p: DeviceProfile) -> String? { p.cpuFailureReason }
    /// replace the measurement's GPU work with these timings (nil: real GPU work)
    public static var timingOverride: MeasurementTimings? {
        get { RoutingMeasurement.timingOverride }
        set { RoutingMeasurement.timingOverride = newValue }
    }
    /// run a profile's busy gate now (waits for our own GPU work to pause, then samples); true when idle
    public static func runGate(_ p: DeviceProfile) -> Bool { p.gate() }
    /// seconds since this process's last command buffer completed (0 while one runs)
    public static var ownGPUQuietSeconds: Double { GPUActivity.quietFor }
    /// why the last attempt was not used, while it stands
    public static func failureReason(_ p: DeviceProfile) -> String? { p.failureReason }
    public static var minColdFixedMs: Double { RoutingMeasurement.minColdFixedMs }
    /// the sustained estimate for a GPU of `gpuCores` cores (`coresEstimated`: the iOS branch)
    public static func estimate(gpuCores: Int, coresEstimated: Bool) -> DeviceProfile.Routing { DeviceProfile.estimate(gpuCores: gpuCores, coresEstimated: coresEstimated) }
    /// the sporadic estimate derived from a sustained one (`ios`: from the iPhone 13's isolated calls, else the M4's)
    public static func sporadicEstimate(_ r: DeviceProfile.Routing, ios: Bool) -> DeviceProfile.Routing { DeviceProfile.sporadicEstimate(r, ios: ios) }
}

/// Setup work inside a call (a pipeline built, the self-check run, a buffer allocated or grown): a call that did
/// any is not a load-correction sample, since its time is not the steady cost the profile predicts.
enum SetupWork {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var n = 0
    static func bump() { lock.lock(); n &+= 1; lock.unlock() }
    static var epoch: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Load correction (DeviceProfile.loadFactors): how much slower or faster recent calls ran than the profile
/// predicted, per kind of call. The profile is measured on an idle device; another app on the CPU or the GPU,
/// thermal throttling or Low Power Mode change the real costs, and the correction follows them from the calls
/// themselves. Each sample is log(observed / predicted), clamped to 0.5x-4x; per kind, the estimate is their
/// weighted mean, its weight halving every halfLife seconds without samples (the clock includes sleep), and the
/// factor applied is the part of exp(mean x min(1, weight / fullWeight)) beyond the 1.25x dead zone, so 0.625x to
/// 3.2x. Advice only: it changes what prefersCPU says, never the bytes.
enum LoadCorrection {
    static let halfLife = 8.0, minSample = 0.5, maxSample = 4.0, fullWeight = 3.0, maxWeight = 8.0
    /// a dead zone: run-to-run noise on an idle M4 moved the factors by 20-50%, which flips near-tie advice for the
    /// worse; load moves them 2-4x. Only the part beyond 1.25x (or below 1/1.25) is applied.
    static let deadZone = 1.25
    /// images at or above this many megapixels are their own bucket (a fixed-cost error does not carry over)
    static let largeMP = 1.0
    private static let lock = NSLock()
    /// on unless EJM_LOAD_CORRECTION=0; DeviceProfile.loadCorrectionEnabled changes it at run time
    nonisolated(unsafe) private static var _enabled = ProcessInfo.processInfo.environment["EJM_LOAD_CORRECTION"] != "0"
    static var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set {
            lock.lock(); _enabled = newValue; lock.unlock()
            if !newValue { DeviceActivity.cancel() }           // reads already running stop after their current one
        }
    }
    /// a bucket: device, side, operation, the state the call started in and its size class. A correction learned
    /// on small cold calls says nothing about large warm ones, so each kind of call corrects only its own kind.
    struct Key: Hashable { let device: UInt64; let cpu: Bool; let decode: Bool; let state: Int; let large: Bool }
    /// state: GPU 0 sporadic (cold), 1 warm; CPU 0 cold, 1 warm
    static func key(_ device: UInt64, cpu: Bool, _ op: DeviceProfile.Operation, state: Int, megapixels: Double) -> Key {
        Key(device: device, cpu: cpu, decode: op == .decode, state: state, large: megapixels >= largeMP)
    }
    private struct State { var mean = 0.0, weight = 0.0, t = -Double.infinity }
    nonisolated(unsafe) private static var states: [Key: State] = [:]
    /// devices whose caller has reported a timed CPU job: until then no factor applies, so a caller that times
    /// only the GPU side does not get advice skewed by GPU-side error alone (content unlike the profile's)
    nonisolated(unsafe) private static var cpuReported: Set<UInt64> = []
    nonisolated(unsafe) private static var samples = 0
    /// this process's public decode and encode calls now in flight, and a count of calls that overlapped another
    nonisolated(unsafe) private static var active = 0, overlap = 0
    /// monotonic seconds, including sleep (a factor learned before the lid closes fades during it)
    static func realClock() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
    /// testing: replaces the clock (read under the lock)
    nonisolated(unsafe) private static var _clock: (() -> Double)?
    static var clockOverride: (() -> Double)? {
        get { lock.lock(); defer { lock.unlock() }; return _clock }
        set { lock.lock(); _clock = newValue; lock.unlock() }
    }
    private static func now() -> Double { (clockOverride ?? realClock)() }

    private static func decayed(_ s: State, _ now: Double) -> State {
        guard s.weight > 0, now > s.t else { return s }
        var d = s; d.weight *= exp2(-(now - s.t) / halfLife); d.t = now
        return d
    }

    static func add(_ k: Key, observedMs: Double, predictedMs: Double) {
        guard isEnabled, observedMs.isFinite, predictedMs.isFinite, observedMs > 0, predictedMs > 0 else { return }
        let x = min(max(log(observedMs / predictedMs), log(minSample)), log(maxSample))
        let t = now()
        lock.lock(); defer { lock.unlock() }
        var s = decayed(states[k] ?? State(), t)
        let w = s.weight + 1
        s.mean = (s.mean * s.weight + x) / w; s.weight = min(w, maxWeight); s.t = t
        states[k] = s
        samples &+= 1
        if k.cpu { cpuReported.insert(k.device) }
    }

    static func factor(_ k: Key) -> Double {
        guard isEnabled else { return 1 }
        let t = now()
        lock.lock(); let s = states[k].map { decayed($0, t) }; let reported = cpuReported.contains(k.device); lock.unlock()
        guard reported, let s, s.weight > 0 else { return 1 }
        let m = s.mean * min(1, s.weight / fullWeight), z = log(deadZone)
        return exp(m > z ? m - z : m < -z ? m + z : 0)
    }

    static func reset() { lock.lock(); states = [:]; cpuReported = []; samples = 0; lock.unlock() }
    static var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return samples }

    /// the start of a public decode or encode: its time, the GPU state the prediction depends on, and what tells
    /// afterwards whether it overlapped another call of this process or did setup work
    struct Start { let t: Double; let warmth: DeviceProfile.Warmth; let setup: Int; let overlap: Int; let concurrent: Bool }
    static func start() -> Start {
        let w = WarmthTracker.current(moveWindow: false, startPolling: false)
        let setup = SetupWork.epoch
        lock.lock()
        let concurrent = active > 0
        if concurrent { overlap &+= 1 }
        active += 1
        let o = overlap
        lock.unlock()
        return Start(t: now(), warmth: w, setup: setup, overlap: o, concurrent: concurrent)
    }

    /// GPU work of this process that is never a sample (encode batches, the library's own calibration and
    /// self-check calls) but that other calls overlapping it must see: run it inside track()
    static func track<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); if active > 0 { overlap &+= 1 }; active += 1; lock.unlock()
        defer { lock.lock(); if active > 1 { overlap &+= 1 }; active -= 1; lock.unlock() }
        return try body()
    }

    /// the end of a public call started with start(): a sample when it succeeded (width and height given), ran
    /// alone (no other public call of this process in flight at any point: those share the GPU, and their latency
    /// is not load) and did no setup work
    static func finish(_ s: Start, gpu op: DeviceProfile.Operation, _ device: MTLDevice, width: Int?, height: Int?) {
        let ms = (now() - s.t) * 1000
        lock.lock()
        let alone = !s.concurrent && overlap == s.overlap && active == 1
        if active > 1 { overlap &+= 1 }
        active -= 1
        lock.unlock()
        guard alone, let width, let height, SetupWork.epoch == s.setup, !s.warmth.gpuInFlight else { return }
        let mp = Double(width * height) / 1e6
        let p = DeviceProfileRegistry.shared.profile(device)
        let warm = s.warmth.gpuWarm
        let r = warm ? p.warmRouting : p.sporadicRouting
        add(key(device.registryID, cpu: false, op, state: warm ? 1 : 0, megapixels: mp), observedMs: ms,
            predictedMs: r.gpuMs(megapixels: mp, operation: op))
    }
}

/// Whether other processes keep the GPU busy (and so clocked up), on macOS: IORegistry Device Utilization %. The
/// counter covers the time since the previous read by any process (Activity Monitor and other users of this library
/// read it too), so only a read whose interval held none of this process's own GPU work is used: then whatever the
/// interval, the value is the share of GPU work outside this library's own calls (other apps, or the app's own
/// rendering). Reads run on a background thread every `refresh` seconds for
/// `activeFor` seconds after the warmth was last read for routing advice (currentWarmth, or prefersCPU and
/// routingDecision when they detect warmth, with this process's own GPU work not already making the GPU warm), and
/// stop when it is not; a decode or encode only uses the latest value and never starts the thread. A value older than
/// `maxAge` counts as unknown. One read cost 0.2-1.7 ms on an M4 (up to 25 ms seen once), never on a call's path.
/// iOS has no such counter: nil. The counter is the default Metal device's (Apple silicon has one GPU).
enum DeviceActivity {
    static let refresh = 0.25, maxAge = 1.0, activeFor = 5.0, warmPercent = 25
    private static let lock = NSLock()
    /// the latest usable result: when read, and other processes' share in percent
    nonisolated(unsafe) private static var last: (t: Double, others: Int?) = (-.infinity, nil)
    /// the previous read: when, and this process's busy seconds then (nil: the next read only sets a baseline)
    nonisolated(unsafe) private static var prev: (t: Double, busy: Double)?
    nonisolated(unsafe) private static var askedUntil = -Double.infinity
    nonisolated(unsafe) private static var running = false
    /// testing: replaces the whole result (one value per call), synchronously
    nonisolated(unsafe) private static var _override: (() -> Int?)?
    static var override: (() -> Int?)? {
        get { lock.lock(); defer { lock.unlock() }; return _override }
        set { lock.lock(); _override = newValue; lock.unlock() }
    }
    /// testing: replaces the counter read inside readNow (not shared with IdleSampler's hook)
    nonisolated(unsafe) private static var _readOverride: (() -> Int?)?
    static var readOverride: (() -> Int?)? {
        get { lock.lock(); defer { lock.unlock() }; return _readOverride }
        set { lock.lock(); _readOverride = newValue; lock.unlock() }
    }
    #if os(macOS)
    private static let registryID: UInt64 = MTLCreateSystemDefaultDevice()?.registryID ?? 0
    #endif

    /// other processes' share in percent from one read: the value when this process had no GPU work in the
    /// interval, else nil (part of it may be ours, and other readers make the interval unknown)
    static func others(devicePercent: Int, ownBusySeconds: Double) -> Int? { ownBusySeconds > 0 ? nil : devicePercent }

    /// the latest other-process share in percent, nil when none is recent; never blocks on a read.
    /// startPolling: keep the background reads going (routing queries); false for a decode or encode
    static func percent(startPolling: Bool = true) -> Int? {
        if let o = override { return o() }
        #if os(macOS)
        let t = GPUActivity.now()
        lock.lock()
        let v = t - last.t <= maxAge ? last.others : nil
        var start = false
        if startPolling {
            askedUntil = t + activeFor
            if !running { running = true; prev = nil; start = true }
        }
        lock.unlock()
        if start { Thread.detachNewThread { loop() } }
        return v
        #else
        return nil
        #endif
    }
    /// whether the background reads are running (testing)
    static var polling: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// testing: ends the background reads after their current one; true once they have stopped within `timeout`
    static func stop(timeout: Double) -> Bool {
        lock.lock(); askedUntil = -.infinity; lock.unlock()
        let t0 = GPUActivity.now()
        while polling { if GPUActivity.now() - t0 > timeout { return false }; Thread.sleep(forTimeInterval: 0.01) }
        return true
    }

    /// forget every request for reads (load correction turned off): a running loop ends after its current read
    static func cancel() { lock.lock(); askedUntil = -.infinity; lock.unlock() }

    #if os(macOS)
    /// reads every `refresh` seconds while asked within `activeFor` and load correction is on, then ends
    private static func loop() {
        Thread.current.qualityOfService = .utility
        while true {
            readNow()
            let enabled = LoadCorrection.isEnabled
            lock.lock()
            if !enabled || GPUActivity.now() > askedUntil { running = false; lock.unlock(); return }
            lock.unlock()
            Thread.sleep(forTimeInterval: refresh)
        }
    }
    #endif

    /// one read now (on the calling thread), updating the latest result
    static func readNow() {
        #if os(macOS)
        let v = readOverride?() ?? IdleSampler.utilization(registryID)
        let t = GPUActivity.now(), busy = GPUActivity.busySeconds()
        lock.lock()
        if let p = prev, let pct = v, let o = Self.others(devicePercent: pct, ownBusySeconds: busy - p.busy) { last = (t, o) }
        prev = (t, busy)
        lock.unlock()
        #endif
    }
    static func reset() { lock.lock(); last = (-.infinity, nil); prev = nil; lock.unlock() }
    /// testing: the latest result's age gate, as percent() applies it at time t (GPUActivity's clock)
    static func cached(at t: Double) -> Int? { lock.lock(); defer { lock.unlock() }; return t - last.t <= maxAge ? last.others : nil }
}
