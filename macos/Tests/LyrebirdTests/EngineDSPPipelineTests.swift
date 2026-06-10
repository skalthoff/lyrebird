import AVFoundation
import XCTest

@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Coverage for the AVAudioEngine DSP pipeline behind the
/// `engine.useAVAudioEngine` feature flag (#39):
///
///   1. The flag defaults **off**, and while off the AVQueuePlayer path runs
///      untouched — the DSP pipeline type is never even constructed.
///   2. With the flag on, transport routes to the pipeline and the gapless
///      preload (an AVQueuePlayer concept) becomes a no-op.
///   3. The byte-stream bridge — `DSPAudioFileStreamParser` parse +
///      `AVAudioConverter` decode + node scheduling — is exercised against a
///      synthesized WAV fixture, with no audio hardware required (the engine
///      is never started).
///   4. The node graph keeps a live-but-flat `AVAudioUnitEQ` between the
///      player node and the mixer (the #40 EQ UI's mounting point).
@MainActor
final class EngineDSPPipelineTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    override func setUp() {
        super.setUp()
        // Each test starts from the shipping default: flag absent ⇒ off.
        UserDefaults.standard.removeObject(forKey: AppModel.engineDSPDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.engineDSPDefaultsKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEngine() throws -> AudioEngine {
        let dir = NSTemporaryDirectory() + "lyrebird-dsp-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "dsp-test"))
        return AudioEngine(core: core)
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

    /// Synthesize a PCM16 WAV in memory: 44-byte canonical header + a sine
    /// tone. Deterministic, no bundled binary fixture needed.
    private static func makeWavData(
        sampleRate: Int = 44_100,
        channels: Int = 2,
        frames: Int = 22_050
    ) -> Data {
        let bytesPerFrame = channels * 2
        let dataSize = frames * bytesPerFrame
        var data = Data(capacity: 44 + dataSize)

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * bytesPerFrame))
        append16(UInt16(bytesPerFrame))
        append16(16)
        append("data")
        append32(UInt32(dataSize))

        var samples = [Int16]()
        samples.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            let value = Int16(sin(2.0 * .pi * 440.0 * Double(frame) / Double(sampleRate)) * 16_000)
            for _ in 0..<channels { samples.append(value) }
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    // MARK: - Flag gating

    /// The capability ships dark: a fresh install (no defaults key) must read
    /// `false`, and the engine must come up with the DSP path disabled and the
    /// pipeline unconstructed. Opting in via the documented defaults key
    /// flips the capability, and `AppModel.init` seeds the engine from it.
    func testEngineDSPFlagDefaultsOffAndSeedsEngine() throws {
        let model = try AppModel()
        XCTAssertFalse(model.supportsEngineDSP, "engine.useAVAudioEngine must default off")
        XCTAssertFalse(model.audio.dspPipelineEnabled, "AppModel.init must seed the engine flag off by default")
        XCTAssertNil(model.audio.dspPipeline, "flag off ⇒ the pipeline is never constructed")

        UserDefaults.standard.set(true, forKey: AppModel.engineDSPDefaultsKey)
        let optedIn = try AppModel()
        XCTAssertTrue(optedIn.supportsEngineDSP)
        XCTAssertTrue(optedIn.audio.dspPipelineEnabled, "AppModel.init must seed the engine flag from the capability")
        XCTAssertNil(optedIn.audio.dspPipeline, "pipeline construction is lazy — nothing built until first DSP play")
    }

    /// Flag off ⇒ zero behaviour change: every transport entry point runs the
    /// AVQueuePlayer path and never constructs the DSP pipeline.
    func testFlagOffTransportNeverTouchesPipeline() throws {
        let engine = try makeEngine()
        XCTAssertFalse(engine.dspPipelineEnabled)

        engine.installEmptyPlayerForTesting()
        engine.pause()
        engine.resume()
        engine.seek(toSeconds: 12)
        engine.setVolume(0.4)
        engine.preloadNextTrack(makeTrack("a"))
        engine.stop()

        XCTAssertNil(engine.dspPipeline, "flag off ⇒ no DSP pipeline may ever be built")
    }

    /// Flag on ⇒ the gapless preload is a documented no-op on the DSP path
    /// (the pipeline plays one track at a time; `onTrackEnded` rebuilds).
    /// The guard must short-circuit before the preload records intent or
    /// touches the AVQueuePlayer.
    func testFlagOnPreloadIsNoOp() throws {
        let engine = try makeEngine()
        engine.dspPipelineEnabled = true
        engine.installEmptyPlayerForTesting()

        engine.preloadNextTrack(makeTrack("next"))

        XCTAssertNil(engine.lastPreloadedTrackIdForTesting, "DSP path must not arm the AVQueuePlayer preload")
        XCTAssertEqual(engine.queuedItemCountForTesting, 0)
    }

    /// Flag on ⇒ transport routes to the pipeline (volume is the cheapest
    /// member to observe: it lazily constructs the pipeline and never starts
    /// audio hardware).
    func testFlagOnVolumeRoutesToPipeline() throws {
        let engine = try makeEngine()
        engine.dspPipelineEnabled = true
        XCTAssertNil(engine.dspPipeline)

        engine.setVolume(0.5)

        XCTAssertNotNil(engine.dspPipeline, "DSP-routed transport should lazily build the pipeline")
    }

    // MARK: - Node graph

    /// The EQ node must be live in the graph (deck players → fade mixers →
    /// blend mixer → EQ → main mixer, the #41 dual-deck layout) and
    /// flat/bypassed — #39 ships the mounting point, #40 ships the controls.
    func testPipelineGraphKeepsFlatEQBetweenPlayerAndMixer() {
        let pipeline = EngineDSPPipeline()
        XCTAssertTrue(pipeline.isEQWiredForTesting, "AVAudioUnitEQ must sit between the active deck and the mixer")
        XCTAssertTrue(pipeline.isEQFlatForTesting, "EQ must ship flat/bypassed until #40 lands controls")
        XCTAssertEqual(pipeline.eq.bands.count, 10)
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.positionSeconds, 0, accuracy: 0.0001)
    }

    /// #41 graph contract: both decks reach the blend mixer through their
    /// own per-node gain mixers, and with crossfade off both gain stages sit
    /// at unity (a 1.0 float mix is audibly identical to the pre-#41 single-
    /// node graph).
    func testDualDeckGraphShipsAtUnityGain() {
        let pipeline = EngineDSPPipeline()
        XCTAssertTrue(pipeline.areBothDecksWiredForTesting, "both decks must feed the blend mixer via their fade mixers")
        XCTAssertEqual(pipeline.fadeMixerGainsForTesting, [1, 1], "fade mixers must ship at unity gain")
        XCTAssertEqual(pipeline.activeDeckIndexForTesting, 0)
        XCTAssertFalse(pipeline.isFadeInFlightForTesting)
        XCTAssertNil(pipeline.armedTrackKeyForTesting)
    }

    /// Crossfade off (the default) must ignore arming entirely — the standby
    /// deck stays cold and the scheduler never sees a next track, preserving
    /// the pre-#41 transition behaviour byte-for-byte.
    func testArmIsIgnoredWhileCrossfadeDisabled() {
        let pipeline = EngineDSPPipeline()
        XCTAssertFalse(pipeline.crossfadeIsEnabled, "crossfade ships off")
        pipeline.armNextTrack(EngineDSPPipeline.ArmedNextTrack(
            key: "next",
            albumKey: nil,
            url: URL(fileURLWithPath: "/dev/null"),
            authHeader: nil,
            containerHint: nil,
            durationHint: 180,
            mediaSourceId: nil,
            playSessionId: nil
        ))
        XCTAssertNil(pipeline.armedTrackKeyForTesting, "arming must be a no-op while crossfade is off")
        XCTAssertNil(pipeline.adoptHandedOffTrack(key: "next"), "no handoff may ever be pending while off")
    }

    /// With crossfade on, arming records the next track; turning the setting
    /// off again disarms it (a pending overlap must not fire after the user
    /// disabled the feature); and the adopt receipt stays nil until a real
    /// handoff happens.
    func testArmAndDisarmFollowSettings() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyCrossfade(CrossfadeSettings(durationSeconds: 4, curve: .equalPower))
        XCTAssertTrue(pipeline.crossfadeIsEnabled)

        pipeline.armNextTrack(EngineDSPPipeline.ArmedNextTrack(
            key: "next",
            albumKey: "album",
            url: URL(fileURLWithPath: "/dev/null"),
            authHeader: nil,
            containerHint: nil,
            durationHint: 180,
            mediaSourceId: "ms",
            playSessionId: "ps"
        ))
        XCTAssertEqual(pipeline.armedTrackKeyForTesting, "next")
        XCTAssertNil(pipeline.adoptHandedOffTrack(key: "next"), "no receipt before a handoff")

        pipeline.applyCrossfade(CrossfadeSettings(durationSeconds: 0))
        XCTAssertNil(pipeline.armedTrackKeyForTesting, "disabling crossfade must disarm the pending track")
    }

    /// Jellyfin container strings map onto AudioToolbox sniffing hints;
    /// unknown containers fall back to byte-sniffing (0).
    func testContainerHintMapping() {
        XCTAssertEqual(EngineDSPPipeline.fileTypeHint(forContainer: "flac"), kAudioFileFLACType)
        XCTAssertEqual(EngineDSPPipeline.fileTypeHint(forContainer: "MP3"), kAudioFileMP3Type)
        XCTAssertEqual(EngineDSPPipeline.fileTypeHint(forContainer: "m4a"), kAudioFileM4AType)
        XCTAssertEqual(EngineDSPPipeline.fileTypeHint(forContainer: "ogg"), 0)
        XCTAssertEqual(EngineDSPPipeline.fileTypeHint(forContainer: nil), 0)
    }

    // MARK: - Byte-stream bridge

    /// Chunked parse of a synthesized WAV: the parser must surface the
    /// stream's format, the canonical 44-byte data offset, every audio byte
    /// as packets, and an exact (non-estimated) seek byte mapping.
    func testParserParsesWavFixture() throws {
        let sampleRate = 44_100
        let channels = 2
        let frames = 11_025
        let wav = Self.makeWavData(sampleRate: sampleRate, channels: channels, frames: frames)

        let parser = try DSPAudioFileStreamParser(fileTypeHint: kAudioFileWAVEType)
        var readyFormat: AudioStreamBasicDescription?
        var packetBytes = 0
        parser.onReadyToProducePackets = { asbd, _ in readyFormat = asbd }
        parser.onPackets = { batch in packetBytes += batch.data.count }

        // Feed in deliberately awkward chunk sizes to exercise resumable
        // parsing across boundaries.
        var offset = 0
        while offset < wav.count {
            let end = min(offset + 999, wav.count)
            try parser.parse(wav.subdata(in: offset..<end))
            offset = end
        }

        let format = try XCTUnwrap(readyFormat, "header must parse to a stream description")
        XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(format.mSampleRate, Double(sampleRate))
        XCTAssertEqual(Int(format.mChannelsPerFrame), channels)
        XCTAssertEqual(parser.dataOffset, 44, "canonical PCM16 WAV header is 44 bytes")
        XCTAssertEqual(packetBytes, frames * channels * 2, "every audio byte must come back out as packets")

        // LPCM packets are frames: packet 1000 starts exactly at
        // dataOffset + 1000 * bytesPerFrame.
        let mapping = try XCTUnwrap(parser.seekByteOffset(forPacket: 1_000))
        XCTAssertEqual(mapping.byteOffset, 44 + 1_000 * Int64(channels * 2))
        XCTAssertFalse(mapping.isEstimated, "LPCM seek offsets are exact")
    }

    /// End-to-end bridge over a local file URL (URLSession → parse → decode
    /// → schedule): every frame of the fixture must end up scheduled on the
    /// player node, without ever starting audio hardware.
    func testStreamerDecodesAndSchedulesWavEndToEnd() throws {
        let frames = 22_050
        let wav = Self.makeWavData(sampleRate: 44_100, channels: 2, frames: frames)
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsp-fixture-\(UUID().uuidString).wav")
        try wav.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)

        let streamer = DSPTrackStreamer(
            url: fileURL,
            authHeader: nil,
            playerNode: node,
            fileTypeHint: kAudioFileWAVEType
        )

        let formatReady = expectation(description: "format resolved")
        var resolvedFormat: AVAudioFormat?
        streamer.onFormatReady = { format in
            resolvedFormat = format
            // Mirror EngineDSPPipeline.handleFormatReady: wire the graph for
            // the resolved format, then unblock scheduling.
            engine.connect(node, to: engine.mainMixerNode, format: format)
            streamer.beginScheduling()
            formatReady.fulfill()
        }
        var streamFailure: String?
        streamer.onStreamError = { message in streamFailure = message }

        streamer.start()
        wait(for: [formatReady], timeout: 10)

        let format = try XCTUnwrap(resolvedFormat)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32, "engine processing format is canonical float32")
        XCTAssertEqual(format.sampleRate, 44_100)
        XCTAssertEqual(format.channelCount, 2)

        // The whole fixture is far below the ~8s pacing cap, so every frame
        // should schedule without any playback-completion callbacks (the
        // engine is never started). Poll the decode queue's snapshot.
        let deadline = Date().addingTimeInterval(10)
        var snapshot = streamer.progressSnapshotForTesting()
        while Date() < deadline {
            snapshot = streamer.progressSnapshotForTesting()
            if snapshot.networkDone && snapshot.scheduledFrames >= AVAudioFramePosition(frames) && snapshot.queuedPackets == 0 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNil(streamFailure, "local-file stream must decode cleanly")
        XCTAssertTrue(snapshot.networkDone, "URLSession should finish delivering the fixture")
        XCTAssertEqual(snapshot.scheduledFrames, AVAudioFramePosition(frames), "every fixture frame must be decoded and scheduled")
        XCTAssertEqual(snapshot.queuedPackets, 0, "decoder should drain the parsed packet backlog")

        streamer.cancel()
    }

    /// An unparseable byte stream (no valid container) must surface
    /// `onStreamError` — the hook the engine uses to skip to the next track —
    /// rather than hanging or crashing.
    func testStreamerSurfacesErrorForGarbageBytes() throws {
        let garbage = Data((0..<4_096).map { _ in UInt8.random(in: 0...255) })
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsp-garbage-\(UUID().uuidString).bin")
        try garbage.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)

        let streamer = DSPTrackStreamer(
            url: fileURL,
            authHeader: nil,
            playerNode: node,
            fileTypeHint: kAudioFileWAVEType
        )

        let failed = expectation(description: "stream error surfaced")
        streamer.onStreamError = { _ in failed.fulfill() }
        streamer.onFormatReady = { _ in
            XCTFail("garbage bytes must not resolve a format")
        }

        streamer.start()
        wait(for: [failed], timeout: 10)
    }
}
