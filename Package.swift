// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RDNS",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RDNS", path: "Sources/RDNS")
    ]
)
