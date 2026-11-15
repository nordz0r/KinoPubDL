// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KinoPubDL",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KinoPubDL", targets: ["KinoPubDL"]),
    ],
    targets: [
        .executableTarget(name: "KinoPubDL"),
    ],
    swiftLanguageModes: [.v5]
)
