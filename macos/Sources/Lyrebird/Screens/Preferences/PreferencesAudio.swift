import SwiftUI

/// Audio quality preferences pane.
///
/// Deliberately overlaps with the Playback pane's quality pickers — both read
/// from `playback.streamingQuality` and `playback.downloadQuality` so changes
/// in one surface show up in the other. Audio is the "proper" home per the
/// System Settings-style layout (#114); Playback keeps its copy because a
/// user hunting for "streaming quality" will look under Playback first.
///
/// Also houses the **Transcoding preference** — a two-option toggle between
/// Direct Play (the server decides, prefers passthrough) and Always Transcode
/// (the server re-encodes even when a direct stream would work). This is the
/// escape hatch for users hitting compatibility issues with a specific codec
/// or container on their output device.
///
/// Preference keys (user-facing `@AppStorage`, shared with Playback):
/// - `playback.streamingQuality`     — `PlaybackQuality`
/// - `playback.downloadQuality`      — `PlaybackQuality`
/// - `audio.transcodingPreference`   — `TranscodingPreference` (new)
///
/// Spec: `research/03-ux-patterns.md` Issue 69 and GitHub issue #117.
struct PreferencesAudio: View {
    @AppStorage("playback.streamingQuality") private var streamingQuality: PlaybackQuality = .automatic
    @AppStorage("playback.downloadQuality") private var downloadQuality: PlaybackQuality = .lossless
    @AppStorage("audio.transcodingPreference") private var transcodingRaw: String = TranscodingPreference.directPlay.rawValue

    private var transcoding: Binding<TranscodingPreference> {
        Binding(
            get: { TranscodingPreference(rawValue: transcodingRaw) ?? .directPlay },
            set: { transcodingRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Streaming Quality",
                footnote: "Applied when playing over the network. Higher tiers use more bandwidth; Lossless and Original require your server (and your connection) to sustain them."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: streamingQuality.subtitle
                ) {
                    ExplicitQualityPicker(selection: $streamingQuality)
                        .accessibilityLabel("Streaming quality")
                }
            }

            PreferenceSection(
                title: "Download Quality",
                footnote: "Used when saving tracks for offline listening. Higher settings consume more disk space."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: downloadQuality.subtitle
                ) {
                    ExplicitQualityPicker(selection: $downloadQuality)
                        .accessibilityLabel("Download quality")
                }
            }

            PreferenceSection(
                title: "Transcoding",
                footnote: "Direct Play passes the original file through untouched when your device supports the codec — fastest and highest quality. Always Transcode forces the server to re-encode, which helps when a specific file won't play cleanly."
            ) {
                PreferenceRow(
                    label: "Preference",
                    help: transcoding.wrappedValue.subtitle
                ) {
                    Picker("", selection: transcoding) {
                        ForEach(TranscodingPreference.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .accessibilityLabel("Transcoding preference")
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Streaming and download quality, transcoding preference.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

/// How to handle playback when a direct stream is available.
///
/// TODO(#117): feed this into the `PlaybackInfo` request — `directPlay` maps
/// to sending a `DeviceProfile` that advertises the full set of decodable
/// codecs/containers so the server returns a DirectStream URL when possible;
/// `alwaysTranscode` strips the direct-play advertisements so every playback
/// decision resolves to a transcoded session.
enum TranscodingPreference: String, CaseIterable, Identifiable {
    case directPlay
    case alwaysTranscode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .directPlay: return "Direct Play"
        case .alwaysTranscode: return "Always Transcode"
        }
    }

    var subtitle: String {
        switch self {
        case .directPlay: return "Pass the file through when your device can decode it."
        case .alwaysTranscode: return "Force the server to re-encode every stream."
        }
    }
}

/// Segmented quality picker that shows all five explicit tiers (no Auto).
/// Matches the #117 spec exactly — the Playback pane's `QualityPicker` also
/// shows `automatic` because historically that pane's copy read "Let Jellify
/// pick." A separate picker here avoids touching that surface.
private struct ExplicitQualityPicker: View {
    @Binding var selection: PlaybackQuality

    /// The five tiers the Audio pane cares about — Auto is deliberately
    /// excluded because the spec asks for explicit choices. If the on-disk
    /// value happens to be `.automatic` (legacy), the segmented control just
    /// shows nothing selected; first tap commits to an explicit tier.
    private static let tiers: [PlaybackQuality] = [.low, .normal, .high, .lossless, .original]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Self.tiers) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }
}

#Preview {
    PreferencesAudio()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
