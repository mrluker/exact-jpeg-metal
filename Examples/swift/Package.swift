// swift-tools-version:6.0
// Swift example: a separate package that depends on exact-jpeg-metal by path, the way an app would depend on it.
// Not part of the library's products. ./scripts/swift-example.sh builds and runs it.
import PackageDescription

let package = Package(
    name: "swift-example",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "exact-jpeg-metal", path: "../..")],   // name: the checkout folder may be named differently
    targets: [
        .executableTarget(name: "swift-example", dependencies: [.product(name: "ExactJPEG", package: "exact-jpeg-metal")]),
    ]
)
