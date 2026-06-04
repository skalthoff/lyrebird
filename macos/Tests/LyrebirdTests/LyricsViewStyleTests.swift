import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the Apple-Music-"Sing"-style active-line styling (#90). The
/// per-line fade-in, the 99%→100% scale bloom, the soft glow, and the dim on
/// inactive lines are all resolved by the pure `LyricLineStyle.resolve` value
/// type so they can be asserted without rendering a SwiftUI scene — the same
/// testable-model shape `NowPlayingBackdrop.showsArtworkLayer` uses.
final class LyricsViewStyleTests: XCTestCase {

    // MARK: - Active line (motion allowed)

    func testActiveLineUsesLargeBoldType() {
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        XCTAssertEqual(style.fontSize, 22)
        XCTAssertEqual(style.weight, .bold)
    }

    func testActiveLineIsFullyOpaque() {
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        XCTAssertEqual(style.opacity, 1.0, accuracy: 0.0001)
    }

    func testActiveLineBloomsToFullScale() {
        // The active line settles at 100% — it's the inactive lines that rest
        // at 99%, so the active line reads as the one that bloomed forward.
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        XCTAssertEqual(style.scale, 1.0, accuracy: 0.0001)
    }

    func testActiveLineHasSoftGlow() {
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        XCTAssertGreaterThan(style.glowRadius, 0)
        XCTAssertGreaterThan(style.glowOpacity, 0)
    }

    func testActiveLineAnimatesWhenMotionAllowed() {
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        XCTAssertTrue(style.animates)
    }

    // MARK: - Inactive line (motion allowed)

    func testInactiveLineUsesSmallerMediumType() {
        let style = LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        XCTAssertEqual(style.fontSize, 18)
        XCTAssertEqual(style.weight, .medium)
    }

    func testInactiveLineIsDimmed() {
        // Gentle dim on inactive lines: both a dimmer colour *and* sub-full
        // opacity, so the active line stands out beyond the colour swap alone.
        let style = LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        XCTAssertLessThan(style.opacity, 1.0)
    }

    func testInactiveLineRestsAtNinetyNinePercentScale() {
        let style = LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        XCTAssertEqual(style.scale, 0.99, accuracy: 0.0001)
    }

    func testInactiveLineHasNoGlow() {
        let style = LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        XCTAssertEqual(style.glowRadius, 0)
        XCTAssertEqual(style.glowOpacity, 0, accuracy: 0.0001)
    }

    func testActiveLineIsMoreOpaqueThanInactive() {
        let active = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        let inactive = LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        XCTAssertGreaterThan(active.opacity, inactive.opacity)
    }

    func testActiveLineScalesLargerThanInactive() {
        let active = LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        let inactive = LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        XCTAssertGreaterThan(active.scale, inactive.scale)
    }

    // MARK: - Reduce Motion gate

    func testReduceMotionPinsActiveScaleToFull() {
        // No scale bloom under Reduce Motion — the active line stays at 1.0.
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: true)
        XCTAssertEqual(style.scale, 1.0, accuracy: 0.0001)
    }

    func testReduceMotionPinsInactiveScaleToFull() {
        // Inactive lines also stop resting at 99% under Reduce Motion, so no
        // line moves at all.
        let style = LyricLineStyle.resolve(isActive: false, reduceMotion: true)
        XCTAssertEqual(style.scale, 1.0, accuracy: 0.0001)
    }

    func testReduceMotionDropsActiveGlow() {
        // The bloom is the motion we're gating — Reduce Motion removes it.
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: true)
        XCTAssertEqual(style.glowRadius, 0)
        XCTAssertEqual(style.glowOpacity, 0, accuracy: 0.0001)
    }

    func testReduceMotionDisablesAnimationForActiveAndInactive() {
        let active = LyricLineStyle.resolve(isActive: true, reduceMotion: true)
        let inactive = LyricLineStyle.resolve(isActive: false, reduceMotion: true)
        XCTAssertFalse(active.animates)
        XCTAssertFalse(inactive.animates)
    }

    func testReduceMotionPreservesFontAndColourContract() {
        // The instant-highlight fallback must keep the original 22/bold vs
        // 18/medium size+weight contract so the synced read still works with
        // motion off — only the scale/glow/animation are suppressed.
        let active = LyricLineStyle.resolve(isActive: true, reduceMotion: true)
        let inactive = LyricLineStyle.resolve(isActive: false, reduceMotion: true)

        XCTAssertEqual(active.fontSize, 22)
        XCTAssertEqual(active.weight, .bold)
        XCTAssertEqual(inactive.fontSize, 18)
        XCTAssertEqual(inactive.weight, .medium)
    }

    func testReduceMotionKeepsActiveOpacityFull() {
        // Dimming inactive lines is a static contrast cue, not motion, so the
        // active line stays fully opaque even with motion off.
        let style = LyricLineStyle.resolve(isActive: true, reduceMotion: true)
        XCTAssertEqual(style.opacity, 1.0, accuracy: 0.0001)
    }

    // MARK: - Equatable / determinism

    func testResolveIsDeterministic() {
        XCTAssertEqual(
            LyricLineStyle.resolve(isActive: true, reduceMotion: false),
            LyricLineStyle.resolve(isActive: true, reduceMotion: false)
        )
        XCTAssertEqual(
            LyricLineStyle.resolve(isActive: false, reduceMotion: true),
            LyricLineStyle.resolve(isActive: false, reduceMotion: true)
        )
    }

    func testActiveAndInactiveStylesDiffer() {
        XCTAssertNotEqual(
            LyricLineStyle.resolve(isActive: true, reduceMotion: false),
            LyricLineStyle.resolve(isActive: false, reduceMotion: false)
        )
    }

    func testMotionAndReduceMotionStylesDifferForActiveLine() {
        XCTAssertNotEqual(
            LyricLineStyle.resolve(isActive: true, reduceMotion: false),
            LyricLineStyle.resolve(isActive: true, reduceMotion: true)
        )
    }
}
