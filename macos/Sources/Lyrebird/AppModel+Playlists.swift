import AppKit
import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Playlist-domain methods on `AppModel`: playback actions
/// (`play`/`shuffle`/`playNext`/`addToQueue`/`toggleFavorite`/`enqueueDownload`),
/// sidebar CRUD (create/rename/delete/duplicate, inline-edit commit,
/// drag-reorder), and sharing (web link, open-in-Jellyfin, M3U/JSON export).
///
/// The `@Observable` stored state these methods read (`playlists`,
/// `playlistTracks`, `currentPlaylistTracks`, `playlistDescriptions`,
/// `sidebarEditingPlaylistId`, `sidebarEditingDraft`,
/// `sidebarCopyingPlaylistIds`, `playlistPendingDelete`) is declared on the
/// main `AppModel` class — stored properties can't live in an extension.
/// Extensions of a `@MainActor` type inherit its isolation, so every method
/// here is main-actor-bound just like the rest of the class.
extension AppModel {
    // MARK: - Playlist actions
    //
    // Parallels the album actions above. Issue #313.
    //
    // Playback (#125, `playlist_tracks`), favorite (#133, `set_favorite` /
    // `unset_favorite`), rename (`rename_playlist`), delete (#131,
    // `delete_playlist`), and reorder (`reorder_playlist_track`) are all
    // live now that their FFI has landed. The two remaining unbacked
    // actions are the download engine (#819, fully gated behind
    // `supportsDownloads`) and description persistence — the latter has no
    // `update_playlist` FFI yet (#130), so `updatePlaylistDescription` only
    // mutates the in-memory `playlistDescriptions` map.

    /// Fetch a playlist's tracks and start playback from the top.
    func play(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle a playlist — loads tracks, randomises order, then plays from
    /// the top. Mirrors `shuffle(album:)`.
    func shuffle(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert a playlist's tracks immediately after the currently-playing track.
    /// Wired to `core.playNext` for #282. Falls back to `play(playlist:)`
    /// when nothing is currently playing so the menu item still does the
    /// obvious thing.
    func playNext(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
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

    /// Append a playlist's tracks to the end of the queue. Wired to
    /// `core.addToQueue` for #282. Falls back to `play(playlist:)` when
    /// nothing is currently playing.
    func addToQueue(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
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

    /// Toggle the favorite flag for a playlist on the Jellyfin server.
    /// TODO: #133, #222 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(playlist: Playlist) {
        // `/Users/{id}/FavoriteItems/{id}` is polymorphic, so the same
        // set/unset-favorite FFI used for albums/tracks works on playlists.
        Task { await setFavorite(itemId: playlist.id, enabled: !isFavorite(playlist: playlist)) }
    }

    /// Download every track in the playlist for offline playback (#819).
    /// Mirrors `enqueueDownload(album:)`. Gated behind `supportsDownloads`.
    func enqueueDownload(playlist: Playlist) {
        guard supportsDownloads else { return }
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            await downloadTracks(tracks)
        }
    }

    /// Flip the sidebar's inline TextField onto an existing playlist row so
    /// the user can rename it in-place. Mirrors the #71 Cmd+N flow —
    /// Escape / blur-without-change cancels, Return commits through
    /// `commitSidebarPlaylistEdit` which dispatches to `renamePlaylist`.
    /// See BATCH-06b / issue #75.
    func requestRename(playlist: Playlist) {
        sidebarEditingPlaylistId = playlist.id
        sidebarEditingDraft = playlist.name
    }

    /// Present a delete confirmation for a playlist. Alias for
    /// `confirmDelete(playlist:)`, kept for historical call sites.
    func requestDelete(playlist: Playlist) {
        confirmDelete(playlist: playlist)
    }

    /// Raise a delete-confirmation dialog for a playlist. Sets
    /// `playlistPendingDelete`, which `MainShell` observes to present a
    /// `.confirmationDialog` with clear "Delete <playlist name>?" copy.
    /// The actual delete happens in `performDeletePending()` once the user
    /// confirms.
    func confirmDelete(playlist: Playlist) {
        playlistPendingDelete = playlist
    }

    /// Execute the pending playlist deletion, if any. Called from the
    /// confirmation dialog's destructive button. Delegates to
    /// `deletePlaylist(id:)` which owns the stub + local-remove behaviour.
    func performDeletePending() {
        guard let target = playlistPendingDelete else { return }
        playlistPendingDelete = nil
        deletePlaylist(id: target.id)
    }

    /// Dismiss the pending delete dialog without deleting anything.
    func cancelDeletePending() {
        playlistPendingDelete = nil
    }

    /// Duplicate a playlist: create a new playlist named "<original> Copy"
    /// and populate it with the same track ids. Fires-and-forgets on the
    /// main actor; the sidebar row shows a progress indicator for the
    /// source playlist while the round trip is in flight (see
    /// `sidebarCopyingPlaylistIds`). See BATCH-06b / issues #75 / #126.
    func requestDuplicate(playlist: Playlist) {
        Task { await duplicatePlaylist(id: playlist.id) }
    }

    /// Present a save panel and write the playlist to disk as an extended-M3U
    /// (`.m3u8`) file. Fetches the playlist's tracks via `playlist_tracks` FFI,
    /// then delegates the string-building to `PlaylistExport.m3u8`.
    ///
    /// Stream URLs embed the server `api_key` so the exported file is actually
    /// playable in an external player — a bare `/universal` path requires the
    /// `Authorization` header and 401s for a generic M3U player (#76 / #237).
    /// Because that bakes a credential into the file, the save panel warns the
    /// user before they write it. If the token can't be resolved, the export
    /// falls back to auth-free (prompt-on-play) URLs.
    func exportPlaylist(playlist: Playlist) {
        Task {
            // Fetch tracks before opening the panel so we know the export
            // will succeed before the user picks a save location.
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else {
                errorMessage = "No tracks to export for \"\(playlist.name)\"."
                return
            }
            // Resolve the server token off the main actor (single FFI call,
            // not per-track) so the M3U entries authenticate on their own.
            let apiKey = await resolveExportApiKey(sampleTrackId: tracks.first?.id)
            let content = PlaylistExport.m3u8(
                playlistName: playlist.name,
                tracks: tracks,
                serverURL: serverURL,
                apiKey: apiKey
            )
            writeExport(
                content,
                suggestedName: "\(playlist.name).m3u8",
                fileExtension: "m3u8",
                panelTitle: "Export Playlist as .m3u8",
                warning: apiKey == nil
                    ? nil
                    : "This .m3u8 embeds your server access key so the tracks play in another app. Anyone you share the file with can stream your library with it — treat it like a password."
            )
        }
    }

    /// Extract the Jellyfin `api_key` the app authenticates with, for embedding
    /// in an exported `.m3u8` so its entries are playable standalone. There's
    /// no dedicated token FFI, so we read it out of `core.streamUrl(...)` —
    /// which builds the same authenticated URL the audio engine streams from —
    /// and pull the `api_key` query item. Runs off the main actor (the FFI
    /// takes the Rust `Inner` mutex) and returns `nil` if the URL can't be
    /// built or carries no key, in which case the caller emits auth-free URLs.
    private func resolveExportApiKey(sampleTrackId: String?) async -> String? {
        guard let sampleTrackId else { return nil }
        let urlString: String?
        do {
            urlString = try await Task.detached(priority: .userInitiated) { [core] in
                // Only the api_key query item is read out of this URL, so the
                // bitrate cap is irrelevant — pass nil (no cap).
                try core.streamUrl(trackId: sampleTrackId, mediaSourceId: nil, playSessionId: nil, maxStreamingBitrate: nil)
            }.value
        } catch {
            return nil
        }
        guard let urlString,
              let components = URLComponents(string: urlString),
              let key = components.queryItems?.first(where: { $0.name == "api_key" })?.value,
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Present a save panel and write the playlist to disk as a JSON manifest
    /// (`.json`). Fetches the playlist's tracks via `playlist_tracks` FFI, then
    /// delegates serialization to `PlaylistExport.json`. The manifest is a
    /// stable, self-contained projection (id + ordered tracks) suitable for
    /// backup / re-import / scripting (#237).
    func exportPlaylistJSON(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else {
                errorMessage = "No tracks to export for \"\(playlist.name)\"."
                return
            }
            let content: String
            do {
                content = try PlaylistExport.json(
                    playlistId: playlist.id,
                    playlistName: playlist.name,
                    tracks: tracks
                )
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
                return
            }
            writeExport(
                content,
                suggestedName: "\(playlist.name).json",
                fileExtension: "json",
                panelTitle: "Export Playlist as JSON"
            )
        }
    }

    /// Shared `NSSavePanel` IO for the playlist export formats. Presents the
    /// panel on the main actor and writes `content` to the chosen URL, routing
    /// any failure to `errorMessage`. A user cancel is a silent no-op.
    ///
    /// `warning`, when non-nil, is shown in the panel's message area before the
    /// user commits — used by the M3U export to disclose that the file embeds a
    /// server credential.
    private func writeExport(
        _ content: String,
        suggestedName: String,
        fileExtension: String,
        panelTitle: String,
        warning: String? = nil
    ) {
        let panel = NSSavePanel()
        panel.title = panelTitle
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.init(filenameExtension: fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        if let warning {
            panel.message = warning
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Rename a playlist in place from the playlist hero's click-to-edit
    /// title (#234). Thin wrapper around `renamePlaylist(id:, newName:)`
    /// so the hero and the sidebar share a single code path.
    func renamePlaylist(_ playlist: Playlist, newName: String) {
        renamePlaylist(id: playlist.id, newName: newName)
    }

    /// Update the in-memory description (Jellyfin `Overview`) for a playlist.
    ///
    /// Currently UNCALLED: there is no `update_playlist` FFI (#130), so this
    /// can't persist, and the playlist hero (`PlaylistView`) therefore renders
    /// the description read-only rather than wiring a click-to-edit editor to
    /// it. The method only logs and stashes the text in the in-memory
    /// `playlistDescriptions` map keyed by playlist id; it is held in place
    /// for when the backing FFI lands. Do not wire it to the UI before then.
    ///
    /// TODO: #130 — switch this to `core.updatePlaylist(playlistId:, overview:)`
    /// once the FFI lands, then surface a real editor in the hero and drop
    /// `playlistDescriptions` entirely in favour of a
    /// `description: Option<String>` field on `Playlist` in
    /// `core/src/models.rs`.
    func updatePlaylistDescription(_ playlist: Playlist, newDescription: String) {
        let trimmed = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // TODO: #130 — persist via `core.updatePlaylist` once available.
        Log.app.notice("updatePlaylistDescription(\(playlist.id, privacy: .public)) not yet persisted — see #130")
        if trimmed.isEmpty {
            playlistDescriptions.removeValue(forKey: playlist.id)
        } else {
            playlistDescriptions[playlist.id] = trimmed
        }
    }

    // MARK: - Sidebar playlist CRUD (BATCH-06b, #71 / #73 / #75)

    /// Drop a placeholder row into edit mode so Cmd+N feels instant. The
    /// placeholder is identified by `sidebarNewPlaylistSentinel`; the
    /// sidebar renders a single TextField in its slot. Committing via
    /// `commitSidebarPlaylistEdit` turns this into a real `create_playlist`
    /// call; Escape / empty-blur bails out via `cancelSidebarPlaylistEdit`.
    /// See issue #71.
    func beginNewPlaylist() {
        sidebarEditingPlaylistId = Self.sidebarNewPlaylistSentinel
        sidebarEditingDraft = ""
    }

    /// Dismiss the inline TextField without saving. Used for Escape /
    /// blur-with-empty-text on a new-playlist row, and for blur-without-
    /// change on a rename-in-progress row.
    func cancelSidebarPlaylistEdit() {
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
    }

    /// Commit the current sidebar draft. Branches on the editing id:
    ///   - `sidebarNewPlaylistSentinel` → `createPlaylist(name:)`;
    ///   - any other id → `renamePlaylist(id:, newName:)`.
    /// An empty or whitespace-only draft is treated as cancel, matching
    /// macOS Finder conventions for inline rename. See #71 / #75.
    func commitSidebarPlaylistEdit() async {
        guard let editingId = sidebarEditingPlaylistId else { return }
        let trimmed = sidebarEditingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear the edit state up-front so the TextField unmounts before the
        // async create / rename completes; prevents the view from appearing
        // "stuck" on slow networks.
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
        guard !trimmed.isEmpty else { return }
        if editingId == Self.sidebarNewPlaylistSentinel {
            await createPlaylist(name: trimmed)
        } else {
            renamePlaylist(id: editingId, newName: trimmed)
        }
    }

    /// Create a new (empty) playlist on the server and prepend it to the
    /// in-memory `playlists` list so the sidebar surfaces it immediately.
    /// Backed by `core.createPlaylist(name:, itemIds:)` — see #126.
    /// A thin optimistic update: if the core call fails we fall back to
    /// an `errorMessage` and do not insert the row.
    func createPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let newId = try await Task.detached(priority: .userInitiated) { [core] in
                try core.createPlaylist(name: trimmed, itemIds: [])
            }.value
            // The core returns only the id; build a minimal `Playlist`
            // record client-side rather than refetching. An `imageTag` of
            // `nil` falls through to the gradient placeholder until the
            // next library refresh picks up the server's Primary tag.
            let newPlaylist = Playlist(
                id: newId,
                name: trimmed,
                trackCount: 0,
                runtimeTicks: 0,
                imageTag: nil,
                userData: nil
            )
            playlists.insert(newPlaylist, at: 0)
        } catch {
            errorMessage = "Create playlist failed: \(error.localizedDescription)"
        }
    }

    /// Rename a playlist by id. Optimistically updates the in-memory list
    /// first for instant UI feedback, then persists to the server via
    /// `core.renamePlaylist`. On failure the old name is restored and
    /// `errorMessage` surfaces the failure.
    func renamePlaylist(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let existing = playlists[idx]
        guard trimmed != existing.name else { return }
        // Optimistic update so the sidebar / hero reflects the new name
        // before the network round-trip completes.
        playlists[idx] = Playlist(
            id: existing.id,
            name: trimmed,
            trackCount: existing.trackCount,
            runtimeTicks: existing.runtimeTicks,
            imageTag: existing.imageTag,
            userData: existing.userData
        )
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.renamePlaylist(playlistId: id, newName: trimmed)
                }.value
                serverReachability.noteSuccess()
            } catch {
                if handleAuthError(error) { return }
                // Rollback the optimistic rename on failure.
                if let rollbackIdx = playlists.firstIndex(where: { $0.id == id }) {
                    playlists[rollbackIdx] = existing
                }
                errorMessage = "Rename failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
    }

    /// Duplicate a playlist: create "<original> Copy" and seed it with the
    /// same tracks via `add_to_playlist`. Shows a per-row spinner while the
    /// two round trips are in flight (tracked in
    /// `sidebarCopyingPlaylistIds`). No-op if the source playlist isn't in
    /// the in-memory list. See #75 / #126.
    func duplicatePlaylist(id: String) async {
        guard let source = playlists.first(where: { $0.id == id }) else { return }
        sidebarCopyingPlaylistIds.insert(id)
        defer { sidebarCopyingPlaylistIds.remove(id) }

        // Gather every track id on the source playlist so the copy starts
        // with the same contents. `loadAllPlaylistTracks` already walks the
        // server in pages and caps pathological playlists at the safety
        // limit — reusing it keeps behaviour consistent with what the
        // user sees in the detail view.
        let tracks = await loadAllPlaylistTracks(playlistID: source.id)
        let trackIds = tracks.map(\.id)
        let copyName = "\(source.name) Copy"
        do {
            let newId = try await Task.detached(priority: .userInitiated) { [core] in
                try core.createPlaylist(name: copyName, itemIds: trackIds)
            }.value
            // Core's `create_playlist` can accept seed items directly; the
            // `itemIds` path above covers the common case. We still build a
            // fresh `Playlist` record locally rather than refetch.
            let newPlaylist = Playlist(
                id: newId,
                name: copyName,
                trackCount: UInt32(trackIds.count),
                runtimeTicks: source.runtimeTicks,
                imageTag: nil,
                userData: nil
            )
            playlists.insert(newPlaylist, at: 0)
            // Prime the tracks cache so the detail view doesn't have to
            // re-walk the server the first time the user opens the copy.
            if !tracks.isEmpty {
                playlistTracks[newId] = tracks
            }
        } catch {
            errorMessage = "Duplicate playlist failed: \(error.localizedDescription)"
        }
    }

    /// Delete a playlist. Optimistically removes the playlist from
    /// the in-memory list for instant UI feedback, then persists the
    /// deletion to the server via `core.deletePlaylist`. On failure
    /// the playlist is re-inserted at its original position and
    /// `errorMessage` surfaces the failure.
    func deletePlaylist(id: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let removed = playlists[idx]
        let removedTracks = playlistTracks[id]
        let removedDescription = playlistDescriptions[id]
        // Optimistic drop.
        playlists.remove(at: idx)
        playlistTracks.removeValue(forKey: id)
        playlistDescriptions.removeValue(forKey: id)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.deletePlaylist(playlistId: id)
                }.value
                serverReachability.noteSuccess()
            } catch {
                if handleAuthError(error) { return }
                // Rollback the optimistic delete on failure.
                let insertIdx = min(idx, playlists.count)
                playlists.insert(removed, at: insertIdx)
                if let tracks = removedTracks { playlistTracks[id] = tracks }
                if let desc = removedDescription { playlistDescriptions[id] = desc }
                errorMessage = "Delete failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
    }

    /// Resolve a dropped track id (from the drag-reorder affordance in
    /// `PlaylistReorderHandle`) back to an index and dispatch the move.
    /// Separated from `moveTrackInPlaylist` so the drop delegate doesn't
    /// need to hold an index snapshot that could go stale by the time the
    /// async `NSItemProvider` callback fires.
    func applyPlaylistDrop(playlistId: String, trackId: String, destinationIndex: Int) {
        guard let tracks = playlistTracks[playlistId] else { return }
        guard let sourceIndex = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        moveTrackInPlaylist(playlistId: playlistId, from: sourceIndex, to: destinationIndex)
    }

    /// Index-addressed variant of `applyPlaylistDrop`. The drag payload carries
    /// the source row's index (see `PlaylistReorderPayload`), which is the only
    /// thing that disambiguates a duplicated track: when the same track id
    /// appears more than once in a playlist, resolving by id alone always moves
    /// the first copy. Routing by index moves the exact copy the user grabbed.
    ///
    /// The index is validated against the *current* cached order before the
    /// move, so a stale index from a list that mutated mid-drag is dropped
    /// rather than moving the wrong row.
    func applyPlaylistDrop(playlistId: String, sourceIndex: Int, destinationIndex: Int) {
        guard let tracks = playlistTracks[playlistId] else { return }
        guard sourceIndex >= 0, sourceIndex < tracks.count else { return }
        moveTrackInPlaylist(playlistId: playlistId, from: sourceIndex, to: destinationIndex)
    }

    /// Reorder a track within a playlist. Applies the move to the local
    /// cache immediately (optimistic update), then calls
    /// `core.reorderPlaylistTrack` to persist the new position on the server.
    /// Requires the moved track to carry a `playlistItemId` — if it doesn't
    /// (e.g. old cached data pre-dating the `PlaylistItemId` field), the move
    /// is local-only and an error is logged.
    ///
    /// Indices are relative to the current cached order in
    /// `playlistTracks[playlistId]`. The semantics match SwiftUI's native
    /// `Array.move(fromOffsets:toOffset:)` so the detail view can feed its
    /// drop position straight through.
    func moveTrackInPlaylist(playlistId: String, from: Int, to: Int) {
        guard var tracks = playlistTracks[playlistId] else { return }
        guard from >= 0, from < tracks.count else { return }
        // SwiftUI's `move(fromOffsets:toOffset:)` accepts `to` as an
        // insertion index in the pre-move list, so the valid range is
        // [0, tracks.count]. `from == to` and `from + 1 == to` are both
        // no-ops — bail early to avoid a needless assignment + notify.
        guard to >= 0, to <= tracks.count else { return }
        guard to != from, to != from + 1 else { return }
        let movedTrack = tracks[from]
        tracks.remove(at: from)
        let insertIndex = to > from ? to - 1 : to
        tracks.insert(movedTrack, at: insertIndex)
        playlistTracks[playlistId] = tracks
        // Keep currentPlaylistTracks in sync if this playlist is currently shown.
        if !currentPlaylistTracks.isEmpty {
            currentPlaylistTracks = tracks
        }
        // Persist the reorder to the server if the track carries a PlaylistItemId.
        guard let playlistItemId = movedTrack.playlistItemId else {
            Log.app.notice("moveTrackInPlaylist(\(playlistId, privacy: .public)) — track missing PlaylistItemId, local-only")
            return
        }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.reorderPlaylistTrack(
                        playlistId: playlistId,
                        playlistItemId: playlistItemId,
                        newIndex: UInt32(insertIndex)
                    )
                }.value
                serverReachability.noteSuccess()
            } catch {
                if handleAuthError(error) { return }
                errorMessage = "Reorder failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
    }

    // MARK: - Playlist sharing

    /// Jellyfin web URL for a playlist, e.g.
    /// `https://server.example.com/web/#/details?id=<playlistId>`. The Jellyfin
    /// web UI uses the same `details` route for albums, artists, and playlists.
    ///
    /// Routes through `PlaylistExport.webURL`, which strips any embedded
    /// credentials / query / fragment from the stored server URL so a copied
    /// "Copy Link" never leaks a password or token (#237).
    func webURL(for playlist: Playlist) -> URL? {
        PlaylistExport.webURL(serverURL: serverURL, itemId: playlist.id)
    }

    /// Copy the playlist's web URL to the system pasteboard.
    func copyShareLink(playlist: Playlist) {
        guard let url = webURL(for: playlist) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the playlist in the Jellyfin web UI.
    func openInJellyfin(playlist: Playlist) {
        guard let url = webURL(for: playlist) else { return }
        NSWorkspace.shared.open(url)
    }
}
