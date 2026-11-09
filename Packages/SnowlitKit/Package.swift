// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnowlitKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "SnowlitCore", targets: ["SnowlitCore"]),
        .library(name: "SnowlitStorage", targets: ["SnowlitStorage"]),
        .library(name: "YingxueKit", targets: ["YingxueKit"]),
        .library(name: "SnowlitReader", targets: ["SnowlitReader"]),
    ],
    targets: [
        .target(name: "SnowlitCore"),
        .target(name: "SnowlitStorage", dependencies: ["SnowlitCore"]),
        .target(name: "YingxueKit", dependencies: ["SnowlitCore"]),
        .target(name: "SnowlitReader", dependencies: ["SnowlitCore"]),
        .testTarget(name: "SnowlitStorageTests", dependencies: ["SnowlitStorage"]),
    ],
    swiftLanguageModes: [.v6]
)
