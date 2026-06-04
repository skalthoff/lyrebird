import XCTest

@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Coverage for the #116 playback-behaviour preferences that are now wired
/// into the engine / queue rather than persisting a value nothing reads:
///
/// - **Gapless playback** (`playback.gaplessEnabled`) gates
///   `AppModel.armNextTrackPreload`. Default-on (an unset key must read
///   `true`, not `bool(forKey:)`'s `false`); when off the engine is never
///   handed a queued-ahead item.
/// - **Stop after current track** (`playback.stopAfterCurrent`) is a one-shot:
///   `consumeStopAfterCurrent()` returns `true` exactly once then disarms, and
///   starting a fresh queue via `play(tracks:)` resets a leftover arming —
///   matching the toggle's "Resets to off the next time you start playback".
///
/// `AppModel` is `@MainActor`, so the suite is main-actor isolated.
/// Constructing it boots a live `LyrebirdCore`; the data dir is redirected to a
/// throwaway temp dir via `XDG_DATA_HOME` so tests never touch the real app
/// database — same pattern as `AutoplayWhenQueueEndsTests` /
/// `AppModelAdvancePreloadTests`. Both keys live in the standard `UserDefaults`
/// domain shared with `AppModelAdvancePreloadTests` (which relies on gapless
/// defaulting on), so each test scrubs them before and after to stay hermetic.
@MainActor
final class PlaybackBehaviorPreferencesTests: XCTestCase {

    /// Persisted keys, kept in sync with `PreferencesPlayback`'s `@AppStorage`
    /// and `AppModel`'s private key constants. If those strings drift, the
    /// gating here goes stale, so this suite pins the contract.
    private let gaplessKey = "playback.gaplessEnabled"
    private let stopAfterKey = "playback.stopAfterCurrent"

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-playback-prefs-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    override func setUp() {
        super.setUp()
        // A stale value would mask the default-on / default-off probes and
        // could leak into sibling suites that share `UserDefaults.standard`.
        UserDefaults.standard.removeObject(forKey: gaplessKey)
        UserDefaults.standard.removeObject(forKey: stopAfterKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: gaplessKey)
        UserDefaults.standard.removeObject(forKey: stopAfterKey)
        super.tearDown()
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 0,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - Gapless default-on contract

    /// With the key never written, `gaplessEnabled` must read `true`. A naive
    /// `bool(forKey:)` would return `false` and silently disable gapless for
    /// everyone who never opened the pane.
    func testGaplessDefaultsToOnWhenKeyUnset() throws {
        XCTAssertNil(
            UserDefaults.standard.object(forKey: gaplessKey),
            "precondition: key must be unset for the default probe"
        )
        XCTAssertTrue(AppModel.gaplessEnabled, "an unset gapless preference must default to on")
    }

    func testGaplessHonoursPersistedOff() throws {
        UserDefaults.standard.set(false, forKey: gaplessKey)
        XCTAssertFalse(AppModel.gaplessEnabled, "a persisted opt-out must be restored, not reset to the default")
    }

    // MARK: - Gapless gates the engine pre-load

    /// Default-on: arming runs through to the engine and pre-loads the track
    /// after the current one — the #931 behaviour, unchanged when gapless is
    /// left at its default.
    func testArmPreloadRunsWhenGaplessDefaultOn() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)
        model.armNextTrackPreloadForTesting()

        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "t1",
            "with gapless on (default), arming must pre-load the next track"
        )
    }

    /// Gapless off: arming must be a no-op — the engine is never handed a
    /// queued-ahead item, so each track ends cleanly before the next is built.
    /// This is the bug the audit flagged: the toggle previously did nothing
    /// because preload ran unconditionally.
    func testArmPreloadIsSuppressedWhenGaplessOff() throws {
        UserDefaults.standard.set(false, forKey: gaplessKey)

        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)
        model.armNextTrackPreloadForTesting()

        XCTAssertNil(
            model.audio.lastPreloadedTrackIdForTesting,
            "with gapless off, arming must not hand the engine a pre-loaded item"
        )
    }

    /// The normal end-of-track advance seam must also honour the gapless flag:
    /// with gapless off the playhead still advances (the queue keeps playing)
    /// but no item is pre-loaded for the following transition.
    func testAdvanceDoesNotPreloadWhenGaplessOff() throws {
        UserDefaults.standard.set(false, forKey: gaplessKey)

        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1"), makeTrack("t2")], startIndex: 0)
        let landed = model.advanceAndArmPreloadForTesting()

        XCTAssertEqual(landed?.id, "t1", "advance must still move the playhead even with gapless off")
        XCTAssertNil(
            model.audio.lastPreloadedTrackIdForTesting,
            "gapless off must suppress the pre-load on a normal advance too"
        )
    }

    // MARK: - Stop after current track (one-shot)

    /// Default-off: an unset key reads `false`, so `consumeStopAfterCurrent`
    /// returns `false` and the queue advances normally.
    func testStopAfterCurrentDefaultsOff() throws {
        XCTAssertNil(
            UserDefaults.standard.object(forKey: stopAfterKey),
            "precondition: key must be unset"
        )
        XCTAssertFalse(
            AppModel.consumeStopAfterCurrent(),
            "an unset stop-after-current key must not halt playback"
        )
    }

    /// Armed: the first consume returns `true` (caller stops), and the key is
    /// cleared so the *next* end-of-track transition advances normally — the
    /// one-shot contract the audit required.
    func testStopAfterCurrentIsConsumedExactlyOnce() throws {
        UserDefaults.standard.set(true, forKey: stopAfterKey)

        XCTAssertTrue(AppModel.consumeStopAfterCurrent(), "first end-of-track must honour the armed stop")
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: stopAfterKey),
            "honouring the stop must disarm the toggle"
        )
        XCTAssertFalse(
            AppModel.consumeStopAfterCurrent(),
            "a consumed one-shot must not fire again on the following track"
        )
    }

    /// Starting a fresh queue disarms a leftover stop-after-current — "Resets
    /// to off the next time you start playback." Without this an arming left
    /// over from a previous session would stop the user one track into a brand
    /// new queue.
    func testPlayResetsStopAfterCurrent() throws {
        UserDefaults.standard.set(true, forKey: stopAfterKey)

        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()
        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: stopAfterKey),
            "starting playback must reset a leftover stop-after-current arming"
        )
    }
}
