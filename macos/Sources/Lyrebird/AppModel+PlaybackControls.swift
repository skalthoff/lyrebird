import Foundation
@preconcurrency import LyrebirdCore
import LyrebirdAudio

/// Playback transport and output control on `AppModel`: play/pause/stop, skip
/// next/previous, volume, relative & absolute seek, play/pause toggle, the
/// gapless pre-load arming, Core Audio output-device routing + exclusive (hog)
/// mode, ReplayGain normalization, and the gapless / stop-after-current
/// preferences.
///
/// All state here is either driven through the injected `audio` engine /
/// `core` queue or persisted in `UserDefaults` (static keys), so nothing moved
/// out of the main class's instance storage. Extensions of a `@MainActor` type
/// inherit its isolation, so every method here is main-actor-bound just like
/// the rest of the class.
extension AppModel {
    // MARK: - Transport

    func pause() { audio.pause() }
    func resume() { audio.resume() }
    func stop() { audio.stop() }

    func skipNext() {
        if let next = core.skipNext() {
            playCurrent(next)
        } else {
            stop()
        }
    }

    func skipPrevious() {
        if let prev = core.skipPrevious() {
            playCurrent(prev)
        }
    }

    func setVolume(_ v: Float) { audio.setVolume(v) }

    // MARK: - Output device routing

    /// Select the Core Audio output device playback routes to. Persists the
    /// UID and re-pins the live + future players. An empty UID means "follow
    /// the system default". If exclusive mode is on, the hog claim is moved to
    /// the newly-selected device (and released from the old one); a failure to
    /// release the old claim or acquire the new one surfaces via `errorMessage`.
    func setOutputDevice(uid: String) {
        // Read the previous device from the engine, which still holds the
        // currently-applied output. The Preferences picker commits its
        // `@AppStorage` to UserDefaults *before* calling this, so reading the
        // previous UID from UserDefaults would already see the new value and
        // strand the old device's hog claim.
        let previousUID = audio.outputDeviceUID ?? ""
        UserDefaults.standard.set(uid, forKey: AudioOutputDevices.preferenceKey)
        audio.outputDeviceUID = uid.isEmpty ? nil : uid

        // Migrate an active hog claim to the new device so exclusive mode keeps
        // following the user's chosen output instead of stranding the lock on
        // the old one.
        let exclusive = UserDefaults.standard.bool(forKey: AudioOutputDevices.exclusiveModePreferenceKey)
        guard exclusive else { return }
        Task.detached {
            // Release the old device's hog claim. A failure here can leave the
            // previous device permanently hogged, so surface it instead of
            // swallowing it — but still attempt to claim the new device.
            var releaseError: Error?
            do {
                try AudioOutputDevices.setExclusiveMode(false, forUID: previousUID)
            } catch {
                releaseError = error
            }
            do {
                try AudioOutputDevices.setExclusiveMode(true, forUID: uid)
                if let releaseError {
                    await MainActor.run {
                        self.errorMessage = releaseError.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    UserDefaults.standard.set(false, forKey: AudioOutputDevices.exclusiveModePreferenceKey)
                }
            }
        }
    }

    /// Toggle exclusive (hog) mode on the currently-selected device. Acquires
    /// or releases the Core Audio hog claim off the main actor; on failure it
    /// surfaces `errorMessage` and rolls the persisted flag back to its prior
    /// value (the optimistic-UI-without-echo pattern — CLAUDE.md gap #5).
    /// Returns immediately; the caller's `@AppStorage` binding has already
    /// flipped optimistically.
    func setExclusiveMode(_ enabled: Bool) {
        let uid = UserDefaults.standard.string(forKey: AudioOutputDevices.preferenceKey) ?? ""
        Task.detached {
            do {
                try AudioOutputDevices.setExclusiveMode(enabled, forUID: uid)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    // Roll the toggle back to its pre-tap state.
                    UserDefaults.standard.set(!enabled, forKey: AudioOutputDevices.exclusiveModePreferenceKey)
                }
            }
        }
    }

    /// `@AppStorage` key for the ReplayGain mode (`NormalizationMode` raw value).
    /// Mirrors the literal used by `PreferencesPlayback`; kept here so the init
    /// seed and the picker route never drift apart. See #42.
    static let normalizationKey = "playback.normalization"

    /// `@AppStorage` key for the user pre-gain in dB. See #42.
    static let preGainKey = "playback.preGainDb"

    /// Map the persisted `NormalizationMode` raw value onto the engine's
    /// `ReplayGainMode`. Both enums share the same `off`/`track`/`album` tokens,
    /// so the raw string round-trips; an unknown / absent value (e.g. a key
    /// that was never written) falls back to `.off`, matching the picker's
    /// default. Pure + static (and `nonisolated`, since it touches no
    /// `@MainActor` state) so the test target — and the engine-seed path — can
    /// exercise the mapping from any context without building an `AppModel`.
    nonisolated static func normalizationMode(forStoredValue raw: String?) -> ReplayGainMode {
        ReplayGainMode(rawValue: raw ?? "") ?? .off
    }

    /// Apply the chosen ReplayGain mode + pre-gain to the live engine (#42).
    /// Persists both values and pushes them onto `AudioEngine`, which re-reads
    /// the current item's loudness tags and re-applies (or clears) the gain on
    /// the playing track immediately — the same eager-apply contract as
    /// `setOutputDevice`. The Preferences picker routes through here so a change
    /// takes effect on the current song, not just the next one.
    ///
    /// Pre-gain only matters while `mode != .off`; passing it through regardless
    /// keeps the stored value and the engine in sync so flipping normalization
    /// back on later already reflects the saved pre-gain.
    func setNormalization(mode: NormalizationMode, preGainDb: Double) {
        UserDefaults.standard.set(mode.rawValue, forKey: AppModel.normalizationKey)
        UserDefaults.standard.set(preGainDb, forKey: AppModel.preGainKey)
        audio.normalizationMode = AppModel.normalizationMode(forStoredValue: mode.rawValue)
        audio.normalizationPreGainDb = preGainDb
    }

    /// Seek the current track by a relative offset (seconds). Negative rewinds,
    /// positive fast-forwards. Clamped to `[0, duration]` so the seek never
    /// overshoots the track's own bounds; routes through `audio.seek` exactly
    /// like the scrubber / `mediaSessionSeek` so the `MPNowPlayingInfoCenter`
    /// widget gets the same one-writer update. Wired to the ⌘⇧← / ⌘⇧→ menu
    /// shortcuts and the list row "skip back/forward" affordances. See #6.
    func seek(by delta: Double) {
        guard status.currentTrack != nil else { return }
        let duration = max(0, status.durationSeconds)
        let target = status.positionSeconds + delta
        let clamped = max(0, duration > 0 ? min(target, duration) : target)
        audio.seek(toSeconds: clamped)
    }

    /// Absolute seek used by the PlayerBar's scrubber Slider (#332). Same
    /// clamping + one-writer routing as `seek(by:)`, but takes an absolute
    /// position rather than a delta so the Slider's drag handle can bind
    /// straight through.
    func seek(toSeconds target: Double) {
        guard status.currentTrack != nil else { return }
        let duration = max(0, status.durationSeconds)
        let clamped = max(0, duration > 0 ? min(target, duration) : target)
        audio.seek(toSeconds: clamped)
    }

    func togglePlayPause() {
        switch status.state {
        case .playing: pause()
        case .paused: resume()
        case .ended, .stopped, .idle, .loading:
            // End-of-track or other non-active states: restart the current
            // track so ⌘-Space after a song ends does the obvious thing.
            if let track = status.currentTrack {
                playCurrent(track)
            }
        }
    }

    func playCurrent(_ track: Track, armPreload: Bool = false) {
        Task {
            do {
                try await audio.play(track: track)
                // `play(track:)` builds a fresh single-item `AVQueuePlayer`,
                // so any previously pre-loaded next item is gone. On a normal
                // end-of-track advance, re-arm the gapless path now that the
                // new player exists by pre-inserting the upcoming track — same
                // selection the engine would otherwise pick when this track
                // ends (#931). Only the advance path opts in; manual skips and
                // the ⌘-Space restart build their player the same way but the
                // poll loop re-arms via `audioEngineDidRecover` only on stall
                // recovery, so leaving them off keeps this change scoped.
                if armPreload {
                    armNextTrackPreload()
                }
            } catch {
                if handleAuthError(error) { return }
                errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playback)
            }
        }
    }

    /// The track the engine should pre-load for gapless playback after the
    /// current one. Read straight from the core queue's lookahead
    /// (`core.peekNext()`) — the track `skipNext()` would return next — so the
    /// pre-loaded item is *always* the one that actually plays at end-of-track,
    /// honouring the current repeat mode. This is the same queue the in-app
    /// "Up Next" / auto-queue split mirrors (user "Play Next" inserts land at
    /// `queue_index + 1`, the source tail follows), so it captures both without
    /// depending on those overlays being kept in sync. Shared by the
    /// end-of-track advance (`handleTrackEnded`) and stall recovery
    /// (`audioEngineDidRecover`) so both arm the same item. See #931.
    ///
    /// `peekNext()` is a read-only in-memory clone under the core's queue mutex
    /// (no network, no DB) — the same cost profile as the `core.skipNext()`
    /// call `handleTrackEnded` already makes synchronously, and it fires once
    /// per advance rather than per-cell, so it's safe on the main actor.
    private var nextTrackForPreload: Track? {
        core.peekNext()
    }

    /// Arm the engine's gapless pre-load for whatever comes after the current
    /// track. A no-op when the queue holds nothing further (end of queue), in
    /// which case the engine simply has no item to splice ahead. Single source
    /// of truth shared by the normal advance and stall recovery (#931).
    ///
    /// Gated on the user's "Gapless playback" preference (#116): when off, the
    /// engine is never handed a queued-ahead item, so each track ends cleanly
    /// before `handleTrackEnded` rebuilds the next via `play(track:)` — the
    /// gap-prone path becomes the *intended* behaviour rather than a fallback.
    func armNextTrackPreload() {
        guard AppModel.gaplessEnabled else { return }
        guard let next = nextTrackForPreload else { return }
        audio.preloadNextTrack(next)
    }

    // MARK: - Playback behaviour preferences (#116)

    /// UserDefaults key for the "Gapless playback" toggle in the Playback
    /// pane. Kept in sync with `PreferencesPlayback`'s `@AppStorage`.
    private static let gaplessEnabledKey = "playback.gaplessEnabled"

    /// UserDefaults key for the "Stop after current track" toggle in the
    /// Playback pane. Kept in sync with `PreferencesPlayback`'s `@AppStorage`.
    private static let stopAfterCurrentKey = "playback.stopAfterCurrent"

    /// Resolve the persisted gapless flag, defaulting to `true` when the key
    /// has never been written. `UserDefaults.bool(forKey:)` returns `false`
    /// for a missing key, which would silently invert this feature's
    /// "default on" contract (the toggle ships on), so probe for the object
    /// first — same pattern as `autoplayWhenQueueEndsDefault`.
    static var gaplessEnabled: Bool {
        guard UserDefaults.standard.object(forKey: gaplessEnabledKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: gaplessEnabledKey)
    }

    /// Read **and clear** the "Stop after current track" one-shot. Returns
    /// `true` exactly once per arming: `handleTrackEnded` calls this, and a
    /// `true` result both halts the advance and disarms the toggle so the
    /// next end-of-track transition behaves normally. Defaults to `false`
    /// for an unset key (the toggle ships off), which `bool(forKey:)` already
    /// returns, so no object-probe is needed here.
    static func consumeStopAfterCurrent() -> Bool {
        let armed = UserDefaults.standard.bool(forKey: stopAfterCurrentKey)
        if armed {
            UserDefaults.standard.set(false, forKey: stopAfterCurrentKey)
        }
        return armed
    }

    /// Disarm "Stop after current track" when a fresh playback session
    /// begins. Honours the toggle's documented contract — "Resets to off the
    /// next time you start playback" — so an arming left over from a previous
    /// session can never silently stop the user one track into a new queue.
    static func resetStopAfterCurrent() {
        if UserDefaults.standard.bool(forKey: stopAfterCurrentKey) {
            UserDefaults.standard.set(false, forKey: stopAfterCurrentKey)
        }
    }

    #if DEBUG
    /// Test seam: drive the end-of-track advance the way `handleTrackEnded`
    /// does — step the core queue forward (`core.skipNext()`) and then arm the
    /// gapless pre-load for the track after the new current one. Skips only the
    /// async `play(track:)` rebuild (which throws un-authed and which the test's
    /// empty player stands in for); the queue advance and the arming step are
    /// the *production* calls, reading the same core queue `play(tracks:)`
    /// populated. Returns the track the advance landed on (or `nil` at end of
    /// queue) so a test can assert the playhead moved as well. See #931.
    @discardableResult
    func advanceAndArmPreloadForTesting() -> Track? {
        guard let next = core.skipNext() else { return nil }
        armNextTrackPreload()
        return next
    }

    /// Test seam: run just the gapless-arming step (`armNextTrackPreload`)
    /// without advancing the queue — mirrors stall recovery
    /// (`audioEngineDidRecover`), which re-arms the pre-load for the track
    /// after the *current* one without moving the playhead. See #931.
    func armNextTrackPreloadForTesting() {
        armNextTrackPreload()
    }
    #endif
}
