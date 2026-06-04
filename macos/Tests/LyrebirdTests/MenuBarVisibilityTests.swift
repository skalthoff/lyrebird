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

    // MARK: - Persistent-toggle startup restore

    /// The persistent "Show in menu bar" key is a stable on-disk identifier
    /// shared between PreferencesGeneral (the writer) and AppDelegate (which
    /// re-applies it at launch). A drift would silently disconnect the toggle
    /// from the value restored at startup.
    func testShowInMenuBarKeyIsStable() {
        XCTAssertEqual(PreferencesGeneral.showInMenuBarKey, "general.showInMenuBar")
    }

    /// `setVisible(_:)` resolving the actual icon needs a window server, so the
    /// restore behaviour is verified structurally: `AppDelegate`'s launch path
    /// must read the persisted key and call `setVisible(_:)`, so a user who
    /// enabled the icon last session sees it again before opening Settings.
    /// Previously the toggle's only call sites were inside PreferencesGeneral,
    /// so the icon never came back at launch.
    func testAppDelegateRestoresPersistentVisibilityAtLaunch() throws {
        let code = try appDelegateSource()
        XCTAssertTrue(
            code.contains("func applicationDidFinishLaunching"),
            "AppDelegate must own the launch hook"
        )
        XCTAssertTrue(
            code.contains("MenuBarController.shared.setVisible("),
            "AppDelegate must (re-)apply the persistent menu-bar toggle at launch"
        )
        XCTAssertTrue(
            code.contains("PreferencesGeneral.showInMenuBarKey"),
            "The launch restore must read the same key PreferencesGeneral writes"
        )
    }

    /// Loads `AppDelegate.swift` relative to this test file via `#filePath`, so
    /// the lookup is independent of the test runner's working directory.
    private func appDelegateSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let appDelegate = here
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird/AppDelegate.swift")
        guard let data = try? Data(contentsOf: appDelegate),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read AppDelegate.swift at \(appDelegate.path)", file: file, line: line)
            return ""
        }
        return text
    }
}
