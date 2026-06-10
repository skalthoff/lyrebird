import Foundation

/// User-facing crossfade state (#41).
///
/// The DSP pipeline (#39) keeps two `AVAudioPlayerNode` decks live in its
/// node graph, each behind its own `AVAudioMixerNode`; this struct is the
/// single value type that flows from the Preferences pane through `AppModel`
/// → `AudioEngine.dspApplyCrossfade(_:)` → `EngineDSPPipeline.applyCrossfade(_:)`
/// onto those gain stages, and round-trips to `UserDefaults` so the choice
/// survives relaunch — the same shape as `EqualizerSettings` (#40).
///
/// Two facts persist:
/// - `durationSeconds` — the overlap window. Reuses the pre-existing
///   `playback.crossfadeSeconds` key the Playback pane has written since #116
///   (0 = off, 1…12 s), so a value a user set before the engine support
///   landed is honoured the moment the DSP path turns on.
/// - `curve` — the gain envelope: equal-power (the default; preserves
///   perceived loudness through the overlap) or linear (can dip slightly at
///   the midpoint). Issue #41 asks for both.
///
/// Off (`durationSeconds == 0`, or anything below one second) is a true
/// no-op: the pipeline never arms a second deck, never starts a fade, and
/// track transitions behave exactly as they did before #41 — the gapless
/// contract the issue's acceptance criteria demand.
public struct CrossfadeSettings: Equatable, Sendable {
    // MARK: - Gain curves

    /// The fade envelope shape. Raw values are stable user-defaults strings —
    /// do not rename without a migration.
    public enum Curve: String, CaseIterable, Sendable, Identifiable {
        /// `gainIn(t) = sin(t·π/2)`, `gainOut(t) = cos(t·π/2)` — the power
        /// sum is 1 at every point, so the overlap holds perceived loudness.
        case equalPower

        /// `gainIn(t) = t`, `gainOut(t) = 1 − t` — amplitude-constant, which
        /// dips perceptibly around the midpoint on correlated material.
        case linear

        public var id: String { rawValue }

        /// Display label for the Preferences picker.
        public var label: String {
            switch self {
            case .equalPower: return "Equal power"
            case .linear: return "Linear"
            }
        }
    }

    // MARK: - Ranges

    /// Slider range in seconds. 0 reads as "Off"; the issue specifies an
    /// active range of 1–12 s, matching the existing Playback-pane slider.
    public static let durationRange: ClosedRange<Double> = 0...12

    /// Anything below this is treated as off — the slider steps in whole
    /// seconds, so sub-second values only appear via hand-edited defaults.
    public static let minimumActiveDuration: Double = 1

    /// Default overlap when the user enables crossfade (issue spec: 4 s).
    public static let defaultActiveDuration: Double = 4

    /// The short fade applied to the *outgoing* track on a manual skip while
    /// crossfade is on, so a mid-track next never pops (issue spec: 250 ms).
    public static let quickSwitchDuration: Double = 0.25

    // MARK: - State

    /// Overlap window in seconds. 0 (or anything below
    /// `minimumActiveDuration`) means crossfade is off.
    public var durationSeconds: Double

    /// Selected gain envelope.
    public var curve: Curve

    public init(
        durationSeconds: Double = 0,
        curve: Curve = .equalPower
    ) {
        self.durationSeconds = CrossfadeSettings.normalizedDuration(durationSeconds)
        self.curve = curve
    }

    /// Whether crossfade participates in playback at all. Off must behave
    /// byte-for-byte like the pre-#41 pipeline.
    public var isEnabled: Bool {
        durationSeconds >= CrossfadeSettings.minimumActiveDuration
    }

    // MARK: - Normalization

    /// Coerce an arbitrary persisted duration into a valid one: zero
    /// non-finite values (a corrupted plist must never reach the fade
    /// scheduler) and clamp to `durationRange`.
    public static func normalizedDuration(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, durationRange.lowerBound), durationRange.upperBound)
    }

    // MARK: - Envelope math

    /// Incoming-track gain for fade progress `t` in [0, 1]. Clamps out-of-
    /// range progress so a jittery timer can never push an out-of-range gain
    /// onto a mixer node.
    public static func fadeInGain(progress: Double, curve: Curve) -> Float {
        let t = min(max(progress, 0), 1)
        switch curve {
        case .equalPower: return Float(sin(t * .pi / 2))
        case .linear: return Float(t)
        }
    }

    /// Outgoing-track gain for fade progress `t` in [0, 1].
    public static func fadeOutGain(progress: Double, curve: Curve) -> Float {
        let t = min(max(progress, 0), 1)
        switch curve {
        case .equalPower: return Float(cos(t * .pi / 2))
        case .linear: return Float(1 - t)
        }
    }

    // MARK: - Scheduling decisions (pure, testable)

    /// How early before the fade window the standby deck starts buffering the
    /// armed track. Generous enough to ride out network jitter while keeping
    /// the double-stream overlap short.
    public static let prepareLeadSeconds: Double = 10

    /// The overlap to use for a specific transition — or 0 for a zero-fade
    /// join (the armed track starts the instant the outgoing one finishes,
    /// with no overlap and no envelope).
    ///
    /// Zero-fade applies when:
    /// - the configured duration is off,
    /// - current and next track share an album (`sameAlbum`) — issue #41's
    ///   gapless-album rule: don't smear continuous album audio together,
    /// - the outgoing track is too short to give the fade room (shorter than
    ///   twice the window), or its duration is unknown (no metadata to place
    ///   the fade against).
    public static func effectiveFadeDuration(
        configured: Double,
        trackDurationSeconds: Double?,
        sameAlbum: Bool
    ) -> Double {
        let window = normalizedDuration(configured)
        guard window >= minimumActiveDuration else { return 0 }
        guard !sameAlbum else { return 0 }
        guard let duration = trackDurationSeconds,
              duration.isFinite,
              duration >= window * 2
        else { return 0 }
        return window
    }

    /// What the 1 Hz position tick should do about an armed next track.
    public enum TickAction: Equatable {
        /// Outside every window — keep playing.
        case none
        /// Inside the buffering window — start streaming the armed track on
        /// the standby deck (no audio yet).
        case prepare
        /// Inside the fade window and the standby deck is ready — begin the
        /// gain ramps now.
        case beginFade
    }

    /// Pure decision function for the crossfade scheduler. `remainingSeconds`
    /// is the outgoing track's time left; `fadeDuration` is the value
    /// returned by `effectiveFadeDuration` (0 ⇒ zero-fade join, which never
    /// begins a ramp — the handoff happens at track completion instead).
    public static func tickAction(
        remainingSeconds: Double,
        fadeDuration: Double,
        prepStarted: Bool,
        standbyReady: Bool
    ) -> TickAction {
        guard remainingSeconds.isFinite else { return .none }
        if fadeDuration > 0, prepStarted, standbyReady, remainingSeconds <= fadeDuration {
            return .beginFade
        }
        if !prepStarted, remainingSeconds <= fadeDuration + prepareLeadSeconds {
            return .prepare
        }
        return .none
    }

    // MARK: - Persistence

    /// `UserDefaults` keys. `duration` is the pre-existing #116 Playback-pane
    /// key (kept verbatim so prior opt-ins survive); `curve` is new with #41.
    public enum DefaultsKey {
        public static let duration = "playback.crossfadeSeconds"
        public static let curve = "playback.crossfadeCurve"
    }

    /// Load persisted settings; missing/partial keys fall back to the shipped
    /// default (off, equal-power) so a fresh install behaves exactly like the
    /// pre-#41 pipeline.
    public static func load(from defaults: UserDefaults) -> CrossfadeSettings {
        let duration = defaults.double(forKey: DefaultsKey.duration)
        let curve = defaults.string(forKey: DefaultsKey.curve)
            .flatMap(Curve.init(rawValue:)) ?? .equalPower
        return CrossfadeSettings(durationSeconds: duration, curve: curve)
    }

    /// Persist both facts as plist-native scalars so `defaults read` stays
    /// inspectable for support/debugging (same contract as the EQ keys).
    public func save(to defaults: UserDefaults) {
        defaults.set(CrossfadeSettings.normalizedDuration(durationSeconds), forKey: DefaultsKey.duration)
        defaults.set(curve.rawValue, forKey: DefaultsKey.curve)
    }
}
