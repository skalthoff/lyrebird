import XCTest

@testable import Lyrebird

/// Coverage for the bare-Space Play/Pause decision (audit L383). The old
/// menu-level ⎵ shortcut fired even while a text field was focused, swallowing
/// the space the user meant to type. The replacement routes Space through an
/// `NSEvent` monitor whose pure decision lives in `PlayPauseSpaceDecision`; this
/// asserts each branch of that decision so the regression can't silently return.
final class PlayPauseSpaceDecisionTests: XCTestCase {

    /// Plain Space with a track loaded and no text field focused → toggle.
    func testTogglesWhenIdleWithTrackLoaded() {
        XCTAssertEqual(
            PlayPauseSpaceDecision.decide(
                hasModifiers: false,
                isTextEditing: false,
                hasCurrentTrack: true
            ),
            .togglePlayback
        )
    }

    /// The core regression: while editing text, Space must type, never toggle —
    /// even with a track loaded.
    func testPassesThroughWhileEditingText() {
        XCTAssertEqual(
            PlayPauseSpaceDecision.decide(
                hasModifiers: false,
                isTextEditing: true,
                hasCurrentTrack: true
            ),
            .passThrough,
            "Space in a focused text field must type a space, not toggle playback"
        )
    }

    /// Nothing loaded → nothing to toggle; don't eat the key.
    func testPassesThroughWhenNoTrackLoaded() {
        XCTAssertEqual(
            PlayPauseSpaceDecision.decide(
                hasModifiers: false,
                isTextEditing: false,
                hasCurrentTrack: false
            ),
            .passThrough
        )
    }

    /// A modified Space (e.g. ⌥Space) is never a transport toggle.
    func testPassesThroughWithModifiers() {
        XCTAssertEqual(
            PlayPauseSpaceDecision.decide(
                hasModifiers: true,
                isTextEditing: false,
                hasCurrentTrack: true
            ),
            .passThrough
        )
    }

    /// Modifier + text editing also passes through (both reasons hold).
    func testPassesThroughWithModifiersWhileEditing() {
        XCTAssertEqual(
            PlayPauseSpaceDecision.decide(
                hasModifiers: true,
                isTextEditing: true,
                hasCurrentTrack: true
            ),
            .passThrough
        )
    }
}
