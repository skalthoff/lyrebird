import XCTest
@testable import Lyrebird
import LyrebirdCore

/// Tests for the graceful-shutdown / queue-restore path:
///
///   * `shouldPersistSnapshot` — the pure guard function.
///   * `shutdownSteps`         — canonical ordering (stop before persist).
///   * `persistQueueSnapshot` + `loadQueueSnapshot` — round-trip through
///     `UserDefaults` JSON.
///   * `applyQueueSnapshot`    — hydrates the in-app overlays.
///   * `resumeFromSnapshot`    — clears `pendingResumeSnapshot`.
///   * `PersistedTrack`        — Codable round-trip and `toTrack()` losslessness.
///
/// All tests redirect the core's data directory to a throwaway temp dir (via
/// `XDG_DATA_HOME`) so they never touch the real on-disk database, and scrub
/// the `UserDefaults` keys before / after each test so state does not leak.
@MainActor
final class GracefulShutdownTests: XCTestCase {

    // MARK: - Fixtures

    private let snapshotKey   = AppModel.queueSnapshotKey
    private let snapshotReady = AppModel.queueSnapshotReadyKey

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-shutdown-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: snapshotReady)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: snapshotReady)
        super.tearDown()
    }

    private func makeTrack(
        id: String = "t1",
        name: String = "Test Track",
        artistName: String = "Test Artist"
    ) -> Track {
        Track(
            id: id,
            name: name,
            albumId: "a1",
            albumName: "Test Album",
            artistName: artistName,
            artistId: "ar1",
            indexNumber: 1,
            discNumber: 1,
            year: 2024,
            runtimeTicks: 2_000_000_000,
            isFavorite: false,
            playCount: 3,
            container: "flac",
            bitrate: 1_411_200,
            imageTag: "abc123",
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - shouldPersistSnapshot

    func testShouldNotPersistWhenIdle() {
        XCTAssertFalse(
            AppModel.shouldPersistSnapshot(
                currentTrack: nil,
                userAddedCount: 0,
                autoQueueCount: 0
            ),
            "idle (no track, empty queue) must return false"
        )
    }

    func testShouldPersistWhenCurrentTrackPresent() {
        XCTAssertTrue(
            AppModel.shouldPersistSnapshot(
                currentTrack: makeTrack(),
                userAddedCount: 0,
                autoQueueCount: 0
            ),
            "a current track alone is enough to trigger a snapshot"
        )
    }

    func testShouldPersistWhenUserQueueNonEmpty() {
        XCTAssertTrue(
            AppModel.shouldPersistSnapshot(
                currentTrack: nil,
                userAddedCount: 2,
                autoQueueCount: 0
            ),
            "a non-empty user-added queue must trigger a snapshot"
        )
    }

    func testShouldPersistWhenAutoQueueNonEmpty() {
        XCTAssertTrue(
            AppModel.shouldPersistSnapshot(
                currentTrack: nil,
                userAddedCount: 0,
                autoQueueCount: 1
            ),
            "a non-empty auto-queue must trigger a snapshot"
        )
    }

    // MARK: - shutdownSteps ordering

    func testShutdownStepsIdleReturnsEmpty() {
        let steps = AppModel.shutdownSteps(isPlayingOrPaused: false, hasQueue: false)
        XCTAssertTrue(steps.isEmpty, "idle state should produce no shutdown steps")
    }

    func testShutdownStepsPlayingPersistsQueue() {
        let steps = AppModel.shutdownSteps(isPlayingOrPaused: true, hasQueue: true)
        XCTAssertEqual(steps, [.stopPlayback, .persistQueue],
                       "playing with a queue: stop first, persist second")
    }

    func testShutdownStepsPlayingNoQueueOnlyStops() {
        let steps = AppModel.shutdownSteps(isPlayingOrPaused: true, hasQueue: false)
        XCTAssertEqual(steps, [.stopPlayback],
                       "playing with an empty queue should only stop, not persist")
    }

    func testShutdownStepsPausedQueuePersistsQueue() {
        let steps = AppModel.shutdownSteps(isPlayingOrPaused: true, hasQueue: true)
        XCTAssertTrue(steps.first == .stopPlayback, "stop must precede persist")
        XCTAssertTrue(steps.last == .persistQueue, "persist must follow stop")
    }

    func testShutdownStepsIdleWithQueueSkipsStop() {
        // Not-playing but queue present (e.g. loaded but never played).
        let steps = AppModel.shutdownSteps(isPlayingOrPaused: false, hasQueue: true)
        XCTAssertEqual(steps, [.persistQueue],
                       "idle-but-queued should persist without stopping (nothing is playing)")
    }

    // MARK: - PersistedTrack round-trip

    func testPersistedTrackCodableRoundTrip() throws {
        let original = makeTrack(id: "xyz", name: "Round Trip", artistName: "Artist A")
        let persisted = PersistedTrack(from: original)

        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedTrack.self, from: data)

        XCTAssertEqual(decoded.id, "xyz")
        XCTAssertEqual(decoded.name, "Round Trip")
        XCTAssertEqual(decoded.artistName, "Artist A")
        XCTAssertEqual(decoded.imageTag, original.imageTag)
        XCTAssertEqual(decoded.container, original.container)
        XCTAssertEqual(decoded, persisted,
                       "encode → decode should be identity for PersistedTrack")
    }

    func testPersistedTrackToTrackPreservesId() {
        let original = makeTrack(id: "abc-123", name: "Restore Me")
        let restored = PersistedTrack(from: original).toTrack()

        XCTAssertEqual(restored.id, original.id,
                       "toTrack() must preserve the Jellyfin item id")
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.artistName, original.artistName)
    }

    func testPersistedTrackToTrackZerosNonEssentialFields() {
        let original = makeTrack()
        let restored = PersistedTrack(from: original).toTrack()

        // Play-count and favorite are not persisted — they are refreshed from
        // the server after the library reloads.
        XCTAssertEqual(restored.isFavorite, false)
        XCTAssertEqual(restored.playCount, 0)
    }

    // MARK: - QueueSnapshot Codable round-trip

    func testQueueSnapshotCodableRoundTrip() throws {
        let snapshot = QueueSnapshot(
            currentTrack: PersistedTrack(from: makeTrack(id: "c1", name: "Current")),
            positionSeconds: 47.5,
            userAdded: [PersistedTrack(from: makeTrack(id: "u1", name: "User Next"))],
            autoQueue: [PersistedTrack(from: makeTrack(id: "a1", name: "Auto 1")),
                        PersistedTrack(from: makeTrack(id: "a2", name: "Auto 2"))],
            contextName: "My Album",
            contextId: "album-id-42",
            contextSourceType: "album"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.positionSeconds, 47.5, accuracy: 0.001)
        XCTAssertEqual(decoded.userAdded.count, 1)
        XCTAssertEqual(decoded.autoQueue.count, 2)
        XCTAssertEqual(decoded.contextSourceType, "album")
    }

    // MARK: - persistQueueSnapshot + loadQueueSnapshot

    func testPersistAndLoadRoundTrip() throws {
        let model = try AppModel()

        // Inject queue state through the public stored properties.
        model.upNextUserAdded = [Queue(track: makeTrack(id: "u1", name: "User Added"))]
        model.upNextAutoQueue = [Queue(track: makeTrack(id: "a1", name: "Auto Q"))]

        model.persistQueueSnapshot()

        let loaded = AppModel.loadQueueSnapshot()
        XCTAssertNotNil(loaded, "a snapshot must be loadable after persistQueueSnapshot()")
        XCTAssertEqual(loaded?.userAdded.first?.id, "u1")
        XCTAssertEqual(loaded?.autoQueue.first?.id, "a1")
    }

    func testPersistIdleDoesNotWriteSnapshot() throws {
        let model = try AppModel()
        // No track, no queue — shouldPersistSnapshot is false.
        model.persistQueueSnapshot()

        XCTAssertNil(
            AppModel.loadQueueSnapshot(),
            "an idle snapshot should not be written"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: snapshotReady),
            "the ready flag must not be set when nothing was written"
        )
    }

    func testPersistIdleClearsStaleSnapshot() throws {
        // Pre-seed a stale entry.
        UserDefaults.standard.set("{}", forKey: snapshotKey)
        UserDefaults.standard.set(true,  forKey: snapshotReady)

        let model = try AppModel()
        // Idle — nothing playing.
        model.persistQueueSnapshot()

        XCTAssertNil(
            UserDefaults.standard.object(forKey: snapshotKey),
            "an idle persist must clear any stale JSON entry"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: snapshotReady),
            "an idle persist must clear the ready flag"
        )
    }

    func testLoadSnapshotWithMissingReadyFlagReturnsNil() {
        UserDefaults.standard.set("{\"positionSeconds\":0}", forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: snapshotReady)

        XCTAssertNil(
            AppModel.loadQueueSnapshot(),
            "loadQueueSnapshot must return nil when the ready flag is absent"
        )
    }

    func testLoadSnapshotWithMalformedJsonClearsAndReturnsNil() {
        UserDefaults.standard.set("not-valid-json", forKey: snapshotKey)
        UserDefaults.standard.set(true, forKey: snapshotReady)

        let result = AppModel.loadQueueSnapshot()

        XCTAssertNil(result, "malformed JSON should return nil")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: snapshotKey),
            "malformed JSON should also clear the persisted entry"
        )
    }

    // MARK: - applyQueueSnapshot

    func testApplySnapshotHydratesOverlays() throws {
        let model = try AppModel()
        let snapshot = QueueSnapshot(
            currentTrack: PersistedTrack(from: makeTrack(id: "c1")),
            positionSeconds: 12.0,
            userAdded: [PersistedTrack(from: makeTrack(id: "u1")),
                        PersistedTrack(from: makeTrack(id: "u2"))],
            autoQueue: [PersistedTrack(from: makeTrack(id: "aq1"))],
            contextName: "Test Playlist",
            contextId: "pl-1",
            contextSourceType: "playlist"
        )

        model.applyQueueSnapshot(snapshot)

        XCTAssertEqual(model.upNextUserAdded.count, 2)
        XCTAssertEqual(model.upNextUserAdded[0].track.id, "u1")
        XCTAssertEqual(model.upNextUserAdded[1].track.id, "u2")
        XCTAssertEqual(model.upNextAutoQueue.count, 1)
        XCTAssertEqual(model.upNextAutoQueue[0].track.id, "aq1")
        XCTAssertEqual(model.currentContext?.name, "Test Playlist")
        XCTAssertEqual(model.currentContext?.sourceType, .playlist)
    }

    func testApplySnapshotSetsPendingResume() throws {
        let model = try AppModel()
        let snapshot = QueueSnapshot(
            currentTrack: PersistedTrack(from: makeTrack()),
            positionSeconds: 30.0,
            userAdded: [],
            autoQueue: [],
            contextName: nil,
            contextId: nil,
            contextSourceType: nil
        )

        model.applyQueueSnapshot(snapshot)

        XCTAssertNotNil(
            model.pendingResumeSnapshot,
            "applyQueueSnapshot must set pendingResumeSnapshot"
        )
        XCTAssertEqual(model.pendingResumeSnapshot?.positionSeconds, 30.0)
    }

    func testApplySnapshotClearsUserDefaults() throws {
        let model = try AppModel()
        UserDefaults.standard.set("{}", forKey: snapshotKey)
        UserDefaults.standard.set(true,  forKey: snapshotReady)

        let snapshot = QueueSnapshot(
            currentTrack: nil,
            positionSeconds: 0,
            userAdded: [],
            autoQueue: [],
            contextName: nil,
            contextId: nil,
            contextSourceType: nil
        )
        model.applyQueueSnapshot(snapshot)

        XCTAssertNil(
            UserDefaults.standard.object(forKey: snapshotKey),
            "applyQueueSnapshot must clear the persisted JSON after consuming it"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: snapshotReady),
            "applyQueueSnapshot must clear the ready flag"
        )
    }

    // MARK: - dismissResumeSnapshot

    func testDismissResumeSnapshotClearsPending() throws {
        let model = try AppModel()
        model.pendingResumeSnapshot = QueueSnapshot(
            currentTrack: nil,
            positionSeconds: 0,
            userAdded: [],
            autoQueue: [],
            contextName: nil,
            contextId: nil,
            contextSourceType: nil
        )
        model.dismissResumeSnapshot()
        XCTAssertNil(model.pendingResumeSnapshot)
    }

    // MARK: - resumeFromSnapshot

    func testResumeFromSnapshotClearsPending() throws {
        let model = try AppModel()
        // Seed a minimal snapshot with a valid current track so play(tracks:)
        // has something to work with.
        model.pendingResumeSnapshot = QueueSnapshot(
            currentTrack: PersistedTrack(from: makeTrack(id: "r1")),
            positionSeconds: 0.5, // ≤ 1.0 so no seek is scheduled
            userAdded: [],
            autoQueue: [],
            contextName: nil,
            contextId: nil,
            contextSourceType: nil
        )
        model.resumeFromSnapshot()
        XCTAssertNil(
            model.pendingResumeSnapshot,
            "resumeFromSnapshot must clear the pending snapshot regardless of playback outcome"
        )
    }

    func testResumeFromNilSnapshotIsNoOp() throws {
        let model = try AppModel()
        model.pendingResumeSnapshot = nil
        // Should not crash.
        model.resumeFromSnapshot()
        XCTAssertNil(model.pendingResumeSnapshot)
    }
}
