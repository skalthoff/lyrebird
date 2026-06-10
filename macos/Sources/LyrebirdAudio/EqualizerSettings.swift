import Foundation

/// User-facing 10-band graphic-equalizer state (#40).
///
/// The DSP pipeline (#39) keeps an `AVAudioUnitEQ(numberOfBands: 10)` live in
/// its node graph; this struct is the single value type that flows from the
/// Preferences pane through `AppModel` → `AudioEngine.equalizer` →
/// `EngineDSPPipeline.applyEqualizer(_:)` onto that node, and round-trips to
/// `UserDefaults` so the curve survives relaunch.
///
/// Three facts persist (`audio.eq.*` keys):
/// - `isEnabled` — global enable. Off means every band is bypassed, which is
///   the bit-perfect contract the issue demands ("Off" must equal the
///   engine-disabled output, not "all gains zero through live filters").
/// - `presetID` — the selected entry of `EqualizerPreset.all`, or
///   `EqualizerPreset.customID` for the user's own curve.
/// - `customGains` — the custom slider positions, kept even while a named
///   preset is selected so switching back to Custom restores them.
///
/// The *active* curve is always derived (`activeGains`), never stored twice —
/// a named preset resolves through the preset table, Custom resolves through
/// `customGains`, and an unknown id (a renamed/removed preset from a future
/// build) degrades to Flat instead of crashing or persisting garbage.
public struct EqualizerSettings: Equatable, Sendable {
    // MARK: - Band layout

    /// Matches `EngineDSPPipeline.configureFlatEQ` — the standard 10-band
    /// ISO octave centers. Index i of any gains array maps to this frequency.
    public static let bandFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
    ]

    public static var bandCount: Int { bandFrequencies.count }

    /// Per-band gain range in dB. ±12 matches the macOS Music.app EQ window
    /// and keeps any single band well inside `AVAudioUnitEQ`'s ±96 dB limits.
    public static let gainRange: ClosedRange<Float> = -12...12

    // MARK: - State

    /// Global enable. `false` bypasses every band (bit-perfect off).
    public var isEnabled: Bool

    /// Selected preset id — an `EqualizerPreset.all` id or
    /// `EqualizerPreset.customID`.
    public var presetID: String

    /// The user's custom curve. Normalized on init; consumers re-normalize
    /// at point of use so a hand-mutated value can never push an out-of-range
    /// gain into the audio node or the defaults plist.
    public var customGains: [Float]

    public init(
        isEnabled: Bool = false,
        presetID: String = EqualizerPreset.flat.id,
        customGains: [Float] = [Float](repeating: 0, count: EqualizerSettings.bandCount)
    ) {
        self.isEnabled = isEnabled
        self.presetID = presetID
        self.customGains = EqualizerSettings.normalizedGains(customGains)
    }

    /// The curve the EQ node should run right now: the named preset's table
    /// entry, the custom gains, or Flat when `presetID` doesn't resolve.
    /// Always exactly `bandCount` values, each clamped to `gainRange`.
    public var activeGains: [Float] {
        if presetID == EqualizerPreset.customID {
            return EqualizerSettings.normalizedGains(customGains)
        }
        guard let preset = EqualizerPreset.preset(id: presetID) else {
            return EqualizerPreset.flat.gains
        }
        return EqualizerSettings.normalizedGains(preset.gains)
    }

    /// True when the active curve is all-zero — together with band-level
    /// bypass this is what makes the Flat preset bit-identical to no EQ.
    public var isActiveCurveFlat: Bool {
        activeGains.allSatisfy { $0 == 0 }
    }

    // MARK: - Normalization

    /// Coerce an arbitrary gains array into a valid curve: clamp each value
    /// to `gainRange`, zero non-finite values (a corrupted plist must never
    /// reach the audio node), truncate extras, and pad short arrays with 0.
    public static func normalizedGains(_ gains: [Float]) -> [Float] {
        var result = gains.prefix(bandCount).map { gain -> Float in
            guard gain.isFinite else { return 0 }
            return min(max(gain, gainRange.lowerBound), gainRange.upperBound)
        }
        while result.count < bandCount {
            result.append(0)
        }
        return Array(result)
    }

    // MARK: - Persistence

    /// `UserDefaults` keys. Dotted `audio.*` namespace matches the app's other
    /// audio preferences (`audio.transcodingPreference`, `audio.outputDevice`).
    public enum DefaultsKey {
        public static let enabled = "audio.eq.enabled"
        public static let preset = "audio.eq.preset"
        public static let customGains = "audio.eq.customGains"
    }

    /// Load persisted settings; missing/partial keys fall back to the shipped
    /// default (disabled, Flat, zeroed custom curve) so a fresh install and a
    /// pre-#40 profile both come up bit-perfect.
    public static func load(from defaults: UserDefaults) -> EqualizerSettings {
        let enabled = defaults.bool(forKey: DefaultsKey.enabled)
        let storedPreset = defaults.string(forKey: DefaultsKey.preset)
        let presetID: String = {
            guard let storedPreset else { return EqualizerPreset.flat.id }
            let known = storedPreset == EqualizerPreset.customID
                || EqualizerPreset.preset(id: storedPreset) != nil
            return known ? storedPreset : EqualizerPreset.flat.id
        }()
        let storedGains = (defaults.array(forKey: DefaultsKey.customGains) as? [Double]) ?? []
        return EqualizerSettings(
            isEnabled: enabled,
            presetID: presetID,
            customGains: normalizedGains(storedGains.map(Float.init))
        )
    }

    /// Persist all three facts. Gains are written as `[Double]` (a plist-
    /// native array) rather than encoded blobs so `defaults read` stays
    /// inspectable for support/debugging.
    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: DefaultsKey.enabled)
        defaults.set(presetID, forKey: DefaultsKey.preset)
        defaults.set(
            EqualizerSettings.normalizedGains(customGains).map(Double.init),
            forKey: DefaultsKey.customGains
        )
    }
}

/// A named EQ curve. The table mirrors the classic iTunes / Music.app preset
/// set — the values come straight from issue #40's spec so users moving over
/// from Music find the names *and* the curves they expect.
public struct EqualizerPreset: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Exactly `EqualizerSettings.bandCount` per-band dB gains, low→high.
    public let gains: [Float]

    /// Sentinel id for the user's own curve. Not a member of `all` — the
    /// UI appends its own "Custom" row so the preset table stays purely the
    /// named curves.
    public static let customID = "custom"

    public static let flat = EqualizerPreset(
        id: "flat", name: "Flat",
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    public static let bassBoost = EqualizerPreset(
        id: "bassBoost", name: "Bass Boost",
        gains: [6, 5, 4, 3, 1, 0, 0, 0, 0, 0])
    public static let trebleBoost = EqualizerPreset(
        id: "trebleBoost", name: "Treble Boost",
        gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6])
    public static let bassAndTreble = EqualizerPreset(
        id: "bassAndTreble", name: "Bass & Treble",
        gains: [5, 4, 3, 1, 0, 0, 2, 3, 5, 5])
    public static let vocalBoost = EqualizerPreset(
        id: "vocalBoost", name: "Vocal Boost",
        gains: [-2, -1, 0, 1, 3, 4, 3, 1, 0, -1])
    public static let acoustic = EqualizerPreset(
        id: "acoustic", name: "Acoustic",
        gains: [4, 4, 3, 1, 2, 2, 3, 4, 3, 2])
    public static let dance = EqualizerPreset(
        id: "dance", name: "Dance",
        gains: [4, 6, 5, 0, 1, 3, 5, 4, 3, 0])
    public static let electronic = EqualizerPreset(
        id: "electronic", name: "Electronic",
        gains: [4, 4, 2, 0, -2, 2, 1, 2, 4, 5])
    public static let hipHop = EqualizerPreset(
        id: "hipHop", name: "Hip-Hop",
        gains: [5, 4, 1, 3, -1, -1, 1, -1, 2, 3])
    public static let jazz = EqualizerPreset(
        id: "jazz", name: "Jazz",
        gains: [4, 3, 2, 2, -1, -1, 0, 1, 2, 3])
    public static let classical = EqualizerPreset(
        id: "classical", name: "Classical",
        gains: [5, 4, 3, 2, -2, -2, 0, 2, 3, 4])
    public static let rock = EqualizerPreset(
        id: "rock", name: "Rock",
        gains: [5, 4, 3, 1, -1, -1, 0, 2, 3, 4])
    public static let pop = EqualizerPreset(
        id: "pop", name: "Pop",
        gains: [-1, -1, 0, 2, 4, 4, 2, 0, -1, -1])
    public static let piano = EqualizerPreset(
        id: "piano", name: "Piano",
        gains: [3, 2, 0, 2, 3, 1, 3, 4, 3, 3])

    /// Every named preset, Flat first, the rest alphabetical-ish in the order
    /// the issue lists them (the order users see in the picker).
    public static let all: [EqualizerPreset] = [
        .flat, .bassBoost, .trebleBoost, .bassAndTreble, .vocalBoost,
        .acoustic, .dance, .electronic, .hipHop, .jazz, .classical,
        .rock, .pop, .piano,
    ]

    public static func preset(id: String) -> EqualizerPreset? {
        all.first { $0.id == id }
    }
}
