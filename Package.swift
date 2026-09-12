// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flint",
            path: "Sources/Flint",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        )
    ]
)
