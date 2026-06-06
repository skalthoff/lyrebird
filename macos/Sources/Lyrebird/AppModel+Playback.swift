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
    /// streams, resolved from the persisted Streaming Quality preference (#260).
    /// `nil` = uncapped (the Lossless / Original tiers). When the feature is
    /// gated off, returns the historical 320 kbps default so playback is
    /// byte-for-byte unchanged. Seeded at audio-config time and refreshed at the
    /// start of each `play(tracks:)`, so a quality change applies the next time
    /// playback starts.
    var resolvedStreamingBitrate: UInt32? {
        guard supportsStreamingBitrate else { return 320_000 }
        let raw = UserDefaults.standard.string(forKey: "playback.streamingQuality")
        let quality = raw.flatMap(PlaybackQuality.init(rawValue:)) ?? .automatic
        return quality.maxStreamingBitrate
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
        do {
            _ = try core.setQueue(tracks: tracks, startIndex: UInt32(startIndex))
            guard let first = tracks[safe: startIndex] else { return }
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
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.playNext(tracks: tracks)
            }.value
            self.status = core.status()
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
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.addToQueue(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }
}
