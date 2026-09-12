// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pilot",
            path: "Sources/Pilot",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        )
    ]
)
