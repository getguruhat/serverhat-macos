// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ServerHat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ServerHat", path: "Sources/ServerHat"),
        .testTarget(name: "ServerHatTests", dependencies: ["ServerHat"], path: "Tests/ServerHatTests"),
    ]
)
