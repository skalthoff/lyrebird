import AppKit
import XCTest

@testable import Lyrebird

/// Coverage for full-screen chrome handling (#20).
///
/// The chrome state machine lives in the pure `FullScreenChrome` reducer so its
/// per-phase decision (presentation options + title-bar transparency) is
/// verified without realizing a live full-screen `NSWindow`, which would need a
/// window-server connection a headless run doesn't have — the same constraint
/// `MenuBarVisibilityTests` / `SidebarAutoHideTests` work around. A second
/// group asserts the observer stays wired into `RootView` (read from source) so
/// a regression that drops the `.background(FullScreenChromeObserver())` mount
/// is caught here rather than in the field.
final class FullScreenChromeTests: XCTestCase {

    // MARK: - Reducer: full-screen phase

    /// Entering full-screen auto-hides the toolbar *and* the menu bar so the
    /// content owns the whole space and both reveal on a top-edge hover.
    func testFullScreenAutoHidesToolbarAndMenuBar() {
        let decision = FullScreenChrome.decide(phase: .fullScreen)
        XCTAssertTrue(
            decision.presentationOptions.contains(.autoHideToolbar),
            "full-screen must auto-hide the unified toolbar"
        )
        XCTAssertTrue(
            decision.presentationOptions.contains(.autoHideMenuBar),
            "full-screen must auto-hide the menu bar"
        )
    }

    /// In full-screen the transparent title bar is dropped so the
    /// `fullSizeContentView` inset collapses and the content fills cleanly
    /// rather than sitting below where the (now absent) traffic lights were.
    func testFullScreenDropsTransparentTitlebar() {
        let decision = FullScreenChrome.decide(phase: .fullScreen)
        XCTAssertFalse(
            decision.titlebarAppearsTransparent,
            "full-screen should make the title bar opaque so content fills the space"
        )
    }

    /// Full-screen must not request options it has no business holding
    /// (e.g. `.hideDock` or `.disableProcessSwitching`) — only the two
    /// auto-hide flags, so the reveal-on-hover behaviour stays standard.
    func testFullScreenRequestsExactlyTheTwoAutoHideOptions() {
        let decision = FullScreenChrome.decide(phase: .fullScreen)
        XCTAssertEqual(
            decision.presentationOptions,
            [.autoHideToolbar, .autoHideMenuBar],
            "full-screen should request exactly the toolbar + menu-bar auto-hide pair"
        )
    }

    // MARK: - Reducer: windowed phase

    /// Exiting to the windowed phase clears every presentation override.
    /// `NSApp.presentationOptions` only accepts the auto-hide flags while a
    /// full-screen window exists and must be emptied on exit, so the windowed
    /// decision has to be the empty set — anything else would leave AppKit
    /// rejecting the assignment or the menu bar stuck hidden.
    func testWindowedClearsPresentationOptions() {
        let decision = FullScreenChrome.decide(phase: .windowed)
        XCTAssertEqual(
            decision.presentationOptions,
            [],
            "the windowed phase must clear all presentation overrides"
        )
    }

    /// The windowed phase restores the transparent title bar so the
    /// `.hiddenTitleBar` edge-to-edge sidebar/content layout returns intact.
    func testWindowedRestoresTransparentTitlebar() {
        let decision = FullScreenChrome.decide(phase: .windowed)
        XCTAssertTrue(
            decision.titlebarAppearsTransparent,
            "windowed should restore the transparent title bar for the hidden-title-bar layout"
        )
    }

    // MARK: - Reducer: round-trip symmetry

    /// Enter → exit must be a true round trip: whatever full-screen changed,
    /// the windowed decision restores. Pins the symmetry so a future tweak to
    /// one phase can't silently leave the other stranded (e.g. an opaque title
    /// bar that never goes transparent again, or lingering presentation
    /// options).
    func testEnterExitRoundTripIsSymmetric() {
        let entered = FullScreenChrome.decide(phase: .fullScreen)
        let exited = FullScreenChrome.decide(phase: .windowed)

        XCTAssertNotEqual(
            entered.titlebarAppearsTransparent,
            exited.titlebarAppearsTransparent,
            "the title-bar transparency must actually flip between the two phases"
        )
        XCTAssertNotEqual(
            entered.presentationOptions,
            exited.presentationOptions,
            "the two phases must request distinct presentation options"
        )
        // The windowed leg is the resting state the app launches in, so it must
        // be the no-override baseline.
        XCTAssertEqual(exited.presentationOptions, [])
        XCTAssertTrue(exited.titlebarAppearsTransparent)
    }

    // MARK: - Structural wiring (source-read)

    /// `RootView` must mount the observer as a background bridge, or none of
    /// the full-screen handling runs. Asserted against source because the mount
    /// lives inside a `some View` body that can't be introspected headlessly.
    func testRootViewMountsFullScreenChromeObserver() throws {
        let source = try Self.readSource("Sources/Lyrebird/LyrebirdApp.swift")
        XCTAssertTrue(
            source.contains(".background(FullScreenChromeObserver())"),
            "RootView must mount FullScreenChromeObserver as a background bridge"
        )
    }

    /// The observer must scope its observation to the *specific* host window
    /// (the notification's `object`), not all windows — otherwise the mini
    /// player / preferences windows entering full-screen would drive the main
    /// window's chrome. Both transition notifications must be observed.
    func testObserverScopesNotificationsToHostWindow() throws {
        let source = try Self.readSource("Sources/Lyrebird/System/FullScreenChromeController.swift")
        XCTAssertTrue(
            source.contains("NSWindow.willEnterFullScreenNotification"),
            "observer must watch the enter-full-screen notification"
        )
        XCTAssertTrue(
            source.contains("NSWindow.willExitFullScreenNotification"),
            "observer must watch the exit-full-screen notification"
        )
        XCTAssertTrue(
            source.contains("object: window"),
            "observation must be scoped to the host window, not nil (all windows)"
        )
    }

    // MARK: - Helpers

    /// Resolve a repo-relative source path from this test file's location so
    /// the structural assertions don't depend on the CWD of the test runner.
    /// `#filePath` points at `<repo>/macos/Tests/LyrebirdTests/<this>.swift`;
    /// walk up to `macos/` and join `relativePath`.
    private static func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosDir = thisFile
            .deletingLastPathComponent() // LyrebirdTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
        let url = macosDir.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
