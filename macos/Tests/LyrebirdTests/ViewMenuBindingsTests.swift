import XCTest

@testable import Lyrebird

/// Coverage for the View-menu command wiring that the audit flagged as dead or
/// decoupled:
///   • "Show Sidebar" / "Show Queue" used to be permanently-disabled stubs with
///     empty actions (L251) — now they drive real `AppModel` state.
///   • the Mini Player `Toggle` discarded the value SwiftUI passed and blindly
///     toggled (L365) — the binding now drives to the requested value.
///
/// `AppModel` is `@MainActor`; constructing it boots a live `LyrebirdCore`, so
/// the suite redirects the core's data dir to a throwaway temp dir.
@MainActor
final class ViewMenuBindingsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Show Sidebar (L251)

    /// The menu can't reach `MainShell`'s private `columnVisibility`, so it
    /// drives a monotonic request counter that `MainShell` observes. Each tap
    /// must produce a fresh, observable bump even when the rail is already in
    /// the requested state.
    func testRequestSidebarToggleBumpsMonotonically() throws {
        let model = try AppModel()
        let start = model.sidebarToggleRequest

        model.requestSidebarToggle()
        XCTAssertEqual(model.sidebarToggleRequest, start + 1)

        model.requestSidebarToggle()
        XCTAssertEqual(
            model.sidebarToggleRequest, start + 2,
            "a repeat request must still change the counter so MainShell re-fires"
        )
    }

    /// The menu `Toggle` renders its checkmark from `isSidebarVisible`, which
    /// `MainShell` mirrors from the real column visibility. Confirm it's a
    /// writable mirror the shell can keep in sync.
    func testSidebarVisibleMirrorIsWritable() throws {
        let model = try AppModel()
        XCTAssertTrue(model.isSidebarVisible, "fresh model assumes the sidebar is showing")

        model.isSidebarVisible = false
        XCTAssertFalse(model.isSidebarVisible)
        model.isSidebarVisible = true
        XCTAssertTrue(model.isSidebarVisible)
    }

    // MARK: - Show Queue (L251)

    /// "Show Queue" now toggles the real inspector both ways (it used to be a
    /// permanently-disabled no-op).
    func testToggleQueueInspectorFlipsBothWays() throws {
        let model = try AppModel()
        XCTAssertFalse(model.isQueueInspectorOpen, "fresh model starts with the inspector closed")

        model.toggleQueueInspector()
        XCTAssertTrue(model.isQueueInspectorOpen, "first toggle opens the inspector")

        model.toggleQueueInspector()
        XCTAssertFalse(model.isQueueInspectorOpen, "second toggle closes it")
    }

    // MARK: - Mini Player setter (L365)

    /// The Mini Player menu `Toggle`'s setter now assigns the requested value
    /// directly (`isMiniPlayerVisible = $0`) instead of calling
    /// `toggleMiniPlayer()` and discarding it. Simulate SwiftUI delivering the
    /// same value twice (e.g. a redundant set) and confirm the state tracks the
    /// requested value rather than flipping away from it.
    func testMiniPlayerDirectSetTracksRequestedValue() throws {
        let model = try AppModel()
        XCTAssertFalse(model.isMiniPlayerVisible)

        // Drive to `true` twice. The old toggling setter would have closed it on
        // the second call; the direct-set binding keeps it open.
        model.isMiniPlayerVisible = true
        model.isMiniPlayerVisible = true
        XCTAssertTrue(
            model.isMiniPlayerVisible,
            "driving the bound value to true twice must leave it open, not toggle it back"
        )

        model.isMiniPlayerVisible = false
        XCTAssertFalse(model.isMiniPlayerVisible)
    }
}
