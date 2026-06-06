import Foundation
import os
@preconcurrency import LyrebirdCore

/// Favorite + played state: toggle/read the heart and played glyphs against the server.
extension AppModel {
    /// Toggle the favorite flag for an album on the Jellyfin server. Reads
    /// the current state from `favoriteById` (falling back to `false` on a
    /// cold start) and calls the opposite side of `set_favorite` /
    /// `unset_favorite` on the core. The returned [`FavoriteState`] is the
    /// server's authoritative answer and is written back to `favoriteById`
    /// so the heart glyph reflects the saved state.
    ///
    /// Errors surface the generic `errorMessage` banner — a failed toggle is
    /// rare enough that swallowing it would hide real trouble (token
    /// revoked, network flapping), but not so load-bearing that we want a
    /// modal.
    func toggleFavorite(album: Album) {
        Task { await setFavorite(itemId: album.id, enabled: !isFavorite(album: album)) }
    }

    /// Toggle the favorite flag for a track. Same contract as
    /// `toggleFavorite(album:)` — see its doc for the state-cache semantics.
    func toggleFavorite(track: Track) {
        Task { await setFavorite(itemId: track.id, enabled: !isFavorite(track: track)) }
    }

    /// Check the local favorite-state cache. Returns `false` when the item
    /// hasn't been toggled this session AND no snapshot is available — the
    /// snapshot-aware overloads `isFavorite(track:)` / `isFavorite(album:)` /
    /// `isFavorite(artist:)` are preferred at call sites that have a model
    /// object on hand because they read the server-authoritative
    /// `userData.isFavorite` from the snapshot when the cache is cold.
    func isFavorite(id: String) -> Bool {
        favoriteById[id] ?? false
    }

    /// Snapshot-aware favorite check for tracks. Reads the in-memory cache
    /// first (toggled-this-session is authoritative), then falls back to
    /// the server-authoritative `track.userData?.isFavorite` projection,
    /// then to the legacy top-level `track.isFavorite` mirror. This is the
    /// preferred read for any heart-glyph UI that has the `Track` value on
    /// hand: it shows the correct state on first paint for already-favorited
    /// tracks (the cache-only `isFavorite(id:)` returns `false` until the
    /// user toggles, which makes the next tap appear to no-op against the
    /// server). See the rc6 favorite-cache seeding fix.
    func isFavorite(track: Track) -> Bool {
        if let cached = favoriteById[track.id] { return cached }
        if let userFav = track.userData?.isFavorite { return userFav }
        return track.isFavorite
    }

    /// Snapshot-aware favorite check for albums. Mirrors
    /// `isFavorite(track:)` — falls back to `album.userData?.isFavorite`
    /// when the cache is cold so the album-detail heart shows the correct
    /// state on first paint. `Album` has no legacy top-level `isFavorite`
    /// mirror so the final fallback is `false`.
    func isFavorite(album: Album) -> Bool {
        if let cached = favoriteById[album.id] { return cached }
        return album.userData?.isFavorite ?? false
    }

    /// Snapshot-aware favorite check for playlists. Mirrors
    /// `isFavorite(album:)` — falls back to `playlist.userData?.isFavorite`
    /// when the cache is cold so the playlist-detail heart shows the correct
    /// state on first paint.
    func isFavorite(playlist: Playlist) -> Bool {
        if let cached = favoriteById[playlist.id] { return cached }
        return playlist.userData?.isFavorite ?? false
    }

    /// Snapshot-aware favorite check for artists. Mirrors
    /// `isFavorite(track:)` — falls back to `artist.userData?.isFavorite`.
    func isFavorite(artist: Artist) -> Bool {
        if let cached = favoriteById[artist.id] { return cached }
        return artist.userData?.isFavorite ?? false
    }

    /// Internal helper — hits `set_favorite` / `unset_favorite` on the core
    /// and mirrors the server's answer into `favoriteById`. `internal` (not
    /// `private`) so the `toggleFavorite(...)` wrappers — some now in
    /// `AppModel+*` extension files (e.g. `AppModel+Playlists.swift`) — can
    /// route through it; the `toggleFavorite(...)` API stays the preferred
    /// entry point so the desired-state boolean is always computed at the
    /// call site.
    func setFavorite(itemId: String, enabled: Bool) async {
        Log.tracks.info("setFavorite item=\(itemId, privacy: .public) target=\(enabled, privacy: .public)")
        do {
            let state = try await Task.detached(priority: .userInitiated) { [core] in
                if enabled {
                    return try core.setFavorite(itemId: itemId)
                } else {
                    return try core.unsetFavorite(itemId: itemId)
                }
            }.value
            Log.tracks.info("setFavorite ok item=\(itemId, privacy: .public) server=\(state.isFavorite, privacy: .public)")
            favoriteById[itemId] = state.isFavorite
            favoriteChangeToken &+= 1
            serverReachability.noteSuccess()
            // If the app UI just favorited the currently-playing track, sync
            // Control Center's like indicator — only the remote-command path
            // self-refreshes otherwise (#460).
            if status.currentTrack?.id == itemId {
                mediaSession.refreshTransportState()
            }
        } catch {
            Log.tracks.error("setFavorite failed item=\(itemId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .favorite)
        }
    }

    /// Read the locally-cached played state for an item id. Mirrors
    /// `isFavorite(id:)`; used by row views + `toggleMarkPlayed(tracks:)`
    /// to compute the target state for a multi-select toggle. See #133.
    func isPlayed(id: String) -> Bool {
        playedById[id] ?? false
    }

    /// Internal helper — hits `mark_played` / `mark_unplayed` on the core
    /// and mirrors the server's answer (full `UserItemData`) into
    /// `playedById`. Mirrors `setFavorite(itemId:enabled:)` in shape so a
    /// single-item toggle has a single failure path. See #133.
    func setPlayed(itemId: String, played: Bool) async {
        do {
            let state = try await Task.detached(priority: .userInitiated) { [core] in
                try core.setPlayed(itemId: itemId, played: played)
            }.value
            playedById[itemId] = state.played
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .markPlayed)
        }
    }
}
