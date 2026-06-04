import LyrebirdAudio
import SwiftUI

/// Audio quality preferences pane.
///
/// Canonical home for **Streaming Quality**, **Download Quality**, and the
/// **Preferred Codec** (#117). These used to be duplicated in the Playback
/// pane against the same `@AppStorage` keys; the duplicates were removed so
/// each setting has exactly one editing surface here. The quality/codec
/// pickers are gated behind `model.supportsStreamQualitySelection` and shown
/// disabled until the core threads `MaxStreamingBitrate` + a `DeviceProfile`
/// into the Jellyfin `PlaybackInfo` request (#260) — until then they would
/// persist a preference nothing reads.
///
/// Also houses the **Transcoding preference** — a two-option toggle between
/// Direct Play (the server decides, prefers passthrough) and Always Transcode
/// (the server re-encodes even when a direct stream would work). This is the
/// escape hatch for users hitting compatibility issues with a specific codec
/// or container on their output device.
///
/// Preference keys (user-facing `@AppStorage`):
/// - `playback.streamingQuality`     — `PlaybackQuality`
/// - `playback.downloadQuality`      — `PlaybackQuality`
/// - `playback.preferredCodec`       — `PreferredAudioCodec`
/// - `audio.transcodingPreference`   — `TranscodingPreference`
///
/// Spec: `research/03-ux-patterns.md` Issue 69 and GitHub issue #117.
struct PreferencesAudio: View {
    @Environment(AppModel.self) private var model

    @AppStorage("playback.streamingQuality") private var streamingQuality: PlaybackQuality = .automatic
    @AppStorage("playback.downloadQuality") private var downloadQuality: PlaybackQuality = .lossless
    @AppStorage("playback.preferredCodec") private var preferredCodec: PreferredAudioCodec = .automatic
    @AppStorage("audio.transcodingPreference") private var transcodingRaw: String = TranscodingPreference.directPlay.rawValue
    @AppStorage(AudioOutputDevices.preferenceKey) private var outputDeviceUID: String = ""
    @AppStorage(AudioOutputDevices.exclusiveModePreferenceKey) private var exclusiveMode: Bool = false

    /// Devices enumerated off the main actor on appear (HAL reads can block —
    /// CLAUDE.md gap #2). The "System Default" option is presented separately
    /// and maps to an empty UID.
    @State private var devices: [AudioOutputDevice] = []

    /// Watches Core Audio for device hot-plug/unplug so the list refreshes
    /// while the pane is open instead of freezing at its on-appear snapshot.
    /// Started in `.task`, torn down in `.onDisappear` to avoid leaking the HAL
    /// listener.
    @State private var deviceObserver = AudioOutputDeviceObserver()

    private var transcoding: Binding<TranscodingPreference> {
        Binding(
            get: { TranscodingPreference(rawValue: transcodingRaw) ?? .directPlay },
            set: { transcodingRaw = $0.rawValue }
        )
    }

    /// Picker binding. Reads/writes `@AppStorage` for instant UI, and routes
    /// the change through `AppModel` so the live player re-pins immediately.
    private var deviceSelection: Binding<String> {
        Binding(
            get: { outputDeviceUID },
            set: { newUID in
                outputDeviceUID = newUID
                model.setOutputDevice(uid: newUID)
            }
        )
    }

    /// Exclusive-mode toggle binding. Flips `@AppStorage` optimistically and
    /// asks `AppModel` to acquire/release the Core Audio hog claim; on failure
    /// the model surfaces an error and rolls the flag back.
    private var exclusiveBinding: Binding<Bool> {
        Binding(
            get: { exclusiveMode },
            set: { enabled in
                exclusiveMode = enabled
                model.setExclusiveMode(enabled)
            }
        )
    }

    /// `true` when the saved UID names a device that's no longer present, so
    /// the row can hint that playback is falling back to the system default.
    private var savedDeviceMissing: Bool {
        !outputDeviceUID.isEmpty && !devices.contains { $0.uid == outputDeviceUID }
    }

    /// Whether the quality / codec pickers are wired into playback. Gated on
    /// the capability flag (#260) — the core has no `MaxStreamingBitrate` /
    /// `DeviceProfile` parameter on its `PlaybackInfo` request yet, so until it
    /// does the pickers are shown disabled rather than persisting a preference
    /// nothing reads.
    private var qualityAvailable: Bool { model.supportsStreamQualitySelection }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Output Device",
                footnote: "Choose where audio plays. System Default follows whatever you pick in Sound settings; choosing a specific device keeps Lyrebird on it even when the system default changes. A disconnected device falls back to the system default automatically."
            ) {
                PreferenceRow(
                    label: "Device",
                    help: savedDeviceMissing ? "Saved device unavailable — using system default." : nil
                ) {
                    Picker("", selection: deviceSelection) {
                        Text("System Default").tag("")
                        if savedDeviceMissing {
                            // Keep the stale selection visible (greyed) so the
                            // picker doesn't silently jump to System Default.
                            Text("Unavailable device").tag(outputDeviceUID)
                        }
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    .accessibilityLabel("Output device")
                }

                PreferenceRow(
                    label: "Exclusive Mode",
                    help: "Take exclusive control of the device for bit-perfect, lossless output. Other apps can't play audio while this is on."
                ) {
                    Toggle("", isOn: exclusiveBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(outputDeviceUID.isEmpty)
                        .accessibilityLabel("Exclusive mode")
                }
            }

            PreferenceSection(
                title: "Streaming Quality",
                footnote: qualityAvailable
                    ? "Applied when playing over the network. Higher tiers use more bandwidth; Lossless and Original require your server (and your connection) to sustain them."
                    : "Quality and codec selection is planned. It needs server-side transcoding support that isn't available in this build yet."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: qualityAvailable ? streamingQuality.subtitle : "Coming soon."
                ) {
                    AudioQualityPicker(selection: $streamingQuality)
                        .disabled(!qualityAvailable)
                        .accessibilityLabel("Streaming quality")
                }
            }
            .opacity(qualityAvailable ? 1 : 0.55)

            PreferenceSection(
                title: "Download Quality",
                footnote: "Used when saving tracks for offline listening. Higher settings consume more disk space."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: qualityAvailable ? downloadQuality.subtitle : "Coming soon."
                ) {
                    AudioQualityPicker(selection: $downloadQuality)
                        .disabled(!qualityAvailable)
                        .accessibilityLabel("Download quality")
                }
            }
            .opacity(qualityAvailable ? 1 : 0.55)

            PreferenceSection(
                title: "Preferred Codec",
                footnote: "Codec the server transcodes to when a direct stream isn't possible. \"Automatic\" trusts the server's default."
            ) {
                PreferenceRow(
                    label: "Codec",
                    help: qualityAvailable ? preferredCodec.subtitle : "Coming soon."
                ) {
                    Picker("", selection: $preferredCodec) {
                        ForEach(PreferredAudioCodec.allCases) { codec in
                            Text(codec.label).tag(codec)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    .disabled(!qualityAvailable)
                    .accessibilityLabel("Preferred audio codec")
                }
            }
            .opacity(qualityAvailable ? 1 : 0.55)

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
        .task {
            await loadDevices()
            // Refresh whenever a device is plugged in / removed while the pane
            // is open. The callback runs on the main actor; loadDevices() hops
            // the actual HAL read back off it.
            deviceObserver.start {
                Task { await loadDevices() }
            }
        }
        .onDisappear { deviceObserver.stop() }
    }

    /// Enumerate output devices off the main actor (HAL property reads can
    /// block) and publish back to `@State` on the main actor.
    private func loadDevices() async {
        let found = await Task.detached { AudioOutputDevices.outputDevices() }.value
        devices = found
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

/// Segmented quality picker covering every `PlaybackQuality` case, Auto
/// included. The streaming default is `.automatic` and the codec/quality model
/// treats Auto as a first-class choice ("Picked by Lyrebird"), so the control
/// must offer a segment for it — otherwise a stored `.automatic` (the default,
/// or any value migrated from the old shared keys) leaves the segmented control
/// with nothing selected and the pane looks broken until the first tap.
private struct AudioQualityPicker: View {
    @Binding var selection: PlaybackQuality

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PlaybackQuality.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }
}

// Note: real rendering requires an `AppModel` in the environment (the pane
// reads `@Environment(AppModel.self)` to route output-device changes). The
// Settings scene injects it at runtime; a bare `#Preview` would crash on the
// missing environment value, so it's intentionally omitted here — matching
// `PreferencesServer` / `PreferencesAccount`.
