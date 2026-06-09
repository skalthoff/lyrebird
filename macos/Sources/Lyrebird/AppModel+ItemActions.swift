import AppKit
import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Context-menu actions and share links for library items — albums, artists,
/// and individual tracks. Backs `AlbumContextMenu` / `ArtistContextMenu` /
/// `TrackContextMenu` and the artist/track detail action bars: play / shuffle
/// / play-next / add-to-queue / instant-mix radio, favorite & follow toggles,
/// multi-select favorite / download / mark-played, add/remove-from-playlist,
/// navigation jumps, and Jellyfin web-link sharing.
///
/// Stored UI state stays on the main `AppModel` class — `trackInfoSubject`
/// (the track-info sheet anchor) can't move to an extension. Extensions of a
/// `@MainActor` type inherit its isolation, so every method here is
/// main-actor-bound just like the rest of the class.
extension AppModel {
    // MARK: - Sharing

    /// Jellyfin web URL for an album, e.g.
    /// `https://server.example.com/web/#/details?id=<albumId>`.
    func webURL(for album: Album) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(album.id)")
    }

    /// Copy the album's web URL to the system pasteboard.
    func copyShareLink(album: Album) {
        guard let url = webURL(for: album) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the album in the Jellyfin web UI.
    func openInJellyfin(album: Album) {
        guard let url = webURL(for: album) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Artist actions

    /// Play every track in an artist's catalog (album → disc → track order).
    /// Caps at the soft 500-track ceiling — prolific artists may have more,
    /// but the player gets a deterministic prefix that matches what
    /// `tracks_by_artist` returned. See #156.
    func playAll(artist: Artist) {
        Task {
            let tracks = await loadTracks(forArtist: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle every track in an artist's catalog. Loads in catalog order,
    /// shuffles client-side, plays from the head. Same 500-track soft cap
    /// as `playAll(artist:)`. See #156.
    func shuffle(artist: Artist) {
        Task {
            let tracks = await loadTracks(forArtist: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Internal helper — fetch the first page of an artist's catalog via the
    /// `tracks_by_artist` FFI. Mirrors `loadTracks(forAlbum:)` in shape so
    /// `playAll(artist:)` / `shuffle(artist:)` collapse to a one-liner. The
    /// 500-row limit is a deliberate soft cap to keep the FFI / queue under
    /// a single round-trip. See #156.
    private func loadTracks(forArtist artistId: String) async -> [Track] {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.tracksByArtist(artistId: artistId, offset: 0, limit: 500)
            }.value
            return page.items
        } catch {
            if !handleAuthError(error) {
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
            }
            return []
        }
    }

    /// Play the artist's top tracks (play-count-weighted). Fetches the
    /// top 5 via the core, then starts playback from the first. See #229.
    func playTopTracks(artist: Artist) {
        Task {
            let tracks = await loadArtistTopTracks(artistId: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Toggle the favorite flag for an artist on the Jellyfin server.
    /// Jellyfin's `/Users/{id}/FavoriteItems/{id}` endpoint is polymorphic,
    /// so the same `set_favorite` / `unset_favorite` FFI used for albums
    /// and tracks works on artist ids too.
    func toggleFavorite(artist: Artist) {
        Task { await setFavorite(itemId: artist.id, enabled: !isFavorite(artist: artist)) }
    }

    /// Toggle the follow flag for an artist. Routes through `setFavorite`
    /// since Jellyfin's `/Users/{id}/FavoriteItems/{id}` endpoint is the
    /// correct server primitive for "following" an artist — the vocabulary
    /// differs but the data is the same `IsFavorite` flag on the artist item.
    func toggleFollow(artist: Artist) {
        Task { await setFavorite(itemId: artist.id, enabled: !isFavorite(artist: artist)) }
    }

    /// `true` when the user has favorited/followed this artist.
    /// Snapshot-aware so first-paint state matches the server even before
    /// the user toggles — see `isFavorite(artist:)` for the fallback chain.
    func isFollowing(artist: Artist) -> Bool {
        isFavorite(artist: artist)
    }

    /// Insert the artist's full catalog immediately after the currently-playing
    /// track. Loads the same track set as `playAll(artist:)` / `shuffle(artist:)`
    /// (via `loadTracks(forArtist:)`, the 500-track soft cap) so "Play Next"
    /// queues the whole artist — matching `playNext(album:)` — rather than just
    /// the top-tracks teaser. Uses the `core.playNext` primitive wired in for
    /// #282; falls back to `play` when nothing is currently playing so the menu
    /// item never queues into an empty player. Silent no-op when the artist has
    /// no loadable tracks.
    func playNextArtist(artist: Artist) {
        Task {
            let tracks = await loadTracks(forArtist: artist.id)
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

    /// Navigate to the artist detail screen. Used when the menu is invoked
    /// from a surface other than the artist detail itself (e.g. a track
    /// row whose secondary line is the artist).
    func goToArtistPage(artist: Artist) {
        navPath.append(Route.artist(artist.id))
    }

    /// Kick off an Instant Mix ("artist radio") seeded by this artist.
    func startArtistRadio(artist: Artist) {
        playInstantMix(seedId: artist.id, seedName: artist.name)
    }

    /// Navigate to the artist detail screen, anchored on the discography.
    /// The artist detail screen itself is tracked in #58 / #60 / #408; for now
    /// we just route to `.artist(id)` and let that view (when it lands) pick
    /// up the discography anchor.
    func goToDiscography(artist: Artist) {
        navPath.append(Route.artist(artist.id))
    }

    /// Show artists similar to this one. Navigates to the artist detail page
    /// and pre-warms the similar-artists cache so the row is ready when the
    /// view appears. Backed by `core.similarArtists` via `loadSimilarArtists`.
    /// See #146.
    func showSimilar(artist: Artist) {
        Task {
            await loadSimilarArtists(artistId: artist.id)
        }
        navPath.append(Route.artist(artist.id))
    }

    // MARK: - Artist sharing

    /// Jellyfin web URL for an artist, e.g.
    /// `https://server.example.com/web/#/details?id=<artistId>`.
    func webURL(for artist: Artist) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(artist.id)")
    }

    /// Copy the artist's web URL to the system pasteboard.
    func copyShareLink(artist: Artist) {
        guard let url = webURL(for: artist) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the artist in the Jellyfin web UI.
    func openInJellyfin(artist: Artist) {
        guard let url = webURL(for: artist) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Track actions
    //
    // Backing calls for `TrackContextMenu`. Accept `[Track]` rather than a
    // single `Track` so the same surface handles single-row and multi-select
    // invocations — spec in #95 / #310 / #315. Most of these are TODO stubs
    // pending follow-up FFI work (queue primitives #282, favorites #133,
    // download engine #819, mark-played #133, song radio #144, metadata
    // editor #96).

    /// Insert a selection of tracks immediately after the currently-playing
    /// track. Wired to `core.playNext` for #282; when nothing is playing
    /// falls back to `play(tracks:)` so the menu item always does something.
    func playNext(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if status.currentTrack == nil {
            play(tracks: tracks, startIndex: 0)
            return
        }
        Task {
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

    /// Append a selection of tracks to the end of the queue. Wired to
    /// `core.addToQueue` for #282; when nothing is playing falls back to
    /// `play(tracks:)`.
    func addToQueue(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if status.currentTrack == nil {
            play(tracks: tracks, startIndex: 0)
            return
        }
        Task {
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

    /// Kick off an Instant Mix ("song radio") seeded by a single track.
    /// Kick off an Instant Mix ("song radio") seeded by this track.
    func startSongRadio(track: Track) {
        playInstantMix(seedId: track.id, seedName: track.name)
    }

    /// Routing for the Discover-screen "Song Radio" CTA (#255), split out from
    /// the SwiftUI closure so the seed-source decision is unit-testable.
    /// Returns the action it dispatched so tests can assert the branch without
    /// reaching into the FFI: `.songRadio` when a track is playing, `.instantMix`
    /// when nothing is, which leans on `startInstantMix`'s own library fallback
    /// rather than dead-ending the button.
    @discardableResult
    func startDiscoverSongRadio() -> SongRadioRoute {
        if let current = status.currentTrack {
            startSongRadio(track: current)
            return .songRadio
        }
        startInstantMix()
        return .instantMix
    }

    /// Which seed source `startDiscoverSongRadio()` dispatched to.
    enum SongRadioRoute: Equatable {
        case songRadio
        case instantMix
    }

    /// Append a selection of tracks to a user-picked playlist.
    /// Route-through to the async `addToPlaylist(trackIds:playlistId:)`
    /// so every context menu **Add to Playlist** entry actually hits the
    /// server.
    func addTracksToPlaylist(tracks: [Track], playlist: Playlist) {
        guard !tracks.isEmpty else { return }
        Task { await addToPlaylist(trackIds: tracks.map(\.id), playlistId: playlist.id) }
    }

    /// Navigate to the album detail screen for this track's album.
    func goToAlbum(track: Track) {
        guard let albumID = track.albumId else { return }
        navPath.append(Route.album(albumID))
    }

    /// Navigate to the artist detail screen for this track's artist.
    func goToArtist(track: Track) {
        guard let artistID = track.artistId else { return }
        navPath.append(Route.artist(artistID))
    }

    /// Present the per-track info sheet (title, album, year, runtime,
    /// codec/bitrate, play count). Read-only landing — edit-in-place is
    /// tracked under #96 and arrives separately. The sheet itself lives at
    /// `Components/TrackInfoSheet.swift`; mounting happens on `MainShell`
    /// driven by `trackInfoSubject`. See #95.
    func showTrackInfo(track: Track) {
        trackInfoSubject = track
    }

    /// Remove a selection of tracks from a specific playlist. Used by the
    /// multi-select context menu when scoped to a playlist detail view.
    /// Delegates to `removeFromPlaylist(playlistId:entryIds:)` which also
    /// handles the optimistic UI + server sync.
    func removeTracksFromPlaylist(tracks: [Track], playlist: Playlist) {
        guard !tracks.isEmpty else { return }
        removeFromPlaylist(playlistId: playlist.id, entryIds: tracks.map(\.id))
    }

    /// Toggle favorite across every track in the selection. If every track
    /// is already favorited, this unfavorites them all; otherwise favorites
    /// the un-favorited subset.
    func toggleFavorite(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let allFavorited = tracks.allSatisfy { isFavorite(track: $0) }
        let target = !allFavorited
        // Fire each toggle on its own task so partial success is preserved —
        // one rate-limit or 500 doesn't poison the rest of the selection.
        for track in tracks {
            // Skip tracks already in the target state so we don't retoggle.
            guard isFavorite(track: track) != target else { continue }
            Task { await setFavorite(itemId: track.id, enabled: target) }
        }
    }

    /// Toggle the download state across a multi-select of tracks (#819).
    ///
    /// Target direction mirrors the favorite/played multi-select convention:
    /// when **every** selected track is already downloaded, the action removes
    /// them all; otherwise it downloads the ones that aren't already done (or
    /// in flight). Gated behind `supportsDownloads`.
    func toggleDownload(tracks: [Track]) {
        guard supportsDownloads, !tracks.isEmpty else { return }
        let allDownloaded = tracks.allSatisfy { downloadStateById[$0.id] == .done }
        if allDownloaded {
            Task { await removeDownloads(tracks) }
        } else {
            let pending = tracks.filter {
                downloadStateById[$0.id] != .done && !downloadsInFlight.contains($0.id)
            }
            guard !pending.isEmpty else { return }
            Task { await downloadTracks(pending) }
        }
    }

    /// Toggle the played flag across a multi-select of tracks. Target
    /// state is "everyone unplayed" if **all** selected tracks are
    /// currently played; otherwise "everyone played". This matches the
    /// menubar / context-menu convention where a single click on a
    /// mixed selection commits to one direction. Each track's flip is
    /// optimistic locally and reconciled against the server's response;
    /// failures don't abort the rest of the batch. See #133.
    func toggleMarkPlayed(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // Decide target: prefer the cached value, fall back to the track's
        // embedded user_data, finally `false` if nothing is known. Mark
        // played unless every track is *already* played.
        let allPlayed = tracks.allSatisfy { track in
            if let cached = playedById[track.id] { return cached }
            return track.userData?.played ?? false
        }
        let target = !allPlayed
        // Optimistic flip on the whole selection so the glyph updates instantly.
        for track in tracks { playedById[track.id] = target }
        Task {
            for track in tracks {
                await setPlayed(itemId: track.id, played: target)
            }
        }
    }

    // MARK: - Track sharing

    /// Jellyfin web URL for a single track. Jellyfin's web UI uses the
    /// same `details` route for every item type, so this mirrors
    /// `webURL(for album:)` / `webURL(for playlist:)`.
    func webURL(for track: Track) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(track.id)")
    }

    /// Copy the track's web URL to the system pasteboard.
    func copyShareLink(track: Track) {
        guard let url = webURL(for: track) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }
}
