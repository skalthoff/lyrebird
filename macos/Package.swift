// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jellify",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Jellify", targets: ["Jellify"]),
        .executable(name: "SmokeTest", targets: ["SmokeTest"]),
        .library(name: "JellifyCore", targets: ["JellifyCore"]),
        .library(name: "JellifyAudio", targets: ["JellifyAudio"]),
    ],
    dependencies: [
        // Nuke powers artwork loading (disk cache, request coalescing, background
        // decoding, decode-time downscaling). Replaces SwiftUI.AsyncImage which had
        // no caching and decoded at source resolution — #426 / #427.
        .package(url: "https://github.com/kean/Nuke.git", from: "13.0.0"),
        // Sparkle 2 handles the self-update feed (Ed25519-signed appcast,
        // in-app "Check for Updates…", scheduled background checks).
        // Feed URL + public key live in Info.plist; the release workflow
        // substitutes the public key at build time. See #183/#184/#188.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .binaryTarget(
            name: "JellifyCoreFFI",
            path: "Jellify.xcframework"
        ),
        .target(
            name: "JellifyCore",
            dependencies: ["JellifyCoreFFI"],
            path: "Sources/JellifyCore"
        ),
        .target(
            name: "JellifyAudio",
            dependencies: ["JellifyCore"],
            path: "Sources/JellifyAudio"
        ),
        .executableTarget(
            name: "Jellify",
            dependencies: [
                "JellifyCore",
                "JellifyAudio",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Jellify",
            // Resources are NOT processed by SwiftPM. SwiftPM's generated
            // `resource_bundle_accessor.swift` resolves the bundle via
            // `Bundle.main.bundleURL.appendingPathComponent("<Pkg>_<Target>.bundle")`,
            // so the bundle has to live at the .app's TOP LEVEL — but
            // macOS .app structure forbids any top-level entry other
            // than `Contents/` (`codesign` rejects with "unsealed contents
            // present in the bundle root"). Instead, `make-bundle.sh`
            // copies `Sources/Jellify/Resources/` contents straight into
            // `Contents/Resources/`, and code that needs them reads via
            // `Bundle.main.url(forResource:withExtension:)` (the
            // standard macOS .app pattern).
            // resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["JellifyCore", "JellifyAudio"],
            path: "Sources/SmokeTest",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ],
    // Pin Swift 5 language mode at the package level rather than via per-
    // target `.swiftLanguageMode(.v5)`. The per-target API serialises to
    // `5` (no `.0`) and xcodebuild on Xcode 26 rejects it (`SWIFT_VERSION
    // '5' unsupported, supported: 4.0, 4.2, 5.0, 6.0`). The package-level
    // form serialises through `SWIFT_VERSION = 5.0`. Stays on Swift 5 mode
    // pending the wider Sendable / strict-concurrency cleanup tracked
    // across the codebase.
    swiftLanguageVersions: [.v5]
)
