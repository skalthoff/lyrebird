import AppKit

/// Trackpad haptic feedback for transport + scrub interactions (#18, #325).
///
/// Force Touch trackpads expose a haptic actuator through
/// `NSHapticFeedbackManager.defaultPerformer`. Firing a short pattern when the
/// user taps play/pause/skip, or when the scrub thumb settles, gives the
/// transport the same tactile "click" Music.app and the system volume HUD
/// have — the control feels physical rather than purely visual.
///
/// ## Pattern mapping
///
/// AppKit ships three feedback patterns; we map each to the interaction whose
/// semantics it was designed for:
///   - `.generic`     → discrete transport taps (play / pause / skip). The
///                      catch-all "a thing happened" tap.
///   - `.levelChange` → a value moved through detents (shuffle / repeat mode
///                      cycling), matching the system volume / brightness HUD.
///   - `.alignment`   → the scrub thumb committing to a position, mirroring the
///                      snap-to-guide feel AppKit designed this pattern for.
///
/// ## Reduce-Motion gate
///
/// All feedback is suppressed when **Reduce Motion** is enabled. Apple groups
/// non-essential haptics under the motion-sensitivity umbrella (the same
/// accessibility preference that quiets parallax / autoplay), so a user who
/// has opted out of incidental motion shouldn't feel incidental buzzes either.
/// We read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
/// directly, mirroring how `Theme` reads the increase-contrast /
/// differentiate-without-color accessibility flags inline at the call site
/// rather than threading them through state.
///
/// ## Testability
///
/// The gate and the dispatch are split from the system singletons: the pure
/// `perform(_:reduceMotion:using:)` overload takes the reduce-motion flag and
/// a `HapticPerformer` so the gating contract can be asserted headlessly,
/// without a Force Touch device or a live `NSWorkspace`. The zero-argument
/// convenience methods wire in the real performer + the live accessibility
/// flag for production call sites.
enum Haptics {
    /// The subset of `NSHapticFeedbackPerformer` behaviour we depend on,
    /// abstracted so tests can inject a recording double. `NSHapticFeedbackManager`'s
    /// `defaultPerformer` conforms to `NSHapticFeedbackPerformer` and is
    /// adapted to this protocol below.
    protocol HapticPerformer {
        func perform(
            _ pattern: NSHapticFeedbackManager.FeedbackPattern,
            performanceTime: NSHapticFeedbackManager.PerformanceTime
        )
    }

    /// Discrete transport tap — play / pause / previous / next. Maps to
    /// `.generic`.
    @MainActor
    static func transport() {
        perform(.generic)
    }

    /// A value cycled through detents — shuffle toggle, repeat-mode rotation.
    /// Maps to `.levelChange`, matching the system volume/brightness HUD feel.
    @MainActor
    static func levelChange() {
        perform(.levelChange)
    }

    /// The scrub thumb settling onto a committed position. Maps to
    /// `.alignment`, the snap-to-guide pattern.
    @MainActor
    static func scrubCommit() {
        perform(.alignment)
    }

    /// Production entry point: fire `pattern` on the system performer unless
    /// Reduce Motion is on. Reads the live accessibility flag inline.
    @MainActor
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        perform(
            pattern,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            using: SystemHapticPerformer.shared
        )
    }

    /// Pure, injectable core used by both production and tests. No-ops when
    /// `reduceMotion` is true; otherwise performs `pattern` on `performer` at
    /// `.now` so the tap lands on the same runloop turn as the interaction
    /// that triggered it. Returns whether the feedback was actually dispatched
    /// so the gating contract is observable in tests.
    @discardableResult
    static func perform(
        _ pattern: NSHapticFeedbackManager.FeedbackPattern,
        reduceMotion: Bool,
        using performer: HapticPerformer
    ) -> Bool {
        guard !reduceMotion else { return false }
        performer.perform(pattern, performanceTime: .now)
        return true
    }
}

/// Adapts the real `NSHapticFeedbackManager.defaultPerformer` to
/// `Haptics.HapticPerformer`. `defaultPerformer` is re-fetched on every call
/// rather than cached because AppKit documents it as a dynamic accessor whose
/// returned performer can change with the active device configuration.
private struct SystemHapticPerformer: Haptics.HapticPerformer {
    static let shared = SystemHapticPerformer()

    func perform(
        _ pattern: NSHapticFeedbackManager.FeedbackPattern,
        performanceTime: NSHapticFeedbackManager.PerformanceTime
    ) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: performanceTime)
    }
}
