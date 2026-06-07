import MediaPlayer
import XCTest

@testable import LyrebirdAudio
@testable import LyrebirdCore

/// Coverage for `MediaSession`'s now-playing / remote-command behaviour:
///   * the no-art track must not inherit the previous track's cover (#162),
///   * cover-art caching is keyed by album identity so every track on an
///     album reuses one fetch (#160),
///   * a forward skip clamps to the track duration instead of seeking past
///     the end (#408),
///   * `refreshTransportState()` lets app-UI-driven shuffle / repeat /
///     favorite changes reach Control Center (#460).
///
/// The artwork-fetch network path can't run headlessly, so the clamp and
/// cache-key logic are exercised through pure static helpers
/// (`MediaSession.skipForwardTarget`, `MediaSession.artworkCacheKey`) the
/// same way `MenuBarNowPlayingTests` tests its decisions. The now-playing /
/// remote-command writes go through the real `MPNowPlayingInfoCenter` /
/// `MPRemoteCommandCenter` singletons, which are available in a headless run.
@MainActor
final class MediaSessionTests: XCTestCase {

    // MARK: - Mock delegate

    private final class MockDelegate: MediaSessionDelegate {
        var currentStatus: PlayerStatus
        var favorite = false
        var seekedTo: Double?

        init(status: PlayerStatus) { self.currentStatus = status }

        func mediaSessionTogglePlayPause() {}
        func mediaSessionPlay() {}
        func mediaSessionPause() {}
        func mediaSessionStop() {}
        func mediaSessionSkipNext() {}
        func mediaSessionSkipPrevious() {}
        func mediaSessionSeek(toSeconds seconds: Double) { seekedTo = seconds }
        func mediaSessionSetShuffle(_ on: Bool) {}
        func mediaSessionSetRepeatMode(_ mode: RepeatMode) {}
        func mediaSessionToggleFavorite() -> Bool? { favorite.toggle(); return favorite }
        func mediaSessionCurrentTrackIsFavorite() -> Bool { favorite }
        func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL? { nil }
        func mediaSessionAuthorizationHeader() -> String? { nil }
    }

    // MARK: - Fixtures

    private func makeTrack(
        id: String = "t1",
        albumId: String? = "album-1",
        imageTag: String? = "tag-1",
        runtimeTicks: UInt64 = 0
    ) -> Track {
        Track(
            id: id,
            name: "Song \(id)",
            albumId: albumId,
            albumName: "Album",
            artistName: "Artist",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: runtimeTicks,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: imageTag,
            playlistItemId: nil,
            userData: nil
        )
    }

    private func makeStatus(
        track: Track?,
        state: PlaybackState = .playing,
        position: Double = 0,
        duration: Double = 0,
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off,
        queueLength: UInt32 = 1,
        queuePosition: UInt32 = 0
    ) -> PlayerStatus {
        PlayerStatus(
            state: state,
            currentTrack: track,
            positionSeconds: position,
            durationSeconds: duration,
            volume: 1.0,
            queuePosition: queuePosition,
            queueLength: queueLength,
            shuffle: shuffle,
            repeatMode: repeatMode,
            playSessionId: nil
        )
    }

    private func dummyArtwork() -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: CGSize(width: 1, height: 1)) { _ in
            NSImage(size: CGSize(width: 1, height: 1))
        }
    }

    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    // MARK: - #162 stale artwork

    func testTrackChangedDropsPreviousArtworkWhenNewTrackHasNoImageTag() {
        // Seed the now-playing info with artwork, as if a prior art-bearing
        // track had been published.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyArtwork: dummyArtwork()
        ]

        let noArtTrack = makeTrack(id: "t2", imageTag: nil)
        let delegate = MockDelegate(status: makeStatus(track: noArtTrack))
        let session = MediaSession()
        session.attach(delegate: delegate)

        session.trackChanged(noArtTrack)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNil(
            info?[MPMediaItemPropertyArtwork],
            "a track with no image tag must not inherit the previous track's cover (#162)"
        )
        // Sanity: the rest of the info was still published.
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Song t2")
    }

    func testTrackChangedKeepsPlaceholderWhenNewTrackHasImageTag() {
        let placeholder = dummyArtwork()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyArtwork: placeholder
        ]

        let artTrack = makeTrack(id: "t3", imageTag: "tag-3")
        let delegate = MockDelegate(status: makeStatus(track: artTrack))
        let session = MediaSession()
        session.attach(delegate: delegate)

        session.trackChanged(artTrack)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNotNil(
            info?[MPMediaItemPropertyArtwork],
            "an art-bearing track keeps the placeholder cover until its own art decodes (#30)"
        )
    }

    // MARK: - #160 album-keyed artwork cache

    func testArtworkCacheKeyIsSharedAcrossTracksOnSameAlbum() {
        let trackA = makeTrack(id: "a", albumId: "album-9", imageTag: "cover-9")
        let trackB = makeTrack(id: "b", albumId: "album-9", imageTag: "cover-9")
        XCTAssertEqual(
            MediaSession.artworkCacheKey(for: trackA),
            MediaSession.artworkCacheKey(for: trackB),
            "two tracks on the same album with the same cover tag must hit one cache entry (#160)"
        )
    }

    func testArtworkCacheKeyDiffersAcrossAlbumsAndOnTagChange() {
        let base = makeTrack(id: "a", albumId: "album-1", imageTag: "tag-1")
        let otherAlbum = makeTrack(id: "b", albumId: "album-2", imageTag: "tag-1")
        let newTag = makeTrack(id: "c", albumId: "album-1", imageTag: "tag-2")
        XCTAssertNotEqual(
            MediaSession.artworkCacheKey(for: base),
            MediaSession.artworkCacheKey(for: otherAlbum),
            "different albums must not collide on one cache entry"
        )
        XCTAssertNotEqual(
            MediaSession.artworkCacheKey(for: base),
            MediaSession.artworkCacheKey(for: newTag),
            "a changed cover tag must invalidate the cache key"
        )
    }

    func testArtworkCacheKeyFallsBackToTrackIdWithoutAlbum() {
        let single = makeTrack(id: "solo", albumId: nil, imageTag: "tag-x")
        XCTAssertEqual(
            MediaSession.artworkCacheKey(for: single),
            "solo|tag-x" as NSString,
            "a track with no album id keys on its own id"
        )
    }

    // MARK: - #408 skip-forward clamp

    func testSkipForwardClampsToDurationNearEnd() {
        // 295s into a 300s track, +15s would overshoot to 310 → clamp to 300.
        XCTAssertEqual(
            MediaSession.skipForwardTarget(position: 295, interval: 15, duration: 300),
            300,
            "a forward skip near the end must clamp to the track duration (#408)"
        )
    }

    func testSkipForwardDoesNotClampMidTrack() {
        XCTAssertEqual(
            MediaSession.skipForwardTarget(position: 100, interval: 15, duration: 300),
            115,
            "a mid-track forward skip advances by the full interval"
        )
    }

    func testSkipForwardWithUnknownDurationDoesNotClamp() {
        XCTAssertEqual(
            MediaSession.skipForwardTarget(position: 100, interval: 15, duration: 0),
            115,
            "a zero/unknown duration disables the cap so the skip still advances"
        )
    }

    // MARK: - #460 refreshTransportState

    func testRefreshTransportStateMirrorsFavoriteToLikeCommand() {
        let track = makeTrack()
        let delegate = MockDelegate(status: makeStatus(track: track))
        let session = MediaSession()
        session.attach(delegate: delegate)

        delegate.favorite = true
        session.refreshTransportState()
        XCTAssertTrue(
            MPRemoteCommandCenter.shared().likeCommand.isActive,
            "favoriting the playing track in app UI must light the Control Center like glyph (#460)"
        )

        delegate.favorite = false
        session.refreshTransportState()
        XCTAssertFalse(
            MPRemoteCommandCenter.shared().likeCommand.isActive,
            "un-favoriting must clear the like glyph on the next refresh (#460)"
        )
    }

    func testRefreshTransportStateMirrorsShuffleAndRepeat() {
        let track = makeTrack()
        let delegate = MockDelegate(
            status: makeStatus(track: track, shuffle: true, repeatMode: .one)
        )
        let session = MediaSession()
        session.attach(delegate: delegate)

        session.refreshTransportState()

        let cc = MPRemoteCommandCenter.shared()
        XCTAssertEqual(
            cc.changeShuffleModeCommand.currentShuffleType, .items,
            "an app-UI shuffle-on must mirror to Control Center's shuffle cell (#460)"
        )
        XCTAssertEqual(
            cc.changeRepeatModeCommand.currentRepeatType, .one,
            "an app-UI repeat-one must mirror to Control Center's repeat cell (#460)"
        )
    }

    func testRefreshTransportStateClearsLikeWhenNoTrack() {
        let delegate = MockDelegate(status: makeStatus(track: nil, queueLength: 0))
        let session = MediaSession()
        session.attach(delegate: delegate)

        session.refreshTransportState()
        XCTAssertFalse(
            MPRemoteCommandCenter.shared().likeCommand.isActive,
            "with no playing track the like command is inactive"
        )
        XCTAssertFalse(MPRemoteCommandCenter.shared().likeCommand.isEnabled)
    }

    // MARK: - #38 AirPlay currentPlaybackDate

    /// Verify `trackChanged` publishes `currentPlaybackDate` while playing so
    /// AirPlay receivers (HomePod, Apple TV) can derive a wall-clock anchor and
    /// display an accurate progress bar without polling the source device.
    func testTrackChangedPublishesCurrentPlaybackDateWhenPlaying() {
        let track = makeTrack(id: "t-cpd", runtimeTicks: 300_000_000) // 30s
        let delegate = MockDelegate(
            status: makeStatus(track: track, state: .playing, position: 10)
        )
        let session = MediaSession()
        session.attach(delegate: delegate)

        let before = Date()
        session.trackChanged(track)
        let after = Date()

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let dateValue = info?[MPNowPlayingInfoPropertyCurrentPlaybackDate] as? Date
        XCTAssertNotNil(
            dateValue,
            "currentPlaybackDate must be set while playing so AirPlay receivers can display progress (#38)"
        )
        if let dateValue {
            // The published date is "now − elapsed" (10 s behind wall clock).
            // Allow ±2 s of test-scheduling slack.
            let expectedLo = before.addingTimeInterval(-10 - 2)
            let expectedHi = after.addingTimeInterval(-10 + 2)
            XCTAssertTrue(
                dateValue >= expectedLo && dateValue <= expectedHi,
                "currentPlaybackDate should reflect elapsed position relative to wall clock"
            )
        }
    }

    /// Verify `currentPlaybackDate` is absent when the track is paused — a
    /// paused AirPlay receiver must not auto-advance its own scrubber.
    func testTrackChangedOmitsCurrentPlaybackDateWhenPaused() {
        let track = makeTrack(id: "t-paused")
        let delegate = MockDelegate(
            status: makeStatus(track: track, state: .paused, position: 5)
        )
        let session = MediaSession()
        session.attach(delegate: delegate)

        session.trackChanged(track)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNil(
            info?[MPNowPlayingInfoPropertyCurrentPlaybackDate],
            "currentPlaybackDate must be absent while paused (#38)"
        )
    }

    /// Verify `rateChanged(isPlaying:false)` removes `currentPlaybackDate` so a
    /// HomePod / Apple TV doesn't drift its scrubber forward after the user pauses.
    func testRateChangedToPausedRemovesCurrentPlaybackDate() {
        let track = makeTrack(id: "t-rate")
        let delegate = MockDelegate(
            status: makeStatus(track: track, state: .paused, position: 20)
        )
        let session = MediaSession()
        session.attach(delegate: delegate)

        // Start from a published playing state so the date key exists.
        let playDelegate = MockDelegate(
            status: makeStatus(track: track, state: .playing, position: 20)
        )
        let playSession = MediaSession()
        playSession.attach(delegate: playDelegate)
        playSession.trackChanged(track)
        XCTAssertNotNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyCurrentPlaybackDate],
            "precondition: currentPlaybackDate must be set while playing"
        )

        // Pause the session.
        session.trackChanged(track) // establishes currentTrackID on `session`
        session.rateChanged(isPlaying: false)

        XCTAssertNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyCurrentPlaybackDate],
            "pausing must remove currentPlaybackDate so AirPlay receivers stop advancing (#38)"
        )
    }
}
