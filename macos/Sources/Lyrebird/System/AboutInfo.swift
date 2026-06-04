import Foundation

/// Shared, side-effect-free source of truth for the app's "about" payload.
///
/// Two surfaces show the same identity block:
///
/// 1. The Preferences → About pane (`PreferencesAbout`), which users reach
///    inside Settings, and
/// 2. The dedicated **About Lyrebird** window (`AboutView`) summoned from the
///    app menu's standard `.appInfo` slot (#25).
///
/// Both render version / build / copyright / connected-server / credits from
/// *this* enum so the two can never drift. Before this existed each surface
/// reimplemented `Bundle.main.object(forInfoDictionaryKey:)` lookups inline,
/// which is exactly the kind of duplicate that rots when one is bumped and the
/// other forgotten.
///
/// ## Testability
///
/// Everything here is a pure function over its inputs. The bundle lookups take
/// an injectable ``BundleReading`` so tests assert on a fake bundle without
/// touching `Bundle.main`, and ``connectedServerHost(from:)`` reuses the same
/// host-only redaction contract as `DiagnosticBundle` (host only — no scheme,
/// userinfo, port, path, or query). The static ``credits`` list is plain data.
enum AboutInfo {

    // MARK: - Bundle reading seam

    /// Minimal read seam over `Bundle`'s Info.plist lookup so the version /
    /// build / copyright accessors are unit-testable without `Bundle.main`.
    protocol BundleReading {
        func infoString(for key: String) -> String?
    }

    /// `Bundle` conformance: reads `Info.plist` string values, treating an
    /// empty string as absent so callers fall back to a placeholder rather
    /// than rendering a blank row.
    struct AppBundle: BundleReading {
        let bundle: Bundle
        init(_ bundle: Bundle = .main) { self.bundle = bundle }

        func infoString(for key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    // MARK: - Identity

    /// Display name. A literal rather than a bundle lookup so the About
    /// surfaces stay correct even running unbundled from Xcode (where
    /// `CFBundleName` can be the executable name).
    static let appName = "Lyrebird"

    /// One-line product description, shared by both About surfaces.
    static let tagline = "A native macOS music player for Jellyfin."

    /// Marketing version (`CFBundleShortVersionString`). Falls back to a
    /// dev-only placeholder when the bundle key is missing — e.g. when running
    /// from Xcode against an unconfigured Info.plist.
    static func version(bundle: BundleReading = AppBundle()) -> String {
        bundle.infoString(for: "CFBundleShortVersionString") ?? "0.0.0 (dev)"
    }

    /// Build number (`CFBundleVersion`). Same fallback reasoning as
    /// ``version(bundle:)``.
    static func build(bundle: BundleReading = AppBundle()) -> String {
        bundle.infoString(for: "CFBundleVersion") ?? "—"
    }

    /// Copyright string (`NSHumanReadableCopyright`). When missing, render a
    /// generic attribution rather than an empty row.
    static func copyright(bundle: BundleReading = AppBundle()) -> String {
        bundle.infoString(for: "NSHumanReadableCopyright")
            ?? "Copyright © Skyler Althoff and Lyrebird contributors."
    }

    // MARK: - Connected server

    /// Bare host of the connected server, dropping scheme, userinfo, port,
    /// path, and query. Returns `nil` for an empty / signed-out URL so callers
    /// can hide the row entirely rather than print a placeholder.
    ///
    /// Mirrors `DiagnosticBundle.redactServerHost`'s contract: the About window
    /// is a user-facing, screenshot-prone surface, so it deliberately shows the
    /// host only — never a reverse-proxy path, token query, or basic-auth
    /// userinfo that the full `serverURL` can carry.
    ///
    /// Examples:
    /// - `https://music.example.com/jellyfin` → `music.example.com`
    /// - `https://user:pw@host:8443/x?token=abc` → `host`
    /// - `music.example.com:8096` → `music.example.com`
    /// - `""` → `nil`
    static func connectedServerHost(from urlString: String) -> String? {
        // Shared with `DiagnosticBundle.redactServerHost` so the two never
        // drift; the only difference is the empty/signed-out spelling, which
        // this surface renders as `nil` (the row is hidden) rather than a
        // placeholder string.
        ServerHostRedaction.host(from: urlString)
    }

    // MARK: - Credits

    /// A single acknowledgement row: the named project plus a one-line note on
    /// what it does for Lyrebird. `Identifiable` so the About window can drive
    /// a `ForEach` directly off the catalog.
    struct Credit: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let role: String
    }

    /// Short acknowledgements list shown in the About window. Hand-curated (the
    /// open-source projects Lyrebird leans on most directly) rather than a
    /// scraped dependency dump, so it stays a readable credit rather than a
    /// license manifest. Kept here, not in the view, so it's assertable.
    static let credits: [Credit] = [
        Credit(name: "Jellyfin", role: "The free software media server Lyrebird connects to."),
        Credit(name: "Nuke", role: "Artwork loading, caching, and decoding."),
        Credit(name: "Sparkle", role: "Secure in-app software updates."),
        Credit(name: "Mozilla UniFFI", role: "Swift bindings over the Rust core."),
    ]
}
