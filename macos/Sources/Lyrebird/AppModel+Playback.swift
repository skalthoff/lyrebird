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

    func play(tracks: [Track], startIndex: Int = 0) {
        // Starting a fresh queue disarms any leftover "Stop after current
        // track" one-shot — "Resets to off the next time you start
        // playback" (#116).
        AppModel.resetStopAfterCurrent()
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
