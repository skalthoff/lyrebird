import Foundation
import os

/// Runtime feature flags loaded from
/// `~/Library/Application Support/Lyrebird/flags.json`.
///
/// ## Purpose
/// Provides toggle-able knobs for experimental or unreleased features without
/// shipping a new binary. A power user (or developer) edits `flags.json`,
/// then either relaunches the app or sends `SIGUSR1` to reload live.
///
/// ## Schema
/// ```json
/// {
///   "crossfade_ms": 0,
///   "gapless_playback": false,
///   "debug_panel_enabled": true,
///   "library_delta_sync": true
/// }
/// ```
/// Unknown keys are silently ignored. Missing keys inherit the compiled-in
/// default. The file is optional — if absent the app runs with all defaults.
///
/// ## Thread safety
/// All mutable state is guarded by `@MainActor`. The `SIGUSR1` handler
/// dispatches a reload onto the main actor, so no additional synchronization
/// is needed in call sites.
///
/// ## Closed issue
/// Resolves #451 (Feature flags — static file + in-app toggles).
@MainActor
@Observable
final class FeatureFlags {

    // MARK: - Shared instance

    static let shared = FeatureFlags()

    // MARK: - Flags

    /// Enable the debug / experiments panel in Preferences. When false the
    /// "Experiments" pane is hidden from the navigation sidebar, keeping the
    /// in-app toggle surface invisible to non-developer users.
    var debugPanelEnabled: Bool = false

    /// Gapless playback via crossfade-joining the audio graph. Separate from
    /// `Capabilities.supportsCrossfade`, which gates the slider UI — this flag
    /// is the runtime knob that would activate the feature once the audio engine
    /// grows overlapping-playback support.
    var gaplessPlayback: Bool = true

    /// Crossfade duration in milliseconds. 0 = off.
    var crossfadeMs: Int = 0

    /// Library delta-sync: fetch only items changed since the last sync rather
    /// than doing a full library reload on each launch.
    var libraryDeltaSync: Bool = true

    // MARK: - Private

    private let logger = Logger(subsystem: Log.subsystem, category: "flags")

    /// File URL for `flags.json` in the app's Application Support directory.
    private var flagsFileURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return support.appendingPathComponent("Lyrebird/flags.json")
    }

    // MARK: - Init

    private init() {}

    // MARK: - Load

    /// Load flags from disk. Call once at app startup (from `LyrebirdApp.init`
    /// or `AppDelegate.applicationDidFinishLaunching`). No-ops if the file is
    /// absent.
    func loadFromDisk() {
        guard let url = flagsFileURL else { return }
        applyFile(at: url)
        installSIGUSR1Handler()
    }

    /// Apply the flags file at the given URL. Unknown keys are ignored; missing
    /// keys leave the compiled-in default in place. Errors are logged but do not
    /// crash — a malformed file has the same effect as an absent file.
    private func applyFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("flags.json absent — using compiled defaults")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONSerialization.jsonObject(with: data)
            guard let dict = raw as? [String: Any] else {
                logger.error("flags.json root is not a JSON object — ignoring")
                return
            }
            apply(dict: dict)
            logger.notice("flags.json loaded from \(url.path, privacy: .public)")
        } catch {
            logger.error("flags.json read/parse failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Write flag values from a decoded dictionary onto self. Unknown keys are
    /// silently ignored per the acceptance criteria.
    private func apply(dict: [String: Any]) {
        if let v = dict["debug_panel_enabled"] as? Bool { debugPanelEnabled = v }
        if let v = dict["gapless_playback"] as? Bool { gaplessPlayback = v }
        if let v = dict["crossfade_ms"] as? Int { crossfadeMs = v }
        if let v = dict["library_delta_sync"] as? Bool { libraryDeltaSync = v }
    }

    // MARK: - SIGUSR1

    /// Install a POSIX SIGUSR1 handler that re-reads the flags file live.
    ///
    /// The signal handler cannot access Swift runtime state directly, so it
    /// dispatches work onto the main queue, which `@MainActor` call sites read.
    private func installSIGUSR1Handler() {
        // Use a DispatchSource-based signal handler rather than a raw C signal
        // handler — it's safe to call Swift closures from DispatchSource event
        // handlers, unlike raw POSIX signal handlers.
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.logger.notice("SIGUSR1 received — reloading flags.json")
                guard let url = self.flagsFileURL else { return }
                self.applyFile(at: url)
            }
        }
        // Ignore the signal at the POSIX level so the DispatchSource handler
        // takes precedence over the default action (which terminates the process).
        signal(SIGUSR1, SIG_IGN)
        source.resume()
        // Retain the source for the lifetime of the app by storing it in a
        // static reference; otherwise ARC would release it immediately and the
        // signal would go back to unhandled.
        FeatureFlags._sigusrSource = source
    }

    // nonisolated static storage for the signal source — avoids needing to
    // annotate with @MainActor here since DispatchSourceSignal is Sendable.
    private nonisolated(unsafe) static var _sigusrSource: (any DispatchSourceSignal)?
}
