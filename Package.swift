// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "thing-finder",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "thing-finder",
            targets: ["thing-finder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Liquid4All/leap-ios.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "600.0.1")
    ],
    targets: [
        .target(
            name: "thing-finder",
            dependencies: [
                .product(name: "LeapSDK", package: "leap-ios"),
                .product(name: "LeapModelDownloader", package: "leap-ios")
            ],
            path: "thing-finder",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "thing-finderTests",
            dependencies: ["thing-finder"],
            path: "thing-finderTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
