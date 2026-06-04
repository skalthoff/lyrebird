import Foundation
import LyrebirdCore

/// Decides *when* to scrobble, independent of *how*.
///
/// The "how" — POSTing to ListenBrainz — lives in the Rust core
/// (`scrobble_now_playing` / `scrobble_submit_listen`). This gate owns the
/// per-track bookkeeping that decides which of those calls to make and exactly
/// once each:
///
/// - A **`playing_now`** fires the moment a new track becomes current.
/// - A **`single`** (durable listen) fires once that track crosses the
///   scrobble threshold (half the track, or four minutes — see
///   `core.scrobbleThresholdReached`). It is keyed to the track's *start*
///   time, which the gate captures when the track first appears.
///
/// The gate is a plain value type with no networking and no `LyrebirdCore`
/// dependency in its decision path (the threshold rule is injected), so the
/// trigger logic is deterministic and unit-testable without a server. The
/// owner (`AppModel`) drives it from the 1 Hz status poll: `noteTrack(...)` on
/// every tick, then performs whichever `Action` comes back.
///
/// Implements #46.
struct ScrobbleGate {
    /// What the owner should do in response to a poll tick. `.none` is the
    /// overwhelmingly common case (mid-track, nothing to send).
    enum Action: Equatable {
        case none
        /// Send a `playing_now` for this track.
        case nowPlaying(Track)
        /// Send a durable `single` listen for this track, keyed to the given
        /// Unix start timestamp (seconds).
        case submitListen(Track, listenedAt: Int64)
    }

    /// The track currently being tracked, and the bookkeeping for it.
    private var currentId: String?
    private var startedAtUnix: Int64 = 0
    private var submittedListen = false

    /// Feed the gate one observation. Pass the current track (or `nil` when
    /// playback stopped), its playhead `position` and `duration` in seconds,
    /// whether scrobbling is enabled + configured, and a `thresholdReached`
    /// predicate (production hands in `core.scrobbleThresholdReached`).
    ///
    /// `now` is injectable for tests; production passes the wall clock.
    ///
    /// Returns the single action to perform this tick. When scrobbling is off
    /// the gate still tracks the current track id (so re-enabling mid-track
    /// doesn't retro-fire a stale `playing_now`) but emits `.none`.
    mutating func noteTrack(
        _ track: Track?,
        position: Double,
        duration: Double,
        enabled: Bool,
        now: Int64 = Int64(Date().timeIntervalSince1970),
        thresholdReached: (_ position: Double, _ duration: Double) -> Bool
    ) -> Action {
        // Playback stopped / no track: reset so the next track starts clean.
        guard let track, !track.id.isEmpty else {
            reset()
            return .none
        }

        // New track became current — reset per-track state and capture the
        // start time. Emit `playing_now` only when scrobbling is live.
        if track.id != currentId {
            currentId = track.id
            startedAtUnix = now
            submittedListen = false
            return enabled ? .nowPlaying(track) : .none
        }

        // Same track, already counted, or scrobbling disabled: nothing to do.
        guard enabled, !submittedListen else { return .none }

        // Threshold crossed for the first time -> one durable listen, keyed to
        // the captured start time (ListenBrainz dedupes on `listened_at`).
        if thresholdReached(position, duration) {
            submittedListen = true
            return .submitListen(track, listenedAt: startedAtUnix)
        }

        return .none
    }

    /// Forget the current track. Called implicitly when playback stops; exposed
    /// so the owner can also clear state on logout / explicit stop.
    mutating func reset() {
        currentId = nil
        startedAtUnix = 0
        submittedListen = false
    }
}

/// `@AppStorage` keys + convenience readers for the scrobbling preference.
///
/// Only the **enabled** flag lives in `UserDefaults`; the ListenBrainz token
/// itself is a secret and is stored exclusively in the Rust core's settings
/// table (never `UserDefaults`, never the diagnostic bundle). The pane writes
/// the token through `AppModel`, which forwards it to the core.
enum ScrobblePreference {
    /// Whether scrobbling is switched on. A token can be configured while the
    /// master switch is off (e.g. temporarily paused), so the gate checks
    /// *both* this flag and the core's `isScrobbleConfigured()`.
    static let enabledKey = "scrobble.enabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
