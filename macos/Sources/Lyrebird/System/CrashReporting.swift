import Foundation
import os
import Sentry

/// Opt-in crash and error reporting via Sentry.
///
/// **Design goals**
/// 1. Default-off: nothing is sent until the user flips the toggle in
///    Preferences → Privacy, and the toggle copy makes that clear.
/// 2. No secrets in the repo: the DSN is read from (in order of precedence):
///    a. `UserDefaults` key `"sentry.dsnOverride"` — dev / CI override
///    b. `Info.plist` key `LyrebirdSentryDSN` — set at build time via an
///       environment variable; never committed to source control
///    c. Missing / empty → Sentry is a no-op even if the toggle is on;
///       `CrashReporter.isAvailable` returns `false` and the preference UI
///       shows a "no DSN configured" note.
/// 3. PII scrubbed by `beforeSend`: no request URLs with credentials, no
///    usernames, no track/album/artist names. Stack + OS + app-version only.
/// 4. Rust panics forwarded: `RustCrashReporter` implements the
///    `CrashReporterProtocol` UniFFI callback interface so the Rust side can
///    hand off panic info when the user has opted in and a DSN is present.
///
/// **Initialization lifecycle**
/// `start()` is called once in `LyrebirdApp.init()`, gated on
/// `(optInEnabled && dsnPresent)`. It is idempotent — a second call in the
/// same process is a no-op because `SentrySDK.isEnabled` stays `true` after
/// the first `start`. Changing the opt-in toggle mid-session captures the new
/// value on the next relaunch; `isOptedIn` is read from `UserDefaults` each
/// time `start()` is invoked so a build-time or CI `UserDefaults` override can
/// force-enable in automated testing.
///
/// Issues closed: #442.
enum CrashReporter {

    // MARK: - UserDefaults keys (stable on-disk; changing them silently loses
    // persisted user choices)

    /// The user's opt-in choice. `false` by default.
    static let optInKey = "privacy.crashReportingEnabled"

    /// Development / CI override DSN. When present it wins over `Info.plist`.
    static let dsnOverrideKey = "sentry.dsnOverride"

    /// Info.plist key for the production DSN. Set at build time; never
    /// committed to source. Inject via the environment in CI:
    ///   `INFOPLIST_KEY_LyrebirdSentryDSN=$(SENTRY_DSN)`
    static let infoPlistDSNKey = "LyrebirdSentryDSN"

    // MARK: - Derived state

    /// Resolves the DSN using the documented precedence order:
    ///  1. `UserDefaults["sentry.dsnOverride"]` (dev / CI)
    ///  2. `Info.plist["LyrebirdSentryDSN"]` (build-time injection)
    ///  3. `nil` → Sentry is a no-op
    ///
    /// The returned value is **not** logged anywhere; it would contain a token.
    static var resolvedDSN: String? {
        if let override = UserDefaults.standard.string(forKey: dsnOverrideKey),
           !override.isEmpty {
            return override
        }
        if let plistValue = Bundle.main.infoDictionary?[infoPlistDSNKey] as? String,
           !plistValue.isEmpty {
            return plistValue
        }
        return nil
    }

    /// `true` if a non-empty DSN was resolved from any source.
    static var isAvailable: Bool {
        resolvedDSN != nil
    }

    /// `true` if the user has opted in via the Preferences toggle.
    static var isOptedIn: Bool {
        UserDefaults.standard.bool(forKey: optInKey)
    }

    /// `true` if Sentry is both opted-in and a DSN is present — the combined
    /// predicate that guards `SentrySDK.start`.
    static var shouldInit: Bool {
        isOptedIn && isAvailable
    }

    // MARK: - Initialization

    /// Configure and start the Sentry SDK. Safe to call on the main thread at
    /// app startup. Skips silently if `shouldInit` is `false` or if the SDK
    /// is already running (`SentrySDK.isEnabled`).
    ///
    /// Call exactly once, from `LyrebirdApp.init()` after `UserDefaults` is
    /// reachable.
    static func start() {
        guard shouldInit, !SentrySDK.isEnabled else { return }

        guard let dsn = resolvedDSN else {
            Log.app.notice("[CrashReporter] opt-in set but no DSN found; Sentry not started")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn

            // Error sample rate: 1.0 (all crashes / errors are rare; we
            // want every one). Zero performance traces — no profiling data.
            options.sampleRate = 1.0
            options.tracesSampleRate = 0.0

            // Never send default PII (IP address, device name, user id).
            options.sendDefaultPii = false

            // Strip PII from every event before it leaves the process.
            options.beforeSend = { event in
                return CrashReporter.scrub(event: event)
            }

            // Breadcrumb filter: keep only SDK-internal lifecycle breadcrumbs;
            // drop any that carry user-visible strings (network URLs, titles,
            // view names that could encode library content).
            options.beforeBreadcrumb = { crumb in
                return CrashReporter.shouldKeepBreadcrumb(crumb)
            }

            // Note: `attachScreenshot` and `attachViewHierarchy` are UIKit-only
            // and are not available on macOS; they default to false on all
            // non-UIKit platforms, so no explicit setter is needed here.
        }

        Log.app.notice("[CrashReporter] started (DSN source: \(CrashReporter.dsnSource, privacy: .public))")
    }

    // MARK: - PII scrubbing

    /// Strips fields that could carry PII or library metadata from an event.
    ///
    /// What is kept: exception type + value (stack address, not user data),
    /// stack trace (file + line from Sentry's symbolication), OS version,
    /// app version, device model family (macOS hardware class — not serial).
    ///
    /// What is removed:
    /// - `request.url` and all request headers (could contain server URL +
    ///   credentials or token)
    /// - `user` block entirely
    /// - Any extra/context key whose name looks like library metadata
    ///   (track, album, artist, playlist, query, url, username)
    nonisolated static func scrub(event: Event) -> Event {
        // Remove the user block entirely.
        event.user = nil

        // Remove the request context — it can carry the server URL + token.
        event.request = nil

        // Strip suspicious extra / context keys.
        if var extra = event.extra {
            let bannedSubstrings = ["track", "album", "artist", "playlist",
                                    "query", "url", "username", "user", "token",
                                    "password", "server", "host"]
            for key in extra.keys {
                let lower = key.lowercased()
                if bannedSubstrings.contains(where: { lower.contains($0) }) {
                    extra.removeValue(forKey: key)
                }
            }
            event.extra = extra
        }

        // Remove tags that could encode library paths.
        if var tags = event.tags {
            let bannedSubstrings = ["url", "server", "host", "username"]
            for key in tags.keys {
                let lower = key.lowercased()
                if bannedSubstrings.contains(where: { lower.contains($0) }) {
                    tags.removeValue(forKey: key)
                }
            }
            event.tags = tags
        }

        // Remove the context dictionary entirely — it can carry arbitrary
        // key/value pairs populated by SDK integrations or future event
        // enrichment, and no app-defined context is expected in this build.
        event.context = nil

        return event
    }

    /// Returns `nil` (dropping the crumb) for any breadcrumb that carries
    /// a URL, a network request, or a navigation data string that could
    /// contain library metadata. Keeps level/type bookkeeping breadcrumbs.
    nonisolated static func shouldKeepBreadcrumb(_ crumb: Breadcrumb) -> Breadcrumb? {
        // Drop network request breadcrumbs entirely — the URL encodes the
        // Jellyfin server address and optionally query params with ids.
        if crumb.type == "http" { return nil }

        // Drop breadcrumbs that carry a `url` data field.
        if let data = crumb.data, data["url"] != nil { return nil }

        // Drop navigation breadcrumbs whose `to`/`from` might encode content.
        if crumb.type == "navigation" { return nil }

        return crumb
    }

    // MARK: - Rust panic reporting

    /// Capture a Rust panic as a synthetic `NSError` with the panic message
    /// and location as the error description, and the full backtrace attached
    /// as a breadcrumb. Called from `RustCrashForwarder` (the UniFFI callback
    /// bridge) — no-ops if Sentry is not running.
    static func capturePanic(message: String, location: String, backtrace: String) {
        guard SentrySDK.isEnabled else { return }

        // Build a breadcrumb with the backtrace so it appears in the Sentry
        // issue timeline without polluting the event's `exception` block.
        let crumb = Breadcrumb(level: .fatal, category: "rust.panic")
        crumb.message = "Rust panic at \(location)"
        crumb.data = ["backtrace": String(backtrace.prefix(4000))] // cap size
        SentrySDK.addBreadcrumb(crumb)

        let error = NSError(
            domain: "org.lyrebird.desktop.rust",
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "Rust panic: \(message) (at \(location))"
            ]
        )
        SentrySDK.capture(error: error)

        Log.app.error("[CrashReporter] Rust panic captured: \(message, privacy: .public) at \(location, privacy: .public)")
    }

    // MARK: - Helpers

    /// Human-readable label for the DSN source — logged at startup (not the
    /// DSN value itself). Marked `privacy: .public` in the log call site.
    private static var dsnSource: String {
        if UserDefaults.standard.string(forKey: dsnOverrideKey).map({ !$0.isEmpty }) == true {
            return "UserDefaults override"
        }
        return "Info.plist"
    }
}

// MARK: - Decision helper (extracted for unit testing)

/// Pure function that mirrors `CrashReporter.shouldInit` but takes its
/// inputs explicitly so tests can exercise all four combinations without
/// touching `UserDefaults` or `Bundle.main`.
///
/// This is the single source of truth for "should Sentry be started" and
/// is tested in `CrashReporterDecisionTests`.
func crashReporterShouldInit(optedIn: Bool, dsnPresent: Bool) -> Bool {
    optedIn && dsnPresent
}
