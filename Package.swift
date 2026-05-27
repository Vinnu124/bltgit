// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "bltgit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "bltgit",
            path: "Sources"
        ),
        .testTarget(
            name: "bltgitTests",
            dependencies: ["bltgit"],
            path: "Tests"
        ),
    ]
)
