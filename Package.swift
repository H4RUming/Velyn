// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VelynEngine",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "VelynEngine", targets: ["VelynEngine"])],
    targets: [
        .target(name: "VelynEngine", path: "Velyn/Engine"),
        .testTarget(name: "VelynEngineTests", dependencies: ["VelynEngine"], path: "Tests/VelynEngineTests", resources: [.copy("Fixtures")])
    ]
)
