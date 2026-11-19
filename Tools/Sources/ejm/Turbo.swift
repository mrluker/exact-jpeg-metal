import Foundation
import TurboRef

/// Swift wrappers over the libjpeg-turbo reference (TurboRef).
enum Turbo {
    /// "libjpeg-turbo <version>": the version loaded at run time when its path names one (Homebrew's Cellar keg),
    /// otherwise the header version marked as such. The libjpeg API has no run-time version call.
    static var version: String {
        runtimeVersion.map { "libjpeg-turbo \($0)" } ?? "libjpeg-turbo \(headerVersion) (headers; run-time version unknown)"
    }
    /// LIBJPEG_TURBO_VERSION of the headers ejm was built against
    static var headerVersion: String { String(cString: tr_header_version()) }
    /// the loaded library's version, from its resolved path; nil when the path names none. Testing: the environment
    /// variable EJM_TEST_TURBO_RUNTIME replaces it, but only with a version other than the target (it can make a
    /// 3.2.0 run look like another version, never another version look like 3.2.0)
    static var runtimeVersion: String? {
        if let t = ProcessInfo.processInfo.environment["EJM_TEST_TURBO_RUNTIME"], t != target { return t.isEmpty ? nil : t }
        let v = String(cString: tr_runtime_version()); return v.isEmpty ? nil : v
    }
    static var runtimePath: String { String(cString: tr_runtime_path()) }
    /// the exactness target of the committed manifest and the docs
    static let target = "3.2.0"

    static func encode(_ rgb: [UInt8], _ w: Int, _ h: Int, gray: Bool = false, quality: Int, samp: Int,
                       restartMCUs: Int = 0, restartRows: Int = 0, optimize: Bool = false, progressive: Bool = false,
                       baseline: Bool = true) -> Data {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var len = 0
        tr_set_force_baseline(baseline ? 1 : 0)
        defer { tr_set_force_baseline(1) }
        let r = rgb.withUnsafeBufferPointer {
            tr_encode($0.baseAddress, Int32(w), Int32(h), gray ? 1 : 0, Int32(quality), Int32(samp), Int32(restartMCUs),
                      Int32(restartRows), optimize ? 1 : 0, progressive ? 1 : 0, &out, &len)
        }
        precondition(r == 0, "tr_encode failed")
        let d = Data(bytes: out!, count: len)
        tr_free(out)
        return d
    }

    static func info(_ d: Data) -> (w: Int, h: Int, nc: Int)? {
        var w: Int32 = 0, h: Int32 = 0, nc: Int32 = 0
        let r = d.withUnsafeBytes { tr_info($0.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, &w, &h, &nc) }
        return r == 0 ? (Int(w), Int(h), Int(nc)) : nil
    }

    /// Decoded pixels (RGB, or gray), or nil on error. warned: libjpeg-turbo reported corrupt data.
    static func decode(_ d: Data, gray: Bool = false) -> (px: [UInt8], w: Int, h: Int, warned: Bool)? {
        guard let i = info(d) else { return nil }
        var px = [UInt8](repeating: 0, count: i.w * i.h * (gray ? 1 : 3))
        let r = d.withUnsafeBytes { src in
            px.withUnsafeMutableBufferPointer { tr_decode(src.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, $0.baseAddress, gray ? 1 : 0) }
        }
        if r < 0 { return nil }
        return (px, i.w, i.h, r == 1)
    }

    static func decodeInto(_ d: Data, _ out: UnsafeMutablePointer<UInt8>) -> Int32 {
        d.withUnsafeBytes { tr_decode($0.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, out, 0) }
    }
}
