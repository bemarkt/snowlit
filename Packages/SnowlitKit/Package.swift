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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
    ],
    targets: [
        .target(name: "SnowlitCore"),
        .target(name: "SnowlitStorage", dependencies: ["SnowlitCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "YingxueKit", dependencies: ["SnowlitCore", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "SnowlitReader", dependencies: ["SnowlitCore"]),
        .testTarget(name: "SnowlitCoreTests", dependencies: ["SnowlitCore"]),
        .testTarget(name: "SnowlitStorageTests", dependencies: ["SnowlitCore", "SnowlitStorage", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "YingxueKitTests", dependencies: ["SnowlitCore", "YingxueKit"]),
    ],
    swiftLanguageModes: [.v6]
)
