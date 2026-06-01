import XCTest

@testable import Lyrebird

/// Coverage for `MenuBarController`'s persistent-vs-transient visibility
/// precedence — the rule that decides whether the menu-bar `NSStatusItem`
/// should be on screen given the persistent "Show in menu bar" (General)
/// toggle and the transient "Show in menu bar while playing" (Notifications)
/// toggle.
///
/// The decision is exercised through the pure `resolveVisibility(playing:
/// persistent:)` helper so the precedence is verified without realizing a
/// live `NSStatusItem`, which would require a window-server connection that a
/// headless test run doesn't have.
final class MenuBarVisibilityTests: XCTestCase {

    func testBothOffHidesIcon() {
        XCTAssertFalse(
            MenuBarController.resolveVisibility(playing: false, persistent: false),
            "neither toggle on: icon stays hidden"
        )
    }

    func testPersistentToggleAloneShowsIcon() {
        XCTAssertTrue(
            MenuBarController.resolveVisibility(playing: false, persistent: true),
            "the persistent General toggle shows the icon regardless of playback"
        )
    }

    func testPlayingAloneShowsIconTransiently() {
        XCTAssertTrue(
            MenuBarController.resolveVisibility(playing: true, persistent: false),
            "the while-playing toggle shows the icon during playback"
        )
    }

    func testPersistentWinsWhenPlaybackStops() {
        // Simulate a playing→stopped transition while the persistent toggle is
        // on: the icon must NOT be hidden.
        XCTAssertTrue(
            MenuBarController.resolveVisibility(playing: false, persistent: true),
            "stopping playback must never hide an icon the user pinned persistently"
        )
    }

    func testTransientHidesWhenStoppedAndNotPinned() {
        XCTAssertFalse(
            MenuBarController.resolveVisibility(playing: false, persistent: false),
            "with only the while-playing toggle, stopping playback removes the icon"
        )
    }

    func testBothOnShowsIcon() {
        XCTAssertTrue(
            MenuBarController.resolveVisibility(playing: true, persistent: true),
            "both toggles on: icon visible"
        )
    }
}
