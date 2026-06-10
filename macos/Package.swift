// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lyrebird",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lyrebird", targets: ["Lyrebird"]),
        .executable(name: "SmokeTest", targets: ["SmokeTest"]),
        .library(name: "LyrebirdCore", targets: ["LyrebirdCore"]),
        .library(name: "LyrebirdAudio", targets: ["LyrebirdAudio"]),
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
        // Sentry crash reporter. Opt-in only; initialized at startup behind a
        // UserDefaults gate + DSN presence check. DSN is never committed —
        // inject via Info.plist key `LyrebirdSentryDSN` at build time. See #442.
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.40.0"),
    ],
    targets: [
        .binaryTarget(
            name: "LyrebirdCoreFFI",
            path: "Lyrebird.xcframework"
        ),
        .target(
            name: "LyrebirdCore",
            dependencies: ["LyrebirdCoreFFI"],
            path: "Sources/LyrebirdCore"
        ),
        .target(
            name: "LyrebirdAudio",
            dependencies: ["LyrebirdCore"],
            path: "Sources/LyrebirdAudio"
        ),
        .executableTarget(
            name: "Lyrebird",
            dependencies: [
                "LyrebirdCore",
                "LyrebirdAudio",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/Lyrebird",
            // Resources are NOT processed by SwiftPM. SwiftPM's generated
            // `resource_bundle_accessor.swift` resolves the bundle via
            // `Bundle.main.bundleURL.appendingPathComponent("<Pkg>_<Target>.bundle")`,
            // so the bundle has to live at the .app's TOP LEVEL — but
            // macOS .app structure forbids any top-level entry other
            // than `Contents/` (`codesign` rejects with "unsealed contents
            // present in the bundle root"). Instead, `make-bundle.sh`
            // copies `Sources/Lyrebird/Resources/` contents straight into
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
            dependencies: ["LyrebirdCore", "LyrebirdAudio"],
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
        // Unit tests for the `Lyrebird` app module. `@testable import Lyrebird`
        // reaches the executable target's internal symbols (e.g. `AppModel`),
        // so view-model logic can be exercised headlessly without booting the
        // SwiftUI scene graph. See `Tests/LyrebirdTests`.
        .testTarget(
            name: "LyrebirdTests",
            dependencies: [
                "Lyrebird",
                "LyrebirdAudio",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Tests/LyrebirdTests"
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
