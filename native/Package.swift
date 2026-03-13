// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KlausAvatar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tattn/VRMKit.git", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "KlausAvatar",
            dependencies: [
                .product(name: "VRMKit", package: "VRMKit"),
                .product(name: "VRMSceneKit", package: "VRMKit"),
            ],
            path: "Sources",
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
