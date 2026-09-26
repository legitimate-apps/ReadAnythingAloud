// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadAloudKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ReadAloudKit", targets: ["ReadAloudKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .target(
            name: "ReadAloudKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [
                .copy("Resources/Readability.js"),
                .copy("Resources/Readability-readerable.js"),
                .copy("Resources/ArticleWalker.js"),
            ]
        ),
        .executableTarget(
            name: "ReadAloudProbe",
            dependencies: ["ReadAloudKit", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "KokoroDebug",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "ReadAloudKitTests",
            dependencies: ["ReadAloudKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
