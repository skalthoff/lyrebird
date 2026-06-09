import XCTest

@testable import Lyrebird

/// Coverage for the Mini Player view-model surface: the
/// visibility toggle, the persisted always-on-top preference, and the
/// "return to full window" / close-sync contract that keeps the ⌘⌥P menu
/// `Toggle` checkmark from drifting out of sync with the real window.
///
/// `AppModel` is `@MainActor`, so the whole suite is main-actor isolated.
/// Constructing it boots a live `LyrebirdCore`; we redirect the core's data
/// directory to a throwaway temp dir via `XDG_DATA_HOME` (honoured by
/// `storage::default_data_dir()`) so the test never touches the real app's
/// database, and we run the persistence assertions against an isolated
/// `UserDefaults` suite so they don't pollute the standard domain.
@MainActor
final class MiniPlayerStateTests: XCTestCase {

    /// Point the core at a unique temp data dir before the first `AppModel()`
    /// in the process. Set once for the whole suite — the core reads the env
    /// var when it builds its default data dir, and we never want the real
    /// `~/Library/Application Support/lyrebird-desktop` DB created by tests.
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - toggleMiniPlayer

    func testToggleMiniPlayerFlipsVisibilityBothWays() throws {
        let model = try AppModel()
        XCTAssertFalse(model.isMiniPlayerVisible, "fresh model starts hidden")

        model.toggleMiniPlayer()
        XCTAssertTrue(model.isMiniPlayerVisible, "first toggle opens")

        model.toggleMiniPlayer()
        XCTAssertFalse(model.isMiniPlayerVisible, "second toggle closes")
    }

    // MARK: - returnToFullWindow

    func testReturnToFullWindowClearsVisibility() throws {
        let model = try AppModel()
        model.isMiniPlayerVisible = true

        model.returnToFullWindow()

        XCTAssertFalse(
            model.isMiniPlayerVisible,
            "returning to the full window must close the mini player"
        )
    }

    /// Regression for the ⌘W / Window > Close drift bug:
    /// AppKit's automatic Close-Window handler orders the chromeless window out
    /// without touching `isMiniPlayerVisible`. `RootView`'s
    /// `willCloseNotification` observer is wired to clear the flag in exactly
    /// that case, and it does so by treating the close as a return-to-full.
    /// This asserts the post-close state machine: after a close-driven clear,
    /// the flag is false and a fresh ⌘⌥P reopens on the *first* press rather
    /// than being stuck needing two presses.
    func testCloseDrivenClearThenToggleReopensOnFirstPress() throws {
        let model = try AppModel()

        // Open via the menu Toggle path.
        model.toggleMiniPlayer()
        XCTAssertTrue(model.isMiniPlayerVisible)

        // Simulate the ⌘W close handler: the observer clears the flag because
        // the model still thinks the player is visible.
        XCTAssertTrue(model.isMiniPlayerVisible, "precondition: observer only fires while visible")
        model.isMiniPlayerVisible = false

        // The next ⌘⌥P must reopen immediately — the original bug left the flag
        // stuck `true`, so the first toggle closed an already-closed window.
        model.toggleMiniPlayer()
        XCTAssertTrue(
            model.isMiniPlayerVisible,
            "after a close, the next ⌘⌥P should reopen on the first press"
        )
    }

    // MARK: - setMiniPlayerAlwaysOnTop (persistence)

    func testSetAlwaysOnTopUpdatesPropertyAndPersists() throws {
        let model = try AppModel()
        let key = "miniPlayer.alwaysOnTop"

        // Clean both possible domains so a stale value can't mask the write.
        UserDefaults.standard.removeObject(forKey: key)

        model.setMiniPlayerAlwaysOnTop(true)
        XCTAssertTrue(model.miniPlayerAlwaysOnTop, "live property reflects the set value")
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: key),
            "always-on-top must persist so the next launch restores it"
        )

        model.setMiniPlayerAlwaysOnTop(false)
        XCTAssertFalse(model.miniPlayerAlwaysOnTop)
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: key),
            "clearing the preference must persist too"
        )

        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - setMiniPlayerTransparentWhenInactive (persistence)

    func testSetTransparentWhenInactiveUpdatesPropertyAndPersists() throws {
        let model = try AppModel()
        let key = "miniPlayer.transparentWhenInactive"

        UserDefaults.standard.removeObject(forKey: key)

        model.setMiniPlayerTransparentWhenInactive(true)
        XCTAssertTrue(
            model.miniPlayerTransparentWhenInactive,
            "live property reflects the set value"
        )
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: key),
            "transparent-when-inactive must persist across launches"
        )

        model.setMiniPlayerTransparentWhenInactive(false)
        XCTAssertFalse(model.miniPlayerTransparentWhenInactive)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))

        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - closeMiniPlayer

    func testCloseMiniPlayerClearsVisibilityWithoutActivatingMainWindow() throws {
        let model = try AppModel()
        model.isMiniPlayerVisible = true

        model.closeMiniPlayer()

        XCTAssertFalse(
            model.isMiniPlayerVisible,
            "closeMiniPlayer must clear the visibility flag"
        )
    }
}
