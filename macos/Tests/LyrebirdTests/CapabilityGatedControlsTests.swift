import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the capability flags that gate inert preference controls so
/// they aren't presented as working settings while their backing work is
/// unwired (audit fixes for the Appearance Theme picker and the General
/// Language picker).
///
/// `AppModel` is `@MainActor`, so the suite is main-actor isolated. We redirect
/// the core's data dir to a throwaway temp dir via `XDG_DATA_HOME` so the tests
/// never touch the real app database.
@MainActor
final class CapabilityGatedControlsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    /// Theme selection stays gated off until the theme engine (#405) actually
    /// resolves `Theme.primary` / `Theme.accent` from the persisted preset.
    /// Until then the Appearance Theme picker renders as a disabled "coming
    /// soon" preview rather than a working selector.
    func testThemeSelectionGatedOff() throws {
        let model = try AppModel()
        XCTAssertFalse(
            model.supportsThemeSelection,
            "Theme selection must stay gated until the theme engine consumes appearance.theme"
        )
    }

    /// Language selection stays gated off until in-app localization (#345) is
    /// wired — nothing reads `general.language` back to re-render the UI, so the
    /// General Language picker is hidden rather than shown as an inert control.
    func testLanguageSelectionGatedOff() throws {
        let model = try AppModel()
        XCTAssertFalse(
            model.supportsLanguageSelection,
            "Language selection must stay gated until a runtime locale override is wired"
        )
    }

    // MARK: - Appearance theme offerings

    /// The Theme picker only offers presets the engine can actually render —
    /// Purple plus the two colour-blind-verified alternatives. Sunset / Peanut
    /// were dropped because they had no backing `ThemePreset` (they silently
    /// folded into Purple), so offering them would promise a palette the engine
    /// can't produce.
    func testAppearanceThemeOffersOnlyRenderablePresets() {
        XCTAssertEqual(AppearanceTheme.allCases, [.purple, .ocean, .forest])
    }

    /// The persisted raw values are an on-disk contract; renaming one silently
    /// resets a user's saved theme. Pin the three that remain.
    func testAppearanceThemeStableRawValues() {
        XCTAssertEqual(AppearanceTheme.purple.rawValue, "purple")
        XCTAssertEqual(AppearanceTheme.ocean.rawValue, "ocean")
        XCTAssertEqual(AppearanceTheme.forest.rawValue, "forest")
    }

    /// A legacy persisted value for a dropped case decodes to `nil` so the
    /// `@AppStorage` getter's `?? .purple` fallback keeps the user on a valid,
    /// renderable theme rather than crashing or stranding an unknown value.
    func testDroppedThemeRawValuesNoLongerDecode() {
        XCTAssertNil(AppearanceTheme(rawValue: "sunset"))
        XCTAssertNil(AppearanceTheme(rawValue: "peanut"))
    }
}
