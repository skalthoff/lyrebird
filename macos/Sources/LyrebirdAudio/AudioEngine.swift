import AVFoundation
import Foundation
@preconcurrency import LyrebirdCore

// NOTE: `AVAudioSession` is iOS-only and deliberately NOT imported here. On
// macOS there is no session/category concept — `AVPlayer` talks to CoreAudio
// directly. The app keeps playing when the window is minimized or another
// app takes focus because that's the default AppKit behaviour for a regular
// SwiftUI app. Background-audio entitlements are an iOS concept; macOS
// expects `LSApplicationCategoryType = public.app-category.music` in the
// bundle Info.plist instead. See issue #47. Do not reach for
// `AVAudioSession.sharedInstance()` here — the iOS-only symbol won't link,
// and even on a cross-platform build it would just pollute this engine with
// dead code.

/// How long the engine will tolerate `AVPlayer` sitting in
/// `.waitingToPlayAtSpecifiedRate` before treating it as a stall and
/// kicking the stream.
private let stallThreshold: TimeInterval = 5.0

/// Maximum number of silent restart attempts before the engine surfaces a
/// terminal failure to the owner. Two retries covers the "flaky Wi-Fi
/// transient" case without turning a genuine outage into a busy-loop.
private let maxAutoRetries: Int = 2

/// Observer contract for transport failures surfaced by [`AudioEngine`].
///
/// The engine does not render UI — it only tells the owner that the stream
/// stalled (retry in progress) or ultimately failed. See issue #439.
///
/// Every method is `@MainActor`-bound so implementors don't have to hop
/// queues before touching SwiftUI state.
@MainActor
public protocol AudioEngineDelegate: AnyObject {
    /// Called when the engine has been in
    /// `.waitingToPlayAtSpecifiedRate` for longer than the stall threshold
    /// and is about to restart the stream. The owner typically shows a
    /// transient toast ("Stalled, retrying…").
    func audioEngineDidStall()

    /// Called when the engine has exhausted its auto-retry budget. The
    /// owner should surface a terminal error with a tap-to-retry
    /// affordance — the engine will NOT retry again on its own.
    func audioEngineDidFail(_ message: String)

    /// Called when an `AVPlayerItem` reports a transient network failure
    /// (`NSURLErrorNetworkConnectionLost` / `Timeout` /
    /// `NotConnectedToInternet`). The engine has already cancelled the
    /// blind stall watchdog and triggered a queue advance via
    /// `onTrackEnded`; the owner only needs to surface a transient toast
    /// (e.g. "Connection lost — skipping"). See issue #806.
    func audioEngineDidEncounterTransientError(_ message: String)
}

public extension AudioEngineDelegate {
    /// Default no-op so existing conformers don't have to implement the
    /// new transient-error hook to compile (#806).
    func audioEngineDidEncounterTransientError(_ message: String) {}
}

/// `AVQueuePlayer`-backed audio engine. Reports transport state back to the
/// Rust core so other parts of the app can observe it via `core.status()`.
///
/// Gapless playback (issue #580): `AVQueuePlayer` preloads the next
/// `AVPlayerItem` while the current one is still playing and transitions
/// between them without silence. Call `preloadNextTrack(_:)` whenever the
/// caller knows which track follows the current one — typically right after
/// a `play(track:)` call and again inside `onTrackEnded`. The queue player
/// will splice the pre-built item in gaplessly.
@MainActor
public final class AudioEngine: NSObject {
    private let core: LyrebirdCore
    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    /// KVO observation on `AVQueuePlayer.currentItem`. Fires whenever the
    /// queue player auto-advances to the next item so we can re-wire the
    /// `AVPlayerItemDidPlayToEndTime` notification to the new `currentItem`
    /// and update `currentStreamURL` for stall recovery.
    private var currentItemObservation: NSKeyValueObservation?
    /// KVO observations on the live `AVPlayerItem` (#806). Re-attached
    /// every time `AVQueuePlayer.currentItem` changes so we always watch
    /// the item that's actually playing — not the one that was current
    /// at `play(track:)` time. `.error` fires when the byte pump dies
    /// (e.g. CoreMedia surfaces a -1005); `.status` fires when an item
    /// flips to `.failed` before playback can start (early-track death).
    private var itemErrorObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?

    /// The URL + auth header of the item currently loaded into the player.
    /// Captured on `play(_:)` so we can rebuild a fresh `AVPlayerItem` when
    /// recovering from a stall.
    private var currentStreamURL: URL?
    private var currentAuthHeader: String?

    /// Pending stall-detection work item. Scheduled the moment
    /// `timeControlStatus` flips to `.waitingToPlayAtSpecifiedRate`;
    /// cancelled when playback resumes or the engine tears down.
    private var stallWorkItem: DispatchWorkItem?

    /// How many silent restart attempts we've made on the *current* stream.
    /// Reset to 0 every time `play(_:)` loads a brand-new track.
    private var stallRetryCount: Int = 0

    /// Monotonically-increasing counter used to detect stale seek completions
    /// (#582). Each call to `seek(toSeconds:)` increments this; the completion
    /// closure captures the value at dispatch time and discards the callback if
    /// a newer seek has already been issued.
    private var seekGeneration: Int = 0

    /// Called when AVPlayer reaches the end of the current item, so the
    /// owner (AppModel) can advance the queue.
    public var onTrackEnded: (() -> Void)?

    /// Single writer of `MPNowPlayingInfoCenter.nowPlayingInfo`. Held weakly
    /// because the session is owned by `AppModel` — the engine just notifies
    /// it of transport state transitions. See `MediaSession.swift` and
    /// issues #29 / #48.
    public weak var mediaSession: MediaSession?

    /// Receives stall / terminal-failure notifications for issue #439.
    /// Held weakly — the owner (`AppModel`) has the strong reference.
    public weak var delegate: AudioEngineDelegate?

    public init(core: LyrebirdCore) {
        self.core = core
        super.init()
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
        }
    }

    // MARK: - Private helpers

    /// Resolve `(MediaSourceId, PlaySessionId)` via `POST /PlaybackInfo`
    /// ahead of stream-URL construction. Both are `nil` on error so the
    /// caller falls back to the server's default source and an
    /// opportunistic (uncorrelated) session — the URL is still playable.
    private func resolvePlaybackSource(for trackId: String) -> (mediaSourceId: String?, playSessionId: String?) {
        let opts = PlaybackInfoOpts(
            userId: nil,
            startTimeTicks: nil,
            mediaSourceId: nil,
            maxStreamingBitrate: nil,
            enableDirectPlay: nil,
            enableDirectStream: nil,
            enableTranscoding: nil,
            autoOpenLiveStream: nil,
            deviceProfile: nil
        )
        guard let info = try? core.playbackInfo(itemId: trackId, opts: opts) else {
            return (nil, nil)
        }
        return (info.mediaSources.first?.id, info.playSessionId)
    }

    /// The currently-reporting session, captured at the last
    /// `reportPlaybackStarted` call. Held so `stop` / track-change can emit a
    /// matching `reportPlaybackStopped` with the same `itemId` + source +
    /// session triple — Jellyfin requires those to line up server-side.
    private var reportingItemId: String?
    private var reportingMediaSourceId: String?
    private var reportingPlaySessionId: String?

    private func positionTicks() -> Int64 {
        guard let player, let item = player.currentItem else { return 0 }
        let seconds = CMTimeGetSeconds(item.currentTime())
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }

    /// Fire `POST /Sessions/Playing` for the track that just became the
    /// AVQueuePlayer's `currentItem`. Best-effort — Jellyfin accepts the
    /// stream regardless of whether the session-begin report landed, so we
    /// swallow errors rather than surfacing them to the UI.
    private func reportStarted(
        trackId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        playMethod: String?
    ) {
        let info = PlaybackStartInfo(
            itemId: trackId,
            sessionId: nil,
            mediaSourceId: mediaSourceId,
            audioStreamIndex: nil,
            playSessionId: playSessionId,
            playMethod: playMethod,
            positionTicks: 0,
            playbackStartTimeTicks: nil,
            volumeLevel: nil,
            playlistIndex: nil,
            playlistLength: nil,
            canSeek: true,
            isPaused: false,
            isMuted: false
        )
        try? core.reportPlaybackStarted(info: info)
        reportingItemId = trackId
        reportingMediaSourceId = mediaSourceId
        reportingPlaySessionId = playSessionId
    }

    /// Fire `POST /Sessions/Playing/Stopped` for the previously-reported
    /// session, then clear the reporting triple. Safe to call when nothing
    /// is active — it no-ops when `reportingItemId` is `nil`.
    private func reportStopped() {
        guard let itemId = reportingItemId else { return }
        let info = PlaybackStopInfo(
            itemId: itemId,
            failed: false,
            positionTicks: positionTicks(),
            mediaSourceId: reportingMediaSourceId,
            playSessionId: reportingPlaySessionId,
            sessionId: nil
        )
        try? core.reportPlaybackStopped(info: info)
        reportingItemId = nil
        reportingMediaSourceId = nil
        reportingPlaySessionId = nil
    }

    /// Fire a single `PlaybackProgressInfo` report — used on pause / resume /
    /// seek transitions so the server sees state changes promptly rather
    /// than waiting for the next heartbeat tick. Best-effort: swallow
    /// errors, the periodic heartbeat (if running) will catch up.
    private func reportProgressSnapshot(isPaused: Bool) {
        guard let itemId = reportingItemId else { return }
        let info = PlaybackProgressInfo(
            itemId: itemId,
            failed: false,
            isPaused: isPaused,
            isMuted: false,
            positionTicks: positionTicks(),
            mediaSourceId: reportingMediaSourceId,
            playSessionId: reportingPlaySessionId,
            playMethod: nil,
            volumeLevel: nil,
            playbackRate: nil,
            audioStreamIndex: nil,
            sessionId: nil
        )
        try? core.reportPlaybackProgress(info: info)
    }

    // MARK: - Public

    public func play(track: Track) throws {
        // Resolve media source + play session id via PlaybackInfo so the
        // server picks the right source for multi-version items and can
        // correlate subsequent /Sessions/Playing* reports with the stream.
        // Falling back to nil is harmless — the server just picks its
        // default source and correlation stays opportunistic.
        let (mediaSourceId, playSessionId) = resolvePlaybackSource(for: track.id)
        let urlString = try core.streamUrl(
            trackId: track.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId
        )
        guard let url = URL(string: urlString) else {
            throw AudioEngineError.invalidURL(urlString)
        }
        core.setPlaySessionId(playSessionId: playSessionId)
        let authHeader = try core.authHeader()
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Authorization": authHeader
                ]
            ]
        )
        let item = AVPlayerItem(asset: asset)

        // Tear down the old player cleanly before switching.
        removePlayerObservers()
        // AVQueuePlayer: pass the first item at construction time, which
        // sets it as currentItem without an extra insert call.
        let newPlayer = AVQueuePlayer(items: [item])
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        self.player = newPlayer

        // Remember the stream so `recoverFromStall` can rebuild a fresh
        // `AVPlayerItem` without re-asking the core for a URL (which would
        // cost an extra async hop on the main actor).
        self.currentStreamURL = url
        self.currentAuthHeader = authHeader
        // Each new track gets a fresh budget for silent restart attempts —
        // a genuine library-wide outage shouldn't poison the *next* song.
        self.stallRetryCount = 0

        attachPlayerObservers(to: newPlayer, item: item)

        // Any previous session needs a matching Stopped report before we
        // start the new one — Jellyfin keys sessions by PlaySessionId and
        // leaks a transcode job otherwise.
        reportStopped()

        core.markTrackStarted(track: track)
        core.markState(state: .playing)
        newPlayer.play()
        // Publish the new track to MPNowPlayingInfoCenter. `MediaSession`
        // reads the current position via its delegate, so `core.markState`
        // must run first so the snapshot is up to date. See issue #29.
        mediaSession?.trackChanged(track)

        // POST /Sessions/Playing so Jellyfin shows "Now Playing on macOS"
        // on other clients and the heartbeat has a session to report against.
        reportStarted(
            trackId: track.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            playMethod: nil
        )

        // (Re)start the 5s heartbeat against the new PlaySessionId so
        // Jellyfin's "last seen" timer for this session stays fresh and the
        // server's resume-from-position store follows playback. Calling
        // start_heartbeat on every play is intentional — the core cancels
        // any prior interval before installing the new one.
        core.startHeartbeat(intervalSecs: 5, playSessionId: playSessionId)
    }

    public func pause() {
        player?.pause()
        core.markState(state: .paused)
        // `rateObservation` below also fires `rateChanged`, but that
        // callback is async (Task hop) — calling here keeps the widget in
        // sync within the same run loop turn for responsiveness. Duplicate
        // calls are cheap: MediaSession.rateChanged is idempotent.
        mediaSession?.rateChanged(isPlaying: false)
        reportProgressSnapshot(isPaused: true)
    }

    public func resume() {
        player?.play()
        core.markState(state: .playing)
        mediaSession?.rateChanged(isPlaying: true)
        reportProgressSnapshot(isPaused: false)
    }

    public func stop() {
        cancelStallWatchdog()
        // Emit Stopped BEFORE draining the queue so positionTicks still
        // reflects the last known playback position.
        reportStopped()
        core.stopHeartbeat()
        player?.pause()
        // removeAllItems() drains the AVQueuePlayer's item list (including any
        // pre-loaded next-track entry) and implicitly nulls currentItem — the
        // equivalent of replaceCurrentItem(with: nil) for a queue player.
        player?.removeAllItems()
        removePlayerObservers()
        player = nil
        currentStreamURL = nil
        currentAuthHeader = nil
        stallRetryCount = 0
        core.stop()
        mediaSession?.trackChanged(nil)
    }

    public func seek(toSeconds seconds: Double) {
        guard let player = player else { return }
        // #582: Cancel any in-flight seek before issuing the new one so
        // rapid scrubber drags don't race against each other.
        player.currentItem?.cancelPendingSeeks()
        seekGeneration &+= 1
        let generation = seekGeneration
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            // Ignore completions from seeks that were superseded by a
            // newer drag event — `finished` is `false` for pre-empted seeks,
            // but we gate on generation equality instead so we never update
            // elapsed to a stale position even on a race between two seeks
            // that both happen to complete (the earlier one finishing after
            // the later one due to scheduling). Push the post-seek elapsed to
            // MPNowPlayingInfoCenter so the widget confirms the scrub without
            // waiting for the next status tick (issue #32).
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.mediaSession?.seeked(to: seconds)
                // Fire a PlaybackProgressInfo post-seek so the server's
                // "last position" reflects the scrub immediately rather
                // than waiting for the next heartbeat tick — this is what
                // powers resume-from-position on other clients.
                let paused = self.player?.rate == 0
                self.reportProgressSnapshot(isPaused: paused)
            }
        }
    }

    public func setVolume(_ v: Float) {
        player?.volume = max(0, min(1, v))
        core.setVolume(volume: v)
    }

    /// Pre-load the next track into the `AVQueuePlayer` so it can transition
    /// gaplessly when the current item reaches end-of-file.
    ///
    /// The caller should invoke this:
    ///   1. Right after `play(track:)` when the next queue item is known.
    ///   2. Inside `onTrackEnded` once `AppModel` has advanced the queue —
    ///      pass the *new* next track (queue position + 1) so the player
    ///      always has one item queued ahead.
    ///
    /// Calling this when there is no next track (end of queue) is a no-op.
    /// `AVQueuePlayer.insert(_:after:nil)` appends after the last item, which
    /// is what we want. Existing queued-but-not-yet-playing items are replaced
    /// so rapid skip-next doesn't accumulate stale entries.
    public func preloadNextTrack(_ track: Track) throws {
        guard let player else { return }

        // Preload uses the same PlaybackInfo resolution as play(track:)
        // so the gapless transition doesn't swap to a different source
        // mid-queue. The session id isn't installed yet — setPlaySessionId
        // runs when the item actually becomes current (see play path).
        let (mediaSourceId, playSessionId) = resolvePlaybackSource(for: track.id)
        let urlString = try core.streamUrl(
            trackId: track.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId
        )
        guard let url = URL(string: urlString) else {
            throw AudioEngineError.invalidURL(urlString)
        }
        let authHeader = try core.authHeader()
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Authorization": authHeader
                ]
            ]
        )
        let nextItem = AVPlayerItem(asset: asset)

        // Remove any previously queued (not-yet-playing) items so we never
        // accumulate stale entries from rapid queue mutations. `items()` returns
        // all items including the current one; skip index 0 (currently playing).
        let queued = player.items()
        for item in queued.dropFirst() {
            player.remove(item)
        }

        // Append the new item after the current one (or as the only item if
        // the player was empty — shouldn't happen in normal flow but safe).
        player.insert(nextItem, after: player.currentItem)
    }

    // MARK: - Observers

    private func attachPlayerObservers(to player: AVQueuePlayer, item: AVPlayerItem) {
        // 1s interval (was 0.5s in rc<=10). The observer fires every interval
        // regardless of play state — when paused the time stays put but the
        // closure still fires and crosses an FFI boundary into Rust to take
        // the core's `parking_lot` mutex. Halving the cadence directly halves
        // that idle CPU + main-queue traffic, and the elapsed-time widget
        // interpolates between ticks (issue #48) so 1s granularity is
        // visually identical to 0.5s for the progress bar.
        let interval = CMTime(seconds: 1.0, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            // Skip the FFI write entirely when the player isn't advancing.
            // `rate == 0` covers paused, stalled, and "buffering past EOF"
            // states; in all of them `time.seconds` would just write back
            // the same value and burn the lock. Reading `rate` is a cheap
            // KVO-backed property access on AVPlayer, no async needed.
            guard player.rate != 0 else { return }
            let seconds = time.seconds.isFinite ? time.seconds : 0
            self.core.markPosition(seconds: seconds)
        }

        // Wire the end-of-item notification to the first item. When
        // AVQueuePlayer auto-advances this observer is replaced inside the
        // currentItem KVO handler below so every item in the queue fires
        // onTrackEnded correctly.
        wireEndObserver(to: item)

        // Watch the live item for transient network failures (#806). The
        // observers are re-attached inside the currentItem KVO handler
        // below so they follow gapless auto-advance.
        attachItemFailureObservers(to: item)

        // currentItem KVO — fires when AVQueuePlayer advances to the next
        // pre-loaded item (the gapless transition). We use it to:
        //   1. Re-wire `endObserver` to the new currentItem.
        //   2. Update `currentStreamURL` so stall recovery targets the right URL.
        //   3. Fire `onTrackEnded` so AppModel can update metadata and pre-load
        //      the track after the one that just started.
        currentItemObservation = player.observe(\.currentItem, options: [.new, .old]) { [weak self] player, change in
            // Guard: only act when the item actually changed (not on initial
            // attachment where old == new == firstItem).
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor in
                guard let self else { return }
                // Re-register end-of-item notification for the newly-current item.
                if let current = player.currentItem {
                    self.wireEndObserver(to: current)
                    // Re-attach failure KVO so transient-error detection
                    // follows gapless auto-advance instead of being pinned
                    // to the item that was current at play(track:) time
                    // (#806).
                    self.attachItemFailureObservers(to: current)
                }
                // Reset stall URL tracking — the new item has its own URL.
                if let urlAsset = player.currentItem?.asset as? AVURLAsset {
                    self.currentStreamURL = urlAsset.url
                }
                self.stallRetryCount = 0
            }
        }

        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor in
                guard let self = self else { return }
                let isPlaying = rate != 0
                if isPlaying {
                    self.core.markState(state: .playing)
                } else {
                    self.core.markState(state: .paused)
                }
                // Covers implicit rate flips that don't go through
                // pause()/resume() — e.g. buffering-induced stalls. Per
                // issue #48, the widget's progress calc depends on
                // playbackRate being accurate, so any rate change has to
                // publish.
                self.mediaSession?.rateChanged(isPlaying: isPlaying)
            }
        }

        // Stall detection (issue #439). `timeControlStatus` tells us why
        // the player is or isn't moving:
        //   * `.playing` — audio is flowing.
        //   * `.paused` — user-initiated.
        //   * `.waitingToPlayAtSpecifiedRate` — the buffer drained and the
        //     network isn't catching up. AVPlayer already *wants* to play,
        //     so a brief spell here is normal; anything past
        //     `stallThreshold` is a real hang worth kicking.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self = self else { return }
                switch status {
                case .waitingToPlayAtSpecifiedRate:
                    self.scheduleStallWatchdog()
                case .playing, .paused:
                    // Playback recovered (or user paused) — drop any pending
                    // restart so we don't nuke a perfectly healthy stream.
                    self.cancelStallWatchdog()
                @unknown default:
                    break
                }
            }
        }
    }

    /// Attach (or re-attach) KVO on the given item's `.error` and `.status`
    /// so we can detect transient-network failures within ~1s instead of
    /// waiting for the 5s blind-rebuild watchdog (#806).
    ///
    /// `.error` covers mid-stream byte-pump deaths (the -1005 / -1001 /
    /// -1009 path described in the issue). `.status` covers items that
    /// flip to `.failed` before they ever reach `.readyToPlay` (early-
    /// track death — same root causes, different surface). Both call
    /// through to `handleItemFailure(_:)` which inspects the error and
    /// either short-circuits to fail-fast or no-ops for unrelated codes
    /// (which the existing stall watchdog still handles).
    private func attachItemFailureObservers(to item: AVPlayerItem) {
        itemErrorObservation?.invalidate()
        itemErrorObservation = item.observe(\.error, options: [.new]) { [weak self] item, _ in
            guard let error = item.error as NSError? else { return }
            Task { @MainActor in
                self?.handleItemFailure(error)
            }
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed, let error = item.error as NSError? else { return }
            Task { @MainActor in
                self?.handleItemFailure(error)
            }
        }
    }

    /// `true` if `error` is one of the transient network errors that the
    /// fail-fast path handles (#806). `NSURLErrorDomain` surfaces from
    /// `URLSession` directly; `CoreMediaErrorDomain` surfaces the same
    /// codes from the AVFoundation byte pump.
    private func isTransientNetworkError(_ error: NSError) -> Bool {
        let transientCodes: Set<Int> = [
            NSURLErrorNetworkConnectionLost,   // -1005
            NSURLErrorTimedOut,                // -1001
            NSURLErrorNotConnectedToInternet,  // -1009
        ]
        let transientRawCodes: Set<Int> = [-1005, -1001, -1009]
        if error.domain == NSURLErrorDomain {
            return transientCodes.contains(error.code)
        }
        // CoreMediaErrorDomain proxies the same numeric codes during HTTP
        // byte-pump death. There's no public symbolic enum, so match by
        // raw code value.
        if error.domain == "CoreMediaErrorDomain" {
            return transientRawCodes.contains(error.code)
        }
        // The underlying error chain occasionally carries the NSURL code
        // even when the top-level domain is something else.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isTransientNetworkError(underlying)
        }
        return false
    }

    /// Branch on whether the failing item carries a transient network
    /// error code. For transient codes we fail fast: cancel the blind
    /// 5s stall watchdog, notify the delegate so the UI can surface a
    /// transient toast, and signal `onTrackEnded` so AppModel advances
    /// the queue (same contract as natural end-of-item). Non-transient
    /// errors fall through to the existing stall path. See #806.
    private func handleItemFailure(_ error: NSError) {
        guard isTransientNetworkError(error) else { return }
        // Idempotent: invalidate the per-item observers so a follow-up
        // `.status` flip on the same dead item doesn't re-fire this path
        // before the queue advance lands.
        itemErrorObservation?.invalidate()
        itemErrorObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        // Short-circuit the 5s blind-rebuild path — rebuilding the same
        // URL against the same broken connection would just refail.
        cancelStallWatchdog()
        // Surface the transient indicator and advance the queue. The
        // delegate hook is best-effort; the `onTrackEnded` callback is
        // the same path natural end-of-item takes, so AppModel's queue
        // bookkeeping stays consistent.
        delegate?.audioEngineDidEncounterTransientError("Connection lost — skipping")
        core.markState(state: .ended)
        onTrackEnded?()
    }

    /// Register (or re-register) `endObserver` against `item`. Called once at
    /// player setup and again from the `currentItem` KVO handler whenever
    /// `AVQueuePlayer` gaplessly advances to the next item.
    private func wireEndObserver(to item: AVPlayerItem) {
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Note: by the time this fires, AVQueuePlayer has already
            // advanced currentItem to the next queued item (gapless
            // transition). We mark the state as ended and let AppModel
            // advance its logical queue position + call preloadNextTrack
            // for the item after that.
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }
    }

    private func removePlayerObservers() {
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
        }
        endObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        itemErrorObservation?.invalidate()
        itemErrorObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    // MARK: - Stall recovery (issue #439)

    /// Queue a stall handler to fire after [`stallThreshold`]. If
    /// playback resumes within the window the work item is cancelled in
    /// [`cancelStallWatchdog`]; otherwise [`handleStallTimeout`] fires.
    ///
    /// Scheduling is idempotent — repeatedly calling this while the player
    /// keeps flipping in and out of `.waitingToPlayAtSpecifiedRate` only
    /// keeps one timer alive at a time.
    private func scheduleStallWatchdog() {
        stallWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.handleStallTimeout()
            }
        }
        stallWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + stallThreshold, execute: item)
    }

    private func cancelStallWatchdog() {
        stallWorkItem?.cancel()
        stallWorkItem = nil
    }

    /// Called from the watchdog when the player has been stuck in
    /// `.waitingToPlayAtSpecifiedRate` for [`stallThreshold`].
    ///
    /// On the first two stalls of a given stream we notify the delegate
    /// that a silent retry is in flight and rebuild the `AVPlayerItem`
    /// against the same URL — that's enough to dislodge most transient
    /// CDN / Wi-Fi blips. On the third stall we give up and surface a
    /// terminal failure so the UI can offer tap-to-retry.
    private func handleStallTimeout() {
        // Guard against a stale timer firing after the user already
        // stopped the engine or moved on to a different track.
        guard let player = self.player, let url = self.currentStreamURL else {
            return
        }
        // If playback resumed between the timer firing and us getting
        // onto the main actor, bail — no retry needed.
        if player.timeControlStatus != .waitingToPlayAtSpecifiedRate {
            return
        }

        stallRetryCount += 1
        if stallRetryCount > maxAutoRetries {
            delegate?.audioEngineDidFail("Couldn't play, tap to retry.")
            return
        }

        delegate?.audioEngineDidStall()
        recoverFromStall(player: player, url: url)
    }

    /// Rebuild `AVPlayerItem` from the remembered URL + auth header and
    /// swap it in via `replaceCurrentItem`. This restarts the HTTP fetch
    /// without tearing the player down, so `rate` / `timeControlStatus`
    /// observers remain wired and the UI doesn't flicker.
    ///
    /// `AVQueuePlayer` inherits `replaceCurrentItem` from `AVPlayer`, so this
    /// call drops any pre-loaded next-item from the queue. The owner's
    /// `onTrackEnded` handler should call `preloadNextTrack` again once
    /// playback recovers.
    private func recoverFromStall(player: AVQueuePlayer, url: URL) {
        let options: [String: Any]
        if let header = currentAuthHeader {
            options = [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": header]
            ]
        } else {
            options = [:]
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)

        // Re-wire the end observer to the fresh item — `replaceCurrentItem`
        // does not re-fire the notification for the old item. Keeping
        // `rateObservation` / `timeControlObservation` / `currentItemObservation`
        // in place is intentional; all three target the AVQueuePlayer, not the
        // item, so they stay valid across the swap.
        wireEndObserver(to: item)
        // Re-attach failure KVO on the rebuilt item too (#806). If the
        // rebuilt stream also surfaces -1005/-1001/-1009 we still fail
        // fast on the next refailure instead of grinding through more
        // 5s rebuild cycles.
        attachItemFailureObservers(to: item)

        player.replaceCurrentItem(with: item)
        player.play()
    }
}

enum AudioEngineError: LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid stream URL: \(s)"
        }
    }
}
