import LyrebirdAudio
import SwiftUI

/// Playback preferences pane.
///
/// Exposes the behavioural knobs covered by issues #116 and the four-group
/// playback spec — gapless joins, crossfade, Replay Gain (+ pre-gain),
/// volume normalization, and "stop after current track". Streaming/download
/// quality and preferred codec used to live here too, but they share their
/// `@AppStorage` keys with the Audio pane (#117), which is their canonical
/// home; the duplicates were removed here so each setting has exactly one
/// editing surface.
///
/// What's live:
/// - **Gapless** routes through `AppModel.setGapless` onto both engine
///   paths: the AVQueuePlayer pre-load gate and the DSP pipeline's buffered
///   zero-fade join. **Stop after current track** is consumed by
///   `handleTrackEnded`.
/// - **Replay Gain**, **Pre-gain**, and **Volume Normalization** route
///   through `AppModel.setNormalization` onto the live loudness path (#42):
///   per-item `AVAudioMix` on the AVQueuePlayer path, per-deck player gain
///   on the DSP path. Tags come from the stream's own metadata; untagged
///   tracks play unchanged.
/// - **Crossfade** (#41) rides the AVAudioEngine DSP pipeline's dual decks,
///   so its slider + curve picker gate on `supportsCrossfade` — live only
///   while the DSP engine (#39, opted into via the Equalizer pane) is
///   routing playback this session. The value persists either way and is
///   honoured as soon as the engine path is active.
///
/// Design: matches the native Preferences aesthetic inside the Lyrebird shell.
/// Sections sit on `Theme.surface` with `Theme.border` outlines; labels use
/// 13pt `ink` weight 600, helper copy uses 11pt `ink3`. Option values are
/// stored as stable string raw values so the on-disk keys survive renames of
/// the display labels.
///
/// Preference keys (user-facing `@AppStorage`):
/// - `playback.crossfadeSeconds`             — `Double` (0 = off, 1…12)
/// - `playback.crossfadeCurve`               — `CrossfadeSettings.Curve` raw value
/// - `playback.gaplessEnabled`               — `Bool` (default true)
/// - `playback.normalization`                — `NormalizationMode`
/// - `playback.preGainDb`                    — `Double` (±12)
/// - `playback.volumeNormalizationEnabled`   — `Bool` (default false)
/// - `playback.volumeNormalizationTargetDb`  — `Double` (−23…−14, default −18)
/// - `playback.stopAfterCurrent`             — `Bool`
///
/// Spec: `research/03-ux-patterns.md` Issue 68 and GitHub issues #260 / #116 / #41.
struct PreferencesPlayback: View {
    @Environment(AppModel.self) private var model

    // #116 gap-fill knobs. Raw types are chosen so the key names survive any
    // later enum/struct refactor — a Double for the slider is portable and
    // the Bool toggles are the obvious shape. The crossfade key literals
    // match `CrossfadeSettings.DefaultsKey` (#41) and the loudness literals
    // match `NormalizationSettings.DefaultsKey`, which is how the engine
    // reads them back.
    @AppStorage("playback.crossfadeSeconds") private var crossfadeSeconds: Double = 0
    @AppStorage("playback.crossfadeCurve") private var crossfadeCurveRaw: String = CrossfadeSettings.Curve.equalPower.rawValue
    @AppStorage("playback.gaplessEnabled") private var gaplessEnabled: Bool = true
    @AppStorage("playback.normalization") private var normalizationRaw: String = NormalizationMode.off.rawValue
    @AppStorage("playback.preGainDb") private var preGainDb: Double = 0
    @AppStorage("playback.volumeNormalizationEnabled") private var volumeNormalizationEnabled: Bool = false
    @AppStorage("playback.volumeNormalizationTargetDb") private var volumeNormalizationTargetDb: Double = NormalizationSettings.defaultTargetLoudnessDb
    @AppStorage("playback.stopAfterCurrent") private var stopAfterCurrent: Bool = false

    /// Crossfade duration binding. Reads `@AppStorage` for instant UI, and
    /// routes the change through `AppModel.setCrossfade` so the live DSP
    /// pipeline picks it up for the very next transition (#41) — the same
    /// eager-apply shape as the normalization picker below.
    private var crossfadeDuration: Binding<Double> {
        Binding(
            get: { crossfadeSeconds },
            set: { newValue in
                crossfadeSeconds = newValue
                model.setCrossfade(currentCrossfadeSettings(duration: newValue))
            }
        )
    }

    /// Crossfade curve binding — equal-power holds perceived loudness
    /// through the overlap; linear can dip at the midpoint (#41 offers both).
    private var crossfadeCurve: Binding<CrossfadeSettings.Curve> {
        Binding(
            get: { CrossfadeSettings.Curve(rawValue: crossfadeCurveRaw) ?? .equalPower },
            set: { newCurve in
                crossfadeCurveRaw = newCurve.rawValue
                model.setCrossfade(currentCrossfadeSettings(curve: newCurve))
            }
        )
    }

    private func currentCrossfadeSettings(
        duration: Double? = nil,
        curve: CrossfadeSettings.Curve? = nil
    ) -> CrossfadeSettings {
        CrossfadeSettings(
            durationSeconds: duration ?? crossfadeSeconds,
            curve: curve ?? CrossfadeSettings.Curve(rawValue: crossfadeCurveRaw) ?? .equalPower
        )
    }

    /// Gapless toggle binding. Writes `@AppStorage` for instant UI and routes
    /// the change through `AppModel.setGapless` so the live engine reacts on
    /// the *current* transition: off strips a queued-ahead item (AVQueuePlayer)
    /// or disarms the DSP pipeline's buffered join; on re-arms the upcoming
    /// track on whichever path is active.
    private var gapless: Binding<Bool> {
        Binding(
            get: { gaplessEnabled },
            set: { newValue in
                gaplessEnabled = newValue
                model.setGapless(newValue)
            }
        )
    }

    /// Push the full loudness surface — mode, pre-gain, normalization toggle,
    /// target — through `AppModel.setNormalization` so the engine always sees
    /// a consistent quadruple (#42). Each binding overrides just its own knob
    /// and reads the live `@AppStorage` values for the rest.
    private func pushNormalization(
        mode: NormalizationMode? = nil,
        preGain: Double? = nil,
        volumeNormalization: Bool? = nil,
        target: Double? = nil
    ) {
        model.setNormalization(
            mode: mode ?? (NormalizationMode(rawValue: normalizationRaw) ?? .off),
            preGainDb: preGain ?? preGainDb,
            volumeNormalizationEnabled: volumeNormalization ?? volumeNormalizationEnabled,
            targetLoudnessDb: target ?? volumeNormalizationTargetDb
        )
    }

    /// Replay Gain mode picker binding. Reads `@AppStorage` for instant UI,
    /// and routes the change through `AppModel` so the live player re-reads
    /// the current track's ReplayGain tags and re-applies the gain immediately
    /// rather than only on the next track (#42).
    private var normalization: Binding<NormalizationMode> {
        Binding(
            get: { NormalizationMode(rawValue: normalizationRaw) ?? .off },
            set: { newMode in
                normalizationRaw = newMode.rawValue
                pushNormalization(mode: newMode)
            }
        )
    }

    /// Pre-gain slider binding. Writes `@AppStorage` for instant UI and pushes
    /// the new pre-gain onto the engine via `AppModel`, alongside the other
    /// loudness knobs (#42).
    private var preGain: Binding<Double> {
        Binding(
            get: { preGainDb },
            set: { newValue in
                preGainDb = newValue
                pushNormalization(preGain: newValue)
            }
        )
    }

    /// Volume-normalization toggle binding — shift loudness to the target
    /// below instead of the ReplayGain reference.
    private var volumeNormalization: Binding<Bool> {
        Binding(
            get: { volumeNormalizationEnabled },
            set: { newValue in
                volumeNormalizationEnabled = newValue
                pushNormalization(volumeNormalization: newValue)
            }
        )
    }

    /// Target-loudness slider binding (dB LUFS).
    private var normalizationTarget: Binding<Double> {
        Binding(
            get: { volumeNormalizationTargetDb },
            set: { newValue in
                volumeNormalizationTargetDb = newValue
                pushNormalization(target: newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Transitions",
                footnote: transitionsFootnote
            ) {
                PreferenceRow(
                    label: "Gapless playback",
                    help: gaplessEnabled
                        ? "On — tracks on the same album play without a gap."
                        : "Off — each track ends cleanly before the next starts."
                ) {
                    Toggle("", isOn: gapless)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Gapless playback")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Crossfade",
                    help: model.supportsCrossfade
                        ? crossfadeHelp
                        : "Requires the DSP audio engine — turn it on in the Equalizer pane."
                ) {
                    CrossfadeSlider(seconds: crossfadeDuration)
                        .disabled(!model.supportsCrossfade)
                }
                // Dim the whole row while the DSP engine isn't routing
                // playback this session so it reads as inactive rather than
                // broken — the same gated-feature idiom as the EQ pane (#40).
                .opacity(model.supportsCrossfade ? 1 : 0.55)

                // Envelope preview — shown only while the DSP engine is active
                // and the slider is above the minimum so there's a real fade to
                // illustrate. Animates on every duration/curve change so the
                // shape responds immediately as the slider drags.
                if model.supportsCrossfade && crossfadeSeconds >= CrossfadeSettings.minimumActiveDuration {
                    CrossfadeEnvelopeView(
                        durationSeconds: crossfadeSeconds,
                        curve: CrossfadeSettings.Curve(rawValue: crossfadeCurveRaw) ?? .equalPower
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Crossfade curve",
                    help: crossfadeCurve.wrappedValue == .equalPower
                        ? "Holds perceived loudness steady through the overlap."
                        : "Straight-line gains — can dip slightly mid-overlap."
                ) {
                    CrossfadeCurvePicker(selection: crossfadeCurve)
                        .disabled(!model.supportsCrossfade || crossfadeSeconds < CrossfadeSettings.minimumActiveDuration)
                }
                .opacity(model.supportsCrossfade && crossfadeSeconds >= CrossfadeSettings.minimumActiveDuration ? 1 : 0.55)
            }

            PreferenceSection(
                title: "Replay Gain",
                footnote: "Reads ReplayGain tags from the source when available. Track matches the loudness of each song individually; Album keeps the relative levels inside an album intact. Untagged tracks play unchanged."
            ) {
                PreferenceRow(
                    label: "Mode",
                    help: normalization.wrappedValue.subtitle
                ) {
                    NormalizationPicker(selection: normalization)
                        .accessibilityLabel("Replay Gain mode")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Pre-gain",
                    help: preGainHelp
                ) {
                    PreGainSlider(db: preGain)
                }
            }

            PreferenceSection(
                title: "Volume Normalization",
                footnote: "Shifts overall playback loudness to your target instead of the ReplayGain reference (−18 dB LUFS). Uses each track's loudness tags — with Replay Gain off it falls back to track tags; untagged tracks play unchanged."
            ) {
                PreferenceRow(
                    label: "Normalize volume",
                    help: volumeNormalizationEnabled
                        ? "On — playback loudness lands at the target below."
                        : "Off — tags apply at the standard reference level."
                ) {
                    Toggle("", isOn: volumeNormalization)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Volume normalization")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Target loudness",
                    help: targetLoudnessHelp
                ) {
                    TargetLoudnessSlider(db: normalizationTarget)
                        .disabled(!volumeNormalizationEnabled)
                }
                // Same gated-row idiom as the crossfade rows: dim while the
                // toggle above keeps the slider inert.
                .opacity(volumeNormalizationEnabled ? 1 : 0.55)
            }

            PreferenceSection(
                title: "Queue",
                footnote: "Stops automatically after the current track finishes. Resets to off the next time you start playback."
            ) {
                PreferenceRow(
                    label: "Stop after current track",
                    help: stopAfterCurrent
                        ? "On — playback halts once the current track ends."
                        : "Off — the queue continues to the next track."
                ) {
                    Toggle("", isOn: $stopAfterCurrent)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Stop after current track")
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Transitions, normalization, and queue behaviour.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// Footnote under the Transitions section. Describes gapless always, and
    /// crossfade per its availability — the overlap rides the DSP engine's
    /// dual decks (#41), so without that engine the footnote points at the
    /// opt-in instead of promising an inactive feature.
    private var transitionsFootnote: String {
        let gapless = "Gapless joins tracks with no silence when the source supports it."
        if model.supportsCrossfade {
            return gapless + " Crossfade overlaps the last and next track by the selected number of seconds; tracks from the same album stay gapless, and skipping mid-track uses a short fade instead."
        }
        return gapless + " Crossfade runs on Lyrebird's DSP engine — enable it in the Equalizer pane (takes effect after relaunch). Your setting is saved either way."
    }

    /// Subtitle under the crossfade row. Reads "Off" when the slider is at
    /// zero and "3 seconds" / "12 seconds" otherwise so the helper copy is
    /// always a sentence a user can parse at a glance.
    private var crossfadeHelp: String {
        let rounded = Int(crossfadeSeconds.rounded())
        if rounded <= 0 {
            return "Off — tracks transition with no overlap."
        }
        return "\(rounded) second\(rounded == 1 ? "" : "s") of overlap between tracks."
    }

    /// Subtitle under the pre-gain slider. Shows "0 dB" as a neutral label and
    /// "+3 dB" / "−6 dB" at the edges so the direction is unambiguous.
    private var preGainHelp: String {
        let rounded = Int(preGainDb.rounded())
        if rounded == 0 {
            return "0 dB — no adjustment."
        }
        let sign = rounded > 0 ? "+" : "−"
        return "\(sign)\(abs(rounded)) dB applied before output."
    }

    /// Subtitle under the target-loudness slider. Calls out the reference
    /// value so "−18" reads as "no shift" rather than an arbitrary number.
    private var targetLoudnessHelp: String {
        let rounded = Int(volumeNormalizationTargetDb.rounded())
        if Double(rounded) == NormalizationSettings.defaultTargetLoudnessDb {
            return "−18 dB LUFS — the ReplayGain reference."
        }
        return "−\(abs(rounded)) dB LUFS. Higher is louder."
    }
}

// MARK: - Crossfade envelope preview

/// Compact gain-envelope visualisation shown in the Transitions section while
/// crossfade is active and the DSP engine is routing playback this session.
///
/// Two overlapping `Path`s trace the outgoing track's fade-out and the
/// incoming track's fade-in using the same `CrossfadeSettings.fadeInGain` /
/// `fadeOutGain` math the live pipeline runs — so the shape the user sees is
/// the shape they hear. Equal-power produces a rounded midpoint; linear is a
/// flat X-cross.
///
/// The view animates its `animationPhase` via a repeating spring so the
/// curves appear to "play through" the transition, giving the user an
/// immediate sense of timing. The animation is driven entirely through a
/// SwiftUI `phaseAnimator` so there are no manual timer callbacks.
///
/// Inert contract: this view is only instantiated when
/// `model.supportsCrossfade && crossfadeSeconds >= minimumActiveDuration`
/// (see the call site in `PreferencesPlayback.body`), so it never appears
/// on the AVQueuePlayer path — the disabled-row idiom is the DSP-off state.
private struct CrossfadeEnvelopeView: View {
    let durationSeconds: Double
    let curve: CrossfadeSettings.Curve
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Number of path sample points. 64 is more than enough resolution for
    /// a 264-point-wide preview at this scale while staying well below any
    /// rendering cost.
    private static let sampleCount = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Canvas draws both gain curves from the real engine math.
            // `animationPhase` in [0, 1] shifts the colours so the curves
            // appear to pulse through the overlap — purely cosmetic, the
            // path itself doesn't move.
            PhaseAnimator(
                [0.0, 0.5, 1.0, 0.5, 0.0],
                trigger: envelopeKey
            ) { phase in
                envelopeCanvas(phase: phase)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityHidden(false)
            } animation: { _ in
                reduceMotion ? nil : .easeInOut(duration: 1.2)
            }

            // Legend: two dots + labels identifying the two curves.
            HStack(spacing: 16) {
                legendItem(color: outgoingColor(phase: 1), label: "Outgoing")
                legendItem(color: incomingColor(phase: 1), label: "Incoming")
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Canvas

    private func envelopeCanvas(phase: Double) -> some View {
        Canvas { context, size in
            let samples = CrossfadeSettings.envelopeSamples(
                count: Self.sampleCount,
                curve: curve
            )
            // Outgoing: starts at full gain, fades to zero.
            let outPath = gainPath(gains: samples.fadeOut, size: size)
            context.stroke(
                outPath,
                with: .color(outgoingColor(phase: phase)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            // Incoming: starts at zero, rises to full gain.
            let inPath  = gainPath(gains: samples.fadeIn, size: size)
            context.stroke(
                inPath,
                with: .color(incomingColor(phase: phase)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Convert a gain sample array into a `Path` mapped into `size`.
    /// Gain = 1 maps to the top edge (y = 0); gain = 0 maps to the bottom
    /// (y = height). The x-axis spans the full width.
    private func gainPath(gains: [Float], size: CGSize) -> Path {
        guard !gains.isEmpty else { return Path() }
        return Path { path in
            for (index, gain) in gains.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(gains.count - 1)
                let y = size.height * (1 - CGFloat(gain))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    // MARK: - Colour helpers

    /// Outgoing track colour. Warm tint that brightens at the start of the
    /// overlap (phase ≈ 0) and dims as it hands off — matches the "outgoing"
    /// semantic visually.
    private func outgoingColor(phase: Double) -> Color {
        Theme.accent.opacity(0.55 + 0.35 * (1 - phase))
    }

    /// Incoming track colour. Cool primary tint that brightens as it takes
    /// over — the "arrival" semantic.
    private func incomingColor(phase: Double) -> Color {
        Theme.primary.opacity(0.55 + 0.35 * phase)
    }

    // MARK: - Legend

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Theme.font(10, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Helpers

    /// Stable key that changes whenever duration or curve changes, used as
    /// the `PhaseAnimator` trigger so the animation restarts on every edit.
    private var envelopeKey: String {
        "\(Int(durationSeconds.rounded()))-\(curve.rawValue)"
    }

    private var accessibilityLabel: String {
        let secs = Int(durationSeconds.rounded())
        return "Crossfade envelope preview: \(secs) second\(secs == 1 ? "" : "s"), \(curve.label.lowercased()) curve"
    }
}

// MARK: - Values

/// Quality tiers for streaming and downloads.
///
/// Raw values are stable user-defaults strings — do not rename without a
/// migration. The label/subtitle are display-only and safe to edit.
///
/// TODO(#260): wire these into the Jellyfin `PlaybackInfo` request. Each case
/// maps to a `DeviceProfile` + `MaxStreamingBitrate` pair the core sends to
/// `/Items/{id}/PlaybackInfo`. Original passthrough means omit transcoding
/// containers so the server returns a DirectStream URL.
enum PlaybackQuality: String, CaseIterable, Identifiable {
    case automatic
    case low
    case normal
    case high
    case lossless
    case original

    var id: String { rawValue }

    /// Short label used inside the segmented control / menu.
    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .lossless: return "Lossless"
        case .original: return "Original"
        }
    }

    /// Helper copy shown beneath the row. Mirrors the bitrate tiers from
    /// `research/03-ux-patterns.md` Issue 69 (GitHub #117).
    var subtitle: String {
        switch self {
        case .automatic: return "Picked by Lyrebird"
        case .low: return "96 kbps"
        case .normal: return "192 kbps"
        case .high: return "320 kbps"
        case .lossless: return "FLAC"
        case .original: return "Direct stream — no transcoding"
        }
    }

    /// The Jellyfin `MaxStreamingBitrate` ceiling (bits/s) this tier maps to
    /// when building a stream URL (#260). `nil` means "no cap" — the lossless
    /// and original tiers ask the server for the source without a transcode
    /// ceiling. `automatic` keeps the historical 320 kbps default so existing
    /// users see no change. The bitrate tiers mirror `subtitle`.
    var maxStreamingBitrate: UInt32? {
        switch self {
        case .low: return 96_000
        case .normal: return 192_000
        case .high, .automatic: return 320_000
        case .lossless, .original: return nil
        }
    }
}

/// ReplayGain-style loudness normalization. `off` applies no correction,
/// `track` matches each track's individual loudness, `album` uses the
/// per-album gain so relative dynamics inside an album remain intact.
///
/// Live on both engine paths (#42): the raw values bridge onto the engine's
/// `ReplayGainMode` via `AppModel.normalizationMode(forStoredValue:)`, the
/// engine reads `REPLAYGAIN_TRACK_GAIN` / `_ALBUM_GAIN` (plus the `iTunNORM`
/// fallback) from the stream's own metadata, and applies the selected gain
/// on top of `preGainDb`. Untagged tracks play unchanged.
enum NormalizationMode: String, CaseIterable, Identifiable {
    case off
    case track
    case album

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .album: return "Album"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "No volume adjustment."
        case .track: return "Match the loudness of each track individually."
        case .album: return "Preserve album dynamics; match across albums."
        }
    }
}

/// Preferred audio codec for transcoded playback.
///
/// TODO(#260): feed into the `DeviceProfile.TranscodingProfiles` list so the
/// server honors the user's preference before falling back to its default.
enum PreferredAudioCodec: String, CaseIterable, Identifiable {
    case automatic
    case aac
    case mp3
    case flac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: return "Trust server default"
        case .aac: return "Efficient, wide compatibility"
        case .mp3: return "Universal, lossy"
        case .flac: return "Lossless, larger files"
        }
    }
}

// MARK: - Pickers

// Note: the streaming/download `QualityPicker` and the `CodecPicker` that used
// to live here moved to the Audio pane (#117) — the single home for quality and
// codec selection now that the duplicate sections were removed from this pane.

/// Segmented picker for the crossfade gain envelope (#41). Two mutually-
/// exclusive options — the same control shape as `NormalizationPicker`.
private struct CrossfadeCurvePicker: View {
    @Binding var selection: CrossfadeSettings.Curve

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(CrossfadeSettings.Curve.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
        .accessibilityLabel("Crossfade curve")
    }
}

/// Segmented picker for the three-option normalization mode. Off / Track /
/// Album — a segmented control reads best for a mutually-exclusive short
/// list, matching the Appearance pane's density and mode controls.
private struct NormalizationPicker: View {
    @Binding var selection: NormalizationMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(NormalizationMode.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
    }
}

/// Crossfade slider, 0…12 seconds in 1-second steps. 0 reads as "Off" and
/// the numeric readout on the trailing edge updates live so the user knows
/// exactly what they've committed to. Matches the slider + readout pattern
/// used elsewhere in the app (queue volume, seek chrome) so the shape of
/// the row feels native.
private struct CrossfadeSlider: View {
    @Binding var seconds: Double

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $seconds, in: 0...12, step: 1)
                .frame(width: 200)
                .accessibilityLabel("Crossfade duration")
                .accessibilityValue(seconds <= 0 ? "Off" : "\(Int(seconds)) seconds")
            Text(readout)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var readout: String {
        let rounded = Int(seconds.rounded())
        return rounded <= 0 ? "Off" : "\(rounded) s"
    }
}

/// Pre-gain slider, −12…+12 dB in 1 dB steps. 0 is the default; the readout
/// shows a unicode minus sign so the value is visually aligned with typeset
/// audio copy elsewhere (− vs -, the former is what VoiceOver reads cleanly).
private struct PreGainSlider: View {
    @Binding var db: Double

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $db, in: -12...12, step: 1)
                .frame(width: 200)
                .accessibilityLabel("Pre-gain")
                .accessibilityValue(accessibilityReadout)
            Text(readout)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var readout: String {
        let rounded = Int(db.rounded())
        if rounded == 0 { return "0 dB" }
        let sign = rounded > 0 ? "+" : "−"
        return "\(sign)\(abs(rounded)) dB"
    }

    private var accessibilityReadout: String {
        let rounded = Int(db.rounded())
        if rounded == 0 { return "0 decibels" }
        let direction = rounded > 0 ? "plus" : "minus"
        return "\(direction) \(abs(rounded)) decibels"
    }
}

/// Target-loudness slider for volume normalization, −23…−14 dB LUFS in 1 dB
/// steps (range from `NormalizationSettings.targetRange`). The readout shows
/// the unicode minus for the same typeset/VoiceOver reasons as `PreGainSlider`.
private struct TargetLoudnessSlider: View {
    @Binding var db: Double

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $db, in: NormalizationSettings.targetRange, step: 1)
                .frame(width: 200)
                .accessibilityLabel("Target loudness")
                .accessibilityValue("minus \(abs(Int(db.rounded()))) decibels")
            Text(readout)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var readout: String {
        "−\(abs(Int(db.rounded()))) dB"
    }
}

// MARK: - Layout primitives

/// Grouped box containing a titled set of preference rows. Matches the native
/// "Preferences" grouping: 13pt semibold title, `surface` fill with `border`
/// outline, subdued 11pt footnote under the group.
struct PreferenceSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )

            if let footnote {
                Text(footnote)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A single row inside a `PreferenceSection`. Label on the left at 13pt/600,
/// control on the trailing edge, optional 11pt helper text underneath.
struct PreferenceRow<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                Text(label)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                control()
            }
            if let help {
                Text(help)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.vertical, 2)
    }
}

// Note: real rendering requires an `AppModel` in the environment — the pane
// reads `@Environment(AppModel.self)` to route normalization / pre-gain changes
// onto the live engine (#42). The Settings scene injects it at runtime; a bare
// `#Preview` would crash on the missing environment value, so it's intentionally
// omitted here — matching `PreferencesAudio`.
