// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nimb",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Nimb", path: "Sources/Nimb")
    ]
)
