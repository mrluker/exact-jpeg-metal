// The C API (include/exact_jpeg.h), exported from Swift with @_cdecl.
import Foundation
import Metal
import ExactJPEG
import os

/// One C call at a time per handle (the reason / error string belongs to the call in progress): a call that finds
/// another thread's call on the handle running returns at once (EJM_DECLINED from a decoder, EJM_ERROR from an
/// encoder) without touching the handle. The gate (CallGate) remembers the rejection in that thread, which then
/// reads the static busy string from ejm_decoder_reason / ejm_encoder_error until its next call on the handle.
///
/// The handle's own string is swapped under a lock and freed after the swap, and the getters read it under the
/// same lock, so a getter never sees a half-replaced pointer. A pointer it returns stays valid until the next call
/// on the handle (from any thread) or destroy, as the header says; the busy string is static.
final class CString: @unchecked Sendable {
    private let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var s: UnsafeMutablePointer<CChar>?
    init() { l.initialize(to: os_unfair_lock()) }
    deinit { free(s); l.deinitialize(count: 1); l.deallocate() }
    func set(_ v: String?) {
        let new = v.map { strdup($0) } ?? nil
        os_unfair_lock_lock(l); let old = s; s = new; os_unfair_lock_unlock(l)
        free(old)
    }
    func get() -> UnsafePointer<CChar>? { os_unfair_lock_lock(l); defer { os_unfair_lock_unlock(l) }; return UnsafePointer(s) }
}

nonisolated(unsafe) private let decoderBusyC = UnsafePointer(strdup(Decoder.busyReason)!)
nonisolated(unsafe) private let encoderBusyC = UnsafePointer(strdup(Encoder.busyError)!)

final class CDecoder { let d: Decoder
    let gate = CallGate(busyReason: Decoder.busyReason)
    private let reason = CString()
    init(_ d: Decoder) { self.d = d }
    func setReason(_ s: String?) { reason.set(s) }
    /// the reason as the calling thread should see it
    func reasonForCaller() -> UnsafePointer<CChar>? { gate.rejectedHere ? decoderBusyC : reason.get() }
}
final class CEncoder { let e: Encoder
    let gate = CallGate(busyReason: Encoder.busyError)
    private let error = CString()
    init(_ e: Encoder) { self.e = e }
    func setError(_ s: String?) { error.set(s) }
    func errorForCaller() -> UnsafePointer<CChar>? { gate.rejectedHere ? encoderBusyC : error.get() }
}

nonisolated(unsafe) private let versionString = strdup("exact-jpeg-metal 0.1.0")

@_cdecl("ejm_version") public func ejm_version() -> UnsafePointer<CChar>? { UnsafePointer(versionString) }

@_cdecl("ejm_inspect")
public func ejm_inspect(_ p: UnsafePointer<UInt8>?, _ n: Int, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?,
                        _ c: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let p, n > 0 else { return 1 }
    guard let hd = try? parseJPEGHeader(UnsafeRawBufferPointer(start: p, count: n)) else { return 1 }
    w?.pointee = Int32(hd.width); h?.pointee = Int32(hd.height); c?.pointee = Int32(hd.ncomp)
    return 0
}

@_cdecl("ejm_decoder_create")
public func ejm_decoder_create() -> OpaquePointer? {
    guard MetalContext.sharedSetupError == nil else { return nil }   // no device, or its setup failed
    return OpaquePointer(Unmanaged.passRetained(CDecoder(Decoder())).toOpaque())
}

@_cdecl("ejm_decoder_destroy")
public func ejm_decoder_destroy(_ d: OpaquePointer?) {
    guard let d else { return }
    Unmanaged<CDecoder>.fromOpaque(UnsafeRawPointer(d)).release()
}

private func cdec(_ d: OpaquePointer) -> CDecoder { Unmanaged<CDecoder>.fromOpaque(UnsafeRawPointer(d)).takeUnretainedValue() }

private func format(_ f: Int32) -> PixelFormat? { PixelFormat(rawValue: Int(f)) }

@_cdecl("ejm_decode")
public func ejm_decode(_ d: OpaquePointer?, _ p: UnsafePointer<UInt8>?, _ n: Int, _ f: Int32, _ out: UnsafeMutablePointer<UInt8>?,
                       _ cap: Int, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    // len and capacity are size_t: above Int.max they arrive negative (UnsafeRawBufferPointer would trap on them)
    guard let d, let p, let out, let fmt = format(f), n >= 0, cap >= 0 else { return -1 }
    let cd = cdec(d)
    guard cd.gate.enter() else { return 1 }
    defer { cd.gate.leave() }
    if let why = cd.d.ctx.selfCheck(decode: true, encode: false) { cd.setReason(why); return 1 }      // before anything touches out
    let src = UnsafeRawBufferPointer(start: p, count: n)
    let hd: JPEGHeader
    do { hd = try parseJPEGHeader(src) } catch { cd.setReason("\(error)"); return 1 }
    let need = hd.width * hd.height * fmt.channels
    if cap < need {
        // a file that would be declined anyway is declined (with its reason), not reported as a small buffer
        if let why = cd.d.declineReason(bytes: src, format: fmt) { cd.setReason(why); return 1 }
        cd.setReason("output buffer too small (\(need) bytes needed)")
        return -1
    }
    let page = Int(getpagesize())
    var direct: MTLBuffer? = nil
    if Int(bitPattern: out) % page == 0 && cap % page == 0 {
        direct = cd.d.ctx.device.makeBuffer(bytesNoCopy: out, length: cap, options: .storageModeShared, deallocator: nil)
    }
    guard let img = cd.d.decode(bytes: src, format: fmt, output: direct) else { cd.setReason(cd.d.reason); return 1 }
    if direct == nil { out.update(from: img.bytes.bindMemory(to: UInt8.self).baseAddress!, count: need) }
    w?.pointee = Int32(img.width); h?.pointee = Int32(img.height)
    cd.setReason(nil)
    return 0
}

@_cdecl("ejm_decode_view")
public func ejm_decode_view(_ d: OpaquePointer?, _ p: UnsafePointer<UInt8>?, _ n: Int, _ f: Int32,
                            _ px: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, _ w: UnsafeMutablePointer<Int32>?,
                            _ h: UnsafeMutablePointer<Int32>?, _ c: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let d, let p, let px, let fmt = format(f), n >= 0 else { return -1 }
    let cd = cdec(d)
    guard cd.gate.enter() else { return 1 }
    defer { cd.gate.leave() }
    if let why = cd.d.ctx.selfCheck(decode: true, encode: false) { cd.setReason(why); return 1 }
    guard let img = cd.d.decode(bytes: UnsafeRawBufferPointer(start: p, count: n), format: fmt) else { cd.setReason(cd.d.reason); return 1 }
    px.pointee = img.bytes.bindMemory(to: UInt8.self).baseAddress
    w?.pointee = Int32(img.width); h?.pointee = Int32(img.height); c?.pointee = Int32(img.channels)
    cd.setReason(nil)
    return 0
}

@_cdecl("ejm_decoder_reason")
public func ejm_decoder_reason(_ d: OpaquePointer?) -> UnsafePointer<CChar>? {
    guard let d else { return nil }
    return cdec(d).reasonForCaller()
}

@_cdecl("ejm_encoder_create")
public func ejm_encoder_create() -> OpaquePointer? {
    guard MetalContext.sharedSetupError == nil else { return nil }   // no device, or its setup failed
    return OpaquePointer(Unmanaged.passRetained(CEncoder(Encoder())).toOpaque())
}

@_cdecl("ejm_encoder_destroy")
public func ejm_encoder_destroy(_ e: OpaquePointer?) {
    guard let e else { return }
    Unmanaged<CEncoder>.fromOpaque(UnsafeRawPointer(e)).release()
}

@_cdecl("ejm_encode")
public func ejm_encode(_ e: OpaquePointer?, _ px: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ c: Int32, _ rb: Int,
                       _ q: Int32, _ s: Int32, _ out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                       _ outLen: UnsafeMutablePointer<Int>?) -> Int32 {
    guard let e, let px, let out, let outLen else { return -1 }
    let ce = Unmanaged<CEncoder>.fromOpaque(UnsafeRawPointer(e)).takeUnretainedValue()
    guard ce.gate.enter() else { return -1 }
    defer { ce.gate.leave() }
    if let why = ce.e.ctx.selfCheck(decode: false, encode: true) { ce.setError(why); return -1 }
    let ss: Subsampling
    switch s { case 0: ss = .s444; case 1: ss = .s422; case 2: ss = .s420; default: ce.setError("subsampling must be 0, 1 or 2"); return -1 }
    guard w > 0, h > 0, rb > 0 else { ce.setError("bad size"); return -1 }
    guard c == 3 || c == 4 else { ce.setError("channels must be 3 (RGB) or 4 (RGBA/RGBX)"); return -1 }
    // the pixels' extent, with arithmetic that reports overflow (encode checks the rest before reading them)
    let (rows, o1) = rb.multipliedReportingOverflow(by: Int(h - 1))
    let (len, o2) = rows.addingReportingOverflow(Int(w) * Int(c))
    guard !o1, !o2 else { ce.setError("row_bytes * (height - 1) + width * channels overflows"); return -1 }
    do {
        let d = try ce.e.encode(bytes: UnsafeRawBufferPointer(start: px, count: len), width: Int(w), height: Int(h),
                                channels: Int(c), rowBytes: rb, quality: Int(q), subsampling: ss)
        guard let m = malloc(d.count) else { ce.setError("out of memory"); return -1 }
        d.copyBytes(to: m.assumingMemoryBound(to: UInt8.self), count: d.count)
        out.pointee = m.assumingMemoryBound(to: UInt8.self)
        outLen.pointee = d.count
        ce.setError(nil)
        return 0
    } catch {
        ce.setError("\(error)")
        return -1
    }
}

@_cdecl("ejm_encoder_error")
public func ejm_encoder_error(_ e: OpaquePointer?) -> UnsafePointer<CChar>? {
    guard let e else { return nil }
    return Unmanaged<CEncoder>.fromOpaque(UnsafeRawPointer(e)).takeUnretainedValue().errorForCaller()
}

@_cdecl("ejm_free") public func ejm_free(_ p: UnsafeMutableRawPointer?) { free(p) }

