import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

private let pipelineLog = Logger(subsystem: "org.lyrebird.desktop", category: "dsp")

/// AVAudioEngine-based playback pipeline (#39) — the DSP foundation for the
/// EQ (#40) and crossfade (#41) features that `AVQueuePlayer` cannot host.
///
/// Node graph (#41 dual-deck layout):
///
///     deck A: AVAudioPlayerNode → AVAudioMixerNode ─┐
///                                                   ├→ blend mixer → AVAudioUnitEQ (10-band) → mainMixerNode
///     deck B: AVAudioPlayerNode → AVAudioMixerNode ─┘
///
/// Exactly one deck is *active* (the current track) at any time. The second
/// deck exists for transitions: the upcoming track is armed + buffered on
/// it, and at the fade window each deck's per-node `AVAudioMixerNode` ramps
/// its `outputVolume` along the configured gain envelope (#41) — outgoing
/// down, incoming up — through the shared blend → EQ → main-mixer stage, so
/// the EQ applies to both sides of the overlap. With crossfade off but
/// gapless on, the armed track still buffers ahead and takes over via the
/// zero-fade join at the outgoing track's natural end — the buffered gapless
/// transition. With both off the standby deck is never loaded and both fade
/// mixers sit at unity gain, which is audibly (float-mix at 1.0) identical
/// to the pre-#41 single-node graph.
///
/// Each deck's player node additionally carries the per-track loudness gain
/// (ReplayGain / volume normalization): `AVAudioPlayerNode` conforms to
/// `AVAudioMixing`, so `player.volume` is a gain stage at the player → fade
/// mixer connection that the crossfade envelopes never touch — the fade math
/// and the normalization math compose without fighting over one knob.
///
/// The EQ ships **flat and bypassed** (`globalGain == 0`, every band
/// `bypass == true`) so the engine path makes no audible DSP alteration —
/// #40 owns the preset/slider UI that drives real band gains through the
/// `eq` node this class keeps live in the graph.
///
/// Tracks are fed by a `DSPTrackStreamer` per deck (URLSession → AudioToolbox
/// parse → `AVAudioConverter` decode → scheduled `AVAudioPCMBuffer`s).
/// `AudioEngine` owns an instance of this class only while the
/// `engine.useAVAudioEngine` feature flag is on; with the flag off (the
/// default) this type is never constructed.
///
/// Energy contract (CLAUDE.md gap #2): the position tick runs at 1 Hz and
/// only while playing — `pause()` both pauses the nodes *and* pauses the
/// engine's render thread, and invalidates the timer, so an idle app does
/// zero per-second work on this path too. The gain-ramp timer only exists
/// while a fade is actually in progress (≤ 12 s per transition) and is
/// invalidated the moment the last ramp completes.
@MainActor
public final class EngineDSPPipeline {
    public enum TransportState {
        case idle
        case playing
        case paused
    }

    // MARK: - Crossfade value types (#41)

    /// Owner-resolved parameters for the next track, armed ahead of time so
    /// the pipeline can buffer + fade into it without a queue lookup of its
    /// own. `key` / `albumKey` / `mediaSourceId` / `playSessionId` are opaque
    /// to the pipeline — they exist so the owner can match the handoff back
    /// to its queue item and mirror its server-reporting contract.
    public struct ArmedNextTrack {
        public let key: String
        public let albumKey: String?
        public let url: URL
        public let authHeader: String?
        public let containerHint: String?
        public let durationHint: Double?
        public let mediaSourceId: String?
        public let playSessionId: String?

        public init(
            key: String,
            albumKey: String?,
            url: URL,
            authHeader: String?,
            containerHint: String?,
            durationHint: Double?,
            mediaSourceId: String?,
            playSessionId: String?
        ) {
            self.key = key
            self.albumKey = albumKey
            self.url = url
            self.authHeader = authHeader
            self.containerHint = containerHint
            self.durationHint = durationHint
            self.mediaSourceId = mediaSourceId
            self.playSessionId = playSessionId
        }
    }

    /// What the owner needs to keep reporting parity across a crossfade
    /// handoff: the outgoing track's position at the moment the incoming one
    /// became audible (its `reportPlaybackStopped` mark), plus the reporting
    /// context the armed track's stream was resolved with.
    public struct HandoffReceipt {
        public let outgoingPositionSeconds: Double
        public let mediaSourceId: String?
        public let playSessionId: String?
    }

    // MARK: - Owner callbacks

    /// Fired when a fully-streamed track finishes playing back — the DSP
    /// path's end-of-item signal (`AVPlayerItemDidPlayToEndTime` parity).
    /// Not fired for a transition the crossfade handoff already announced
    /// via `onCrossfadeBegan`.
    public var onTrackFinished: (() -> Void)?

    /// 1 Hz position tick, fired only while playing (never when paused or
    /// stopped). Drives `core.markPosition` parity with the AVPlayer path's
    /// periodic time observer. Always reports the *active* deck — during a
    /// crossfade that is the incoming track.
    public var onPositionTick: ((Double) -> Void)?

    /// Fired when the current track's stream dies (network failure,
    /// unsupported container, decode error). Carries a diagnostic message;
    /// the owner decides the user-facing copy. A *standby* (armed next
    /// track) stream failure never fires this — the crossfade is quietly
    /// abandoned and the transition falls back to the rebuild path.
    public var onStreamError: ((String) -> Void)?

    /// Fired the moment an armed next track becomes audible — either at the
    /// start of a gain-ramp crossfade or at a zero-fade join on track
    /// completion. Carries the armed track's `key`. This is the DSP path's
    /// gapless-auto-advance signal: the owner should advance its queue and
    /// re-route `play(track:)` into `adoptHandedOffTrack(key:)` instead of
    /// reloading. `onTrackFinished` does NOT also fire for this transition.
    public var onCrossfadeBegan: ((String) -> Void)?

    /// Veto hook consulted immediately before an armed track takes over
    /// (both the ramped and the zero-fade paths). Returning `false` lets the
    /// outgoing track run to its natural end instead — the owner uses this
    /// for "stop after current track", which must halt at the *true* end of
    /// the track rather than `crossfadeDuration` seconds early. Re-checked
    /// every tick, so disarming the stop mid-window re-enables the fade.
    public var onShouldBeginCrossfade: (() -> Bool)?

    // MARK: - Deck

    /// One playback lane: a player node feeding a dedicated gain mixer, plus
    /// the per-track streaming/position state that used to live directly on
    /// the pipeline before #41 doubled it.
    private final class Deck {
        let player = AVAudioPlayerNode()
        let fadeMixer = AVAudioMixerNode()
        var streamer: DSPTrackStreamer?
        /// Engine processing format of the loaded track; nil until the
        /// stream header parses (and again after unload).
        var format: AVAudioFormat?
        /// The format the player → fadeMixer → blend chain is physically
        /// wired with. Sticky across unloads so an identical-format reload
        /// skips graph surgery entirely.
        var wiredFormat: AVAudioFormat?
        var sampleRate: Double = 44_100
        /// Stream frame corresponding to node sample time 0 — reset by
        /// load (0) and seek (the landing frame).
        var baseFrame: AVAudioFramePosition = 0
        /// Last node sample time successfully read while rendering, so the
        /// position survives pauses.
        var lastKnownSampleTime: AVAudioFramePosition = 0
        /// Duration hint (seconds) from track metadata; drives the crossfade
        /// window math. nil ⇒ no auto-crossfade for this track.
        var durationSeconds: Double?
        /// Opaque owner identity of the loaded track (track id).
        var trackKey: String?
        /// Opaque album identity — same-album transitions zero-fade (#41).
        var albumKey: String?
        /// Parsed loudness tags for the loaded track; nil until the owner's
        /// metadata resolve lands (and again after unload). Cached so a
        /// settings change mid-track re-applies without a re-fetch.
        var loudnessGains: ReplayGain.Gains?
        /// Bumped per load/unload so a stale streamer's late callbacks
        /// (format-ready, finished, error, seek) can't cross tracks.
        var generation: Int = 0
    }

    // MARK: - Node graph

    private let engine = AVAudioEngine()
    private let decks = [Deck(), Deck()]
    private var activeDeckIndex = 0
    private var activeDeck: Deck { decks[activeDeckIndex] }
    private var standbyDeckIndex: Int { 1 - activeDeckIndex }

    /// Merge point for the two decks; its output feeds the EQ so the EQ
    /// stage applies to both sides of a crossfade overlap.
    private let blendMixer = AVAudioMixerNode()

    /// The EQ stage. Flat/bypassed by default; exposed so #40's preset UI
    /// can drive band gains on the live graph.
    public let eq = AVAudioUnitEQ(numberOfBands: 10)

    /// Format the shared blend → EQ → main-mixer chain is wired with.
    /// Rewired to the incoming track's format only while no other deck is
    /// live (rewiring under a rendering deck would glitch it); the blend
    /// mixer sample-rate-converts any mismatched deck in the meantime.
    private var sharedChainFormat: AVAudioFormat?

    private var configurationChangeObserver: NSObjectProtocol?

    // MARK: - Transport / position state

    public private(set) var state: TransportState = .idle

    /// Pending volume applied to the main mixer once the graph exists.
    private var volume: Float = 1.0

    /// Core Audio output device UID the engine output should pin to
    /// (nil/empty = system default).
    private var outputDeviceUID: String?

    private var positionTimer: Timer?

    // MARK: - Crossfade state (#41)

    private var crossfade = CrossfadeSettings()

    /// Whether the buffered gapless join runs while crossfade is off. With
    /// crossfade *on*, transitions already join (overlap, or zero-fade for
    /// same-album pairs), so this knob only matters for the crossfade-off
    /// case. Defaults to `false` so a bare pipeline preserves the pre-gapless
    /// rebuild transitions; the owner seeds it from the user preference
    /// (default on) at construction.
    public private(set) var gaplessEnabled = false

    /// Loudness settings driving each deck's per-track gain stage. Defaults
    /// to all-off (unity gain everywhere).
    private var normalization = NormalizationSettings()

    /// Loudness tags resolved by the owner before their track was loaded on
    /// a deck (the armed next track ahead of its prepare window). Consumed by
    /// `loadTrack`; bounded so stale keys from rapid queue churn can't
    /// accumulate.
    private var pendingLoudnessGains: [String: ReplayGain.Gains] = [:]

    /// The owner-armed upcoming track, if any. Consumed at handoff.
    private var armed: ArmedNextTrack?

    /// Key of the armed track whose stream has been started on the standby
    /// deck; nil until the prepare window opens.
    private var prepStartedForKey: String?

    /// Whether the standby deck's stream has resolved its format and begun
    /// scheduling — the gate for actually starting the fade.
    private var standbyReady = false

    /// Deck currently fading out (auto-crossfade or quick-switch). nil when
    /// no fade is in flight.
    private var retiringDeckIndex: Int?

    /// Fade-in applied to the active deck's next node start (quick-switch
    /// path: the incoming track ramps up over 250 ms).
    private var pendingFadeInDuration: Double?

    /// Set at handoff, consumed by `adoptHandedOffTrack(key:)`.
    private var pendingAdoptKey: String?
    private var handoffReceipt: HandoffReceipt?

    // MARK: - Deferred stream events (#1048)

    /// Active-deck stream failure that arrived while paused. Surfacing it
    /// immediately would let the owner's skip-on-error start the next track
    /// under a paused transport; instead it parks here and `resume()`
    /// delivers it — the skip then happens in response to an explicit
    /// transport action.
    private var deferredActiveStreamError: String?

    /// The active deck reported fully-played-out while paused (possible via
    /// completion storms when a node stops under a paused engine). The
    /// finish handling — zero-fade join or the owner's queue advance, both
    /// of which start audio — runs on `resume()` instead.
    private var deferredActiveFinish = false

    // MARK: - Gain ramps

    private enum RampDirection {
        case fadeIn
        case fadeOut
    }

    private struct GainRamp {
        let deckIndex: Int
        let direction: RampDirection
        let duration: Double
        let curve: CrossfadeSettings.Curve
        var elapsed: Double = 0
        var onComplete: (() -> Void)?
    }

    private var ramps: [GainRamp] = []
    private var rampTimer: Timer?
    private let rampInterval: TimeInterval = 1.0 / 50.0

    public init() {
        for deck in decks {
            engine.attach(deck.player)
            engine.attach(deck.fadeMixer)
            deck.fadeMixer.outputVolume = 1
        }
        engine.attach(blendMixer)
        engine.attach(eq)
        configureFlatEQ()
        // Initial wiring with a placeholder format so the graph is valid
        // before the first track's real format is known; the per-deck and
        // shared chains rewire with real source formats per track.
        if let placeholder = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) {
            for index in decks.indices {
                wireDeckChain(index, format: placeholder)
            }
            wireSharedChain(format: placeholder)
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
        rampTimer?.invalidate()
    }

    // MARK: - Loading

    /// Tear down the current track (if any) and begin streaming `url`.
    /// Playback starts as soon as the stream's header parses, *if* `play()`
    /// has been called (or had been in effect for the previous track).
    ///
    /// `containerHint` is the Jellyfin container string ("flac", "mp3", …)
    /// used to bias AudioToolbox's container sniffing; `durationHint` (in
    /// seconds) backs seek estimation on streams without packet tables and
    /// the crossfade window math; `trackKey` / `albumKey` are the opaque
    /// track/album identities the crossfade scheduler matches against.
    ///
    /// With crossfade on and audio currently rendering, the outgoing track
    /// quick-fades out over 250 ms on its own deck while the new one loads on
    /// the other — the issue #41 manual-skip contract (no pop). With
    /// crossfade off this is byte-for-byte the pre-#41 hard swap.
    public func load(
        url: URL,
        authHeader: String?,
        containerHint: String? = nil,
        durationHint: Double? = nil,
        trackKey: String? = nil,
        albumKey: String? = nil
    ) {
        // Any pending handoff is dead the moment the owner loads something
        // explicitly — the receipt must not leak into the new track. Same
        // for stream events parked while paused: they belonged to the
        // outgoing track.
        pendingAdoptKey = nil
        handoffReceipt = nil
        deferredActiveStreamError = nil
        deferredActiveFinish = false
        settleFadeImmediately()
        disarmNextTrack()

        let quickSwitch = crossfade.isEnabled
            && state == .playing
            && engine.isRunning
            && activeDeck.player.isPlaying

        if quickSwitch {
            beginQuickRetire(of: activeDeckIndex)
            activeDeckIndex = 1 - activeDeckIndex
            pendingFadeInDuration = CrossfadeSettings.quickSwitchDuration
        } else {
            unload(deck: activeDeck)
            stopPositionTimer()
            // `stop()` on the engine mirrors the pre-#41 teardown — required
            // so a paused track's tail can't leak into the next one. Never
            // taken on the quick-switch path, where the outgoing tail must
            // keep rendering through its fade.
            engine.stop()
        }

        loadTrack(
            onDeckAt: activeDeckIndex,
            url: url,
            authHeader: authHeader,
            containerHint: containerHint,
            durationHint: durationHint,
            trackKey: trackKey,
            albumKey: albumKey,
            initialGain: pendingFadeInDuration == nil ? 1 : 0
        )
    }

    // MARK: - Transport

    /// Declare the transport intent as playing. If the graph is already
    /// configured the node starts immediately; otherwise it starts the
    /// moment the stream's format resolves in `handleFormatReady`.
    public func play() {
        state = .playing
        for deck in decks { deck.streamer?.setTransportPaused(false) }
        startNodeIfReady()
        resumeRetiringNodeIfNeeded()
        resumeRampTimerIfNeeded()
        startPositionTimer()
    }

    public func pause() {
        guard state == .playing else { return }
        // Snapshot positions while the render clock is still readable —
        // `playerTime(forNodeTime:)` returns nil once a node pauses.
        refreshLastKnownSampleTime(of: activeDeck)
        if let retiring = retiringDeckIndex {
            refreshLastKnownSampleTime(of: decks[retiring])
        }
        state = .paused
        stopPositionTimer()
        suspendRampTimer()
        // Park the transfers (#1048): a paused consumer can't drain the
        // decode pacing, so an open response would idle into CFNetwork's
        // request timeout and fail the track from under the user. Parked
        // streamers defer the failure and reconnect on resume.
        for deck in decks { deck.streamer?.setTransportPaused(true) }
        activeDeck.player.pause()
        if let retiring = retiringDeckIndex {
            decks[retiring].player.pause()
        }
        engine.pause()
    }

    public func resume() {
        guard state != .playing else { return }
        // A failure that arrived while paused was parked instead of skipping
        // the track from under the user (#1048). Deliver it now — the owner's
        // skip-on-error runs in response to an explicit transport action.
        if let message = deferredActiveStreamError {
            deferredActiveStreamError = nil
            deferredActiveFinish = false
            stopPositionTimer()
            state = .idle
            onStreamError?(message)
            return
        }
        state = .playing
        for deck in decks { deck.streamer?.setTransportPaused(false) }
        startNodeIfReady()
        resumeRetiringNodeIfNeeded()
        resumeRampTimerIfNeeded()
        startPositionTimer()
        if deferredActiveFinish {
            deferredActiveFinish = false
            finishActiveTrack()
        }
    }

    /// Full teardown: cancel both decks' streams, drop scheduled audio, stop
    /// the engine, reset positions, clear any armed crossfade.
    public func stop() {
        settleFadeImmediately()
        disarmNextTrack()
        pendingAdoptKey = nil
        handoffReceipt = nil
        deferredActiveStreamError = nil
        deferredActiveFinish = false
        pendingLoudnessGains.removeAll()
        unload(deck: activeDeck)
        stopPositionTimer()
        engine.stop()
        state = .idle
    }

    /// Seek the current track. Drops everything scheduled, points the
    /// streamer at the packet-aligned byte offset (ranged request), and
    /// resumes from there. Position reflects the target immediately; the
    /// streamer corrects it via `onSeekCommitted` if the landing differs
    /// (estimated VBR offsets, or a server that ignored the Range header).
    ///
    /// A fade in flight is settled first (outgoing deck silenced, incoming
    /// snapped to full gain) — scrubbing during an overlap targets the track
    /// the UI already shows, and two clocks can't fight over the position.
    public func seek(toSeconds seconds: Double) {
        settleFadeImmediately()
        // A parked end-of-playback is superseded — the seek re-streams the
        // track, so it is no longer "finished". (A parked *failure* stays:
        // its streamer is dead, so the seek below no-ops and resume still
        // owes the owner the error.)
        deferredActiveFinish = false
        let deck = activeDeck
        guard let streamer = deck.streamer else { return }
        // Before the stream header has parsed there is no packet table to
        // seek within (and `sampleRate` is still the placeholder) — drop the
        // request instead of lying about the position.
        guard deck.format != nil else { return }
        let targetFrame = AVAudioFramePosition(max(0, seconds) * deck.sampleRate)

        // Generation-bump the streamer *before* stopping the node so the
        // completions fired by `stop()` can't advance stale bookkeeping.
        streamer.seek(toFrame: targetFrame)

        deck.player.stop()
        deck.baseFrame = targetFrame
        deck.lastKnownSampleTime = 0

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

    /// Current playback position in stream seconds for the *active* track.
    /// Reads the node's render clock while playing; falls back to the last
    /// known position while paused/stopped.
    public var positionSeconds: Double {
        position(of: activeDeck)
    }

    /// Opaque key of the track currently loaded on the active deck — the
    /// owner's stale-arm guard.
    public var currentTrackKey: String? {
        activeDeck.trackKey
    }

    // MARK: - Crossfade (#41)

    /// Drive the crossfade scheduler from user settings. Safe to call at any
    /// time; turning crossfade off mid-track disarms any pending next track
    /// (a fade already in progress completes — it is audibly underway) —
    /// unless gapless keeps the arm alive for the zero-fade join.
    public func applyCrossfade(_ settings: CrossfadeSettings) {
        crossfade = settings
        if !settings.isEnabled, !gaplessEnabled {
            disarmNextTrack()
        }
    }

    /// Drive the gapless preference. Turning it off mid-track disarms a
    /// pending next track only when crossfade isn't keeping it armed for an
    /// overlap of its own.
    public func applyGapless(_ enabled: Bool) {
        gaplessEnabled = enabled
        if !enabled, !crossfade.isEnabled {
            disarmNextTrack()
        }
    }

    /// Drive each deck's per-track loudness gain stage from user settings.
    /// Safe to call at any time — both decks re-apply from their cached tags
    /// immediately, so a mode/target change is audible mid-track without a
    /// metadata re-fetch.
    public func applyNormalization(_ settings: NormalizationSettings) {
        normalization = settings
        for deck in decks {
            applyNormalizationGain(to: deck)
        }
    }

    /// Hand the pipeline a track's parsed loudness tags. Applied immediately
    /// when a deck holds the track; stashed for the upcoming `loadTrack`
    /// otherwise (the armed next track resolves its tags before its prepare
    /// window opens). Unknown keys are dropped when the stash fills — a lost
    /// gain degrades to unity, never a wrong level.
    public func provideLoudnessGains(_ gains: ReplayGain.Gains, forTrackKey key: String) {
        if let deck = decks.first(where: { $0.trackKey == key }) {
            deck.loudnessGains = gains
            applyNormalizationGain(to: deck)
            return
        }
        if pendingLoudnessGains.count >= 4 {
            pendingLoudnessGains.removeAll()
        }
        pendingLoudnessGains[key] = gains
    }

    /// Whether the applied settings enable crossfade — the owner's cheap
    /// guard before resolving an arm.
    public var crossfadeIsEnabled: Bool {
        crossfade.isEnabled
    }

    /// Whether the owner should resolve + arm the next track at all: either
    /// transition feature (crossfade overlap, gapless buffered join) wants
    /// the standby deck loaded ahead of the handoff.
    public var transitionArmingEnabled: Bool {
        crossfade.isEnabled || gaplessEnabled
    }

    /// Arm the upcoming track for a joined transition — crossfade overlap,
    /// or the zero-fade gapless join when crossfade is off. Replaces any
    /// previously armed track; the streamer doesn't start until the prepare
    /// window opens (`CrossfadeSettings.prepareLeadSeconds` before the fade),
    /// so arming is cheap and re-arming after queue edits costs nothing.
    public func armNextTrack(_ next: ArmedNextTrack) {
        guard transitionArmingEnabled else { return }
        if let inFlight = prepStartedForKey, inFlight != next.key {
            // The armed target changed after its stream already started —
            // drop the stale prep so the window math re-prepares the right
            // track.
            cancelPrep()
        }
        armed = next
    }

    /// Drop the armed next track and any standby prep for it. Never touches
    /// a deck that is mid-retirement.
    public func disarmNextTrack() {
        armed = nil
        cancelPrep()
    }

    /// Hand the owner the receipt for a transition `onCrossfadeBegan`
    /// announced, if `key` matches the track that took over. The owner calls
    /// this from its `play(track:)` path: a non-nil receipt means the track
    /// is *already playing* on the active deck — adopt it (mirror the
    /// reporting swap) instead of reloading. One-shot.
    public func adoptHandedOffTrack(key: String) -> HandoffReceipt? {
        guard pendingAdoptKey == key, let receipt = handoffReceipt else { return nil }
        pendingAdoptKey = nil
        handoffReceipt = nil
        return receipt
    }

    // MARK: - Internals: loading

    private func loadTrack(
        onDeckAt deckIndex: Int,
        url: URL,
        authHeader: String?,
        containerHint: String?,
        durationHint: Double?,
        trackKey: String?,
        albumKey: String?,
        initialGain: Float
    ) {
        let deck = decks[deckIndex]
        deck.generation &+= 1
        let generation = deck.generation
        deck.format = nil
        deck.baseFrame = 0
        deck.lastKnownSampleTime = 0
        deck.durationSeconds = durationHint
        deck.trackKey = trackKey
        deck.albumKey = albumKey
        deck.fadeMixer.outputVolume = initialGain
        // Consume a loudness resolve that landed before this load (the armed
        // next track's tags arrive at arm time, ahead of the prepare window).
        deck.loudnessGains = trackKey.flatMap { pendingLoudnessGains.removeValue(forKey: $0) }
        applyNormalizationGain(to: deck)

        let streamer = DSPTrackStreamer(
            url: url,
            authHeader: authHeader,
            playerNode: deck.player,
            fileTypeHint: EngineDSPPipeline.fileTypeHint(forContainer: containerHint),
            durationHintSeconds: durationHint
        )
        streamer.onFormatReady = { [weak self] format in
            guard let self, generation == self.decks[deckIndex].generation else { return }
            self.handleFormatReady(format, deckIndex: deckIndex)
        }
        streamer.onPlaybackFinished = { [weak self] in
            guard let self, generation == self.decks[deckIndex].generation else { return }
            self.handleStreamerFinished(deckIndex: deckIndex)
        }
        streamer.onStreamError = { [weak self] message in
            guard let self, generation == self.decks[deckIndex].generation else { return }
            self.handleStreamerError(message, deckIndex: deckIndex)
        }
        streamer.onSeekCommitted = { [weak self] landedFrame in
            guard let self, generation == self.decks[deckIndex].generation else { return }
            self.decks[deckIndex].baseFrame = landedFrame
        }
        deck.streamer = streamer
        streamer.start()
    }

    private func unload(deck: Deck) {
        // Invalidate callbacks from the outgoing streamer before touching
        // the node so nothing it fires mid-teardown lands on fresh state.
        deck.generation &+= 1
        deck.streamer?.cancel()
        deck.streamer = nil
        // `stop()` drops every scheduled buffer — required so a paused
        // track's tail can't leak into the next one. Safe on an attached
        // node regardless of whether the engine is currently rendering.
        deck.player.stop()
        deck.format = nil
        deck.baseFrame = 0
        deck.lastKnownSampleTime = 0
        deck.durationSeconds = nil
        deck.trackKey = nil
        deck.albumKey = nil
        // The loudness gain is per-track state: reset the player gain stage
        // to unity so the next track never inherits the old track's level.
        deck.loudnessGains = nil
        deck.player.volume = 1
    }

    /// Re-derive a deck's player gain stage from its cached loudness tags
    /// under the current settings. Unity when normalization resolves nothing
    /// (settings off, tags missing, or no usable tag for the mode) — the
    /// documented "leave the level untouched" contract.
    private func applyNormalizationGain(to deck: Deck) {
        let gain = deck.loudnessGains.flatMap { normalization.linearVolume(gains: $0) } ?? 1
        deck.player.volume = gain
    }

    private func handleFormatReady(_ format: AVAudioFormat, deckIndex: Int) {
        let deck = decks[deckIndex]
        deck.format = format
        deck.sampleRate = format.sampleRate
        wireDeckChain(deckIndex, format: format)
        rewireSharedChainIfQuiet(format: format, loadingDeckIndex: deckIndex)
        if !engine.isRunning {
            engine.prepare()
        }
        // Only now may the streamer schedule decoded buffers — scheduling
        // against a graph wired for a different format raises inside
        // AVFoundation.
        deck.streamer?.beginScheduling()

        if deckIndex == activeDeckIndex {
            if state == .playing {
                startNodeIfReady()
            }
        } else if prepStartedForKey != nil, deckIndex == standbyDeckIndex {
            // The armed track's stream is decoding — the fade may begin.
            standbyReady = true
        }
    }

    // MARK: - Internals: graph wiring

    /// Wire (or rewire) one deck's player → fadeMixer → blendMixer chain for
    /// `format`. Skips entirely when the deck is already wired for an equal
    /// format, so a same-format reload never disturbs the running graph —
    /// and a prep load on the standby deck only touches its own subgraph,
    /// never the rendering deck's.
    private func wireDeckChain(_ deckIndex: Int, format: AVAudioFormat) {
        let deck = decks[deckIndex]
        if let wired = deck.wiredFormat, wired == format { return }
        engine.connect(deck.player, to: deck.fadeMixer, format: format)
        engine.connect(deck.fadeMixer, to: blendMixer, fromBus: 0, toBus: deckIndex, format: format)
        deck.wiredFormat = format
    }

    private func wireSharedChain(format: AVAudioFormat) {
        engine.connect(blendMixer, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        sharedChainFormat = format
    }

    /// Rewire the shared blend → EQ → main chain to `format`, but only while
    /// no *other* deck is live (rendering or buffering) — changing the chain
    /// under a playing deck glitches it. When the chain can't move, the
    /// blend mixer converts the mismatched deck's rate/channels instead, so
    /// playback is always correct; the chain re-aligns to the source format
    /// on the next quiet load.
    private func rewireSharedChainIfQuiet(format: AVAudioFormat, loadingDeckIndex: Int) {
        if let current = sharedChainFormat, current == format { return }
        let otherIndex = 1 - loadingDeckIndex
        guard decks[otherIndex].streamer == nil, retiringDeckIndex == nil else { return }
        wireSharedChain(format: format)
    }

    /// Start the engine + active node when both the transport intent is
    /// "playing" and the active deck has a real format. Safe to call
    /// repeatedly. Consumes a pending quick-switch fade-in on first start.
    private func startNodeIfReady() {
        guard state == .playing, activeDeck.format != nil else { return }
        ensureEngineRunning()
        guard engine.isRunning else { return }
        if !activeDeck.player.isPlaying {
            if let fadeIn = pendingFadeInDuration {
                pendingFadeInDuration = nil
                activeDeck.fadeMixer.outputVolume = 0
                addRamp(deckIndex: activeDeckIndex, direction: .fadeIn, duration: fadeIn)
            }
            activeDeck.player.play()
        }
    }

    /// Resume the outgoing deck's tail after a pause that interrupted a fade.
    private func resumeRetiringNodeIfNeeded() {
        guard let retiring = retiringDeckIndex, engine.isRunning else { return }
        let deck = decks[retiring]
        if !deck.player.isPlaying {
            deck.player.play()
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

    private func refreshLastKnownSampleTime(of deck: Deck) {
        guard let nodeTime = deck.player.lastRenderTime,
              let playerTime = deck.player.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid
        else { return }
        deck.lastKnownSampleTime = max(0, playerTime.sampleTime)
    }

    private func position(of deck: Deck) -> Double {
        refreshLastKnownSampleTime(of: deck)
        return Double(deck.baseFrame + deck.lastKnownSampleTime) / deck.sampleRate
    }

    private func handleConfigurationChange() {
        // The engine stops itself when the output device configuration
        // changes (device unplugged, default switched while pinned-to-
        // default). If we were playing, restart on the new configuration.
        guard state == .playing else { return }
        ensureEngineRunning()
        guard engine.isRunning else { return }
        if !activeDeck.player.isPlaying {
            activeDeck.player.play()
        }
        resumeRetiringNodeIfNeeded()
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

    // MARK: - Internals: streamer events

    private func handleStreamerFinished(deckIndex: Int) {
        if deckIndex == retiringDeckIndex {
            // The outgoing track drained mid-fade — its deck is silent now;
            // finish the retirement early. The incoming ramp keeps running.
            finishRetiringDeck()
            return
        }
        guard deckIndex == activeDeckIndex else { return }

        // While paused, end-of-playback handling parks (#1048): both the
        // zero-fade join and the owner's queue advance start audio, which
        // must never happen under a paused transport. `resume()` re-runs it.
        guard state != .paused else {
            deferredActiveFinish = true
            return
        }
        finishActiveTrack()
    }

    /// Natural end of the active track. If an armed next track is fully
    /// buffered, take the zero-fade join (the gapless transition; with
    /// crossfade on it also covers the same-album rule, short tracks, and
    /// a fade window the position never crossed) instead of bouncing
    /// through the owner's rebuild path. Factored from the streamer-finished
    /// handler so `resume()` can run a finish that parked while paused.
    private func finishActiveTrack() {
        if let armed,
           transitionArmingEnabled,
           standbyReady,
           prepStartedForKey == armed.key,
           onShouldBeginCrossfade?() ?? true {
            performZeroFadeHandoff(of: armed)
            return
        }

        stopPositionTimer()
        state = .idle
        onTrackFinished?()
    }

    private func handleStreamerError(_ message: String, deckIndex: Int) {
        if deckIndex == retiringDeckIndex {
            // The outgoing tail died during its fade — it was ending anyway.
            finishRetiringDeck()
            return
        }
        if deckIndex != activeDeckIndex {
            // The *armed* track's prep stream failed. Quietly abandon the
            // crossfade — the transition falls back to the owner's rebuild
            // path at track end, which surfaces its own error if the track
            // is genuinely unreachable. Never skip the currently-playing
            // track over a preload failure.
            pipelineLog.error("DSP crossfade prep failed, falling back to rebuild: \(message, privacy: .public)")
            disarmNextTrack()
            return
        }
        // Park an active-deck failure while paused (#1048): surfacing it now
        // would let the owner's skip-on-error start the next track under a
        // paused transport. Network deaths already defer inside the streamer
        // (with a ranged reconnect on resume); this guard covers decode
        // failures — and any future failure source — the same way.
        guard state != .paused else {
            deferredActiveStreamError = message
            return
        }
        stopPositionTimer()
        state = .idle
        onStreamError?(message)
    }

    // MARK: - Internals: crossfade scheduling

    /// Driven by the 1 Hz position tick (playing only — the energy
    /// contract's existing cadence; no new timers while idle).
    ///
    /// With crossfade off but gapless on, `effectiveFadeDuration` resolves to
    /// 0 — the scheduler then only ever opens the prepare window (buffer the
    /// armed track on the standby deck), and the handoff happens at the
    /// track's natural end via the zero-fade join. Tracks with no usable
    /// duration metadata never open the window and degrade to the owner's
    /// rebuild path.
    private func evaluateCrossfadeWindow() {
        guard state == .playing,
              retiringDeckIndex == nil,
              let armed,
              transitionArmingEnabled,
              let duration = activeDeck.durationSeconds, duration > 0
        else { return }

        let sameAlbum = armed.albumKey != nil && armed.albumKey == activeDeck.albumKey
        let fadeDuration = CrossfadeSettings.effectiveFadeDuration(
            configured: crossfade.durationSeconds,
            trackDurationSeconds: duration,
            sameAlbum: sameAlbum
        )
        let remaining = duration - position(of: activeDeck)

        switch CrossfadeSettings.tickAction(
            remainingSeconds: remaining,
            fadeDuration: fadeDuration,
            prepStarted: prepStartedForKey == armed.key,
            standbyReady: standbyReady
        ) {
        case .none:
            break
        case .prepare:
            beginPrep(of: armed)
        case .beginFade:
            guard onShouldBeginCrossfade?() ?? true else { return }
            // Late starts (slow prep, seek into the window) shorten the
            // fade to what's actually left so the ramp never outlives the
            // outgoing audio by more than the scheduling slack.
            let usable = min(fadeDuration, max(remaining, CrossfadeSettings.quickSwitchDuration))
            beginAutoCrossfade(of: armed, fadeDuration: usable)
        }
    }

    /// Start buffering the armed track on the standby deck. No audio yet —
    /// the node stays stopped and the deck's fade mixer is parked at 0.
    private func beginPrep(of armed: ArmedNextTrack) {
        let deckIndex = standbyDeckIndex
        unload(deck: decks[deckIndex])
        prepStartedForKey = armed.key
        standbyReady = false
        loadTrack(
            onDeckAt: deckIndex,
            url: armed.url,
            authHeader: armed.authHeader,
            containerHint: armed.containerHint,
            durationHint: armed.durationHint,
            trackKey: armed.key,
            albumKey: armed.albumKey,
            initialGain: 0
        )
    }

    private func cancelPrep() {
        guard prepStartedForKey != nil else { return }
        prepStartedForKey = nil
        standbyReady = false
        let deckIndex = standbyDeckIndex
        guard deckIndex != retiringDeckIndex else { return }
        unload(deck: decks[deckIndex])
    }

    /// The ramped overlap: swap the active deck to the armed track, start
    /// its node at gain 0, and run both envelopes. `onCrossfadeBegan` fires
    /// after audio starts so the owner's queue advance observes a track
    /// that is genuinely audible.
    private func beginAutoCrossfade(of armed: ArmedNextTrack, fadeDuration: Double) {
        let outgoingIndex = activeDeckIndex
        let incomingIndex = standbyDeckIndex
        let incoming = decks[incomingIndex]
        guard incoming.format != nil else { return }
        ensureEngineRunning()
        guard engine.isRunning else { return }

        handoffReceipt = HandoffReceipt(
            outgoingPositionSeconds: position(of: decks[outgoingIndex]),
            mediaSourceId: armed.mediaSourceId,
            playSessionId: armed.playSessionId
        )
        pendingAdoptKey = armed.key
        let key = armed.key
        self.armed = nil
        prepStartedForKey = nil
        standbyReady = false

        retiringDeckIndex = outgoingIndex
        activeDeckIndex = incomingIndex
        incoming.fadeMixer.outputVolume = 0
        incoming.player.play()
        addRamp(deckIndex: incomingIndex, direction: .fadeIn, duration: fadeDuration)
        addRamp(deckIndex: outgoingIndex, direction: .fadeOut, duration: fadeDuration) { [weak self] in
            self?.finishRetiringDeck()
        }
        pipelineLog.info("crossfade began: \(fadeDuration, privacy: .public)s overlap")
        onCrossfadeBegan?(key)
    }

    /// The zero-fade join: the outgoing track has fully played out, and the
    /// armed one starts immediately at full gain — the issue's same-album /
    /// short-track gapless contract.
    private func performZeroFadeHandoff(of armed: ArmedNextTrack) {
        let outgoingIndex = activeDeckIndex
        let incomingIndex = standbyDeckIndex
        let incoming = decks[incomingIndex]
        ensureEngineRunning()
        guard engine.isRunning, incoming.format != nil else {
            // Can't take over — degrade to the plain finish so the owner
            // rebuilds the next track the ordinary way.
            disarmNextTrack()
            stopPositionTimer()
            state = .idle
            onTrackFinished?()
            return
        }

        handoffReceipt = HandoffReceipt(
            outgoingPositionSeconds: position(of: decks[outgoingIndex]),
            mediaSourceId: armed.mediaSourceId,
            playSessionId: armed.playSessionId
        )
        pendingAdoptKey = armed.key
        let key = armed.key
        self.armed = nil
        prepStartedForKey = nil
        standbyReady = false

        activeDeckIndex = incomingIndex
        incoming.fadeMixer.outputVolume = 1
        incoming.player.play()

        let outgoing = decks[outgoingIndex]
        unload(deck: outgoing)
        outgoing.fadeMixer.outputVolume = 1
        pipelineLog.info("zero-fade handoff")
        onCrossfadeBegan?(key)
    }

    /// Quick-switch retirement (manual skip while crossfade is on): the
    /// outgoing deck keeps rendering its already-scheduled audio through a
    /// 250 ms fade-out, then stops. Its streamer is cancelled immediately —
    /// the node holds several seconds of scheduled buffers, far more than
    /// the fade needs.
    private func beginQuickRetire(of deckIndex: Int) {
        let deck = decks[deckIndex]
        deck.generation &+= 1
        deck.streamer?.cancel()
        deck.streamer = nil
        retiringDeckIndex = deckIndex
        addRamp(
            deckIndex: deckIndex,
            direction: .fadeOut,
            duration: CrossfadeSettings.quickSwitchDuration
        ) { [weak self] in
            self?.finishRetiringDeck()
        }
    }

    /// Stop + reset the retiring deck once its fade-out (or its own stream
    /// completion) finishes. Idempotent.
    private func finishRetiringDeck() {
        guard let retiring = retiringDeckIndex else { return }
        retiringDeckIndex = nil
        ramps.removeAll { $0.deckIndex == retiring }
        let deck = decks[retiring]
        unload(deck: deck)
        deck.fadeMixer.outputVolume = 1
        if ramps.isEmpty {
            stopRampTimer()
        }
    }

    /// Hard-finish any fade in flight: outgoing deck silenced + unloaded,
    /// active deck snapped to full gain. Used by seek/stop/load, where a
    /// half-faded state has no meaning.
    private func settleFadeImmediately() {
        if let retiring = retiringDeckIndex {
            retiringDeckIndex = nil
            let deck = decks[retiring]
            unload(deck: deck)
            deck.fadeMixer.outputVolume = 1
        }
        ramps.removeAll()
        stopRampTimer()
        pendingFadeInDuration = nil
        activeDeck.fadeMixer.outputVolume = 1
    }

    // MARK: - Internals: gain ramps

    /// Install a gain envelope on a deck's fade mixer. Replaces any ramp
    /// already running on that deck. The 50 Hz ramp timer exists only while
    /// at least one ramp is active.
    private func addRamp(
        deckIndex: Int,
        direction: RampDirection,
        duration: Double,
        onComplete: (() -> Void)? = nil
    ) {
        ramps.removeAll { $0.deckIndex == deckIndex }
        guard duration > 0 else {
            decks[deckIndex].fadeMixer.outputVolume = direction == .fadeIn ? 1 : 0
            onComplete?()
            return
        }
        ramps.append(GainRamp(
            deckIndex: deckIndex,
            direction: direction,
            duration: duration,
            curve: crossfade.curve,
            onComplete: onComplete
        ))
        startRampTimerIfNeeded()
    }

    private func startRampTimerIfNeeded() {
        guard rampTimer == nil, !ramps.isEmpty else { return }
        let timer = Timer(timeInterval: rampInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rampTick()
            }
        }
        timer.tolerance = rampInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    private func suspendRampTimer() {
        rampTimer?.invalidate()
        rampTimer = nil
    }

    private func resumeRampTimerIfNeeded() {
        startRampTimerIfNeeded()
    }

    private func stopRampTimer() {
        rampTimer?.invalidate()
        rampTimer = nil
    }

    private func rampTick() {
        guard state == .playing else { return }
        guard !ramps.isEmpty else {
            stopRampTimer()
            return
        }
        var remaining: [GainRamp] = []
        var completions: [() -> Void] = []
        for var ramp in ramps {
            ramp.elapsed += rampInterval
            let progress = min(1, ramp.elapsed / ramp.duration)
            let gain: Float = ramp.direction == .fadeIn
                ? CrossfadeSettings.fadeInGain(progress: progress, curve: ramp.curve)
                : CrossfadeSettings.fadeOutGain(progress: progress, curve: ramp.curve)
            decks[ramp.deckIndex].fadeMixer.outputVolume = gain
            if progress >= 1 {
                if let onComplete = ramp.onComplete {
                    completions.append(onComplete)
                }
            } else {
                remaining.append(ramp)
            }
        }
        ramps = remaining
        if ramps.isEmpty {
            stopRampTimer()
        }
        for completion in completions {
            completion()
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
                guard self.engine.isRunning, self.activeDeck.player.isPlaying else { return }
                self.onPositionTick?(self.positionSeconds)
                self.evaluateCrossfadeWindow()
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
    /// Test seam: whether the active deck's chain reaches the main mixer
    /// through its fade mixer, the blend mixer, and the EQ — the #41 dual-
    /// deck topology with the EQ stage shared by both decks.
    var isEQWiredForTesting: Bool {
        guard eq.engine === engine, activeDeck.player.engine === engine else { return false }
        let playerFeedsFade = engine.outputConnectionPoints(for: activeDeck.player, outputBus: 0)
            .contains { $0.node === activeDeck.fadeMixer }
        let fadeFeedsBlend = engine.outputConnectionPoints(for: activeDeck.fadeMixer, outputBus: 0)
            .contains { $0.node === blendMixer }
        let blendFeedsEQ = engine.outputConnectionPoints(for: blendMixer, outputBus: 0)
            .contains { $0.node === eq }
        let eqFeedsMixer = engine.outputConnectionPoints(for: eq, outputBus: 0)
            .contains { $0.node === engine.mainMixerNode }
        return playerFeedsFade && fadeFeedsBlend && blendFeedsEQ && eqFeedsMixer
    }

    /// Test seam: the EQ must be audibly inert until #40 ships controls.
    var isEQFlatForTesting: Bool {
        eq.globalGain == 0 && eq.bands.allSatisfy { $0.bypass && $0.gain == 0 }
    }

    /// Test seam: both decks must feed the blend mixer through their own
    /// fade mixers (the #41 per-node gain stages), each parked at unity.
    var areBothDecksWiredForTesting: Bool {
        decks.allSatisfy { deck in
            let playerFeedsFade = engine.outputConnectionPoints(for: deck.player, outputBus: 0)
                .contains { $0.node === deck.fadeMixer }
            let fadeFeedsBlend = engine.outputConnectionPoints(for: deck.fadeMixer, outputBus: 0)
                .contains { $0.node === blendMixer }
            return playerFeedsFade && fadeFeedsBlend
        }
    }

    /// Test seam: per-deck fade-mixer gains, deck order (A, B).
    var fadeMixerGainsForTesting: [Float] {
        decks.map { $0.fadeMixer.outputVolume }
    }

    /// Test seam: index of the deck the transport currently drives.
    var activeDeckIndexForTesting: Int { activeDeckIndex }

    /// Test seam: the armed next track's key, if any.
    var armedTrackKeyForTesting: String? { armed?.key }

    /// Test seam: whether a fade (auto or quick-switch) is in flight.
    var isFadeInFlightForTesting: Bool { retiringDeckIndex != nil }

    /// Test seam: per-deck player gain stages (the normalization knob the
    /// fade envelopes never touch), deck order (A, B).
    var deckPlayerGainsForTesting: [Float] {
        decks.map { $0.player.volume }
    }

    /// Test seam: number of loudness resolves stashed for tracks not yet
    /// loaded on a deck.
    var pendingLoudnessGainsCountForTesting: Int { pendingLoudnessGains.count }

    /// Test seam: drive the active deck's streamer-failure handler directly —
    /// the paused-transport deferral (#1048) lives in the pipeline, not the
    /// streamer, for decode-class failures.
    func injectActiveStreamerErrorForTesting(_ message: String) {
        handleStreamerError(message, deckIndex: activeDeckIndex)
    }

    /// Test seam: drive the active deck's end-of-playback handler directly.
    func injectActiveStreamerFinishedForTesting() {
        handleStreamerFinished(deckIndex: activeDeckIndex)
    }

    /// Test seam: whether a stream event parked while paused (#1048) is
    /// awaiting `resume()`.
    var hasDeferredStreamEventForTesting: Bool {
        deferredActiveStreamError != nil || deferredActiveFinish
    }
    #endif
}
