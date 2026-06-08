// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bltgit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "bltgit"
        ),
        .testTarget(
            name: "bltgitTests",
            dependencies: ["bltgit"]
        ),
    ]
)
