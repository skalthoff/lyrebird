import Foundation
import os

/// Centralized `os.Logger` instances keyed by subsystem area.
///
/// Why a wrapper over the prior `print(...)` pattern: `os.Logger` writes to
/// the unified system log (visible in `Console.app` and `log stream`), is
/// privacy-aware (PII is redacted by default), and survives app crashes —
/// the user can reproduce a bug, copy the relevant entries from Console,
/// and paste them into a GitHub issue. `print` only reaches Xcode's debug
/// console, which is useless for shipped DMGs.
///
/// Categories are scoped to the area of responsibility, not the type. Two
/// types in the same screen share a category if they're solving the same
/// problem (e.g. `AlbumDetailView` + the `AlbumTracks` cache helper both
/// log under `albums`). Keep the count small — Console's filter UI grows
/// hairy past ~10 categories.
///
/// Filter in Console.app:
///     subsystem:org.jellify.desktop category:albums
///
/// `OSLog` exposes its messages to `log stream` / `log show` even when the
/// app isn't attached to a debugger:
///     log stream --predicate 'subsystem == "org.jellify.desktop"' --info --debug
///     log show  --predicate 'subsystem == "org.jellify.desktop"' --last 30m --info --debug
///
/// `--info` and `--debug` are required to surface `.info` / `.debug` levels;
/// `.notice` and above are visible by default.
enum Log {
    /// CFBundleIdentifier; matches the `subsystem` field every entry carries.
    /// Hard-coded rather than read at runtime so `Logger` instances can be
    /// `static let` (read-once, no first-call cost).
    static let subsystem = "org.jellify.desktop"

    /// Top-level lifecycle, login/logout, library refresh — anything in
    /// `AppModel` that doesn't fit a more specific category.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Album browse + detail flow: `loadTracks(forAlbum:)`,
    /// `resolveAlbum(id:)`, `loadAlbumDetail`, `AlbumDetailView`'s `.task`.
    /// Heavy logging here is intentional for debugging tracklist-doesn't-
    /// load reports — the perf cost is negligible vs. the 200ms+ user
    /// expects for the network round-trip.
    static let albums = Logger(subsystem: subsystem, category: "albums")

    /// Track-level operations: track row interactions, favorites toggles,
    /// played-mark mutations, queue mutations. Kept distinct from `albums`
    /// so a noisy heart-spam session doesn't drown out album-load traces.
    static let tracks = Logger(subsystem: subsystem, category: "tracks")

    /// AVQueuePlayer lifecycle, AudioEngine state transitions, transcode
    /// fallbacks, lyrics fetch.
    static let player = Logger(subsystem: subsystem, category: "player")

    /// HTTP / FFI errors that aren't auth-related — 5xx responses, timeouts,
    /// JSON decode failures. Auth lives in `auth` so a 401 storm doesn't
    /// pollute the network category.
    static let net = Logger(subsystem: subsystem, category: "net")

    /// Token persistence, sign-in / sign-out, refresh callback, the auth-
    /// expired modal flow.
    static let auth = Logger(subsystem: subsystem, category: "auth")

    /// Sparkle / Updater diagnostics. Currently only emits at install /
    /// upgrade boundaries; chatty during release testing.
    static let updater = Logger(subsystem: subsystem, category: "updater")

    /// True when the user has flipped the verbose-logging toggle in
    /// Preferences → Advanced. Gates `.debug`-level emissions; `.info` and
    /// up are always written. Read via `UserDefaults` so Logger.debug call
    /// sites can branch without needing a `@AppStorage` binding.
    static var isVerbose: Bool {
        UserDefaults.standard.bool(forKey: "advanced.verboseLogging")
    }
}
