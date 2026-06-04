import AppKit
import XCTest

@testable import Lyrebird

/// Coverage for `Haptics`' Reduce-Motion gate and pattern dispatch.
///
/// The transport / scrub call sites in `PlayerBar` and `MiniPlayerView` fire
/// haptic feedback through `Haptics`, which must stay silent when the user has
/// Reduce Motion enabled (Apple groups incidental haptics under that
/// accessibility preference). Exercising the pure
/// `perform(_:reduceMotion:using:)` overload with a recording double lets us
/// assert the gating + pattern mapping deterministically — no Force Touch
/// actuator and no live `NSWorkspace` required.
final class HapticsTests: XCTestCase {

    /// Records every dispatch so tests can assert what (if anything) fired.
    private final class RecordingPerformer: Haptics.HapticPerformer {
        private(set) var calls: [(pattern: NSHapticFeedbackManager.FeedbackPattern,
                                  time: NSHapticFeedbackManager.PerformanceTime)] = []

        func perform(
            _ pattern: NSHapticFeedbackManager.FeedbackPattern,
            performanceTime: NSHapticFeedbackManager.PerformanceTime
        ) {
            calls.append((pattern, performanceTime))
        }
    }

    func testSuppressedWhenReduceMotionOn() {
        let performer = RecordingPerformer()
        let fired = Haptics.perform(.generic, reduceMotion: true, using: performer)

        XCTAssertFalse(fired, "feedback must report not-fired when Reduce Motion is on")
        XCTAssertTrue(performer.calls.isEmpty, "no haptic may reach the performer under Reduce Motion")
    }

    func testFiresWhenReduceMotionOff() {
        let performer = RecordingPerformer()
        let fired = Haptics.perform(.generic, reduceMotion: false, using: performer)

        XCTAssertTrue(fired, "feedback must report fired when Reduce Motion is off")
        XCTAssertEqual(performer.calls.count, 1, "exactly one dispatch reaches the performer")
    }

    func testPatternIsForwardedUnchanged() {
        // Each call site maps its interaction to a specific AppKit pattern;
        // the gate must forward whichever pattern it was handed, not coerce
        // them all to one value.
        let patterns: [NSHapticFeedbackManager.FeedbackPattern] = [.generic, .alignment, .levelChange]
        for pattern in patterns {
            let performer = RecordingPerformer()
            Haptics.perform(pattern, reduceMotion: false, using: performer)
            XCTAssertEqual(performer.calls.first?.pattern, pattern, "the requested pattern must propagate verbatim")
        }
    }

    func testDispatchUsesNowTiming() {
        // The tap should land on the same runloop turn as the interaction
        // (transport tap / scrub commit), so it's perceived as part of the
        // gesture rather than a delayed afterthought.
        let performer = RecordingPerformer()
        Haptics.perform(.alignment, reduceMotion: false, using: performer)
        XCTAssertEqual(performer.calls.first?.time, .now, "transport/scrub feedback fires at .now")
    }

    func testRepeatedDispatchesAccumulate() {
        // Rapid transport taps (e.g. holding next) should each produce their
        // own feedback rather than coalescing — the gate is stateless.
        let performer = RecordingPerformer()
        for _ in 0..<5 {
            Haptics.perform(.generic, reduceMotion: false, using: performer)
        }
        XCTAssertEqual(performer.calls.count, 5, "each interaction fires its own feedback")
    }
}
