// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuildThisPlease",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "BuildThisPleaseCore", targets: ["BuildThisPleaseCore"]),
        .library(name: "BuildThisPleaseUI", targets: ["BuildThisPleaseUI"]),
        .library(name: "BuildThisPlease", targets: ["BuildThisPlease"])
    ],
    targets: [
        .target(
            name: "BuildThisPleaseCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "BuildThisPleaseUI",
            dependencies: ["BuildThisPleaseCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "BuildThisPlease",
            dependencies: ["BuildThisPleaseCore", "BuildThisPleaseUI"]
        ),
        .testTarget(name: "BuildThisPleaseCoreTests", dependencies: ["BuildThisPleaseCore"]),
        .testTarget(
            name: "BuildThisPleaseUITests",
            dependencies: ["BuildThisPleaseCore", "BuildThisPleaseUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
