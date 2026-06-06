import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the capability flags that gate inert preference controls so
/// they aren't presented as working settings while their backing work is
/// unwired (e.g. the General Language picker). The Appearance Theme picker was
/// such a control until #405 wired the engine — `testThemeSelectionWired` now
/// pins that it consumes `appearance.theme`.
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

    /// Theme selection is wired (#405): `Theme.currentPreset` resolves the
    /// persisted `appearance.theme` preset so `Theme.primary` / `Theme.accent`
    /// recolour with the user's choice, and the Appearance Theme picker is a
    /// live selector (the flag stays only as a kill-switch).
    func testThemeSelectionWired() throws {
        let model = try AppModel()
        XCTAssertTrue(
            model.supportsThemeSelection,
            "Theme selection should be enabled now that Theme.currentPreset consumes appearance.theme"
        )

        // The engine actually reads the persisted preset, not a fixed constant.
        let defaults = UserDefaults.standard
        let key = AppearanceKeys.theme
        let original = defaults.string(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set(AppearanceTheme.ocean.rawValue, forKey: key)
        XCTAssertEqual(Theme.currentPreset, .ocean, "Theme must resolve the persisted preset")
        defaults.set(AppearanceTheme.forest.rawValue, forKey: key)
        XCTAssertEqual(Theme.currentPreset, .forest)
        defaults.set(AppearanceTheme.purple.rawValue, forKey: key)
        XCTAssertEqual(Theme.currentPreset, .purple)
        // An unknown / legacy on-disk value falls back to the shipping default.
        defaults.set("sunset", forKey: key)
        XCTAssertEqual(Theme.currentPreset, .purple, "legacy/unknown theme falls back to purple")
    }

    /// Streaming bitrate selection is wired (#260): the Streaming Quality picker
    /// is live and `resolvedStreamingBitrate` maps the persisted tier to the
    /// stream-URL `MaxStreamingBitrate` cap. Codec / transcoding / download
    /// quality stay gated behind `supportsStreamQualitySelection`.
    func testStreamingBitrateWired() throws {
        let model = try AppModel()
        XCTAssertTrue(model.supportsStreamingBitrate, "Streaming Quality picker should be live")
        XCTAssertFalse(model.supportsStreamQualitySelection, "codec/transcoding/download-quality stay gated")

        let key = "playback.streamingQuality"
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set(PlaybackQuality.low.rawValue, forKey: key)
        XCTAssertEqual(model.resolvedStreamingBitrate, 96_000, "Low tier caps at 96 kbps")
        defaults.set(PlaybackQuality.original.rawValue, forKey: key)
        XCTAssertNil(model.resolvedStreamingBitrate, "Original resolves to an uncapped stream")
        defaults.removeObject(forKey: key)
        XCTAssertEqual(model.resolvedStreamingBitrate, 320_000, "default (automatic) keeps the historical cap")
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
