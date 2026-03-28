// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SubtitleGenerator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SubtitleGenerator",
            path: "SubtitleGenerator"
        ),
        .testTarget(
            name: "SubtitleGeneratorTests",
            dependencies: ["SubtitleGenerator"],
            path: "Tests"
        )
    ]
)
