// swift-tools-version:5.10
// parakeet-server: the sidecar that keeps NVIDIA Parakeet loaded on the Neural Engine
// through FluidAudio. Built by scripts/parakeet.sh.

import PackageDescription

let package = Package(
    name: "parakeet-server",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to the commit the app was measured with: ultra, int8 encoder, ~80 MB resident.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "3f6e600d8434f77bfec13c24ee4686377458ba7d")
    ],
    targets: [
        .executableTarget(
            name: "parakeet-server",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
