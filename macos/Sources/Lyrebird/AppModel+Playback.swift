import Foundation
@preconcurrency import LyrebirdCore
import LyrebirdAudio

/// Album / queue playback initiation on `AppModel`: `play(tracks:)` — the core
/// "replace the queue and start playing" entry point — and the album-level
/// actions play / shuffle / play-next / add-to-queue.
///
/// Extensions of a `@MainActor` type inherit its isolation, so every method
/// here is main-actor-bound just like the rest of the class.
extension AppModel {
    // MARK: - Playback

    /// The transcode-bitrate ceiling (bits/s) the engine should apply to new
    /// streams, resolved from the persisted Streaming Quality preference (#260)
    /// and the current network quality hint (#447).
    ///
    /// `nil` = uncapped (the Lossless / Original tiers). When the feature is
    /// gated off, returns the historical 320 kbps default so playback is
    /// byte-for-byte unchanged. Seeded at audio-config time and refreshed at the
    /// start of each `play(tracks:)`, so a quality change applies the next time
    /// playback starts.
    ///
    /// For the `automatic` quality tier the bitrate is further adapted to the
    /// current link (#447):
    ///   - Unmetered (Ethernet / standard Wi-Fi): 320 kbps — same as before.
    ///   - Metered (cellular / Personal Hotspot / `isExpensive`): 192 kbps so
    ///     the first 8 seconds of a track buffer in ~1 second on a 2 Mbps link.
    ///
    /// Fixed tiers (Low / Normal / High / Lossless / Original) are applied
    /// as-is, regardless of the network condition — the user has explicitly
    /// asked for that quality.
    var resolvedStreamingBitrate: UInt32? {
        guard supportsStreamingBitrate else { return 320_000 }
        let raw = UserDefaults.standard.string(forKey: "playback.streamingQuality")
        let quality = raw.flatMap(PlaybackQuality.init(rawValue:)) ?? .automatic
        // For fixed tiers, honour the user's explicit choice unconditionally.
        guard quality == .automatic else { return quality.maxStreamingBitrate }
        // For the automatic tier, adapt to the current link quality.
        switch network.qualityHint {
        case .unmetered, .offline:
            // Unmetered: stream at full automatic quality (320 kbps).
            // Offline: `isOnline` will be false and playback will not start,
            // but return the unmetered default rather than a degraded one so
            // if the path briefly bounces back we don't serve a low-res stream.
            return 320_000
        case .metered:
            // Cellular or metered Wi-Fi: use 192 kbps so the opening buffer
            // fills quickly on a 2 Mbps link. The server transcodes to mp3 at
            // this ceiling (see `stream_url_with_bitrate` in core/src/client.rs).
            return 192_000
        }
    }

    func play(tracks: [Track], startIndex: Int = 0) {
        // Starting a fresh queue disarms any leftover "Stop after current
        // track" one-shot — "Resets to off the next time you start
        // playback" (#116).
        AppModel.resetStopAfterCurrent()
        // Refresh the engine's transcode ceiling from the Streaming Quality
        // preference so a change picked in Settings takes effect on this fresh
        // playback session (#260).
        audio.maxStreamingBitrate = resolvedStreamingBitrate
        // Bump the generation so any radio Task still awaiting its FFI hop
        // sees a newer play won and bails instead of clobbering this queue.
        playbackGeneration &+= 1
        do {
            _ = try core.setQueue(tracks: tracks, startIndex: UInt32(startIndex))
            guard let first = tracks[safe: startIndex] else { return }
            // A fresh explicit play supersedes any prior source. Clear the
            // context here so a leftover `.radio` label doesn't cling to an
            // album / playlist the user just started. Radio entry points
            // re-stamp `currentContext` after calling through here.
            currentContext = nil
            Task {
                do {
                    try await audio.play(track: first)
                    errorMessage = nil
                } catch {
                    if handleAuthError(error) { return }
                    errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playback)
                }
            }
        } catch {
            if handleAuthError(error) { return }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playback)
        }
    }

    func play(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle an album — loads tracks, randomises order, then plays from top.
    func shuffle(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert an album's tracks immediately after the currently-playing track.
    /// Uses the `core.playNext` primitive wired in for #282. When nothing is
    /// currently playing, falls back to `play(album:)` so the album actually
    /// starts instead of silently queueing into an empty player.
    func playNext(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) { [core] in
                    core.playNext(tracks: tracks)
                }.value
                self.status = core.status()
            } catch {
                if handleAuthError(error) { return }
                self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playback)
            }
        }
    }

    /// Append an album's tracks to the end of the queue. Uses the
    /// `core.addToQueue` primitive wired in for #282; when nothing is playing
    /// falls back to `play(album:)` so we don't end up with a loaded queue
    /// but no playhead.
    func addToQueue(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) { [core] in
                    core.addToQueue(tracks: tracks)
                }.value
                self.status = core.status()
            } catch {
                if handleAuthError(error) { return }
                self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playback)
            }
        }
    }
}
