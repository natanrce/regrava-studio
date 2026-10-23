// swift-tools-version: 6.2
import PackageDescription

/// Engine of Regrava Studio, used by the app target in "Regrava Studio.xcodeproj".
let package = Package(
    name: "RegravaKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RegravaCore", targets: ["RegravaCore"]),
        .library(name: "RegravaRender", targets: ["RegravaRender"]),
        .library(name: "RegravaCapture", targets: ["RegravaCapture"]),
        .library(name: "RegravaSpeech", targets: ["RegravaSpeech"]),
    ],
    dependencies: [
        // The speech models run on mlx-swift.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.33.0"),
    ],
    targets: [
        // Pure, platform-independent logic: models, auto-zoom, grouping, springs, camera track.
        .target(name: "RegravaCore"),
        // Core Image / AVFoundation frame compositing, preview composition and export.
        .target(name: "RegravaRender", dependencies: ["RegravaCore", "RegravaSpeech"], resources: [.copy("Resources/Wallpapers"), .copy("Resources/Fonts"), .copy("Resources/Devices"), .copy("Resources/Sounds"), .copy("Resources/BackgroundAudio"), .copy("Resources/CursorSets"), .copy("RegravaKernels.metallib")]),
        // MossFormer2 and TF-Restormer on MLX. Needs Apple silicon.
        .target(
            name: "RegravaSpeech",
            dependencies: ["RegravaCore", .product(name: "MLX", package: "mlx-swift")],
            resources: [.copy("Resources/SpeechModels")]
        ),
        // ScreenCaptureKit recording + mouse event tracking.
        .target(name: "RegravaCapture", dependencies: ["RegravaCore"]),
        .testTarget(name: "RegravaCoreTests", dependencies: ["RegravaCore"]),
        .testTarget(name: "RegravaRenderTests", dependencies: ["RegravaCore", "RegravaRender"]),
        .testTarget(name: "RegravaSpeechTests", dependencies: ["RegravaSpeech", .product(name: "MLX", package: "mlx-swift")], exclude: ["build-mlx-metallib.sh"]),
    ],
    swiftLanguageModes: [.v5]
)
