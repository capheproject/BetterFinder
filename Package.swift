// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BetterFinder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BetterFinder",
            path: "Sources/BetterFinder",
            linkerSettings: [
                .linkedFramework("Quartz"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        )
    ]
)
