import XCTest
@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

@MainActor
final class AudioEnginePreloadTests: XCTestCase {
    private func makeEngine() throws -> AudioEngine {
        // Build a real (un-authed) core against a throwaway data dir, same
        // pattern as MiniPlayerStateTests. The off-main resolve fails fast
        // without touching the network.
        let dir = NSTemporaryDirectory() + "lyrebird-preload-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "preload-test"))
        let engine = AudioEngine(core: core)
        engine.installEmptyPlayerForTesting()
        return engine
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

    /// The PlaybackInfo / streamUrl / authHeader resolution must run off the
    /// main actor: `preloadNextTrack` dispatches the FFI into a detached task
    /// and returns immediately, so no item can be spliced into the queue
    /// synchronously on the caller's thread. If the resolution ran inline this
    /// would block until the (un-authed) resolve threw — and on success it
    /// would have mutated the queue before returning.
    func testPreloadDoesNotMutateQueueSynchronously() throws {
        let engine = try makeEngine()
        XCTAssertEqual(engine.queuedItemCountForTesting, 0)

        engine.preloadNextTrack(makeTrack("a"))

        // Control returned to the main actor with the queue still untouched —
        // the resolve is happening off-main.
        XCTAssertEqual(engine.queuedItemCountForTesting, 0)
    }

    /// Rapid back-to-back preloads (e.g. skip-next, or `onTrackEnded` firing
    /// again) must not deadlock or crash, and must not synchronously enqueue.
    /// The generation guard ensures only the latest in-flight resolve can ever
    /// win the marshal-back, so a stale resolution can't clobber the queue.
    func testConcurrentPreloadsDoNotEnqueueSynchronously() throws {
        let engine = try makeEngine()

        engine.preloadNextTrack(makeTrack("a"))
        engine.preloadNextTrack(makeTrack("b"))

        XCTAssertEqual(engine.queuedItemCountForTesting, 0)
    }

    /// Stall recovery rebuilds the current item via `replaceCurrentItem`,
    /// which drops any pre-loaded next-track item. The owner needs a
    /// post-recovery signal to re-arm gapless playback, so `recoverFromStall`
    /// must fire `audioEngineDidRecover()` after restarting playback.
    func testStallRecoveryFiresDidRecoverDelegate() throws {
        let engine = try makeEngine()
        let spy = RecoverySpy()
        engine.delegate = spy

        engine.recoverFromStallForTesting(url: URL(string: "https://example.invalid/stream")!)

        XCTAssertEqual(spy.didRecoverCount, 1)
    }
}

@MainActor
private final class RecoverySpy: AudioEngineDelegate {
    var didRecoverCount = 0
    func audioEngineDidStall() {}
    func audioEngineDidFail(_ message: String) {}
    func audioEngineDidRecover() { didRecoverCount += 1 }
}

/// #931 — gapless must engage on a *normal* queue advance, not just stall
/// recovery. `AppModel.handleTrackEnded` steps the core queue forward
/// (`core.skipNext()`) and rebuilds the player via `play(track:)` (a fresh
/// single-item `AVQueuePlayer`), which drops any pre-inserted next item. The
/// advance must therefore re-arm the engine's pre-load for the track *after*
/// the new current one, read from the core queue lookahead (`core.peekNext()`)
/// so it always matches what `skipNext()` plays next.
///
/// These drive the **production queue-population path** the app actually uses:
/// `model.play(tracks:)` calls `core.setQueue(...)` synchronously (an in-memory
/// queue mutation that succeeds un-authed; only the async `play(track:)` it
/// kicks off needs the network, and that's irrelevant to the queue state), so
/// the core queue is populated exactly as it is in the running app. The advance
/// itself runs through `advanceAndArmPreloadForTesting()`, which performs the
/// same `core.skipNext()` + `armNextTrackPreload()` calls `handleTrackEnded`
/// makes — skipping only the async player rebuild the empty test player stands
/// in for. Nothing here hand-sets `upNextAutoQueue` / `upNextUserAdded`; a
/// regression that left the preload unwired would surface as a nil armed id.
///
/// The engine records the armed track id (`lastPreloadedTrackIdForTesting`)
/// before its off-main stream resolve, so we assert the *intent* without a
/// network round-trip.
///
/// `AppModel` is `@MainActor`; constructing it boots a live `LyrebirdCore`. We
/// redirect the core's data dir to a throwaway temp dir via `XDG_DATA_HOME`
/// (honoured by `storage::default_data_dir()`) so tests never touch the real
/// app database — same pattern as `AutoplayWhenQueueEndsTests`.
@MainActor
final class AppModelAdvancePreloadTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-advance-preload-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
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

    /// A normal advance through a queue built by `play(tracks:)` arms the
    /// engine pre-load for the track *after* the one the advance landed on.
    /// This is the end-to-end #931 guarantee: start at the head of a three-track
    /// queue, advance once (now playing track 1), and the engine must have
    /// pre-loaded track 2 for the next gapless transition. Before the wiring the
    /// freshly built player carried no queued-ahead item and the armed id stayed
    /// nil.
    func testNormalAdvanceArmsPreloadForFollowingTrack() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        // Production path: populate the core queue exactly as the app does.
        model.play(tracks: [makeTrack("t0"), makeTrack("t1"), makeTrack("t2")], startIndex: 0)

        // End-of-track advance: now playing t1, pre-load should be t2.
        let landed = model.advanceAndArmPreloadForTesting()

        XCTAssertEqual(landed?.id, "t1", "advance must move the playhead to the next track")
        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "t2",
            "a normal advance must pre-load the track after the new current one"
        )
    }

    /// "Play Next" inserts the user's track at `queue_index + 1` in the core
    /// queue, so after an advance it is exactly what the lookahead pre-loads —
    /// the same precedence the old in-app "Up Next" overlay was meant to model,
    /// now sourced straight from the core. Build the base queue via the
    /// production path, insert a track via `core.playNext`, then advance.
    func testAdvanceAfterPlayNextArmsTheInsertedTrack() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)
        // User "Play Next" — lands right after the current track (t0).
        _ = model.core.playNext(tracks: [makeTrack("inserted")])

        // Advance off t0: lands on the inserted track, and the *next* one
        // (the original t1) is what gets pre-loaded.
        let landed = model.advanceAndArmPreloadForTesting()

        XCTAssertEqual(landed?.id, "inserted", "advance must land on the Play-Next track first")
        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "t1",
            "the queue lookahead after the inserted track must be pre-loaded"
        )
    }

    /// Advancing onto the last track of the queue leaves nothing further to
    /// pre-load (repeat off), so the engine's armed id must stay nil rather than
    /// re-arming a stale item.
    func testAdvanceOntoLastTrackArmsNothing() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)

        // Advance onto t1 (the last track) — peekNext is nil, nothing to arm.
        let landed = model.advanceAndArmPreloadForTesting()

        XCTAssertEqual(landed?.id, "t1")
        XCTAssertNil(
            model.audio.lastPreloadedTrackIdForTesting,
            "no track after the last one means nothing to pre-load"
        )
    }

    /// With repeat-all engaged, advancing onto the last track must pre-load the
    /// wrap-around (first) track — the lookahead honours repeat mode so the
    /// pre-loaded item still matches what `skipNext()` would play next.
    func testAdvanceOntoLastTrackWithRepeatAllArmsWrapAround() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)
        model.core.setRepeatMode(mode: .all)

        let landed = model.advanceAndArmPreloadForTesting()

        XCTAssertEqual(landed?.id, "t1")
        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "t0",
            "repeat-all must pre-load the wrap-around track at the end of the queue"
        )
    }

    /// Stall recovery re-arms the pre-load *without* advancing the playhead —
    /// it re-loads the track after the current one. Mirrors
    /// `audioEngineDidRecover`. Build the queue via the production path, then
    /// arm without an advance: the head's successor is what gets pre-loaded.
    func testStallRecoveryArmsFollowingTrackWithoutAdvancing() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()

        model.play(tracks: [makeTrack("t0"), makeTrack("t1")], startIndex: 0)

        // No advance — recovery re-arms for the track after the current (t0).
        model.armNextTrackPreloadForTesting()

        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "t1",
            "stall recovery must re-arm the pre-load for the track after current"
        )
    }
}
