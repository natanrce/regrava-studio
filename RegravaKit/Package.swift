// swift-tools-version: 6.0
import PackageDescription

/// Engine of Regrava Studio, used by the app target in "Regrava Studio.xcodeproj".
let package = Package(
    name: "RegravaKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RegravaCore", targets: ["RegravaCore"]),
    ],
    targets: [
        // Pure, platform-independent logic: models, auto-zoom, grouping, springs, camera track.
        .target(name: "RegravaCore"),
    ],
    swiftLanguageModes: [.v5]
)
