// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RayNeoASR",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "RayNeoASR", targets: ["RayNeoASR"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.16.1")
    ],
    targets: [
        .target(
            name: "RayNeoASR",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/RayNeoASR"
        ),
        .testTarget(name: "RayNeoASRTests", dependencies: ["RayNeoASR"], path: "Tests/RayNeoASRTests")
    ]
)
