import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the window content-state persistence contract (#10).
///
/// `MainShell` persists the last-viewed tab, the sidebar column visibility,
/// and the queue inspector via `@SceneStorage`, decoding through
/// `WindowStateStore`. Those raw strings are an on-disk contract: renaming one
/// silently resets every user's saved layout, and a broken fallback would
/// strand a window in the wrong state. These tests pin the stable identifiers,
/// the round-trips, and every branch of the restore-precedence logic so those
/// regressions surface here rather than in the field.
final class WindowStateStoreTests: XCTestCase {

    // MARK: - Stable storage keys

    /// The `@SceneStorage` keys are stable identifiers shared between the
    /// writer (`MainShell`) and any future reader. A drift silently
    /// disconnects the setting from the state it restores.
    func testStorageKeysAreStable() {
        XCTAssertEqual(WindowStateKeys.screen, "window.lastScreen")
        XCTAssertEqual(WindowStateKeys.sidebar, "window.sidebarVisibility")
        XCTAssertEqual(WindowStateKeys.inspector, "window.inspectorVisible")
    }

    // MARK: - Screen codec

    /// Every `Screen` round-trips through its persisted raw value, so
    /// `@SceneStorage` can decode whatever it wrote.
    func testScreenRawValueRoundTrips() {
        let all: [AppModel.Screen] = [.home, .discover, .library, .favorites, .search, .settings]
        for screen in all {
            XCTAssertEqual(
                AppModel.Screen(persistedRawValue: screen.persistedRawValue),
                screen,
                "Screen.\(screen) failed to round-trip through its persisted raw value"
            )
        }
    }

    /// The stable on-disk identifiers for `Screen`. Renaming any of these is a
    /// breaking change to persisted state and must come with a migration.
    func testScreenStableRawValues() {
        XCTAssertEqual(AppModel.Screen.home.persistedRawValue, "home")
        XCTAssertEqual(AppModel.Screen.discover.persistedRawValue, "discover")
        XCTAssertEqual(AppModel.Screen.library.persistedRawValue, "library")
        XCTAssertEqual(AppModel.Screen.favorites.persistedRawValue, "favorites")
        XCTAssertEqual(AppModel.Screen.search.persistedRawValue, "search")
        XCTAssertEqual(AppModel.Screen.settings.persistedRawValue, "settings")
    }

    /// An unknown raw value (e.g. one written by a newer build) decodes to nil
    /// so the caller's default applies rather than crashing.
    func testScreenUnknownRawValueDecodesToNil() {
        XCTAssertNil(AppModel.Screen(persistedRawValue: "not-a-real-screen"))
        XCTAssertNil(AppModel.Screen(persistedRawValue: ""))
    }

    // MARK: - Sidebar visibility codec

    /// The three visibilities the shell actually persists round-trip cleanly.
    func testSidebarVisibilityRoundTrips() {
        for visibility: NavigationSplitViewVisibility in [.all, .detailOnly, .automatic] {
            XCTAssertEqual(
                NavigationSplitViewVisibility(persistedRawValue: visibility.persistedRawValue),
                visibility,
                "NavigationSplitViewVisibility.\(visibility) failed to round-trip"
            )
        }
    }

    /// Stable on-disk identifiers for the sidebar column visibility.
    func testSidebarVisibilityStableRawValues() {
        XCTAssertEqual(NavigationSplitViewVisibility.all.persistedRawValue, "all")
        XCTAssertEqual(NavigationSplitViewVisibility.detailOnly.persistedRawValue, "detailOnly")
        XCTAssertEqual(NavigationSplitViewVisibility.automatic.persistedRawValue, "automatic")
    }

    /// States the two-column shell never drives collapse to `automatic` rather
    /// than persisting something it can't honour on restore.
    func testSidebarVisibilityUnsupportedStateCollapsesToAutomatic() {
        XCTAssertEqual(NavigationSplitViewVisibility.doubleColumn.persistedRawValue, "automatic")
    }

    /// An unknown sidebar raw value decodes to nil so the caller's default
    /// (or the Appearance preference) applies.
    func testSidebarVisibilityUnknownRawValueDecodesToNil() {
        XCTAssertNil(NavigationSplitViewVisibility(persistedRawValue: "left-and-right"))
        XCTAssertNil(NavigationSplitViewVisibility(persistedRawValue: ""))
    }

    // MARK: - AppearanceSidebar preference -> default visibility

    /// `.visible` and `.auto_hide` both open expanded; only `.hidden` starts
    /// collapsed. (`.autoHide` reveals on hover but still starts shown.)
    func testDefaultVisibilityForPreference() {
        XCTAssertEqual(WindowStateStore.defaultVisibility(for: .visible), .all)
        XCTAssertEqual(WindowStateStore.defaultVisibility(for: .autoHide), .all)
        XCTAssertEqual(WindowStateStore.defaultVisibility(for: .hidden), .detailOnly)
    }

    // MARK: - initialSidebarVisibility precedence

    /// A persisted per-scene visibility wins over the Appearance preference —
    /// restoring the user's last layout is the point of #10.
    func testInitialSidebarPrefersPersistedState() {
        // Persisted `detailOnly` must win even though the preference says visible.
        XCTAssertEqual(
            WindowStateStore.initialSidebarVisibility(
                persistedRaw: NavigationSplitViewVisibility.detailOnly.persistedRawValue,
                preferenceRaw: AppearanceSidebar.visible.rawValue
            ),
            .detailOnly
        )
        // ...and the inverse: persisted `all` wins over a `hidden` preference.
        XCTAssertEqual(
            WindowStateStore.initialSidebarVisibility(
                persistedRaw: NavigationSplitViewVisibility.all.persistedRawValue,
                preferenceRaw: AppearanceSidebar.hidden.rawValue
            ),
            .all
        )
    }

    /// With no persisted state (first launch in a scene), fall back to the
    /// Appearance `Sidebar` preference — the wiring #10 adds for the
    /// previously UI-only `AppearanceSidebar` enum.
    func testInitialSidebarFallsBackToPreferenceWhenUnpersisted() {
        XCTAssertEqual(
            WindowStateStore.initialSidebarVisibility(
                persistedRaw: "",
                preferenceRaw: AppearanceSidebar.hidden.rawValue
            ),
            .detailOnly
        )
        XCTAssertEqual(
            WindowStateStore.initialSidebarVisibility(
                persistedRaw: "",
                preferenceRaw: AppearanceSidebar.visible.rawValue
            ),
            .all
        )
    }

    /// A garbage preference raw value falls back to `.visible` (expanded),
    /// matching `AppearancePane`'s own default.
    func testInitialSidebarUnknownPreferenceDefaultsToVisible() {
        XCTAssertEqual(
            WindowStateStore.initialSidebarVisibility(
                persistedRaw: "",
                preferenceRaw: "bogus-preference"
            ),
            .all
        )
    }

    // MARK: - restoredScreen

    /// A persisted tab is restored verbatim.
    func testRestoredScreenReturnsPersistedTab() {
        XCTAssertEqual(WindowStateStore.restoredScreen(persistedRaw: "search"), .search)
        XCTAssertEqual(WindowStateStore.restoredScreen(persistedRaw: "home"), .home)
    }

    /// Empty or unknown raw values fall back to `.library`, the app's
    /// cold-start default tab (`AppModel.screen`).
    func testRestoredScreenDefaultsToLibrary() {
        XCTAssertEqual(WindowStateStore.restoredScreen(persistedRaw: ""), .library)
        XCTAssertEqual(WindowStateStore.restoredScreen(persistedRaw: "garbage"), .library)
    }

    // MARK: - restoredInspectorVisible

    /// Only the literal "true" string reopens the inspector; everything else
    /// (including the empty first-launch value and nil) leaves it closed.
    func testRestoredInspectorVisible() {
        XCTAssertTrue(WindowStateStore.restoredInspectorVisible(persistedRaw: "true"))
        XCTAssertFalse(WindowStateStore.restoredInspectorVisible(persistedRaw: "false"))
        XCTAssertFalse(WindowStateStore.restoredInspectorVisible(persistedRaw: ""))
        XCTAssertFalse(WindowStateStore.restoredInspectorVisible(persistedRaw: nil))
    }
}
