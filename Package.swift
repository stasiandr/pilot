// swift-tools-version: 6.0
import PackageDescription

// Rustlyn is built by `build-rust.sh` into `.build/rustlyn` and linked
// statically: one binary to sign and ship, and nothing to find at launch.
// `build.sh` runs that script first, so `swift build` on its own only works
// once something has.
let package = Package(
    name: "Pilot",
    platforms: [.macOS(.v14)],
    targets: [
        // The C interface to Rustlyn. The header under `include/` is not
        // checked in — `build-rust.sh` copies it out of the Rustlyn checkout
        // beside the library it just built, so Swift cannot be compiling
        // against declarations that build does not have.
        .systemLibrary(name: "CRustlyn", path: "Sources/CRustlyn"),
        .executableTarget(
            name: "Pilot",
            dependencies: ["CRustlyn"],
            path: "Sources/Pilot",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .unsafeFlags(["-L.build/rustlyn"]),
            ]
        ),
    ]
)
