import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the dedicated Radio / Mixes sidebar destination (#93).
///
/// The feature adds a `.radio` root tab reachable from the sidebar. Two
/// contracts must hold for the destination to behave like every other root
/// tab:
///
/// 1. `selectTab(.radio)` sets `screen` to `.radio` and clears any active drill
///    stack — the same invariant `selectTab` enforces for Home / Discover /
///    Library so drill state never leaks across a tab change.
/// 2. The `.radio` screen survives a `@SceneStorage` round-trip through
///    `WindowStateStore`'s stable String codec, so a user who quits on the
///    Radio tab is restored to it. The raw string is an on-disk contract;
///    renaming it silently resets saved window state, so it is pinned here
///    alongside the other tabs in `WindowStateStoreTests`.
///
/// Same isolation contract as `DiscoverSongRadioRouteTests`: `AppModel` is
/// `@MainActor` and boots a live core pointed at a throwaway data dir.
@MainActor
final class RadioSectionRoutingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-radio-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - selectTab routing

    /// Selecting the Radio tab from any other tab flips `screen` to `.radio`.
    func testSelectTabRoutesToRadio() throws {
        let model = try AppModel()
        // Start somewhere else so the assertion proves a real transition.
        model.selectTab(.library)
        XCTAssertEqual(model.screen, .library)

        model.selectTab(.radio)
        XCTAssertEqual(model.screen, .radio, "selecting the Radio tab must set screen to .radio")
    }

    /// Switching to the Radio tab clears the current drill stack, so a user who
    /// drilled into an album and then taps Radio lands on the Radio root rather
    /// than a stale detail page. This is the shared `selectTab` invariant.
    func testSelectingRadioClearsDrillStack() throws {
        let model = try AppModel()
        model.selectTab(.library)
        model.navPath = [.album("album-1"), .artist("artist-1")]
        XCTAssertFalse(model.navPath.isEmpty)

        model.selectTab(.radio)
        XCTAssertEqual(model.screen, .radio)
        XCTAssertTrue(model.navPath.isEmpty, "switching to Radio must clear the drill stack")
    }

    /// Leaving the Radio tab for another root behaves symmetrically — no Radio
    /// state lingers on `screen`.
    func testLeavingRadioSwitchesScreen() throws {
        let model = try AppModel()
        model.selectTab(.radio)
        XCTAssertEqual(model.screen, .radio)

        model.selectTab(.discover)
        XCTAssertEqual(model.screen, .discover, "leaving Radio must switch screen to the new tab")
    }

    // MARK: - Persisted-state codec

    /// `.radio` round-trips through its persisted raw value so `@SceneStorage`
    /// can decode whatever it wrote when the user quits on the Radio tab.
    func testRadioScreenRawValueRoundTrips() {
        XCTAssertEqual(
            AppModel.Screen(persistedRawValue: AppModel.Screen.radio.persistedRawValue),
            .radio
        )
    }

    /// The stable on-disk identifier for the Radio tab. Renaming this is a
    /// breaking change to persisted window state and must come with a migration.
    func testRadioScreenStableRawValue() {
        XCTAssertEqual(AppModel.Screen.radio.persistedRawValue, "radio")
    }

    /// A window persisted on the Radio tab is restored to it verbatim, rather
    /// than collapsing to the `.library` cold-start default.
    func testRestoredScreenReturnsRadio() {
        XCTAssertEqual(WindowStateStore.restoredScreen(persistedRaw: "radio"), .radio)
    }
}
