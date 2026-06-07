import AppKit
import Foundation
@preconcurrency import LyrebirdCore
import MediaPlayer

/// Abstraction the `MediaSession` uses to route remote-command events
/// (play/pause from Control Center, media keys, Bluetooth headsets, etc.)
/// back into the app's normal transport layer.
///
/// The command handlers stay side-effect-minimal by design: they call through
/// to these methods rather than poking `AudioEngine` directly, so the same
/// code path runs whether a human or a Bluetooth headset triggers playback
/// changes. See issue #31.
@MainActor
public protocol MediaSessionDelegate: AnyObject {
    var currentStatus: PlayerStatus { get }
    func mediaSessionTogglePlayPause()
    func mediaSessionPlay()
    func mediaSessionPause()
    func mediaSessionStop()
    func mediaSessionSkipNext()
    func mediaSessionSkipPrevious()
    func mediaSessionSeek(toSeconds seconds: Double)
    /// Toggle the queue-wide shuffle mode, driven by Control Center's
    /// `MPChangeShuffleModeCommand`. Callers must update the core via
    /// `core.setShuffle(_:)` and refresh `PlayerStatus` observers so the UI
    /// tracks the new mode. See issue #34.
    func mediaSessionSetShuffle(_ on: Bool)
    /// Set the queue-wide repeat mode, driven by Control Center's
    /// `MPChangeRepeatModeCommand`. `.off` stops at end-of-queue, `.one`
    /// replays the current track, `.all` wraps around. See issue #34.
    func mediaSessionSetRepeatMode(_ mode: RepeatMode)
    /// Toggle the currently-playing track's favorite state. Returns the
    /// target state the implementation is attempting to apply so
    /// `MediaSession` can flip `likeCommand.isActive` immediately — the
    /// eventual server response may invalidate that on rollback, but the
    /// latency between tap and state refresh is what the user perceives.
    /// Return `nil` if no track is active (command should be treated as
    /// no-op). See issue #35.
    func mediaSessionToggleFavorite() -> Bool?
    /// Authoritative favorite flag for the currently-playing track, used to
    /// drive `likeCommand.isActive` on a transport refresh. The delegate
    /// reconciles its local cache against the server snapshot, so this is
    /// fresher than `currentStatus.currentTrack?.isFavorite` (which the core
    /// does not mutate on a favorite toggle). Returns `false` when no track
    /// is active. See issue #460.
    func mediaSessionCurrentTrackIsFavorite() -> Bool
    /// Build the artwork URL for a track. Returns `nil` when the track has no
    /// image tag or when the auth context isn't ready. `MediaSession` uses
    /// this rather than holding a reference to `LyrebirdCore` so the session
    /// can be unit-tested with a mock delegate.
    func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL?
    /// Authorization header value for artwork fetches. Matches the header
    /// `AudioEngine` attaches to `AVURLAsset` so the Jellyfin server accepts
    /// the image request.
    func mediaSessionAuthorizationHeader() -> String?
}

/// Single writer of `MPNowPlayingInfoCenter.default().nowPlayingInfo` and
/// owner of `MPRemoteCommandCenter.shared()` handlers. Every other system
/// integration (Control Center, AVRCP, media keys, Dock) reads through this;
/// `nowPlayingInfo` is mutated from exactly one place so `elapsedPlaybackTime`
/// and `playbackRate` stay consistent. See issues #29, #30, #31, #32, #47, #48.
///
/// Update strategy (issue #48): elapsed + rate are only written on state
/// transitions (track change, play, pause, seek). The Control Center widget
/// computes progress from
/// `elapsed + (wallClockNow - lastUpdateTime) * playbackRate`, so continuously
/// pushing elapsed on every 0.5s tick causes the scrubber to stutter. The
/// Rust-side `core.markPosition` tick (used for scrobbling thresholds and UI
/// updates) is intentionally NOT fed to `MPNowPlayingInfoCenter`.
@MainActor
public final class MediaSession {
    private weak var delegate: MediaSessionDelegate?
    private let artworkCache: NSCache<NSString, MPMediaItemArtwork> = {
        let cache = NSCache<NSString, MPMediaItemArtwork>()
        cache.countLimit = 100
        return cache
    }()
    private var artworkTask: Task<Void, Never>?
    private var currentTrackID: String?
    /// Last `(elapsed, rate)` pair published via `updateElapsedAndRate`. The
    /// rate/seek transition hooks fire repeatedly with values the system
    /// already has (e.g. a pause when already paused), and each redundant
    /// write is an IPC round-trip to `mediaremoted` that the system logs as
    /// "Setting identical nowPlayingInfo, skipping update." Short-circuit
    /// those no-ops here (issue #807).
    private var lastPublishedElapsed: Double?
    private var lastPublishedRate: Float?

    /// Construct the session with no delegate. Call `attach(delegate:)` from
    /// the owner's initializer once `self` is available. This two-phase
    /// hand-off lets the delegate (`AppModel`) own the session as a
    /// non-optional `let` without fighting Swift's initialization order.
    public init() {
        configureRemoteCommands()
    }

    /// Wire up the delegate. Idempotent — replacing a delegate is safe, but
    /// the expected pattern is to call this exactly once from `AppModel.init`.
    public func attach(delegate: MediaSessionDelegate) {
        self.delegate = delegate
        refreshRemoteCommandEnablement()
    }

    deinit {
        artworkTask?.cancel()
    }

    // MARK: - Public transition hooks
    //
    // `AudioEngine` / `AppModel` call these when a state change happens. They
    // are the only paths that touch `MPNowPlayingInfoCenter.nowPlayingInfo`,
    // which is how issue #29's "single writer" invariant is enforced.

    /// Called when the currently-playing track changes (or becomes `nil`).
    /// Writes the full property set (title/artist/album/duration/queue) and
    /// kicks off an async artwork fetch. Resets elapsed to zero and pushes
    /// the initial rate based on `status.state`.
    public func trackChanged(_ track: Track?) {
        guard let delegate else { return }

        if track == nil {
            currentTrackID = nil
            lastPublishedElapsed = nil
            lastPublishedRate = nil
            artworkTask?.cancel()
            artworkTask = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            refreshRemoteCommandEnablement()
            return
        }

        let track = track!
        currentTrackID = track.id

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.name
        info[MPMediaItemPropertyArtist] = track.artistName
        if let album = track.albumName, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        info[MPMediaItemPropertyAlbumArtist] = track.artistName
        // `Track.durationSeconds` lives as a Swift convenience in the
        // top-level app target; compute the same thing inline here so
        // `LyrebirdAudio` doesn't need to depend on it.
        info[MPMediaItemPropertyPlaybackDuration] = Double(track.runtimeTicks) / 10_000_000.0
        info[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        let status = delegate.currentStatus
        let elapsed = max(0, status.positionSeconds)
        let rate: Float = status.state == .playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        // `MPNowPlayingInfoPropertyCurrentPlaybackDate` lets AirPlay receivers
        // (HomePod, Apple TV) derive an absolute wall-clock timestamp from the
        // track's start time and display a meaningful progress bar without
        // polling the source device. Compute it as "now minus the elapsed
        // playback position" so the receiver can extrapolate forward at the
        // given `playbackRate`. Only set while playing — a paused receiver
        // must not auto-advance its own scrubber.
        if rate > 0 {
            info[MPNowPlayingInfoPropertyCurrentPlaybackDate] = Date(timeIntervalSinceNow: -elapsed)
        }
        lastPublishedElapsed = elapsed
        lastPublishedRate = rate
        if status.queueLength > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = NSNumber(value: status.queuePosition)
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = NSNumber(value: status.queueLength)
        }

        // Keep the previous artwork in place until the new one decodes —
        // clearing it first shows a blank square mid-transition (see #30).
        // Only carry the previous art over when the new track actually has an
        // image to fetch; a no-art track starts blank so the prior track's
        // cover never lingers under it (#162).
        if let cached = artworkCache.object(forKey: Self.artworkCacheKey(for: track)) {
            info[MPMediaItemPropertyArtwork] = cached
        } else if track.imageTag != nil,
                  let lastArt = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = lastArt
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Kick off artwork fetch. Cancels any in-flight fetch for the
        // previous track so rapid skip-next doesn't show the prior track's
        // art (acceptance criterion on #30).
        artworkTask?.cancel()
        let trackID = track.id
        artworkTask = Task { [weak self] in
            await self?.loadArtwork(for: track, expectedTrackID: trackID)
        }

        refreshRemoteCommandEnablement()
    }

    /// Called when the AVPlayer rate flips between 0 and 1 (play <-> pause).
    /// Updates `elapsedPlaybackTime` + `playbackRate` so Bluetooth AVRCP
    /// doesn't see a stale rate.
    public func rateChanged(isPlaying: Bool) {
        guard let delegate, currentTrackID != nil else { return }
        updateElapsedAndRate(
            elapsed: delegate.currentStatus.positionSeconds,
            rate: isPlaying ? 1.0 : 0.0
        )
    }

    /// Called after the engine seeks to a new position. Updates
    /// `elapsedPlaybackTime` immediately so the widget confirms the scrub
    /// without waiting for the next position tick (issue #32).
    public func seeked(to seconds: Double) {
        guard let delegate, currentTrackID != nil else { return }
        let rate: Float = delegate.currentStatus.state == .playing ? 1.0 : 0.0
        updateElapsedAndRate(elapsed: seconds, rate: rate)
    }

    /// Called when the queue position or length changes (skip next/prev,
    /// setQueue). Refreshes the queue index on the now-playing info and
    /// re-evaluates `nextTrackCommand` / `previousTrackCommand` enablement.
    public func queueChanged() {
        guard let delegate, currentTrackID != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let status = delegate.currentStatus
        if status.queueLength > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = NSNumber(value: status.queuePosition)
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = NSNumber(value: status.queueLength)
        } else {
            info.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueIndex)
            info.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueCount)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        refreshRemoteCommandEnablement()
    }

    /// Re-sync the remote-command surface (Control Center / AVRCP) to the
    /// delegate's current `PlayerStatus`. Call this after an app-UI-driven
    /// change to shuffle, repeat, or the favorite flag so Control Center's
    /// indicators reflect state that didn't originate from a remote command
    /// (#460). `trackChanged` / `queueChanged` / the remote-command callbacks
    /// already refresh on their own; this is the hook for everything else.
    public func refreshTransportState() {
        refreshRemoteCommandEnablement()
    }

    // MARK: - Internals

    private func updateElapsedAndRate(elapsed: Double, rate: Float) {
        let clamped = max(0, elapsed)
        if lastPublishedElapsed == clamped, lastPublishedRate == rate {
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clamped
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        // Keep `currentPlaybackDate` in sync with each rate / seek transition
        // so AirPlay receivers (HomePod, Apple TV) see the correct wall-clock
        // anchor after a scrub or a play/pause toggle. On pause, remove the
        // key — a stopped receiver must not drift the progress bar forward on
        // its own. On play (or seek while playing), recompute from "now".
        if rate > 0 {
            info[MPNowPlayingInfoPropertyCurrentPlaybackDate] = Date(timeIntervalSinceNow: -clamped)
        } else {
            info.removeValue(forKey: MPNowPlayingInfoPropertyCurrentPlaybackDate)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPublishedElapsed = clamped
        lastPublishedRate = rate
    }

    // MARK: - Remote command center

    private func configureRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            if delegate.currentStatus.currentTrack == nil {
                return .noActionableNowPlayingItem
            }
            delegate.mediaSessionPlay()
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            if delegate.currentStatus.currentTrack == nil {
                return .noActionableNowPlayingItem
            }
            delegate.mediaSessionPause()
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            if delegate.currentStatus.currentTrack == nil {
                return .noActionableNowPlayingItem
            }
            delegate.mediaSessionTogglePlayPause()
            return .success
        }

        cc.stopCommand.isEnabled = false
        cc.stopCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            if delegate.currentStatus.currentTrack == nil {
                return .noActionableNowPlayingItem
            }
            delegate.mediaSessionStop()
            return .success
        }

        cc.nextTrackCommand.isEnabled = false
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            delegate.mediaSessionSkipNext()
            return .success
        }

        cc.previousTrackCommand.isEnabled = false
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            // #581: Standard "previous track" behaviour — if the user is more
            // than 3 seconds into the current track, restart it instead of
            // jumping to the previous queue item. Only skip back when at or
            // within the first 3 seconds.
            if delegate.currentStatus.positionSeconds > 3.0 {
                delegate.mediaSessionSeek(toSeconds: 0)
            } else {
                delegate.mediaSessionSkipPrevious()
            }
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let delegate = self.delegate,
                delegate.currentStatus.currentTrack != nil,
                let seek = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            delegate.mediaSessionSeek(toSeconds: seek.positionTime)
            // Update elapsed right away so the widget confirms the scrub
            // without a 0.5s lag (issue #32).
            self.updateElapsedAndRate(
                elapsed: seek.positionTime,
                rate: delegate.currentStatus.state == .playing ? 1.0 : 0.0
            )
            return .success
        }

        // BATCH-14 (#34): shuffle + repeat toggles from Control Center /
        // AirPods Pro long-press / Bluetooth remotes. The `currentShuffle*`
        // and `currentRepeat*` properties on the commands are what
        // `MPNowPlayingInfoCenter` publishes to the remote-control surface;
        // we push them through on status-refresh below so external UIs see
        // the active mode without a round-trip.
        cc.changeShuffleModeCommand.isEnabled = true
        cc.changeShuffleModeCommand.addTarget { [weak self] event in
            guard
                let self,
                let delegate = self.delegate,
                let change = event as? MPChangeShuffleModeCommandEvent
            else {
                return .commandFailed
            }
            let on = change.shuffleType != .off
            delegate.mediaSessionSetShuffle(on)
            // Echo the new mode back to the command so Control Center
            // toggles reflect the on-disk state on the very next redraw.
            cc.changeShuffleModeCommand.currentShuffleType = change.shuffleType
            self.refreshRemoteCommandEnablement()
            return .success
        }

        cc.changeRepeatModeCommand.isEnabled = true
        cc.changeRepeatModeCommand.addTarget { [weak self] event in
            guard
                let self,
                let delegate = self.delegate,
                let change = event as? MPChangeRepeatModeCommandEvent
            else {
                return .commandFailed
            }
            delegate.mediaSessionSetRepeatMode(Self.repeatMode(from: change.repeatType))
            cc.changeRepeatModeCommand.currentRepeatType = change.repeatType
            self.refreshRemoteCommandEnablement()
            return .success
        }

        // BATCH-14 (#35): like toggles the currently-playing track's
        // favorite state via the Jellyfin `/UserFavoriteItems` endpoint.
        // `likeCommand.isActive` is pushed in `refreshRemoteCommandEnablement`
        // so Control Center reflects the server-side favorite flag.
        cc.likeCommand.isEnabled = true
        cc.likeCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            guard let targetState = delegate.mediaSessionToggleFavorite() else {
                return .noActionableNowPlayingItem
            }
            // Optimistic UI: flip `isActive` before the network call
            // completes so the tap has no perceptible latency. The next
            // `trackChanged` / `queueChanged` refresh reconciles if the
            // server rolled back.
            cc.likeCommand.isActive = targetState
            return .success
        }

        // `dislikeCommand` stays disabled — Jellyfin has no concept of a
        // negative rating, so exposing it would be misleading.
        cc.dislikeCommand.isEnabled = false

        // (#33): ±15 s skip — standard podcast interval; costs nothing for
        // music and the Now Playing widget surfaces the buttons automatically
        // when `preferredIntervals` is set.
        cc.skipForwardCommand.isEnabled = true
        cc.skipForwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            guard delegate.currentStatus.currentTrack != nil else {
                return .noActionableNowPlayingItem
            }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            // Clamp to the track duration so a skip near the end seeks to the
            // end instead of past it (the engine seeks with zero tolerance,
            // so an out-of-range target would otherwise land at an undefined
            // position). A zero/unknown duration falls back to no clamp.
            let target = Self.skipForwardTarget(
                position: delegate.currentStatus.positionSeconds,
                interval: interval,
                duration: delegate.currentStatus.durationSeconds
            )
            delegate.mediaSessionSeek(toSeconds: target)
            self.updateElapsedAndRate(
                elapsed: target,
                rate: delegate.currentStatus.state == .playing ? 1.0 : 0.0
            )
            return .success
        }

        cc.skipBackwardCommand.isEnabled = true
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            guard delegate.currentStatus.currentTrack != nil else {
                return .noActionableNowPlayingItem
            }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            let target = max(0, delegate.currentStatus.positionSeconds - interval)
            delegate.mediaSessionSeek(toSeconds: target)
            self.updateElapsedAndRate(
                elapsed: target,
                rate: delegate.currentStatus.state == .playing ? 1.0 : 0.0
            )
            return .success
        }
    }

    /// Map a `MPRepeatType` from Control Center onto the core's
    /// [`RepeatMode`]. `MPRepeatType.one` is Apple's "repeat this track"
    /// flag; `MPRepeatType.all` is "loop the queue". The core only cares
    /// about those two distinctions plus off.
    private static func repeatMode(from type: MPRepeatType) -> RepeatMode {
        switch type {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        @unknown default: return .off
        }
    }

    /// Inverse of [`Self.repeatMode(from:)`], used when pushing the active
    /// mode back out to Control Center after a status refresh.
    private static func repeatType(from mode: RepeatMode) -> MPRepeatType {
        switch mode {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        }
    }

    /// Compute the clamped seek target for a +interval skip. The result is
    /// capped at `duration` so a skip near the end lands on the end rather
    /// than past it; a zero/unknown duration disables the cap so a stream
    /// with no reported length still skips forward. Pulled out as a pure
    /// helper so the clamp is unit-testable without a live remote command
    /// (#408). `internal` for `@testable` access only.
    static func skipForwardTarget(position: Double, interval: Double, duration: Double) -> Double {
        let raw = position + interval
        guard duration > 0 else { return raw }
        return min(raw, duration)
    }

    private func refreshRemoteCommandEnablement() {
        guard let delegate else { return }
        let status = delegate.currentStatus
        let cc = MPRemoteCommandCenter.shared()
        let hasTrack = status.currentTrack != nil
        cc.stopCommand.isEnabled = hasTrack
        // Next/previous gate on queue bounds, with repeat-all letting the
        // user wrap across the end/start of the queue so the remote surface
        // doesn't dead-end on the last or first track.
        if status.queueLength == 0 {
            cc.nextTrackCommand.isEnabled = false
            cc.previousTrackCommand.isEnabled = false
        } else if status.repeatMode == .all {
            cc.nextTrackCommand.isEnabled = true
            cc.previousTrackCommand.isEnabled = true
        } else {
            cc.nextTrackCommand.isEnabled = status.queuePosition + 1 < status.queueLength
            cc.previousTrackCommand.isEnabled = status.queuePosition > 0
        }

        // Shuffle / repeat mirrors: push the current mode back out so
        // Control Center highlights the correct cell when the user opens
        // the "Now Playing" popover.
        cc.changeShuffleModeCommand.currentShuffleType = status.shuffle ? .items : .off
        cc.changeRepeatModeCommand.currentRepeatType = Self.repeatType(from: status.repeatMode)

        // Like: enabled only while a track is playing, with `isActive`
        // reflecting the current favorite flag. Read through the delegate
        // rather than `status.currentTrack?.isFavorite`: the core doesn't
        // mutate the playing track's snapshot on a favorite toggle, so the
        // delegate's reconciled cache is the authoritative source (#460).
        cc.likeCommand.isEnabled = hasTrack
        cc.likeCommand.isActive = hasTrack ? delegate.mediaSessionCurrentTrackIsFavorite() : false

        // Skip forward/backward follow track presence — no point enabling
        // them when there's nothing playing (issue #33).
        cc.skipForwardCommand.isEnabled = hasTrack
        cc.skipBackwardCommand.isEnabled = hasTrack
    }

    // MARK: - Artwork

    /// Fetch and publish artwork for `track`. `expectedTrackID` is checked
    /// against `currentTrackID` before every write so a late-arriving image
    /// never overwrites a subsequent track's artwork (see #30).
    private func loadArtwork(for track: Track, expectedTrackID: String) async {
        guard let delegate else { return }

        // Cached hit from a prior play of the same album cover — publish
        // immediately without a network hop. Keyed by album-art identity so
        // every track on the same album reuses the first fetch (#160).
        let cacheKey = Self.artworkCacheKey(for: track)
        if let cached = artworkCache.object(forKey: cacheKey) {
            guard currentTrackID == expectedTrackID else { return }
            publishArtwork(cached)
            return
        }

        guard track.imageTag != nil,
              let url = delegate.mediaSessionArtworkURL(for: track, maxWidth: 600)
        else {
            // No artwork available for the new track. If it's still the
            // current track, clear any placeholder art that `trackChanged`
            // carried over so a no-art track doesn't keep showing the prior
            // cover (#162).
            guard currentTrackID == expectedTrackID else { return }
            clearArtwork()
            return
        }

        var request = URLRequest(url: url)
        if let auth = delegate.mediaSessionAuthorizationHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else { return }
            // Only publish if the track hasn't changed mid-flight.
            guard currentTrackID == expectedTrackID else { return }

            // macOS honours the size callback; feed it a resized NSImage so
            // the widget doesn't carry a full-resolution copy around.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
                Self.resize(image, to: requestedSize)
            }
            artworkCache.setObject(artwork, forKey: cacheKey)
            publishArtwork(artwork)
        } catch is CancellationError {
            // Track changed during the fetch — silent no-op.
        } catch {
            // Network error on a secondary asset — leave the previous
            // artwork in place so Control Center doesn't go blank.
        }
    }

    private func publishArtwork(_ artwork: MPMediaItemArtwork) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Drop the artwork entry from the now-playing info so a track with no
    /// resolvable cover doesn't inherit the previous track's placeholder
    /// (#162). No-op when nothing is published yet.
    private func clearArtwork() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              info[MPMediaItemPropertyArtwork] != nil
        else { return }
        info.removeValue(forKey: MPMediaItemPropertyArtwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Stable cache key for a track's cover art. Cover art is album-level on
    /// Jellyfin, so key by `albumId` (falling back to the track id for
    /// single tracks) plus the image tag — that way every track on the same
    /// album shares one cache entry and one network fetch instead of
    /// re-downloading the identical cover per track (#160). Including the tag
    /// invalidates the entry if the album art changes server-side.
    /// `internal` for `@testable` access only.
    static func artworkCacheKey(for track: Track) -> NSString {
        "\(track.albumId ?? track.id)|\(track.imageTag ?? "")" as NSString
    }

    /// Produce a resized copy of `image` at `size` points. Used by the
    /// `MPMediaItemArtwork` size callback so the widget can request whatever
    /// resolution it actually needs (Retina Control Center is ~200pt; macOS
    /// Dock thumbnails are smaller).
    private static func resize(_ image: NSImage, to size: CGSize) -> NSImage {
        let target = NSSize(
            width: max(1, size.width),
            height: max(1, size.height)
        )
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}
