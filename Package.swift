// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VelynEngine",
    defaultLocalization: "ko",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "VelynEngine", targets: ["VelynEngine"])],
    targets: [
        .target(name: "VelynEngine", path: "Velyn/Engine", resources: [.process("Resources")]),
        .testTarget(name: "VelynEngineTests", dependencies: ["VelynEngine"], path: "Tests/VelynEngineTests", resources: [.copy("Fixtures")])
    ]
)
