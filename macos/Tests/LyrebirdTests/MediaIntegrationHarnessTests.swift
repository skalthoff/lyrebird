import AVFoundation
import MediaPlayer
import XCTest

@testable import LyrebirdAudio
import LyrebirdCore

/// CI-friendly media-integration harness (#460). Everything here runs
/// headless — no audio output device, no network, no app scene graph — so
/// `swift test` exercises it locally and on the `macos-15` CI runner.
///
/// Acceptance-bullet map for #460 (see also the sibling suites):
///   * **happy path** — `testHappyPathTransitionSequencePublishesCoherentNowPlayingInfo`
///     walks play → pause → seek → resume → track change across the
///     now-playing surface, and `MediaIntegrationEngineHarnessTests`
///     drives a real `AVQueuePlayer` over a local asset to completion.
///     (`Sources/SmokeTest` covers the same transport arc against a live
///     server in `e2e.yml`.)
///   * **stall + recovery** — `MediaIntegrationEngineHarnessTests`
///     induces a transient stream failure and asserts playback recovers
///     onto a real `file://` asset and plays to the end;
///     `AudioEngineRecoveryTests` pins the retry-budget arithmetic.
///   * **track change** — the happy-path sequence + the dedicated
///     artwork/`currentPlaybackDate` cases in `MediaSessionTests`.
///   * **seek** — `testChangePlaybackPositionCommandSeeksAndPublishesElapsed`
///     plus the seek leg of the happy-path sequence.
///   * **command enable/disable at queue bounds** — the
///     `testNextPreviousEnablement*` / `testEmptyQueueDisables*` /
///     `testRepeatAllEnables*` group.
///
/// Remote commands are exercised through `MediaSession`'s internal
/// `handle*Command` methods — the exact bodies the `MPRemoteCommandCenter`
/// `addTarget` closures delegate to. The `MP*CommandEvent` classes have no
/// public initializers, so dispatching a synthetic event through the real
/// command center is not possible from a test; the handler methods are the
/// seam that keeps the full command behaviour (guards, clamps, echoes)
/// under test without duplicating it.
///
/// Note on the buffer-stall simulation: #460 suggests `URLProtocol`
/// interception, but AVFoundation's media loader does not consult
/// app-registered `URLProtocol` subclasses for http(s)/file media, so a
/// protocol stub can never starve an `AVPlayerItem`. The stall is instead
/// induced through the engine's transient-failure path with the same
/// `NSURLErrorDomain` codes the real byte pump surfaces (-1005), which
/// drives the production rebuild-and-retry code end to end.
@MainActor
final class MediaIntegrationHarnessTests: XCTestCase {

    // MARK: - Recording delegate

    /// Delegate double that records every routed command and mirrors
    /// shuffle / repeat / favorite mutations back into `currentStatus`
    /// synchronously — the same contract `AppModel` fulfils by pushing the
    /// change into the core and re-reading `PlayerStatus` before the
    /// handler's enablement refresh runs.
    private final class RecordingDelegate: MediaSessionDelegate {
        var currentStatus: PlayerStatus
        var favorite = false

        var playCalls = 0
        var pauseCalls = 0
        var toggleCalls = 0
        var stopCalls = 0
        var skipNextCalls = 0
        var skipPreviousCalls = 0
        var seeks: [Double] = []
        var shuffleSets: [Bool] = []
        var repeatSets: [RepeatMode] = []

        init(status: PlayerStatus) { self.currentStatus = status }

        func mediaSessionTogglePlayPause() { toggleCalls += 1 }
        func mediaSessionPlay() { playCalls += 1 }
        func mediaSessionPause() { pauseCalls += 1 }
        func mediaSessionStop() { stopCalls += 1 }
        func mediaSessionSkipNext() { skipNextCalls += 1 }
        func mediaSessionSkipPrevious() { skipPreviousCalls += 1 }
        func mediaSessionSeek(toSeconds seconds: Double) { seeks.append(seconds) }
        func mediaSessionSetShuffle(_ on: Bool) {
            shuffleSets.append(on)
            currentStatus.shuffle = on
        }
        func mediaSessionSetRepeatMode(_ mode: RepeatMode) {
            repeatSets.append(mode)
            currentStatus.repeatMode = mode
        }
        func mediaSessionToggleFavorite() -> Bool? {
            guard currentStatus.currentTrack != nil else { return nil }
            favorite.toggle()
            return favorite
        }
        func mediaSessionCurrentTrackIsFavorite() -> Bool { favorite }
        func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL? { nil }
        func mediaSessionAuthorizationHeader() -> String? { nil }
    }

    // MARK: - Fixtures

    private func makeTrack(
        id: String = "t1",
        runtimeTicks: UInt64 = 1_800_000_000 // 180s
    ) -> Track {
        Track(
            id: id,
            name: "Song \(id)",
            albumId: "album-1",
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
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    private func makeStatus(
        track: Track?,
        state: PlaybackState = .playing,
        position: Double = 0,
        duration: Double = 180,
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

    /// Build an attached session. Callers must keep the returned delegate
    /// alive for the duration of the test — the session only holds it
    /// weakly, and a deallocated delegate flips every handler to
    /// `.commandFailed`.
    private func makeSession(
        status: PlayerStatus
    ) -> (MediaSession, RecordingDelegate) {
        let delegate = RecordingDelegate(status: status)
        let session = MediaSession()
        session.attach(delegate: delegate)
        return (session, delegate)
    }

    private func nowPlayingDouble(_ key: String) -> Double? {
        (MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] as? NSNumber)?.doubleValue
    }

    private func nowPlayingInt(_ key: String) -> Int? {
        (MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] as? NSNumber)?.intValue
    }

    private func nowPlayingString(_ key: String) -> String? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] as? String
    }

    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    // MARK: - Transport command routing

    func testTransportCommandsRouteToDelegateWhenTrackActive() {
        let (session, delegate) = makeSession(status: makeStatus(track: makeTrack()))

        XCTAssertEqual(session.handlePlayCommand(), .success)
        XCTAssertEqual(delegate.playCalls, 1, "play command must route to the delegate's play action")

        XCTAssertEqual(session.handlePauseCommand(), .success)
        XCTAssertEqual(delegate.pauseCalls, 1, "pause command must route to the delegate's pause action")

        XCTAssertEqual(session.handleTogglePlayPauseCommand(), .success)
        XCTAssertEqual(delegate.toggleCalls, 1, "toggle command must route to the delegate's toggle action")

        XCTAssertEqual(session.handleStopCommand(), .success)
        XCTAssertEqual(delegate.stopCalls, 1, "stop command must route to the delegate's stop action")
    }

    func testTransportCommandsReportNoActionableItemWithoutTrack() {
        let (session, delegate) = makeSession(
            status: makeStatus(track: nil, queueLength: 0)
        )

        XCTAssertEqual(session.handlePlayCommand(), .noActionableNowPlayingItem)
        XCTAssertEqual(session.handlePauseCommand(), .noActionableNowPlayingItem)
        XCTAssertEqual(session.handleTogglePlayPauseCommand(), .noActionableNowPlayingItem)
        XCTAssertEqual(session.handleStopCommand(), .noActionableNowPlayingItem)
        XCTAssertEqual(
            delegate.playCalls + delegate.pauseCalls + delegate.toggleCalls + delegate.stopCalls,
            0,
            "no transport action may reach the delegate when nothing is playing"
        )
    }

    /// A session whose delegate is gone (owner deallocated) must fail every
    /// command rather than crash or half-apply — the `addTarget` closures
    /// return `.commandFailed` in exactly this case.
    func testAllCommandsFailWithoutDelegate() {
        let session = MediaSession() // never attached

        XCTAssertEqual(session.handlePlayCommand(), .commandFailed)
        XCTAssertEqual(session.handlePauseCommand(), .commandFailed)
        XCTAssertEqual(session.handleTogglePlayPauseCommand(), .commandFailed)
        XCTAssertEqual(session.handleStopCommand(), .commandFailed)
        XCTAssertEqual(session.handleNextTrackCommand(), .commandFailed)
        XCTAssertEqual(session.handlePreviousTrackCommand(), .commandFailed)
        XCTAssertEqual(session.handleChangePlaybackPositionCommand(toSeconds: 10), .commandFailed)
        XCTAssertEqual(session.handleChangeShuffleModeCommand(.items), .commandFailed)
        XCTAssertEqual(session.handleChangeRepeatModeCommand(.all), .commandFailed)
        XCTAssertEqual(session.handleLikeCommand(), .commandFailed)
        XCTAssertEqual(session.handleSkipForwardCommand(interval: 15), .commandFailed)
        XCTAssertEqual(session.handleSkipBackwardCommand(interval: 15), .commandFailed)
    }

    func testNextTrackCommandRoutesSkipNext() {
        let (session, delegate) = makeSession(
            status: makeStatus(track: makeTrack(), queueLength: 2)
        )

        XCTAssertEqual(session.handleNextTrackCommand(), .success)
        XCTAssertEqual(delegate.skipNextCalls, 1)
    }

    // MARK: - Previous-track restart threshold (#581)

    func testPreviousTrackCommandRestartsTrackPastThreeSeconds() {
        let (session, delegate) = makeSession(
            status: makeStatus(track: makeTrack(), position: 10)
        )

        XCTAssertEqual(session.handlePreviousTrackCommand(), .success)
        XCTAssertEqual(delegate.seeks, [0], "past 3s, previous must restart the current track (#581)")
        XCTAssertEqual(delegate.skipPreviousCalls, 0)
    }

    func testPreviousTrackCommandSkipsToPreviousWithinThreeSeconds() {
        let (session, delegate) = makeSession(
            status: makeStatus(track: makeTrack(), position: 2.5, queueLength: 2, queuePosition: 1)
        )

        XCTAssertEqual(session.handlePreviousTrackCommand(), .success)
        XCTAssertEqual(delegate.skipPreviousCalls, 1, "within 3s, previous must jump to the prior queue item")
        XCTAssertTrue(delegate.seeks.isEmpty)
    }

    // MARK: - Seek (changePlaybackPosition)

    func testChangePlaybackPositionCommandSeeksAndPublishesElapsed() {
        let track = makeTrack()
        let (session, delegate) = makeSession(
            status: makeStatus(track: track, state: .playing, position: 10)
        )
        session.trackChanged(track)

        XCTAssertEqual(session.handleChangePlaybackPositionCommand(toSeconds: 42.5), .success)

        XCTAssertEqual(delegate.seeks, [42.5], "the scrub target must route to the delegate seek")
        XCTAssertEqual(
            nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 42.5,
            "elapsed must confirm the scrub immediately, without waiting for a position tick (#32)"
        )
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 1.0)
    }

    func testChangePlaybackPositionCommandFailsWithoutTrack() {
        let (session, delegate) = makeSession(
            status: makeStatus(track: nil, queueLength: 0)
        )

        XCTAssertEqual(session.handleChangePlaybackPositionCommand(toSeconds: 5), .commandFailed)
        XCTAssertTrue(delegate.seeks.isEmpty)
    }

    // MARK: - Shuffle / repeat commands (#34)

    func testShuffleCommandRoutesAndEchoesMode() {
        let (session, delegate) = makeSession(status: makeStatus(track: makeTrack()))
        let cc = MPRemoteCommandCenter.shared()

        XCTAssertEqual(session.handleChangeShuffleModeCommand(.items), .success)
        XCTAssertEqual(delegate.shuffleSets, [true])
        XCTAssertEqual(
            cc.changeShuffleModeCommand.currentShuffleType, .items,
            "the new mode must echo to Control Center on the same call"
        )

        XCTAssertEqual(session.handleChangeShuffleModeCommand(.off), .success)
        XCTAssertEqual(delegate.shuffleSets, [true, false])
        XCTAssertEqual(cc.changeShuffleModeCommand.currentShuffleType, .off)
    }

    func testRepeatCommandRoutesAndEchoesMode() {
        let (session, delegate) = makeSession(status: makeStatus(track: makeTrack()))
        let cc = MPRemoteCommandCenter.shared()

        XCTAssertEqual(session.handleChangeRepeatModeCommand(.all), .success)
        XCTAssertEqual(delegate.repeatSets, [RepeatMode.all])
        XCTAssertEqual(cc.changeRepeatModeCommand.currentRepeatType, .all)

        XCTAssertEqual(session.handleChangeRepeatModeCommand(.one), .success)
        XCTAssertEqual(delegate.repeatSets, [RepeatMode.all, RepeatMode.one])
        XCTAssertEqual(cc.changeRepeatModeCommand.currentRepeatType, .one)

        XCTAssertEqual(session.handleChangeRepeatModeCommand(.off), .success)
        XCTAssertEqual(cc.changeRepeatModeCommand.currentRepeatType, .off)
    }

    // MARK: - Like command (#35)

    func testLikeCommandFlipsIsActiveOptimistically() {
        let (session, delegate) = makeSession(status: makeStatus(track: makeTrack()))
        let like = MPRemoteCommandCenter.shared().likeCommand

        XCTAssertEqual(session.handleLikeCommand(), .success)
        XCTAssertTrue(delegate.favorite, "the toggle must reach the delegate")
        XCTAssertTrue(like.isActive, "isActive must flip before the network round-trip completes")

        XCTAssertEqual(session.handleLikeCommand(), .success)
        XCTAssertFalse(delegate.favorite)
        XCTAssertFalse(like.isActive, "a second toggle must clear the optimistic flag")
    }

    func testLikeCommandWithoutTrackIsNoActionable() {
        let (session, delegate) = makeSession(status: makeStatus(track: nil, queueLength: 0))

        XCTAssertEqual(session.handleLikeCommand(), .noActionableNowPlayingItem)
        XCTAssertFalse(delegate.favorite, "no toggle may be applied when nothing is playing")
        XCTAssertFalse(MPRemoteCommandCenter.shared().likeCommand.isActive)
    }

    // MARK: - Skip ±15s commands (#33 / #408)

    func testSkipForwardCommandClampsToDurationAndPublishesElapsed() {
        let track = makeTrack(runtimeTicks: 3_000_000_000) // 300s
        let (session, delegate) = makeSession(
            status: makeStatus(track: track, state: .playing, position: 295, duration: 300)
        )
        session.trackChanged(track)

        XCTAssertEqual(session.handleSkipForwardCommand(interval: 15), .success)

        XCTAssertEqual(delegate.seeks, [300], "a skip near the end must clamp to the duration (#408)")
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 300)
    }

    func testSkipBackwardCommandFloorsAtZeroAndPublishesElapsed() {
        let track = makeTrack()
        let (session, delegate) = makeSession(
            status: makeStatus(track: track, state: .playing, position: 5)
        )
        session.trackChanged(track)

        XCTAssertEqual(session.handleSkipBackwardCommand(interval: 15), .success)

        XCTAssertEqual(delegate.seeks, [0], "a skip past the start must floor at zero")
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 0)
    }

    func testSkipCommandsWithoutTrackAreNoActionable() {
        let (session, delegate) = makeSession(status: makeStatus(track: nil, queueLength: 0))

        XCTAssertEqual(session.handleSkipForwardCommand(interval: 15), .noActionableNowPlayingItem)
        XCTAssertEqual(session.handleSkipBackwardCommand(interval: 15), .noActionableNowPlayingItem)
        XCTAssertTrue(delegate.seeks.isEmpty)
    }

    // MARK: - Happy path: now-playing info across every transition

    /// Walks the full transport arc — play, pause, seek, resume, track
    /// change — asserting `MPNowPlayingInfoCenter` carries a coherent
    /// dictionary after every transition. This is the headless counterpart
    /// of watching Control Center track a real listening session.
    func testHappyPathTransitionSequencePublishesCoherentNowPlayingInfo() {
        let track1 = makeTrack(id: "hp-1") // 180s
        let (session, delegate) = makeSession(
            status: makeStatus(track: track1, state: .playing, position: 0, queueLength: 2, queuePosition: 0)
        )

        // -- Play: the full property set lands.
        session.trackChanged(track1)
        XCTAssertEqual(nowPlayingString(MPMediaItemPropertyTitle), "Song hp-1")
        XCTAssertEqual(nowPlayingString(MPMediaItemPropertyArtist), "Artist")
        XCTAssertEqual(nowPlayingString(MPMediaItemPropertyAlbumTitle), "Album")
        XCTAssertEqual(nowPlayingDouble(MPMediaItemPropertyPlaybackDuration), 180)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 0)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 1.0)
        XCTAssertEqual(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueIndex), 0)
        XCTAssertEqual(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueCount), 2)

        // -- Pause at 42s: rate 0, elapsed frozen, wall-clock anchor dropped.
        delegate.currentStatus.state = .paused
        delegate.currentStatus.positionSeconds = 42
        session.rateChanged(isPlaying: false)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 42)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 0)
        XCTAssertNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyCurrentPlaybackDate],
            "a paused session must not carry a playback date for receivers to drift on (#38)"
        )

        // -- Seek to 90s while paused: elapsed confirms, still paused.
        delegate.currentStatus.positionSeconds = 90
        session.seeked(to: 90)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 90)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 0)

        // -- Resume: rate returns, elapsed holds the seek target.
        delegate.currentStatus.state = .playing
        session.rateChanged(isPlaying: true)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 1.0)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 90)
        XCTAssertNotNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyCurrentPlaybackDate],
            "resuming must restore the wall-clock anchor for AirPlay receivers (#38)"
        )

        // -- Track change: the dictionary swaps wholesale to the new track.
        let track2 = makeTrack(id: "hp-2", runtimeTicks: 2_400_000_000) // 240s
        delegate.currentStatus = makeStatus(
            track: track2, state: .playing, position: 0, duration: 240,
            queueLength: 2, queuePosition: 1
        )
        session.trackChanged(track2)
        XCTAssertEqual(nowPlayingString(MPMediaItemPropertyTitle), "Song hp-2")
        XCTAssertEqual(nowPlayingDouble(MPMediaItemPropertyPlaybackDuration), 240)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyElapsedPlaybackTime), 0)
        XCTAssertEqual(nowPlayingDouble(MPNowPlayingInfoPropertyPlaybackRate), 1.0)
        XCTAssertEqual(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueIndex), 1)
    }

    func testQueueChangedRepublishesQueueIndexAndCount() {
        let track = makeTrack()
        let (session, delegate) = makeSession(
            status: makeStatus(track: track, queueLength: 3, queuePosition: 0)
        )
        session.trackChanged(track)
        XCTAssertEqual(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueIndex), 0)

        delegate.currentStatus.queuePosition = 1
        session.queueChanged()
        XCTAssertEqual(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueIndex), 1)
        XCTAssertEqual(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueCount), 3)

        // An emptied queue drops the pair rather than publishing 0/0.
        delegate.currentStatus.queueLength = 0
        session.queueChanged()
        XCTAssertNil(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueIndex))
        XCTAssertNil(nowPlayingInt(MPNowPlayingInfoPropertyPlaybackQueueCount))
    }

    // MARK: - Command enablement at queue bounds

    func testNextPreviousEnablementAcrossQueueBounds() {
        let (session, delegate) = makeSession(
            status: makeStatus(track: makeTrack(), queueLength: 3, queuePosition: 0)
        )
        let cc = MPRemoteCommandCenter.shared()

        // Head of the queue: forward only.
        session.refreshTransportState()
        XCTAssertTrue(cc.nextTrackCommand.isEnabled, "next must be enabled with tracks ahead")
        XCTAssertFalse(cc.previousTrackCommand.isEnabled, "previous must be disabled on the first track")

        // Mid-queue: both directions.
        delegate.currentStatus.queuePosition = 1
        session.refreshTransportState()
        XCTAssertTrue(cc.nextTrackCommand.isEnabled)
        XCTAssertTrue(cc.previousTrackCommand.isEnabled)

        // Tail: backward only.
        delegate.currentStatus.queuePosition = 2
        session.refreshTransportState()
        XCTAssertFalse(cc.nextTrackCommand.isEnabled, "next must be disabled on the last track")
        XCTAssertTrue(cc.previousTrackCommand.isEnabled)
    }

    func testEmptyQueueDisablesAllTransportDependentCommands() {
        let (session, delegate) = makeSession(status: makeStatus(track: nil, queueLength: 0))
        let cc = MPRemoteCommandCenter.shared()

        session.refreshTransportState()

        XCTAssertFalse(cc.nextTrackCommand.isEnabled)
        XCTAssertFalse(cc.previousTrackCommand.isEnabled)
        XCTAssertFalse(cc.stopCommand.isEnabled)
        XCTAssertFalse(cc.skipForwardCommand.isEnabled)
        XCTAssertFalse(cc.skipBackwardCommand.isEnabled)
        XCTAssertFalse(cc.likeCommand.isEnabled)
        _ = delegate // keep the weakly-held delegate alive through the refresh
    }

    func testRepeatAllEnablesWrapAroundAtQueueBounds() {
        let (session, delegate) = makeSession(
            status: makeStatus(
                track: makeTrack(), repeatMode: .all, queueLength: 3, queuePosition: 2
            )
        )
        let cc = MPRemoteCommandCenter.shared()

        // Last track + repeat-all: next wraps to the head.
        session.refreshTransportState()
        XCTAssertTrue(cc.nextTrackCommand.isEnabled, "repeat-all must let next wrap past the end")
        XCTAssertTrue(cc.previousTrackCommand.isEnabled)

        // First track + repeat-all: previous wraps to the tail.
        delegate.currentStatus.queuePosition = 0
        session.refreshTransportState()
        XCTAssertTrue(cc.nextTrackCommand.isEnabled)
        XCTAssertTrue(cc.previousTrackCommand.isEnabled, "repeat-all must let previous wrap past the start")
    }

    func testTrackPresenceEnablesStopLikeAndSkips() {
        let (session, delegate) = makeSession(status: makeStatus(track: makeTrack()))
        let cc = MPRemoteCommandCenter.shared()

        session.refreshTransportState()

        XCTAssertTrue(cc.stopCommand.isEnabled)
        XCTAssertTrue(cc.likeCommand.isEnabled)
        XCTAssertTrue(cc.skipForwardCommand.isEnabled)
        XCTAssertTrue(cc.skipBackwardCommand.isEnabled)
        _ = delegate // keep the weakly-held delegate alive through the refresh
    }
}

// MARK: - Engine harness: real playback over a local asset

/// Headless `AudioEngine` integration: a real `AVQueuePlayer` streams a tiny
/// generated `file://` asset to completion with no output device attached —
/// the load-bearing property behind running this suite on CI (#460). The
/// recovery case drives the production transient-failure path
/// (`handleItemFailure` → `recoverFromStall`) and proves the rebuilt item
/// both targets the captured stream URL and still advances the queue at
/// end-of-item (the re-wired end observer), which the synthesized-error
/// tests in `AudioEngineRecoveryTests` never verify against real playback.
@MainActor
final class MediaIntegrationEngineHarnessTests: XCTestCase {

    private final class EngineDelegateSpy: AudioEngineDelegate {
        var didStallCount = 0
        var didRecoverCount = 0
        var didFailCount = 0
        var transientErrorCount = 0

        func audioEngineDidStall() { didStallCount += 1 }
        func audioEngineDidRecover() { didRecoverCount += 1 }
        func audioEngineDidFail(_ message: String) { didFailCount += 1 }
        func audioEngineDidEncounterTransientError(_ message: String) { transientErrorCount += 1 }
    }

    private func makeEngine() throws -> AudioEngine {
        let dir = NSTemporaryDirectory() + "lyrebird-harness-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "harness-test"))
        let engine = AudioEngine(core: core)
        engine.installEmptyPlayerForTesting()
        return engine
    }

    /// Write a short silent PCM file the player can stream over `file://`.
    /// Generated per-test so the suite carries no binary fixtures.
    private func makeTinyLocalAsset(durationSeconds: Double = 0.4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrebird-harness-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(44_100 * durationSeconds)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memset(channels[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Happy path, headless: the production rebuild path (asset build →
    /// observer wiring → `play()`) streams a local asset to the end and the
    /// end-of-item contract fires — state marks `.ended` and `onTrackEnded`
    /// asks the owner to advance the queue.
    func testLocalAssetPlaysToEndHeadlessly() throws {
        let engine = try makeEngine()
        let spy = EngineDelegateSpy()
        engine.delegate = spy
        let asset = try makeTinyLocalAsset()
        defer { try? FileManager.default.removeItem(at: asset) }

        let ended = expectation(description: "local asset played to end")
        engine.onTrackEnded = { ended.fulfill() }

        engine.recoverFromStallForTesting(url: asset)

        let item = try XCTUnwrap(engine.currentItemForTesting)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, asset, "the player must be loaded with the local asset")

        wait(for: [ended], timeout: 30.0)
        XCTAssertEqual(engine.core.status().state, .ended, "end-of-item must mark the core .ended")
        XCTAssertEqual(spy.didFailCount, 0, "a clean local play must not surface a failure")
    }

    /// Stall + recovery, headless: a transient stream failure (the same
    /// `NSURLErrorNetworkConnectionLost` the byte pump surfaces on a real
    /// buffer stall) must rebuild onto the captured stream URL, restart
    /// playback, and still fire the end-of-item advance when the recovered
    /// stream finishes.
    func testTransientFailureRecoversOntoLocalAssetAndPlaysToEnd() throws {
        let engine = try makeEngine()
        let spy = EngineDelegateSpy()
        engine.delegate = spy
        let asset = try makeTinyLocalAsset()
        defer { try? FileManager.default.removeItem(at: asset) }

        // The "stream" that dies mid-playback; recovery rebuilds from the
        // captured URL, which points at the local asset.
        engine.setCurrentStreamURLForTesting(asset)
        let failing = AVPlayerItem(url: URL(string: "https://example.invalid/dead.mp3")!)
        engine.installCurrentItemForTesting(failing)

        let ended = expectation(description: "recovered stream played to end")
        engine.onTrackEnded = { ended.fulfill() }

        engine.handleItemFailureForTesting(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
            failedItem: failing
        )

        XCTAssertEqual(spy.didStallCount, 1, "the retry must surface the stall indicator")
        XCTAssertEqual(spy.didRecoverCount, 1, "the in-place rebuild must fire didRecover")
        XCTAssertEqual(engine.stallRetryCountForTesting, 1, "one failure charges one budget slot")
        let rebuilt = try XCTUnwrap(engine.currentItemForTesting)
        XCTAssertEqual(
            (rebuilt.asset as? AVURLAsset)?.url, asset,
            "recovery must rebuild the item from the captured stream URL"
        )

        wait(for: [ended], timeout: 30.0)
        XCTAssertEqual(
            engine.core.status().state, .ended,
            "the recovered stream must still advance the queue at end-of-item"
        )
        XCTAssertEqual(spy.transientErrorCount, 0, "no terminal skip while the retry succeeded")
    }
}
