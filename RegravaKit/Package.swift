// swift-tools-version: 6.0
import PackageDescription

/// Engine of Regrava Studio, used by the app target in "Regrava Studio.xcodeproj".
let package = Package(
    name: "RegravaKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RegravaCore", targets: ["RegravaCore"]),
        .library(name: "RegravaRender", targets: ["RegravaRender"]),
        .library(name: "RegravaCapture", targets: ["RegravaCapture"]),
    ],
    targets: [
        // Pure, platform-independent logic: models, auto-zoom, grouping, springs, camera track.
        .target(name: "RegravaCore"),
        // Core Image / AVFoundation frame compositing, preview composition and export.
        .target(name: "RegravaRender", dependencies: ["RegravaCore"]),
        // ScreenCaptureKit recording + mouse event tracking.
        .target(name: "RegravaCapture", dependencies: ["RegravaCore"]),
        .testTarget(name: "RegravaCoreTests", dependencies: ["RegravaCore"]),
        .testTarget(name: "RegravaRenderTests", dependencies: ["RegravaCore", "RegravaRender"]),
    ],
    swiftLanguageModes: [.v5]
)
