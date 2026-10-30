// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhostKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "GhostKit", targets: ["GhostKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "GhostKit",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .testTarget(name: "GhostKitTests", dependencies: ["GhostKit"]),
    ]
)
