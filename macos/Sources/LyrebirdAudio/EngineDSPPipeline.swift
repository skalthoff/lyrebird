import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

private let pipelineLog = Logger(subsystem: "org.lyrebird.desktop", category: "dsp")

/// AVAudioEngine-based playback pipeline (#39) — the DSP foundation for the
/// EQ (#40) and crossfade (#41) features that `AVQueuePlayer` cannot host.
///
/// Node graph:
///
///     AVAudioPlayerNode → AVAudioUnitEQ (10-band, flat) → mainMixerNode
///
/// The EQ ships **flat and bypassed** (`globalGain == 0`, every band
/// `bypass == true`) so the engine path makes no audible DSP alteration —
/// #40 owns the preset/slider UI that will drive real band gains through
/// the `eq` node this class already keeps live in the graph.
///
/// Tracks are fed by a `DSPTrackStreamer` (URLSession → AudioToolbox parse →
/// `AVAudioConverter` decode → scheduled `AVAudioPCMBuffer`s), one per track.
/// `AudioEngine` owns an instance of this class only while the
/// `engine.useAVAudioEngine` feature flag is on; with the flag off (the
/// default) this type is never constructed.
///
/// Energy contract (CLAUDE.md gap #2): the position tick runs at 1 Hz and
/// only while playing — `pause()` both pauses the node *and* pauses the
/// engine's render thread, and invalidates the timer, so an idle app does
/// zero per-second work on this path too.
@MainActor
public final class EngineDSPPipeline {
    public enum TransportState {
        case idle
        case playing
        case paused
    }

    // MARK: - Owner callbacks

    /// Fired when a fully-streamed track finishes playing back — the DSP
    /// path's end-of-item signal (`AVPlayerItemDidPlayToEndTime` parity).
    public var onTrackFinished: (() -> Void)?

    /// 1 Hz position tick, fired only while playing (never when paused or
    /// stopped). Drives `core.markPosition` parity with the AVPlayer path's
    /// periodic time observer.
    public var onPositionTick: ((Double) -> Void)?

    /// Fired when the current track's stream dies (network failure,
    /// unsupported container, decode error). Carries a diagnostic message;
    /// the owner decides the user-facing copy.
    public var onStreamError: ((String) -> Void)?

    // MARK: - Node graph

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The EQ stage. Flat/bypassed by default; exposed so #40's preset UI
    /// can drive band gains on the live graph.
    public let eq = AVAudioUnitEQ(numberOfBands: 10)

    private var streamer: DSPTrackStreamer?
    private var processingFormat: AVAudioFormat?
    private var configurationChangeObserver: NSObjectProtocol?

    // MARK: - Transport / position state

    public private(set) var state: TransportState = .idle

    /// Stream frame corresponding to node sample time 0 — reset by
    /// `load` (0) and `seek` (the landing frame). Position is
    /// `baseFrame + playerTime.sampleTime`.
    private var baseFrame: AVAudioFramePosition = 0

    /// Last node sample time successfully read while rendering, so the
    /// position survives pauses (when `playerTime(forNodeTime:)` goes nil).
    private var lastKnownSampleTime: AVAudioFramePosition = 0

    private var sampleRate: Double = 44_100

    /// Pending volume applied to the mixer once the graph exists.
    private var volume: Float = 1.0

    /// Core Audio output device UID the engine output should pin to
    /// (nil/empty = system default).
    private var outputDeviceUID: String?

    private var positionTimer: Timer?

    /// Bumped per `load` so a stale streamer's late callbacks (format-ready,
    /// finished, error) can't cross tracks.
    private var loadGeneration: Int = 0

    public init() {
        engine.attach(playerNode)
        engine.attach(eq)
        configureFlatEQ()
        // Initial wiring with a placeholder format so the graph is valid
        // before the first track's real format is known; `connectGraph`
        // rewires with the source format per track.
        if let placeholder = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) {
            connectGraph(format: placeholder)
        }
        // An output-device disappearance (unplugged interface) stops the
        // engine. Restart best-effort so playback continues on the new
        // default device — parity with AVPlayer's automatic rerouting.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        positionTimer?.invalidate()
    }

    // MARK: - Loading

    /// Tear down the current track (if any) and begin streaming `url`.
    /// Playback starts as soon as the stream's header parses, *if* `play()`
    /// has been called (or had been in effect for the previous track).
    ///
    /// `containerHint` is the Jellyfin container string ("flac", "mp3", …)
    /// used to bias AudioToolbox's container sniffing; `durationHint` (in
    /// seconds) backs seek estimation on streams without packet tables.
    public func load(
        url: URL,
        authHeader: String?,
        containerHint: String? = nil,
        durationHint: Double? = nil
    ) {
        unloadCurrentTrack()

        loadGeneration &+= 1
        let generation = loadGeneration

        let streamer = DSPTrackStreamer(
            url: url,
            authHeader: authHeader,
            playerNode: playerNode,
            fileTypeHint: EngineDSPPipeline.fileTypeHint(forContainer: containerHint),
            durationHintSeconds: durationHint
        )
        streamer.onFormatReady = { [weak self] format in
            guard let self, generation == self.loadGeneration else { return }
            self.handleFormatReady(format)
        }
        streamer.onPlaybackFinished = { [weak self] in
            guard let self, generation == self.loadGeneration else { return }
            self.stopPositionTimer()
            self.state = .idle
            self.onTrackFinished?()
        }
        streamer.onStreamError = { [weak self] message in
            guard let self, generation == self.loadGeneration else { return }
            self.stopPositionTimer()
            self.state = .idle
            self.onStreamError?(message)
        }
        streamer.onSeekCommitted = { [weak self] landedFrame in
            guard let self, generation == self.loadGeneration else { return }
            self.baseFrame = landedFrame
        }
        self.streamer = streamer
        streamer.start()
    }

    // MARK: - Transport

    /// Declare the transport intent as playing. If the graph is already
    /// configured the node starts immediately; otherwise it starts the
    /// moment the stream's format resolves in `handleFormatReady`.
    public func play() {
        state = .playing
        startNodeIfReady()
        startPositionTimer()
    }

    public func pause() {
        guard state == .playing else { return }
        // Snapshot the position while the render clock is still readable —
        // `playerTime(forNodeTime:)` returns nil once the node pauses.
        refreshLastKnownSampleTime()
        state = .paused
        stopPositionTimer()
        playerNode.pause()
        engine.pause()
    }

    public func resume() {
        guard state != .playing else { return }
        state = .playing
        startNodeIfReady()
        startPositionTimer()
    }

    /// Full teardown: cancel the stream, drop scheduled audio, stop the
    /// engine, reset position.
    public func stop() {
        unloadCurrentTrack()
        state = .idle
    }

    /// Seek the current track. Drops everything scheduled, points the
    /// streamer at the packet-aligned byte offset (ranged request), and
    /// resumes from there. Position reflects the target immediately; the
    /// streamer corrects it via `onSeekCommitted` if the landing differs
    /// (estimated VBR offsets, or a server that ignored the Range header).
    public func seek(toSeconds seconds: Double) {
        guard let streamer else { return }
        // Before the stream header has parsed there is no packet table to
        // seek within (and `sampleRate` is still the placeholder) — drop the
        // request instead of lying about the position. The streamer would
        // ignore it anyway; this keeps `baseFrame` honest too.
        guard processingFormat != nil else { return }
        let targetFrame = AVAudioFramePosition(max(0, seconds) * sampleRate)

        // Generation-bump the streamer *before* stopping the node so the
        // completions fired by `stop()` can't advance stale bookkeeping.
        streamer.seek(toFrame: targetFrame)

        playerNode.stop()
        baseFrame = targetFrame
        lastKnownSampleTime = 0

        // Playing: restart the node so re-streamed buffers render as they
        // arrive. Paused: leave everything parked — the streamer keeps
        // scheduling against the stopped node and `resume()` picks it up.
        if state == .playing {
            startNodeIfReady()
        }
    }

    public func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        engine.mainMixerNode.outputVolume = volume
    }

    /// Pin engine output to a Core Audio device by UID (empty/nil = system
    /// default). Matches `AVPlayer.audioOutputDeviceUniqueID` semantics as
    /// closely as the HAL output unit allows: an explicit device pins; the
    /// default falls back to whatever device is the system default at the
    /// time playback (re)starts.
    public func setOutputDevice(uid: String?) {
        outputDeviceUID = uid
        applyOutputDevice()
    }

    // MARK: - Position

    /// Current playback position in stream seconds. Reads the node's render
    /// clock while playing; falls back to the last known position while
    /// paused/stopped.
    public var positionSeconds: Double {
        refreshLastKnownSampleTime()
        return Double(baseFrame + lastKnownSampleTime) / sampleRate
    }

    // MARK: - Internals

    private func unloadCurrentTrack() {
        // Invalidate callbacks from the outgoing streamer before touching
        // the node so nothing it fires mid-teardown lands on fresh state.
        loadGeneration &+= 1
        streamer?.cancel()
        streamer = nil
        stopPositionTimer()
        // `stop()` drops every scheduled buffer — required so a paused
        // track's tail can't leak into the next one. Safe on an attached
        // node regardless of whether the engine is currently rendering.
        playerNode.stop()
        engine.stop()
        baseFrame = 0
        lastKnownSampleTime = 0
    }

    private func handleFormatReady(_ format: AVAudioFormat) {
        processingFormat = format
        sampleRate = format.sampleRate
        connectGraph(format: format)
        engine.prepare()
        // Only now may the streamer schedule decoded buffers — scheduling
        // against a graph wired for a different format raises inside
        // AVFoundation.
        streamer?.beginScheduling()
        if state == .playing {
            startNodeIfReady()
        }
    }

    private func connectGraph(format: AVAudioFormat) {
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
    }

    /// Start the engine + node when both the transport intent is "playing"
    /// and the graph has a real format. Safe to call repeatedly.
    private func startNodeIfReady() {
        guard state == .playing, processingFormat != nil else { return }
        ensureEngineRunning()
        guard engine.isRunning else { return }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        applyOutputDevice()
        do {
            try engine.start()
        } catch {
            pipelineLog.error("AVAudioEngine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshLastKnownSampleTime() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid
        else { return }
        lastKnownSampleTime = max(0, playerTime.sampleTime)
    }

    private func handleConfigurationChange() {
        // The engine stops itself when the output device configuration
        // changes (device unplugged, default switched while pinned-to-
        // default). If we were playing, restart on the new configuration.
        guard state == .playing else { return }
        ensureEngineRunning()
        if engine.isRunning, !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func applyOutputDevice() {
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        guard let uid = outputDeviceUID, !uid.isEmpty,
              let deviceID = AudioOutputDevices.deviceID(forUID: uid)
        else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            pipelineLog.error("Output device pin failed (\(status)) for \(uid, privacy: .public)")
        }
    }

    // MARK: - Position timer (1 Hz, playing only)

    private func startPositionTimer() {
        guard positionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .playing else { return }
                // Skip the tick when nothing is actually rendering yet
                // (stream still buffering) — matches the AVPlayer observer's
                // rate != 0 guard.
                guard self.engine.isRunning, self.playerNode.isPlaying else { return }
                self.onPositionTick?(self.positionSeconds)
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    // MARK: - EQ

    /// Standard 10-band layout (31 Hz … 16 kHz), flat. `bypass = true` on
    /// every band plus `globalGain = 0` guarantees the engine path is
    /// audibly identical to no-EQ until `applyEqualizer` installs the
    /// user's settings (#40).
    private func configureFlatEQ() {
        let frequencies = EqualizerSettings.bandFrequencies
        for (index, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = index < frequencies.count ? frequencies[index] : 1_000
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = true
        }
        eq.globalGain = 0
    }

    /// Drive the live EQ node from user settings (#40). Safe to call at any
    /// time — `AVAudioUnitEQ` band parameters apply in real time, so preset
    /// switches and slider drags take effect mid-render without a graph
    /// rebuild (and without clicks; the unit ramps parameter changes).
    ///
    /// Bit-perfect contract: a band whose gain is 0 — and *every* band while
    /// `isEnabled == false` — is bypassed outright rather than run as a
    /// zero-gain filter, so EQ-off and the Flat preset are bit-identical to
    /// the engine-disabled output. `globalGain` stays 0; the issue reserves
    /// make-up gain for a future loudness pass.
    public func applyEqualizer(_ settings: EqualizerSettings) {
        let gains = settings.activeGains
        for (index, band) in eq.bands.enumerated() {
            let gain = index < gains.count ? gains[index] : 0
            band.gain = gain
            band.bypass = !settings.isEnabled || gain == 0
        }
        eq.globalGain = 0
    }

    /// Map Jellyfin's container string to an AudioToolbox file-type hint.
    /// Unknown containers return 0 (sniff from bytes).
    static func fileTypeHint(forContainer container: String?) -> AudioFileTypeID {
        switch container?.lowercased() {
        case "mp3": return kAudioFileMP3Type
        case "flac": return kAudioFileFLACType
        case "aac", "adts": return kAudioFileAAC_ADTSType
        case "m4a", "m4b", "alac", "mp4": return kAudioFileM4AType
        case "wav": return kAudioFileWAVEType
        case "aiff", "aif": return kAudioFileAIFFType
        case "caf": return kAudioFileCAFType
        default: return 0
        }
    }

    #if DEBUG
    /// Test seam: whether the EQ node is attached to this pipeline's engine
    /// and wired between the player node and the main mixer.
    var isEQWiredForTesting: Bool {
        guard eq.engine === engine, playerNode.engine === engine else { return false }
        let playerFeedsEQ = engine.outputConnectionPoints(for: playerNode, outputBus: 0)
            .contains { $0.node === eq }
        let eqFeedsMixer = engine.outputConnectionPoints(for: eq, outputBus: 0)
            .contains { $0.node === engine.mainMixerNode }
        return playerFeedsEQ && eqFeedsMixer
    }

    /// Test seam: the EQ must be audibly inert until #40 ships controls.
    var isEQFlatForTesting: Bool {
        eq.globalGain == 0 && eq.bands.allSatisfy { $0.bypass && $0.gain == 0 }
    }
    #endif
}
