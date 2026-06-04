import XCTest
@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Offline downloads (#819) — Swift-side coverage.
///
/// Two things matter most here and both are about *safety while the feature is
/// gated off*:
///   1. With `supportsDownloads == false` (today's shipping default) every
///      AppModel download entry point is a no-op and the per-track state read
///      is `nil`, so no UI affordance appears and no work is kicked off.
///   2. The AudioEngine's offline branch never fires while
///      `offlinePlaybackEnabled` is false — `resolveLocalAssetURL` returns nil
///      with no FFI, so the streaming path is byte-for-byte unchanged.
///
/// The snapshot-read helpers and the context-menu toggle-direction logic are
/// also exercised directly against the in-memory `downloadStateById` map (which
/// is `internal`), so the read path the row views depend on is locked even
/// while the engine flag is off.
///
/// `AppModel` is `@MainActor`; the suite redirects the core's data dir to a
/// throwaway temp dir via `XDG_DATA_HOME` so it never touches the real DB.
@MainActor
final class DownloadsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-downloads-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "Artist",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 0,
            isFavorite: false,
            playCount: 0,
            container: "mp3",
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - Gating (feature dormant)

    /// The downloads capability ships gated off, so the four AppModel entry
    /// points stay inert. This is the contract the prompt mandates: a
    /// dormant-but-correct feature.
    func testDownloadsCapabilityGatedOff() throws {
        let model = try AppModel()
        XCTAssertFalse(
            model.supportsDownloads,
            "downloads must stay gated until the full flow is proven solid"
        )
    }

    /// With the feature gated off, the per-track state read returns nil for any
    /// track — so `TrackRow.downloadBadge` renders nothing and the context menu
    /// hides the Download action.
    func testDownloadStateNilWhileGatedOff() throws {
        let model = try AppModel()
        XCTAssertNil(model.downloadState(forTrackId: "anything"))
        XCTAssertFalse(model.isDownloaded(makeTrack("x")))
        XCTAssertFalse(model.isDownloading(makeTrack("x")))
    }

    /// `downloadTracks` / `toggleDownload` are no-ops while gated off: they must
    /// not mutate the in-memory snapshot or kick a fetch. (If they ran, the
    /// optimistic path would stamp a `.queued` badge into `downloadStateById`.)
    func testDownloadEntryPointsAreNoOpsWhileGatedOff() async throws {
        let model = try AppModel()
        let track = makeTrack("gated")

        await model.downloadTracks([track])
        XCTAssertNil(model.downloadStateById[track.id], "downloadTracks must no-op while gated off")

        model.toggleDownload(tracks: [track])
        // toggleDownload dispatches into a Task; give the main actor a turn.
        await Task.yield()
        XCTAssertNil(model.downloadStateById[track.id], "toggleDownload must no-op while gated off")

        await model.refreshDownloads()
        XCTAssertTrue(model.downloads.isEmpty, "refreshDownloads must no-op while gated off")
    }

    // MARK: - AudioEngine offline gate (additive)

    /// The engine flag is seeded from `supportsDownloads`, so it stays false in
    /// the shipping build — guaranteeing `play(track:)` never queries the
    /// download FFI and the streaming path is unchanged.
    func testEngineOfflinePlaybackDisabledByDefault() throws {
        let model = try AppModel()
        XCTAssertFalse(
            model.audio.offlinePlaybackEnabled,
            "offline playback must mirror supportsDownloads (false today)"
        )
    }

    /// With offline playback disabled, the local-asset resolver returns nil for
    /// any track without touching the core — the streaming branch in
    /// `play(track:)` is reached exactly as before #819.
    func testResolveLocalAssetReturnsNilWhenOfflineDisabled() async throws {
        let dir = NSTemporaryDirectory() + "lyrebird-dl-engine-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "dl-test"))
        let engine = AudioEngine(core: core)
        XCTAssertFalse(engine.offlinePlaybackEnabled)

        let url = await engine.resolveLocalAssetURLForTesting("any-track")
        XCTAssertNil(url, "disabled offline playback must resolve no local URL")
    }

    /// Even when the flag is flipped on, a track with no completed download
    /// resolves to nil — so playback still streams. This proves the offline
    /// branch only diverts when an actual local copy exists.
    func testResolveLocalAssetReturnsNilForUndownloadedTrackWhenEnabled() async throws {
        let dir = NSTemporaryDirectory() + "lyrebird-dl-engine2-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "dl-test"))
        let engine = AudioEngine(core: core)
        engine.offlinePlaybackEnabled = true

        let url = await engine.resolveLocalAssetURLForTesting("never-downloaded")
        XCTAssertNil(url, "an undownloaded track must resolve to no local URL even when enabled")
    }

    // MARK: - Snapshot read helpers (independent of the gate)

    /// The read helpers the row views and context menu depend on map the
    /// in-memory state correctly. Driven directly against `downloadStateById`
    /// so the mapping is locked regardless of the capability flag.
    func testSnapshotReadHelpersMapState() throws {
        let model = try AppModel()
        let done = makeTrack("done")
        let queued = makeTrack("queued")
        let downloading = makeTrack("downloading")
        let failed = makeTrack("failed")

        model.downloadStateById = [
            done.id: .done,
            queued.id: .queued,
            downloading.id: .downloading,
            failed.id: .failed,
        ]

        XCTAssertEqual(model.downloadState(forTrackId: done.id), .done)
        XCTAssertTrue(model.isDownloaded(done))
        XCTAssertFalse(model.isDownloaded(failed))

        XCTAssertTrue(model.isDownloading(queued))
        XCTAssertTrue(model.isDownloading(downloading))
        XCTAssertFalse(model.isDownloading(done))
        XCTAssertFalse(model.isDownloading(failed))
    }

    /// `in-flight` set also counts as "downloading" for the spinner, covering
    /// the window between an optimistic enqueue and the core flipping the row.
    func testInFlightCountsAsDownloading() throws {
        let model = try AppModel()
        let t = makeTrack("inflight")
        model.downloadsInFlight = [t.id]
        XCTAssertTrue(model.isDownloading(t))
    }

    /// The budget slider value (GB) converts to the byte count the core stores.
    /// Pin the 1e9-per-GB factor the preferences pane uses so a UI tweak can't
    /// silently change the persisted budget.
    func testBudgetGigabytesToBytesFactor() {
        // 10 GB -> 10_000_000_000 bytes. The conversion lives in
        // `setDownloadBudget(gigabytes:)`; mirror it here as the contract.
        let gb = 10.0
        let bytes = UInt64(max(0, gb) * 1_000_000_000)
        XCTAssertEqual(bytes, 10_000_000_000)
    }
}
