import XCTest

@testable import Lyrebird

/// Coverage for ``BetaChannelPreference`` and ``UpdaterDelegate`` channel logic.
///
/// The key invariants:
///
///  1. Opted-out (default): `allowedChannels` returns an empty set so
///     Sparkle only offers items with no `<sparkle:channel>` tag (stable).
///  2. Opted-in: `allowedChannels` returns `["beta"]` so Sparkle considers
///     both un-tagged (stable) and beta-tagged items, installing whichever
///     version string is newer.
///  3. The UserDefaults key is stable — stored values survive app restarts.
///  4. Toggling the preference changes the allowed-channels set without
///     requiring a relaunch (the delegate reads the default on every call).
final class BetaChannelTests: XCTestCase {

    // MARK: - BetaChannelPreference.allowedChannels

    /// Default (opt-out) state produces an empty channel set.
    /// An empty set is Sparkle's "stable only" signal.
    func testAllowedChannelsWhenOptedOut() {
        let channels = BetaChannelPreference.allowedChannels(betaOptIn: false)
        XCTAssertTrue(channels.isEmpty, "Stable-only users must receive an empty allowed-channels set")
    }

    /// Opted-in state produces exactly `["beta"]`.
    func testAllowedChannelsWhenOptedIn() {
        let channels = BetaChannelPreference.allowedChannels(betaOptIn: true)
        XCTAssertEqual(channels, ["beta"])
    }

    /// The channel identifier must be the lowercase string "beta" — Sparkle
    /// matches it case-sensitively against `<sparkle:channel>` tag values.
    func testBetaChannelIdentifierIsLowercaseBeta() {
        let channels = BetaChannelPreference.allowedChannels(betaOptIn: true)
        XCTAssertTrue(channels.contains("beta"), "Channel identifier must be lowercase 'beta'")
        XCTAssertFalse(channels.contains("Beta"), "Channel identifier must not use title-case")
    }

    /// Verifies that calling `allowedChannels(betaOptIn:)` with `false` after
    /// `true` (simulating a toggle-off) correctly returns the empty set —
    /// the function is stateless and reflects the argument on every call.
    func testAllowedChannelsIsStateless() {
        let afterOptIn = BetaChannelPreference.allowedChannels(betaOptIn: true)
        XCTAssertFalse(afterOptIn.isEmpty)

        let afterOptOut = BetaChannelPreference.allowedChannels(betaOptIn: false)
        XCTAssertTrue(afterOptOut.isEmpty, "Opting back out must return an empty set without relaunch")
    }

    // MARK: - UserDefaults key stability

    /// The key constant must match the value expected by `@AppStorage` in
    /// `PreferencesGeneral`. If this test breaks, both the stored preference
    /// and the `UpdaterDelegate` read-path are silently mismatched.
    func testBetaOptInKeyIsStable() {
        XCTAssertEqual(BetaChannelPreference.betaOptInKey, "updates.betaOptIn")
    }

    /// Reading a key that has never been written returns `false` (the opt-out
    /// default), so fresh installs never silently receive beta updates.
    func testBetaOptInDefaultIsFalse() {
        let domain = "com.lyrebird.BetaChannelTestSuite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        let stored = defaults.bool(forKey: BetaChannelPreference.betaOptInKey)
        let channels = BetaChannelPreference.allowedChannels(betaOptIn: stored)
        XCTAssertTrue(channels.isEmpty, "A fresh install must default to stable-only")
    }

    /// Writing `true` to the key and reading it back produces `["beta"]`,
    /// confirming the round-trip that `UpdaterDelegate.allowedChannels(for:)`
    /// relies on at runtime.
    func testUserDefaultsRoundTrip() {
        let domain = "com.lyrebird.BetaChannelTestSuite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        defaults.set(true, forKey: BetaChannelPreference.betaOptInKey)
        let stored = defaults.bool(forKey: BetaChannelPreference.betaOptInKey)
        let channels = BetaChannelPreference.allowedChannels(betaOptIn: stored)
        XCTAssertEqual(channels, ["beta"])
    }
}
