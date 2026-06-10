import Foundation
import LyrebirdAudio

/// Equalizer routing (#40).
///
/// `EqualizerSettings` is the value type (defined in `LyrebirdAudio` next to
/// the node it drives); this extension is the app-side glue: persist edits to
/// `UserDefaults` and push them onto the engine, which applies them to the
/// live `AVAudioUnitEQ` when the DSP pipeline (#39) is running. The canonical
/// in-memory copy lives on `AudioEngine.equalizer` — seeded once in
/// `AppModel.init` from the persisted defaults — so there is exactly one
/// source of truth between the Preferences pane and the audio graph.
extension AppModel {
    /// Current equalizer settings as held by the engine. The Preferences
    /// pane snapshots this into local `@State` on appear and writes back
    /// through `setEqualizer(_:)`.
    var equalizerSettings: EqualizerSettings {
        audio.equalizer
    }

    /// Whether the AVAudioEngine DSP path is actually routing playback this
    /// session. Distinct from `supportsEngineDSP`, which reads the defaults
    /// key *live*: right after the user flips the engine opt-in toggle the
    /// two disagree until relaunch (the engine path is chosen once at
    /// launch). UI that controls the real EQ node must gate on this one.
    var engineDSPActiveThisSession: Bool {
        audio.dspPipelineEnabled
    }

    /// Persist new equalizer settings and push them onto the engine. When
    /// the DSP pipeline is live the band gains/bypass flags change in real
    /// time (no graph rebuild); when it isn't, the settings still persist so
    /// the curve is waiting once the engine path is enabled.
    func setEqualizer(_ settings: EqualizerSettings) {
        audio.equalizer = settings
        settings.save(to: .standard)
    }
}
