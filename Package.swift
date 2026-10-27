// swift-tools-version:5.10
// Speech to Text for macOS, native: AppKit and SwiftUI, with NVIDIA Parakeet on the Neural
// Engine through FluidAudio, in-process. Built into dist/Speech to Text.app by scripts/build.sh.

import PackageDescription

let package = Package(
    name: "SpeechToText",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The commit the Tauri app's sidecar was measured with: ultra, int8 encoder, ~80 MB resident.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "3f6e600d8434f77bfec13c24ee4686377458ba7d")
    ],
    targets: [
        .executableTarget(
            name: "SpeechToText",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/SpeechToText"
        )
    ]
)
