import Foundation
@preconcurrency import LyrebirdCore

/// Playlist track-list state on `AppModel`: loading a playlist's ordered
/// tracks (keyed cache + the on-screen `currentPlaylistTracks` array) and the
/// optimistic add / remove / undo mutations that keep those caches and the
/// in-memory `Playlist` track counts in sync with the server.
extension AppModel {
    /// Fetch the ordered tracks for a playlist, preserving the server-side
    /// playlist order. Mirrors `loadTracks(forAlbum:)` — results are cached
    /// for the session, scoped to `playlistTracks[playlist.id]`. Backed by
    /// `LyrebirdCore.playlistTracks` (core's `playlist_tracks`, see #125).
    ///
    /// We ask for up to 500 entries, which covers the vast majority of
    /// playlists; paging the tail is a follow-up alongside virtualization of
    /// the track list itself (see #234's spec — the hero ships first, the
    /// long-playlist scroll optimization is a later polish pass).
    @discardableResult
    func loadPlaylistTracks(playlist: Playlist) async -> [Track] {
        if let cached = playlistTracks[playlist.id] { return cached }
        do {
            let playlistID = playlist.id
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistTracks(playlistId: playlistID, offset: 0, limit: 500)
            }.value
            let tracks = page.items
            playlistTracks[playlist.id] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistTracks)
            return []
        }
    }

    /// Look up a cached `Playlist` by id. Returns `nil` if no upstream surface
    /// has inserted one — the caller (`PlaylistView`) renders a minimal
    /// fallback in that case until playlist listing lands (#220).
    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Load the ordered track list for `playlistId` and publish it on
    /// `currentPlaylistTracks` so `PlaylistDetailView` can drive its list and
    /// multi-select surface off a single observable array. See #74 / #236.
    ///
    /// Hits the keyed `playlistTracks` cache first so switching back to a
    /// playlist you just left is instant. On a miss, delegates to
    /// `core.playlistTracks(playlistId:)` for up to 500 entries — same cap as
    /// `loadPlaylistTracks(playlist:)`. Errors surface through the usual
    /// auth / reachability / error-banner path.
    ///
    /// Pass `forceRefresh: true` to bypass the cache and re-fetch from the
    /// server — required after a mutation (e.g. drop-to-add) that changed the
    /// track list but couldn't reconstruct full `Track` rows locally.
    func loadPlaylistTracks(playlistId: String, forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = playlistTracks[playlistId] {
            currentPlaylistTracks = cached
            return
        }
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistTracks(playlistId: playlistId, offset: 0, limit: 500)
            }.value
            playlistTracks[playlistId] = page.items
            currentPlaylistTracks = page.items
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistTracks)
        }
    }

    /// Remove tracks from a playlist by entry id (the track id, since the
    /// core's FFI doesn't yet surface playlist-entry ids — see #128).
    ///
    /// Applied optimistically: rows disappear from `currentPlaylistTracks`
    /// and `playlistTracks[playlistId]` immediately, the removed tracks
    /// are stashed on `pendingPlaylistRemoval` so the 10-second undo window
    /// can put them back via `undoRemoveFromPlaylist`, and the real
    /// `DELETE /Playlists/{id}/Items` call is fired off the main actor.
    /// Track-counts on the in-memory `Playlist` are kept consistent so the
    /// hero stat doesn't lie.
    ///
    /// `entryIds` are track `id`s (the underlying `ItemId`). The server call
    /// needs `PlaylistItemId`s — we resolve those from
    /// `currentPlaylistTracks` before firing the request, so every removed
    /// track must have been loaded with its `playlistItemId` set (i.e.
    /// fetched via `core.playlistTracks`, not synthesized ad-hoc).
    func removeFromPlaylist(playlistId: String, entryIds: [String]) {
        guard !entryIds.isEmpty else { return }
        let removing = Set(entryIds)
        let removed = currentPlaylistTracks.filter { removing.contains($0.id) }
        guard !removed.isEmpty else { return }
        let playlistItemIds = removed.compactMap { $0.playlistItemId }
        // Server call requires playlistItemIds. If any removed track lacks
        // one, the whole batch can't be reconciled with the server. Bail
        // BEFORE the optimistic mutation so there's nothing to roll back —
        // surface a banner so the user knows the action didn't persist.
        // (Earlier we mutated then rolled back, but the rollback restored
        // from the already-mutated array — net no-op.)
        guard !playlistItemIds.isEmpty else {
            errorMessage = "Couldn't remove this track from the playlist. Try refreshing the playlist."
            return
        }
        currentPlaylistTracks.removeAll { removing.contains($0.id) }
        playlistTracks[playlistId] = currentPlaylistTracks
        pendingPlaylistRemoval = PendingRemoval(
            playlistId: playlistId,
            tracks: removed
        )
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            let newCount = max(0, Int(p.trackCount) - removed.count)
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: UInt32(newCount),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag,
                userData: p.userData
            )
        }
        // Capture the optimistic state so we can roll back on server failure.
        // Without this rollback the local list and server diverge silently —
        // user sees the row vanish, refreshes the playlist, row reappears,
        // and the action looks like a phantom event. Same bug class as the
        // rc4-rc5 favorite-not-pushed report.
        let removedSnapshot = removed
        let playlistRef = playlistId
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.removeFromPlaylist(
                        playlistId: playlistRef,
                        entryIds: playlistItemIds
                    )
                }.value
                self?.serverReachability.noteSuccess()
            } catch {
                guard let self else { return }
                if self.handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    self.serverReachability.noteFailure()
                }
                // Rollback: restore the rows + the trackCount we just decremented.
                self.currentPlaylistTracks.append(contentsOf: removedSnapshot)
                self.playlistTracks[playlistRef] = self.currentPlaylistTracks
                if let idx = self.playlists.firstIndex(where: { $0.id == playlistRef }) {
                    let p = self.playlists[idx]
                    self.playlists[idx] = Playlist(
                        id: p.id,
                        name: p.name,
                        trackCount: p.trackCount + UInt32(removedSnapshot.count),
                        runtimeTicks: p.runtimeTicks,
                        imageTag: p.imageTag,
                        userData: p.userData
                    )
                }
                self.pendingPlaylistRemoval = nil
                self.errorMessage = LyrebirdErrorPresenter.message(
                    for: error,
                    context: .playlistTracks
                )
            }
        }
    }

    /// Restore a previously-removed batch by re-adding via `core.addToPlaylist`.
    /// Called from the undo toast in `PlaylistDetailView`. Clears
    /// `pendingPlaylistRemoval` on success; leaves it intact on failure so
    /// the user can retry by tapping Undo again.
    func undoRemoveFromPlaylist() {
        guard let pending = pendingPlaylistRemoval else { return }
        let ids = pending.tracks.map(\.id)
        let playlistId = pending.playlistId
        pendingPlaylistRemoval = nil
        // Optimistically re-insert so the list pops back immediately. The
        // server call below is the actual durability guarantee.
        let existingIds = Set(currentPlaylistTracks.map(\.id))
        let reinserted = pending.tracks.filter { !existingIds.contains($0.id) }
        currentPlaylistTracks.append(contentsOf: reinserted)
        playlistTracks[playlistId] = currentPlaylistTracks
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: p.trackCount + UInt32(reinserted.count),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag,
                userData: p.userData
            )
        }
        // Capture the count of optimistically-reinserted tracks so we can
        // roll back on server failure. Without this the playlist's count is
        // inflated locally vs. server.
        let reinsertedCount = reinserted.count
        let playlistRef = playlistId
        let reinsertedIds = Set(reinserted.map(\.id))
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.addToPlaylist(playlistId: playlistRef, itemIds: ids, position: nil)
                }.value
                self?.serverReachability.noteSuccess()
            } catch {
                guard let self else { return }
                if self.handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    self.serverReachability.noteFailure()
                }
                // Roll back the optimistic re-insert: drop the rows we
                // just added and decrement the playlist count.
                self.currentPlaylistTracks.removeAll { reinsertedIds.contains($0.id) }
                self.playlistTracks[playlistRef] = self.currentPlaylistTracks
                if let idx = self.playlists.firstIndex(where: { $0.id == playlistRef }) {
                    let p = self.playlists[idx]
                    let newCount = max(0, Int(p.trackCount) - reinsertedCount)
                    self.playlists[idx] = Playlist(
                        id: p.id,
                        name: p.name,
                        trackCount: UInt32(newCount),
                        runtimeTicks: p.runtimeTicks,
                        imageTag: p.imageTag,
                        userData: p.userData
                    )
                }
                self.errorMessage = LyrebirdErrorPresenter.message(
                    for: error,
                    context: .playlistTracks
                )
            }
        }
    }

    /// Append tracks to a playlist by id. Backs the drop-to-add handler on
    /// `PlaylistDetailView` and any future "Add to playlist" affordance. See
    /// #236. Updates the in-memory caches optimistically and fires the core
    /// call in a detached task.
    ///
    /// We only know the bare track ids here, not full `Track` records, so the
    /// visible list can't be appended to optimistically. Instead, on a
    /// successful add we invalidate `playlistTracks[playlistId]` and — when
    /// that playlist is the one currently on screen — re-fetch it so the new
    /// rows actually appear. Without this the drop "succeeds" but the list
    /// keeps showing the pre-drop tracks (the cache was never refreshed).
    func addToPlaylist(playlistId: String, trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        let ids = trackIds
        // Is this the playlist currently on screen? `currentPlaylistTracks` is
        // populated from `playlistTracks[playlistId]` whenever a playlist
        // loads, so matching id sequences means the detail view is showing it
        // and needs a re-fetch once the add lands.
        let isShowingThisPlaylist = playlistTracks[playlistId]?.map(\.id) == currentPlaylistTracks.map(\.id)
        // Optimistically bump the count BEFORE the FFI call so the drop
        // visually lands without waiting for the round-trip. We don't know
        // the full `Track` records for ids that aren't already resident, so
        // we only bump the count on the in-memory `Playlist` and leave the
        // list alone — a follow-up `loadPlaylistTracks` (the caller usually
        // fires one after a drop) will reconcile.
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: p.trackCount + UInt32(trackIds.count),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag,
                userData: p.userData
            )
        }
        let bumpedCount = trackIds.count
        let playlistRef = playlistId
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.addToPlaylist(playlistId: playlistRef, itemIds: ids, position: nil)
                }.value
                guard let self else { return }
                self.serverReachability.noteSuccess()
                // The add persisted but we only had bare ids, so the cached
                // rows are now stale (missing the new tracks). Invalidate the
                // cache and, if this playlist is on screen, re-fetch so the
                // dropped tracks actually appear in the list.
                self.playlistTracks[playlistRef] = nil
                if isShowingThisPlaylist {
                    await self.loadPlaylistTracks(playlistId: playlistRef, forceRefresh: true)
                }
            } catch {
                guard let self else { return }
                if self.handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    self.serverReachability.noteFailure()
                }
                // Roll back the optimistic count bump so the in-memory
                // Playlist record stays in sync with the server.
                if let idx = self.playlists.firstIndex(where: { $0.id == playlistRef }) {
                    let p = self.playlists[idx]
                    let newCount = max(0, Int(p.trackCount) - bumpedCount)
                    self.playlists[idx] = Playlist(
                        id: p.id,
                        name: p.name,
                        trackCount: UInt32(newCount),
                        runtimeTicks: p.runtimeTicks,
                        imageTag: p.imageTag,
                        userData: p.userData
                    )
                }
                self.errorMessage = LyrebirdErrorPresenter.message(
                    for: error,
                    context: .playlistTracks
                )
            }
        }
    }

    /// Append a batch of tracks to an existing playlist via `add_to_playlist`
    /// on the core. Used by the album detail popover (#222) and any other
    /// caller that has already resolved a target playlist. Returns `true` on
    /// success so UI can dismiss the popover / show a confirmation tick.
    ///
    /// Errors surface on `errorMessage` rather than throwing so the popover
    /// can stay presentation-only. An empty `trackIds` short-circuits before
    /// the FFI hop since the server would reject it anyway.
    @discardableResult
    func addToPlaylist(trackIds: [String], playlistId: String) async -> Bool {
        guard !trackIds.isEmpty else { return false }
        do {
            try await Task.detached(priority: .userInitiated) { [core] in
                try core.addToPlaylist(playlistId: playlistId, itemIds: trackIds, position: nil)
            }.value
            serverReachability.noteSuccess()
            return true
        } catch {
            if handleAuthError(error) { return false }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistAdd)
            return false
        }
    }
}
