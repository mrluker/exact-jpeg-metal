// swift-tools-version:6.0
// exact-jpeg-metal tools: the `ejm` test and benchmark tool (macOS only, not part of the library).
// It needs libjpeg-turbo from Homebrew as the reference (`brew install jpeg-turbo pkg-config`; scripts/env.sh
// sets PKG_CONFIG_PATH). It depends on the library package one directory up by path.
//   swift build -c release --package-path Tools    # Tools/.build/release/ejm, run it from the repository root
import PackageDescription

let package = Package(
    name: "exact-jpeg-metal-tools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ejm", targets: ["ejm"]),
    ],
    // name: the checkout folder may be named differently (a path dependency's identity is its folder name)
    dependencies: [.package(name: "exact-jpeg-metal", path: "..")],
    targets: [
        .systemLibrary(name: "CJPEGTurbo", pkgConfig: "libjpeg", providers: [.brew(["jpeg-turbo"])]),
        .target(name: "TurboRef", dependencies: ["CJPEGTurbo"]),
        .target(name: "HostBenchObjC", cSettings: [.define("HB_ARC")], linkerSettings: [.linkedFramework("Metal")]),
        // Only the dynamic ExactJPEGC product: libExactJPEGC.dylib contains ExactJPEG and exports its symbols, so ejm
        // imports both modules and gets one copy of the library from the dylib. Depending on the ExactJPEG product too
        // would link a second, static copy and the Objective-C runtime would see every class twice.
        .executableTarget(name: "ejm", dependencies: [
            .product(name: "ExactJPEGC", package: "exact-jpeg-metal"),
            "TurboRef", "HostBenchObjC",
        ]),
    ]
)
