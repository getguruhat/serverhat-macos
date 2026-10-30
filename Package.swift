// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalWeb",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "LocalWeb", path: "Sources/LocalWeb")]
)
