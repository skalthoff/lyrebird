import LyrebirdAudio
import SwiftUI

/// Equalizer preferences pane (#40): the 10-band graphic EQ with the classic
/// iTunes-style preset list, riding the AVAudioEngine DSP pipeline (#39).
///
/// Layout: an engine opt-in section (the DSP path is chosen once at launch,
/// so the toggle advertises the relaunch), the enable/preset/reset controls,
/// and the band slider stack. The EQ controls follow the app's gated-feature
/// idiom (see the crossfade slider in `PreferencesPlayback`): visible but
/// disabled + dimmed while the DSP engine isn't routing playback this
/// session, with the footnote explaining why instead of hiding the pane.
///
/// State flow: the pane snapshots `model.equalizerSettings` into local
/// `@State` on appear and pushes every edit through `model.setEqualizer(_:)`,
/// which persists to `UserDefaults` and applies to the live `AVAudioUnitEQ`
/// in real time — no Apply button, matching every other pane.
///
/// Preference keys:
/// - `engine.useAVAudioEngine` — DSP engine opt-in (#39, read at launch)
/// - `audio.eq.enabled` / `audio.eq.preset` / `audio.eq.customGains` (#40)
struct PreferencesEqualizer: View {
    @Environment(AppModel.self) private var model

    /// DSP engine opt-in (#39). Written live; `AudioEngine` reads it once at
    /// launch, hence the relaunch hint when it diverges from the running path.
    @AppStorage(AppModel.engineDSPDefaultsKey) private var dspOptIn: Bool = false

    /// Local working copy; the engine's `equalizer` is the canonical one.
    @State private var settings = EqualizerSettings()

    /// Whether the DSP pipeline is routing playback *this session* — the EQ
    /// node only exists on that path, so the controls gate on this rather
    /// than on the live defaults key.
    private var eqActive: Bool { model.engineDSPActiveThisSession }

    private var needsRelaunch: Bool { dspOptIn != model.engineDSPActiveThisSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Playback Engine",
                footnote: "The equalizer runs on Lyrebird's DSP engine, which routes playback through an effect graph instead of the system player. Off — the default — keeps streaming on the original bit-perfect path. Changing this takes effect after relaunching Lyrebird."
            ) {
                PreferenceRow(
                    label: "DSP Audio Engine",
                    help: needsRelaunch
                        ? "Relaunch Lyrebird to \(dspOptIn ? "activate the DSP engine" : "return to the system player")."
                        : (dspOptIn ? "Active — the equalizer is live." : "Off — the equalizer is unavailable.")
                ) {
                    Toggle("", isOn: $dspOptIn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("DSP audio engine")
                }
            }

            PreferenceSection(
                title: "Equalizer",
                footnote: eqActive
                    ? "Preset and band changes apply in real time. With the equalizer off — or any band at 0 dB — that stage is bypassed entirely, so Flat is bit-identical to no EQ."
                    : "Requires the DSP engine above. Your settings are saved and will apply once it's active."
            ) {
                PreferenceRow(label: "Enable Equalizer") {
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable equalizer")
                }

                PreferenceRow(label: "Preset", help: presetHelp) {
                    HStack(spacing: 10) {
                        Picker("", selection: presetBinding) {
                            ForEach(EqualizerPreset.all) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                            Text("Custom").tag(EqualizerPreset.customID)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                        .accessibilityLabel("Equalizer preset")

                        Button("Reset") { reset() }
                            .disabled(
                                settings.presetID == EqualizerPreset.flat.id
                                    && settings.customGains.allSatisfy { $0 == 0 }
                            )
                            .help("Return to the Flat preset and zero the custom curve.")
                            .accessibilityLabel("Reset equalizer")
                    }
                }
            }
            .disabled(!eqActive)
            .opacity(eqActive ? 1 : 0.55)

            PreferenceSection(
                title: "Bands",
                footnote: "Per-band gain from −12 dB to +12 dB across the standard octave centers. Dragging a slider switches the preset to Custom."
            ) {
                bandStack
            }
            .disabled(!eqActive || !settings.isEnabled)
            .opacity(eqActive && settings.isEnabled ? 1 : 0.55)

            Spacer(minLength: 0)
        }
        .onAppear { settings = model.equalizerSettings }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Equalizer")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("10-band graphic equalizer with presets.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled },
            set: { enabled in
                settings.isEnabled = enabled
                apply()
            }
        )
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { settings.presetID },
            set: { id in
                settings.presetID = id
                apply()
            }
        )
    }

    /// Per-band slider binding. Writing while a named preset is selected
    /// forks it into Custom seeded from that preset's curve — the universal
    /// EQ behaviour (Music.app, foobar2000, …), and the reason `customGains`
    /// is captured from `activeGains` rather than overwritten blind.
    private func bandBinding(_ index: Int) -> Binding<Float> {
        Binding(
            get: { settings.activeGains[index] },
            set: { newValue in
                var gains = settings.activeGains
                gains[index] = newValue
                settings.customGains = gains
                settings.presetID = EqualizerPreset.customID
                apply()
            }
        )
    }

    private func apply() {
        model.setEqualizer(settings)
    }

    private func reset() {
        settings.presetID = EqualizerPreset.flat.id
        settings.customGains = [Float](repeating: 0, count: EqualizerSettings.bandCount)
        apply()
    }

    private var presetHelp: String? {
        settings.presetID == EqualizerPreset.customID ? "Your own curve — adjust the bands below." : nil
    }

    // MARK: - Band sliders

    private var bandStack: some View {
        HStack(alignment: .top, spacing: 6) {
            dbAxis
            ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                BandColumn(
                    frequency: EqualizerSettings.bandFrequencies[index],
                    gain: bandBinding(index)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }

    /// Leading dB scale: top/center/bottom of the slider track height, with
    /// an empty readout slot above and a label slot below so the marks align
    /// with the sliders' tracks rather than the columns' full height.
    private var dbAxis: some View {
        VStack(spacing: 6) {
            Text(" ")
                .font(Theme.font(10, weight: .semibold))
            VStack {
                Text("+12")
                Spacer()
                Text("0")
                Spacer()
                Text("−12")
            }
            .font(Theme.font(9, weight: .semibold))
            .foregroundStyle(Theme.ink3)
            .monospacedDigit()
            .frame(height: BandColumn.trackLength)
            Text(" ")
                .font(Theme.font(10, weight: .semibold))
        }
        .accessibilityHidden(true)
    }

    /// "31" … "500", then "1K" … "16K" — compact axis labels.
    static func frequencyLabel(_ hz: Float) -> String {
        hz >= 1_000 ? "\(Int(hz / 1_000))K" : "\(Int(hz))"
    }
}

/// One EQ band: gain readout on top, vertical slider, frequency label below.
///
/// SwiftUI has no native vertical `Slider`; the standard macOS technique is a
/// horizontal slider rotated −90° (right → up) inside a fixed frame that
/// reserves the rotated footprint. `rotationEffect` transforms hit-testing
/// along with rendering, so dragging tracks the visual orientation.
private struct BandColumn: View {
    static let trackLength: CGFloat = 150

    let frequency: Float
    @Binding var gain: Float

    private var frequencyLabel: String {
        PreferencesEqualizer.frequencyLabel(frequency)
    }

    private var accessibilityFrequency: String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000)) kilohertz" : "\(Int(frequency)) hertz"
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(readout)
                .font(Theme.font(10, weight: .semibold))
                .foregroundStyle(gain == 0 ? Theme.ink3 : Theme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()

            Slider(
                value: $gain,
                in: EqualizerSettings.gainRange,
                step: 0.5
            )
            .frame(width: BandColumn.trackLength)
            .rotationEffect(.degrees(-90))
            .frame(width: 32, height: BandColumn.trackLength)

            Text(frequencyLabel)
                .font(Theme.font(10, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 38)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityFrequency) band")
        .accessibilityValue(accessibilityReadout)
        .accessibilityAdjustableAction { direction in
            let step: Float = direction == .increment ? 1 : -1
            gain = min(
                max(gain + step, EqualizerSettings.gainRange.lowerBound),
                EqualizerSettings.gainRange.upperBound
            )
        }
    }

    /// "+4", "−2.5", "0" — unicode minus per the app's audio-copy convention
    /// (see `PreGainSlider`), halves only when the value actually has one.
    private var readout: String {
        if gain == 0 { return "0" }
        let sign = gain > 0 ? "+" : "−"
        let magnitude = abs(gain)
        let isWhole = magnitude.rounded() == magnitude
        return sign + (isWhole ? "\(Int(magnitude))" : String(format: "%.1f", magnitude))
    }

    private var accessibilityReadout: String {
        if gain == 0 { return "0 decibels" }
        let direction = gain > 0 ? "plus" : "minus"
        let magnitude = abs(gain)
        let isWhole = magnitude.rounded() == magnitude
        let value = isWhole ? "\(Int(magnitude))" : String(format: "%.1f", magnitude)
        return "\(direction) \(value) decibels"
    }
}

// Note: real rendering requires an `AppModel` in the environment — the pane
// routes EQ changes onto the live engine through it. The Settings scene
// injects it at runtime; a bare `#Preview` would crash on the missing
// environment value, so it's intentionally omitted here — matching
// `PreferencesAudio` / `PreferencesPlayback`.
