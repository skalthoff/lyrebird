import SwiftUI

/// Playback preferences pane.
///
/// Exposes streaming quality, download quality, preferred audio codec, and
/// the behavioural knobs covered by issue #116 — crossfade, gapless, replay-
/// gain normalization, pre-gain, and "stop after current track". Quality and
/// codec live here historically; the Audio pane (#117) also surfaces quality
/// pickers, so the two sections overlap intentionally — the values are the
/// same `@AppStorage` keys behind the scenes.
///
/// These are UI-only knobs today — wiring into the AVPlayer source URL,
/// Jellyfin transcoding profile, and the audio engine's crossfade/replay-gain
/// paths lives in follow-up work (see TODOs below). Persisting the selection
/// now means the eventual implementation can read the current choice on day
/// one without a migration.
///
/// Design: matches the native Preferences aesthetic inside the Jellify shell.
/// Sections sit on `Theme.surface` with `Theme.border` outlines; labels use
/// 13pt `ink` weight 600, helper copy uses 11pt `ink3`. Option values are
/// stored as stable string raw values so the on-disk keys survive renames of
/// the display labels.
///
/// Preference keys (user-facing `@AppStorage`):
/// - `playback.streamingQuality`     — `PlaybackQuality`
/// - `playback.downloadQuality`      — `PlaybackQuality`
/// - `playback.preferredCodec`       — `PreferredAudioCodec`
/// - `playback.crossfadeSeconds`     — `Double` (0 = off, 1…12)
/// - `playback.gaplessEnabled`       — `Bool` (default true)
/// - `playback.normalization`        — `NormalizationMode`
/// - `playback.preGainDb`            — `Double` (±12)
/// - `playback.stopAfterCurrent`     — `Bool`
///
/// Spec: `research/03-ux-patterns.md` Issue 68 and GitHub issues #260 / #116.
struct PreferencesPlayback: View {
    @AppStorage("playback.streamingQuality") private var streamingQuality: PlaybackQuality = .automatic
    @AppStorage("playback.downloadQuality") private var downloadQuality: PlaybackQuality = .lossless
    @AppStorage("playback.preferredCodec") private var preferredCodec: PreferredAudioCodec = .automatic

    // #116 gap-fill knobs. All UI-only until the audio engine grows the
    // corresponding hooks. Raw types are chosen so the key names survive any
    // later enum/struct refactor — a Double for the slider is portable and the
    // Bool toggles are the obvious shape.
    @AppStorage("playback.crossfadeSeconds") private var crossfadeSeconds: Double = 0
    @AppStorage("playback.gaplessEnabled") private var gaplessEnabled: Bool = true
    @AppStorage("playback.normalization") private var normalizationRaw: String = NormalizationMode.off.rawValue
    @AppStorage("playback.preGainDb") private var preGainDb: Double = 0
    @AppStorage("playback.stopAfterCurrent") private var stopAfterCurrent: Bool = false

    private var normalization: Binding<NormalizationMode> {
        Binding(
            get: { NormalizationMode(rawValue: normalizationRaw) ?? .off },
            set: { normalizationRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Streaming",
                footnote: "Applies when playing over the network. \"Automatic\" lets Jellify pick based on your connection."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: streamingQuality.subtitle
                ) {
                    QualityPicker(selection: $streamingQuality)
                        .accessibilityLabel("Streaming quality")
                }
            }

            PreferenceSection(
                title: "Downloads",
                footnote: "Quality used for offline copies. Higher settings use more disk space."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: downloadQuality.subtitle
                ) {
                    QualityPicker(selection: $downloadQuality)
                        .accessibilityLabel("Download quality")
                }
            }

            PreferenceSection(
                title: "Audio Codec",
                footnote: "Preferred codec when transcoding is required. \"Automatic\" trusts the server."
            ) {
                PreferenceRow(
                    label: "Preferred codec",
                    help: preferredCodec.subtitle
                ) {
                    CodecPicker(selection: $preferredCodec)
                        .accessibilityLabel("Preferred audio codec")
                }
            }

            PreferenceSection(
                title: "Transitions",
                footnote: "Gapless joins tracks with no silence when the source supports it. Crossfade overlaps the last and next track by the selected number of seconds."
            ) {
                PreferenceRow(
                    label: "Gapless playback",
                    help: gaplessEnabled
                        ? "On — tracks on the same album play without a gap."
                        : "Off — each track ends cleanly before the next starts."
                ) {
                    Toggle("", isOn: $gaplessEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Gapless playback")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Crossfade",
                    help: crossfadeHelp
                ) {
                    CrossfadeSlider(seconds: $crossfadeSeconds)
                }
            }

            PreferenceSection(
                title: "Normalization",
                footnote: "Reads ReplayGain tags from the source when available. Track matches the loudness of each song individually; Album keeps the relative levels inside an album intact."
            ) {
                PreferenceRow(
                    label: "Volume matching",
                    help: normalization.wrappedValue.subtitle
                ) {
                    NormalizationPicker(selection: normalization)
                        .accessibilityLabel("Volume normalization")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Pre-gain",
                    help: preGainHelp
                ) {
                    PreGainSlider(db: $preGainDb)
                }
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
            Text("Streaming, downloads, transitions, and normalization.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
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
        case .automatic: return "Picked by Jellify"
        case .low: return "96 kbps"
        case .normal: return "192 kbps"
        case .high: return "320 kbps"
        case .lossless: return "FLAC"
        case .original: return "Direct stream — no transcoding"
        }
    }
}

/// ReplayGain-style loudness normalization. `off` applies no correction,
/// `track` matches each track's individual loudness, `album` uses the
/// per-album gain so relative dynamics inside an album remain intact.
///
/// TODO(#116): feed these into the audio engine's playback path. The engine
/// needs to read ReplayGain tags (`REPLAYGAIN_TRACK_GAIN` / `_ALBUM_GAIN`
/// plus their peak siblings), fall back to scanning when tags are missing,
/// and apply the selected gain on top of `preGainDb`. Until then the enum
/// persists the user's choice so the engine can pick it up without a
/// migration.
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

/// Segmented control for the 5-option quality tiers. Uses a native
/// `SegmentedPickerStyle` so keyboard/accessibility comes for free, then
/// restyles the surround with theme tokens so it matches the rest of the
/// Preferences pane.
private struct QualityPicker: View {
    @Binding var selection: PlaybackQuality

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PlaybackQuality.allCases) { q in
                Text(q.label).tag(q)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }
}

/// Inline menu picker for codec. Four short options fit comfortably in a
/// dropdown; a segmented control would feel noisy next to the quality row.
private struct CodecPicker: View {
    @Binding var selection: PreferredAudioCodec

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PreferredAudioCodec.allCases) { c in
                Text(c.label).tag(c)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
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

#Preview {
    PreferencesPlayback()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
