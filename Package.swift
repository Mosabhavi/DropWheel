// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DropWheel",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "DropWheel", path: "Sources/DropWheel")
    ],
    swiftLanguageModes: [.v5]
)
