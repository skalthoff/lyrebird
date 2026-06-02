import XCTest
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

    /// `play(track:)` resolves the PlaybackInfo source off the main actor and
    /// is therefore `async`. Against the un-authed test core the off-main
    /// resolve returns `(nil, nil)` and the subsequent `streamUrl` FFI throws,
    /// so the call completes by throwing rather than deadlocking on the
    /// detached resolve — and the pre-installed empty player is left untouched
    /// because the failure happens before any new player is swapped in.
    func testPlayResolvesOffMainAndThrowsAgainstUnauthedCore() async throws {
        let engine = try makeEngine()
        XCTAssertEqual(engine.queuedItemCountForTesting, 0)

        do {
            try await engine.play(track: makeTrack("a"))
            XCTFail("play(track:) should throw against an un-authed core")
        } catch {
            // Expected: streamUrl/authHeader reject without an active client.
        }

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
