import Foundation

/// Sparkle beta-channel preference — stable `UserDefaults` key and the
/// pure channel-decision helper used both by ``UpdaterDelegate`` and
/// the test suite.
///
/// Sparkle 2 channel semantics:
/// - Items in the appcast with no `<sparkle:channel>` tag are considered
///   "stable" and visible to all users.
/// - Items tagged `<sparkle:channel>beta</sparkle:channel>` are only
///   offered to clients whose delegate returns `["beta"]` from
///   `allowedChannels(for:)`.
/// - A client with allowed channels `["beta"]` sees **both** stable and
///   beta items and installs whichever version string is newer, so a
///   stable release that supersedes the latest beta is picked up
///   automatically.
///
/// The preference defaults to `false` (stable-only). Once set, the value
/// is re-read on every Sparkle check — no relaunch required.
enum BetaChannelPreference {
    /// `UserDefaults` key for the "Receive beta updates" toggle.
    /// Stable `@AppStorage` key — do not rename without a migration.
    static let betaOptInKey = "updates.betaOptIn"

    /// Pure channel-decision function: given the stored preference value,
    /// returns the set of extra channels to pass to Sparkle.
    ///
    /// Extracted here (not inlined in `UpdaterDelegate`) so it is
    /// unit-testable without constructing a live `SPUUpdater`.
    ///
    /// - Parameter betaOptIn: the stored preference value.
    /// - Returns: `["beta"]` when opted in; `[]` otherwise.
    static func allowedChannels(betaOptIn: Bool) -> Set<String> {
        betaOptIn ? ["beta"] : []
    }
}
