import XCTest

@testable import Lyrebird

/// Coverage for the menu-bar extra's persistent-vs-transient visibility
/// precedence — the rule that decides whether the Now Playing `MenuBarExtra`
/// should be inserted in the menu bar given the persistent "Show in menu bar"
/// (General) toggle and the transient "Show in menu bar while playing"
/// (Notifications) toggle.
///
/// The decision is exercised through the pure `MenuBarVisibility.resolve(
/// playing:persistent:)` helper so the precedence is verified without
/// realizing a live `MenuBarExtra`, which would require a window-server
/// connection that a headless test run doesn't have. Since #984 this helper
/// is the single visibility authority: the old AppKit `NSStatusItem` path
/// (`MenuBarController`) is gone, and `LyrebirdApp` feeds the resolved value
/// to `MenuBarExtra(isInserted:)`.
final class MenuBarVisibilityTests: XCTestCase {

    func testBothOffHidesIcon() {
        XCTAssertFalse(
            MenuBarVisibility.resolve(playing: false, persistent: false),
            "neither toggle on: icon stays hidden"
        )
    }

    func testPersistentToggleAloneShowsIcon() {
        XCTAssertTrue(
            MenuBarVisibility.resolve(playing: false, persistent: true),
            "the persistent General toggle shows the icon regardless of playback"
        )
    }

    func testPlayingAloneShowsIconTransiently() {
        XCTAssertTrue(
            MenuBarVisibility.resolve(playing: true, persistent: false),
            "the while-playing toggle shows the icon during playback"
        )
    }

    func testPersistentWinsWhenPlaybackStops() {
        // Simulate a playing→stopped transition while the persistent toggle is
        // on: the icon must NOT be hidden.
        XCTAssertTrue(
            MenuBarVisibility.resolve(playing: false, persistent: true),
            "stopping playback must never hide an icon the user pinned persistently"
        )
    }

    func testTransientHidesWhenStoppedAndNotPinned() {
        XCTAssertFalse(
            MenuBarVisibility.resolve(playing: false, persistent: false),
            "with only the while-playing toggle, stopping playback removes the icon"
        )
    }

    func testBothOnShowsIcon() {
        XCTAssertTrue(
            MenuBarVisibility.resolve(playing: true, persistent: true),
            "both toggles on: icon visible"
        )
    }

    // MARK: - Preference-key stability

    /// The persistent "Show in menu bar" key is a stable on-disk identifier
    /// shared between PreferencesGeneral (the writer) and LyrebirdApp (whose
    /// `MenuBarExtra(isInserted:)` binding reads it). A drift would silently
    /// disconnect the toggle from the menu-bar extra.
    func testShowInMenuBarKeyIsStable() {
        XCTAssertEqual(PreferencesGeneral.showInMenuBarKey, "general.showInMenuBar")
    }

    /// Same contract for the transient while-playing key, shared between
    /// PreferencesNotifications (the writer) and LyrebirdApp (the reader).
    func testShowInMenuBarWhilePlayingKeyIsStable() {
        XCTAssertEqual(
            NotificationPreference.showInMenuBarWhilePlayingKey,
            "notifications.showInMenuBarWhilePlaying"
        )
    }

    // MARK: - Single menu-bar implementation (#984)

    /// `MenuBarExtra(isInserted:)` resolving against a live menu bar needs a
    /// window server, so the wiring is verified structurally: the app scene
    /// must bind `isInserted:` and resolve it from both preference keys via
    /// `MenuBarVisibility.resolve`. Previously the extra had no `isInserted:`
    /// binding at all, so it rendered regardless of the Settings ▸ General
    /// toggle — and doubled up with the old `NSStatusItem` when the toggle
    /// was on.
    func testAppBindsMenuBarExtraInsertionToResolvedVisibility() throws {
        let code = try lyrebirdAppSource()
        XCTAssertTrue(
            code.contains("MenuBarExtra(isInserted:"),
            "LyrebirdApp must gate the menu-bar extra behind an isInserted: binding"
        )
        XCTAssertTrue(
            code.contains("MenuBarVisibility.resolve("),
            "the isInserted binding must resolve through the unit-tested precedence helper"
        )
        XCTAssertTrue(
            code.contains("PreferencesGeneral.showInMenuBarKey"),
            "the binding must read the same key PreferencesGeneral writes"
        )
        XCTAssertTrue(
            code.contains("NotificationPreference.showInMenuBarWhilePlayingKey"),
            "the binding must read the same key PreferencesNotifications writes"
        )
    }

    /// The AppKit `NSStatusItem` path was retired in #984; a reintroduction
    /// would bring the double-icon bug back. Keep the sources free of it.
    func testStatusItemPathStaysRetired() throws {
        let sources = try allAppSources()
        XCTAssertFalse(
            sources.contains("MenuBarController.shared"),
            "MenuBarController was retired in #984 — menu-bar presence is owned by MenuBarExtra(isInserted:)"
        )
    }

    // MARK: - Helpers

    /// Loads `LyrebirdApp.swift` relative to this test file via `#filePath`,
    /// so the lookup is independent of the test runner's working directory.
    private func lyrebirdAppSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let app = sourcesRoot().appendingPathComponent("LyrebirdApp.swift")
        guard let data = try? Data(contentsOf: app),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read LyrebirdApp.swift at \(app.path)", file: file, line: line)
            return ""
        }
        return text
    }

    /// Concatenates every Swift source under `Sources/Lyrebird` for
    /// whole-target structural assertions.
    private func allAppSources(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let root = sourcesRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else {
            XCTFail("Could not enumerate \(root.path)", file: file, line: line)
            return ""
        }
        var combined = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                combined += text
            }
        }
        return combined
    }

    /// `Sources/Lyrebird` resolved relative to this test file.
    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird")
    }
}
