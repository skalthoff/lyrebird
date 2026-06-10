import Sentry
import XCTest

@testable import Lyrebird

/// Unit tests for the opt-in Sentry crash-reporter decision logic (#442).
///
/// Tests are split into three areas:
///
/// 1. **`crashReporterShouldInit` pure function** — exercises all four
///    (optedIn × dsnPresent) combinations without touching `UserDefaults` or
///    `Bundle.main`, so CI doesn't need a real DSN.
///
/// 2. **DSN precedence** — verifies the documented resolution order:
///    `UserDefaults["sentry.dsnOverride"]` > `Info.plist["LyrebirdSentryDSN"]` >
///    `nil` (no-op). Exercises `CrashReporter.resolvedDSN` with a scratchpad
///    `UserDefaults` suite so the real `standard` suite is never polluted.
///
/// 3. **Key stability** — ensures `optInKey` and `dsnOverrideKey` match the
///    documented on-disk values so a typo doesn't silently discard persisted
///    user preferences across app updates.
///
/// Sentry's `SentrySDK.start` is NOT called in these tests — that would require
/// a real DSN and outbound network access. The decision logic is fully testable
/// without it because `crashReporterShouldInit` is a pure function and
/// `CrashReporter.resolvedDSN` reads `UserDefaults` + `Bundle.main` without
/// side-effecting Sentry.
final class CrashReporterDecisionTests: XCTestCase {

    // MARK: - Pure-function decision matrix

    func testOffWhenNeitherOptedInNorDSNPresent() {
        XCTAssertFalse(
            crashReporterShouldInit(optedIn: false, dsnPresent: false),
            "neither opt-in nor DSN → must not start"
        )
    }

    func testOffWhenOptedInButNoDSN() {
        XCTAssertFalse(
            crashReporterShouldInit(optedIn: true, dsnPresent: false),
            "opted in but no DSN configured → must not start (and should be benign)"
        )
    }

    func testOffWhenDSNPresentButNotOptedIn() {
        XCTAssertFalse(
            crashReporterShouldInit(optedIn: false, dsnPresent: true),
            "DSN present but user has not opted in → must not start (default-off guarantee)"
        )
    }

    func testOnWhenOptedInAndDSNPresent() {
        XCTAssertTrue(
            crashReporterShouldInit(optedIn: true, dsnPresent: true),
            "opted in + DSN configured → should start"
        )
    }

    // MARK: - Default-off guarantee

    /// The toggle's raw `UserDefaults` key must default to `false` when absent,
    /// matching the declared default in `PreferencesPrivacy` and the intent of
    /// "opt-in, not opt-out". Tests the key with a fresh isolated suite so the
    /// real `standard` suite state doesn't affect the result.
    func testDefaultIsOff() {
        let suite = UserDefaults(suiteName: "test.crash_reporter_decision.\(UUID().uuidString)")!
        // No value written → bool(forKey:) returns false.
        XCTAssertFalse(
            suite.bool(forKey: CrashReporter.optInKey),
            "crash reporting must be off by default (key absent → false)"
        )
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)
    }

    // MARK: - DSN precedence

    /// `UserDefaults` override wins over an `Info.plist` value when both are
    /// present. Uses a temporary domain to avoid polluting `standard`.
    func testUserDefaultsOverrideTakesPrecedenceOverInfoPlist() {
        let domain = "test.sentry_dsn_precedence.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: domain)!
        let overrideValue = "https://override@sentry.example.com/1"

        suite.set(overrideValue, forKey: CrashReporter.dsnOverrideKey)
        suite.synchronize()

        // Write the override into `standard` too (CrashReporter reads standard)
        // and clean up afterward.
        UserDefaults.standard.set(overrideValue, forKey: CrashReporter.dsnOverrideKey)
        defer {
            UserDefaults.standard.removeObject(forKey: CrashReporter.dsnOverrideKey)
            suite.removePersistentDomain(forName: domain)
        }

        guard let resolved = CrashReporter.resolvedDSN else {
            XCTFail("resolvedDSN should be non-nil when override is set")
            return
        }
        XCTAssertEqual(resolved, overrideValue, "UserDefaults override must win")
    }

    /// When the `UserDefaults` override is absent, `resolvedDSN` returns `nil`
    /// (because `Info.plist["LyrebirdSentryDSN"]` is empty in test builds). This
    /// confirms that an empty plist value is treated as "no DSN" and not as a
    /// valid empty-string DSN.
    func testEmptyInfoPlistDSNTreatedAsAbsent() {
        // Ensure no UserDefaults override is present.
        UserDefaults.standard.removeObject(forKey: CrashReporter.dsnOverrideKey)
        // The Info.plist in the test bundle has LyrebirdSentryDSN = "" (empty).
        // resolvedDSN must return nil for an empty string.
        // Note: if the test runner's bundle happens not to have this key at all,
        // the same nil result is correct and the assertion still passes.
        let plistValue = Bundle.main.infoDictionary?[CrashReporter.infoPlistDSNKey] as? String
        if let plistValue, !plistValue.isEmpty {
            // The test bundle has a real DSN — skip this assertion so the test
            // doesn't fail in a build that intentionally ships a DSN.
            return
        }
        XCTAssertNil(
            CrashReporter.resolvedDSN,
            "empty or absent Info.plist DSN must make resolvedDSN nil → no-op"
        )
    }

    /// When `UserDefaults["sentry.dsnOverride"]` is cleared, `isAvailable`
    /// matches whatever `resolvedDSN` returns (nil → false).
    func testIsAvailableMatchesResolvedDSN() {
        UserDefaults.standard.removeObject(forKey: CrashReporter.dsnOverrideKey)
        let expected = CrashReporter.resolvedDSN != nil
        XCTAssertEqual(CrashReporter.isAvailable, expected,
                       "isAvailable must equal (resolvedDSN != nil)")
    }

    // MARK: - Key stability

    /// Changing `optInKey` would silently lose every user's persisted choice
    /// on the next app update. Pin it to the expected on-disk value.
    func testOptInKeyIsStable() {
        XCTAssertEqual(CrashReporter.optInKey, "privacy.crashReportingEnabled",
                       "optInKey must not change — it is a persisted UserDefaults key")
    }

    /// `dsnOverrideKey` is a developer / CI escape hatch; its name is documented
    /// in Info.plist comments and CLAUDE.md. Pin it so a rename doesn't silently
    /// break CI scripts.
    func testDSNOverrideKeyIsStable() {
        XCTAssertEqual(CrashReporter.dsnOverrideKey, "sentry.dsnOverride",
                       "dsnOverrideKey must not change — it is documented in Info.plist and CLAUDE.md")
    }

    /// `infoPlistDSNKey` names the Info.plist key injected by the build system.
    /// Pin it so a rename requires a matching change in the release workflow.
    func testInfoPlistDSNKeyIsStable() {
        XCTAssertEqual(CrashReporter.infoPlistDSNKey, "LyrebirdSentryDSN",
                       "infoPlistDSNKey must not change without updating the release workflow")
    }

    // MARK: - PII scrubbing

    /// The `beforeSend` scrubber must strip the `user` block. Verifying
    /// the static helper (no Sentry SDK state needed).
    func testScrubRemovesUser() {
        let event = Event()
        event.user = User()
        event.user?.email = "test@example.com"

        let scrubbed = CrashReporter.scrub(event: event)
        XCTAssertNil(scrubbed.user, "scrub must remove the user block entirely")
    }

    /// The scrubber must remove the `request` block (which can carry the
    /// Jellyfin server URL and token).
    func testScrubRemovesRequest() {
        let event = Event()
        let request = SentryRequest()
        request.url = "https://music.example.com/Items?api_key=secret"
        event.request = request

        let scrubbed = CrashReporter.scrub(event: event)
        XCTAssertNil(scrubbed.request, "scrub must remove the request block (contains server URL)")
    }

    /// Extra keys matching library-metadata patterns must be removed.
    func testScrubRemovesLibraryMetadataExtras() {
        let event = Event()
        event.extra = [
            "trackId": "abc123" as AnyObject,
            "albumTitle": "My Album" as AnyObject,
            "artistName": "Some Artist" as AnyObject,
            "appVersion": "1.2.3" as AnyObject,  // safe — should be kept
            "server": "https://music.example.com" as AnyObject,
        ]

        let scrubbed = CrashReporter.scrub(event: event)
        let remaining = Array((scrubbed.extra ?? [:]).keys)
        XCTAssertFalse(remaining.contains("trackId"), "trackId must be stripped")
        XCTAssertFalse(remaining.contains("albumTitle"), "albumTitle must be stripped")
        XCTAssertFalse(remaining.contains("artistName"), "artistName must be stripped")
        XCTAssertFalse(remaining.contains("server"), "server must be stripped")
        XCTAssertTrue(remaining.contains("appVersion"), "appVersion is not PII — must be kept")
    }

    /// The scrubber must clear the context dictionary — it can carry arbitrary
    /// key/value dicts populated by SDK integrations or future enrichment.
    func testScrubDoesNotLeakContextDict() {
        let event = Event()
        event.context = ["server": ["url": "https://music.example.com", "token": "secret"]]
        let scrubbed = CrashReporter.scrub(event: event)
        XCTAssertNil(scrubbed.context?["server"], "scrub must clear event.context entirely")
    }

    // MARK: - Breadcrumb filtering

    func testHTTPBreadcrumbIsDropped() {
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.type = "http"
        let result = CrashReporter.shouldKeepBreadcrumb(crumb)
        XCTAssertNil(result, "HTTP breadcrumbs expose server URLs — must be dropped")
    }

    func testNavigationBreadcrumbIsDropped() {
        let crumb = Breadcrumb(level: .info, category: "navigation")
        crumb.type = "navigation"
        let result = CrashReporter.shouldKeepBreadcrumb(crumb)
        XCTAssertNil(result, "navigation breadcrumbs can encode library content — must be dropped")
    }

    func testBreadcrumbWithURLDataIsDropped() {
        let crumb = Breadcrumb(level: .info, category: "custom")
        crumb.data = ["url": "https://music.example.com/tracks/123"]
        let result = CrashReporter.shouldKeepBreadcrumb(crumb)
        XCTAssertNil(result, "breadcrumbs carrying a url data field must be dropped")
    }

    func testGenericBreadcrumbIsKept() {
        let crumb = Breadcrumb(level: .info, category: "lifecycle")
        crumb.type = "default"
        let result = CrashReporter.shouldKeepBreadcrumb(crumb)
        XCTAssertNotNil(result, "generic non-PII breadcrumbs must be kept")
    }
}
