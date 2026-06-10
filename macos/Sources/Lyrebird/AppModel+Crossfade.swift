import Foundation
import LyrebirdAudio

/// Crossfade routing (#41).
///
/// `CrossfadeSettings` is the value type (defined in `LyrebirdAudio` next to
/// the dual-deck pipeline it drives); this extension is the app-side glue:
/// persist edits to `UserDefaults` and push them onto the engine, which
/// applies them to the live `EngineDSPPipeline` when the DSP path (#39) is
/// running. Unlike the equalizer there is no engine-held canonical copy —
/// `UserDefaults` is the single source of truth (the duration key predates
/// the engine support; see `CrossfadeSettings.DefaultsKey`), and the
/// pipeline re-reads it on construction, so no `AppModel.init` seeding is
/// needed.
extension AppModel {
    /// Current crossfade settings as persisted. The Playback pane's
    /// `@AppStorage` bindings read the same keys for instant UI; edits route
    /// back through `setCrossfade(_:)`.
    var crossfadeSettings: CrossfadeSettings {
        CrossfadeSettings.load(from: .standard)
    }

    /// Persist new crossfade settings and push them onto the engine. When
    /// the DSP pipeline is live the change applies to the very next
    /// transition (and turning crossfade off disarms a pending overlap);
    /// when it isn't, the settings still persist so they're waiting once
    /// the engine path is enabled.
    func setCrossfade(_ settings: CrossfadeSettings) {
        settings.save(to: .standard)
        audio.dspApplyCrossfade(settings)
    }
}
