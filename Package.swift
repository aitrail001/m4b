// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudiobookBinder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AudiobookBinder", targets: ["AudiobookBinder"])
    ],
    targets: [
        .target(
            name: "AudiobookBinderCore",
            path: "Sources/AudiobookBinderCore"
        ),
        .executableTarget(
            name: "AudiobookBinder",
            dependencies: ["AudiobookBinderCore"],
            path: "Sources/AudiobookBinder"
        ),
        .executableTarget(
            name: "AudiobookBinderSelfTest",
            dependencies: ["AudiobookBinderCore"],
            path: "Sources/AudiobookBinderSelfTest"
        ),
        .testTarget(
            name: "AudiobookBinderTests",
            dependencies: ["AudiobookBinderCore"],
            path: "Tests/AudiobookBinderTests"
        )
    ]
)
