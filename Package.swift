// swift-tools-version:6.0
// exact-jpeg-metal: JPEG decoding and encoding on Apple GPUs (Metal), byte-identical to libjpeg-turbo.
//
// Products:
//   ExactJPEG   the library (Swift API), macOS 14+ / iOS 16+, any Apple GPU of Metal family Apple7 or later
//   ExactJPEGC  the same as a dynamic library with a plain C API (include/exact_jpeg.h) for C, C++, Rust, Python
// The library needs nothing but SwiftPM. The test and benchmark tool `ejm` and the libjpeg-turbo reference it
// links live in a separate package, Tools/Package.swift, so that depending on this package never asks for
// pkg-config or libjpeg.
import PackageDescription

let package = Package(
    name: "exact-jpeg-metal",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "ExactJPEG", targets: ["ExactJPEG"]),
        .library(name: "ExactJPEGC", type: .dynamic, targets: ["ExactJPEGC"]),
    ],
    targets: [
        .target(name: "ExactJPEG", exclude: ["Shaders"]),
        .target(name: "ExactJPEGC", dependencies: ["ExactJPEG"]),
    ]
)
