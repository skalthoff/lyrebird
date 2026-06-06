import Foundation
import os
@preconcurrency import LyrebirdCore

/// Library data loading on `AppModel`: paged fetch + load-more for albums,
/// artists, tracks, and playlists; the recently-played / For-You / genre
/// shelves; and the `/Items`-query album & favorite-track fetchers that back
/// the Home and Discover surfaces. The list/total/loading state these write
/// into is `@Observable` stored state on the main class; these loaders refresh
/// it off-main and write it back. Extensions of a `@MainActor` type inherit its
/// isolation, so every method here stays main-actor-bound like the rest of the
/// class.
extension AppModel {
    func refreshLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        // Fetch albums, artists, tracks, and playlists in parallel. Previously
        // the album/artist calls were sequential, doubling time-to-first-paint
        // on every fresh session; `async let` lets all round-trips overlap.
        // Playlists are wired in alongside so switching to the Playlists chip
        // doesn't trigger a first-paint spinner. The smaller
        // `libraryInitialPageSize` (100 vs. the old 200) is a further
        // first-paint win — the grid fills the viewport with 100 and the
        // per-tab `loadMore*` paths take over when the user scrolls.
        //
        // Playlists go through their own try/catch because the library id
        // resolution can fail independently (no playlist library on the
        // server, or an error from a hypothetical future `core.libraries()`)
        // and we don't want that to sink the albums/artists/tracks fetch.
        async let albumsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listAlbums(offset: 0, limit: libraryInitialPageSize)
        }.value
        async let artistsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listArtists(offset: 0, limit: libraryInitialPageSize)
        }.value
        async let tracksPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listTracks(musicLibraryId: nil, offset: 0, limit: libraryInitialPageSize)
        }.value
        async let playlistsResult: Void = refreshPlaylists()
        // Each loader gets its own try/catch so one failure (typically a
        // transient 5xx on a single endpoint) doesn't drop the other two.
        // Before, the tuple-destructure `try await (a, b, c)` cancelled the
        // assignments for all three on any single error — Library rendered
        // empty even when two of the three endpoints succeeded.
        var anySucceeded = false
        do {
            let albums = try await albumsPage
            self.albums = albums.items
            self.albumsTotal = albums.totalCount
            anySucceeded = true
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
        do {
            let artists = try await artistsPage
            self.artists = artists.items
            self.artistsTotal = artists.totalCount
            anySucceeded = true
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
        do {
            let tracks = try await tracksPage
            self.tracks = tracks.items
            self.tracksTotal = tracks.totalCount
            anySucceeded = true
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
        if anySucceeded {
            serverReachability.noteSuccess()
        }
        _ = await playlistsResult
        await refreshRecentlyPlayed()
        await refreshForYou()
        await refreshGenresToExplore()
        await refreshBrowseGenres()
        // Home screen carousels (#49 / #51–#55). Kicked off after the main
        // library so first paint isn't blocked on these secondary shelves.
        // Each of these is best-effort — empty or errored rows just hide in
        // the Home layout.
        await refreshJumpBackIn()
        await refreshRecentlyAdded()
        await refreshQuickPicks()
        await refreshFavoriteAlbums()
        await refreshFavoriteArtists()
        await refreshRecentlyDiscoveredArtists()
        await refreshRediscover()
        await refreshSuggestions()
    }

    /// Fetch the next page of albums and append to `albums`. No-op when a
    /// page is already in flight or when the local count has caught up to
    /// `albumsTotal`. Called from `LibraryView`'s near-end `.onAppear`
    /// trigger — see `LibraryView.swift`.
    func loadMoreAlbums() async {
        guard !isLoadingMoreAlbums else { return }
        guard albumsTotal == 0 || albums.count < Int(albumsTotal) else { return }
        isLoadingMoreAlbums = true
        defer { isLoadingMoreAlbums = false }
        let offset = UInt32(albums.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listAlbums(offset: offset, limit: libraryPageSize)
            }.value
            self.albums.append(contentsOf: page.items)
            self.albumsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Fetch the next page of artists and append to `artists`. Mirror of
    /// `loadMoreAlbums` — see its docs for the trigger contract.
    func loadMoreArtists() async {
        guard !isLoadingMoreArtists else { return }
        guard artistsTotal == 0 || artists.count < Int(artistsTotal) else { return }
        isLoadingMoreArtists = true
        defer { isLoadingMoreArtists = false }
        let offset = UInt32(artists.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listArtists(offset: offset, limit: libraryPageSize)
            }.value
            self.artists.append(contentsOf: page.items)
            self.artistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Refetch the first page of library tracks for the All Tracks tab.
    /// Called from `refreshLibrary` (inline as an `async let`) on session
    /// establishment, and available for an explicit retry path later.
    /// Matches `refreshRecentlyPlayed` in shape — stores items + total.
    func refreshTracks() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.listTracks(musicLibraryId: nil, offset: 0, limit: libraryInitialPageSize)
            }.value
            self.tracks = page.items
            self.tracksTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Fetch the next page of tracks and append to `tracks`. Mirror of
    /// `loadMoreAlbums` — see its docs for the trigger contract.
    func loadMoreTracks() async {
        guard !isLoadingMoreTracks else { return }
        guard tracksTotal == 0 || tracks.count < Int(tracksTotal) else { return }
        isLoadingMoreTracks = true
        defer { isLoadingMoreTracks = false }
        let offset = UInt32(tracks.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listTracks(musicLibraryId: nil, offset: offset, limit: libraryPageSize)
            }.value
            self.tracks.append(contentsOf: page.items)
            self.tracksTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Resolve (and cache) the `ParentId` to scope playlist queries by.
    ///
    /// Calls `core.playlistLibraryId()` once, which hits
    /// `/Users/{id}/Views` and picks the CollectionFolder whose
    /// `CollectionType == "playlists"`. On failure we fall back to the
    /// empty string — Jellyfin's `/Items` endpoint treats an empty
    /// `ParentId` as "no filter", and the client-side `Path`-based filter
    /// in `user_playlists` / `public_playlists` still yields a correct set,
    /// just with more server-side work.
    func ensurePlaylistLibraryId() async -> String {
        if let cached = playlistLibraryId { return cached }
        let resolved: String
        do {
            resolved = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistLibraryId()
            }.value
        } catch {
            Log.net.error("ensurePlaylistLibraryId: core.playlistLibraryId() failed (\(error.localizedDescription, privacy: .public)); falling back to empty ParentId.")
            resolved = ""
        }
        playlistLibraryId = resolved
        return resolved
    }

    /// Fetch the first page of user-owned playlists for the Library screen's
    /// Playlists chip. Wired into `refreshLibrary` so the chip is populated
    /// before the user clicks it. Parallels `loadMoreAlbums` for the error
    /// / auth / reachability story.
    ///
    /// Uses `user_playlists` (user-owned) rather than `public_playlists`. The
    /// Playlists tab spec (#212) describes "your playlists"; a separate
    /// "Community" affordance for public playlists is a future concern.
    func refreshPlaylists() async {
        let libraryId = await ensurePlaylistLibraryId()
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.userPlaylists(
                    playlistLibraryId: libraryId,
                    offset: 0,
                    limit: libraryInitialPageSize
                )
            }.value
            self.playlists = page.items
            self.playlistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            // Silent-ish: don't clobber the albums/artists error banner if
            // both fail in the same refresh. The Playlists tab empty state
            // already explains "nothing to see here" when `playlists` is
            // empty.
            Log.net.error("refreshPlaylists failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetch the next page of playlists and append to `playlists`. Mirror
    /// of `loadMoreAlbums` — see its docs for the trigger contract.
    ///
    /// Server-side total caveat: `user_playlists` filters results client-
    /// side by `Path`, so `playlistsTotal` is an upper bound on the raw
    /// server count, not on `playlists.count`. The `<` guard below uses the
    /// raw total deliberately — stopping at `playlists.count >= total` is
    /// safe even when the two drift, because the server itself won't return
    /// more items past its total and we'd bail on an empty page anyway.
    func loadMorePlaylists() async {
        guard !isLoadingMorePlaylists else { return }
        guard playlistsTotal == 0 || playlists.count < Int(playlistsTotal) else { return }
        isLoadingMorePlaylists = true
        defer { isLoadingMorePlaylists = false }
        let libraryId = await ensurePlaylistLibraryId()
        let offset = UInt32(playlists.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.userPlaylists(
                    playlistLibraryId: libraryId,
                    offset: offset,
                    limit: libraryPageSize
                )
            }.value
            self.playlists.append(contentsOf: page.items)
            self.playlistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistsLoad)
        }
    }

    /// Fetch the user's recently played tracks for the Home screen carousel
    /// (#206). Passes `nil` for the music library id so the core returns
    /// tracks across all music libraries the user can see. Failures are
    /// swallowed silently — an empty carousel is preferable to an error
    /// banner for a best-effort Home widget.
    ///
    /// Stores `totalCount` alongside the page so a future "See all" view can
    /// expand the carousel without issuing another count query.
    func refreshRecentlyPlayed() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, recentlyPlayedInitialPageSize] in
                try core.recentlyPlayed(
                    musicLibraryId: nil,
                    offset: 0,
                    limit: recentlyPlayedInitialPageSize
                )
            }.value
            self.recentlyPlayed = page.items
            self.recentlyPlayedTotal = page.totalCount
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            _ = handleAuthError(error)
        }
    }

    /// Load ALL tracks on a playlist by paging through `playlist_tracks` in
    /// chunks of `playlistPageSize` until `totalCount` is reached or the
    /// `playlistSafetyCap` is hit. Returns as soon as any page fails. No UI
    /// wiring calls this yet (playlist detail screen is #313 et al), but the
    /// FFI is now paginated so the caller that lands it can rely on "pass
    /// this a playlist id and get every track". See #125 / #429.
    func loadAllPlaylistTracks(playlistID: String) async -> [Track] {
        var all: [Track] = []
        var offset: UInt32 = 0
        let limit = playlistPageSize
        let cap = playlistSafetyCap
        do {
            while all.count < cap {
                let page = try await Task.detached(priority: .userInitiated) { [core] in
                    try core.playlistTracks(
                        playlistId: playlistID,
                        offset: offset,
                        limit: limit
                    )
                }.value
                all.append(contentsOf: page.items)
                if page.items.isEmpty { break }
                if all.count >= Int(page.totalCount) { break }
                offset = UInt32(all.count)
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return all }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistLoad)
        }
        return all
    }

    /// Refresh the Discover "For You" carousel (#249). Until the core exposes
    /// a real recommendations endpoint (e.g. Jellyfin Items/Suggestions or a
    /// client-side "artists similar to top-3 played, minus already-played"
    /// algorithm per research/06-screen-specs.md), this is a best-effort
    /// stub that mirrors the first 20 recently played tracks so the shelf is
    /// never empty for an active listener. If `recentlyPlayed` is empty the
    /// carousel hides itself rather than showing nothing-of-interest.
    ///
    /// TODO: replace this stub with a real `core.recommendations(limit: 20)`
    /// FFI call once it lands. At that point the view layer stays unchanged —
    /// only the body of this method needs swapping.
    func refreshForYou() async {
        // Best-effort fallback: reuse the recently played tracks we already
        // fetched. Capped at 20 so the carousel stays tight even if the core
        // later starts returning a longer list.
        self.forYou = Array(recentlyPlayed.prefix(20))
    }

    /// Refresh the Discover "Genres to Explore" grid (#250).
    ///
    /// Pulls one page of `/MusicGenres` (already filtered server-side to
    /// genres that carry Audio/Album/Artist items), keeps only those present
    /// in the library (`song_count > 0`), then ranks them so the *least*
    /// explored bubble to the top. Jellyfin's `/MusicGenres` projection
    /// carries no per-genre play count, so we approximate "least-played" with
    /// ascending `song_count` (the smallest real genres are the ones a user
    /// is least likely to have worked through), tie-broken by name for a
    /// stable order. Capped at 8 to fill the 4×2 grid.
    ///
    /// Runs the sync `core.genres` FFI off the MainActor (gap pattern #2) and
    /// marshals the ranked result back. Failures leave the prior grid intact
    /// rather than blanking the section mid-session.
    func refreshGenresToExplore() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                // limit: 500 matches `resolvedGenreId`'s fetch — /MusicGenres sorts
                // SortName ascending, so a smaller cap would silently drop
                // alphabetically-late genres from the ranking pool (the test
                // library has 254 genres).
                try core.genres(offset: 0, limit: 500)
            }.value
            // Project the FFI genres to plain tuples before ranking. Passing the
            // `core.Genre` struct directly would force a `LyrebirdCore.Genre`
            // annotation, which the generated `open class LyrebirdCore` shadows
            // (module-vs-type name collision — same reason `resolvedGenreId`
            // tuple-extracts). Tuples keep the ranking helper pure + testable.
            self.genresToExplore = AppModel.rankGenresToExplore(
                page.items.map { (id: $0.id, name: $0.name, songCount: $0.songCount) }
            )
        } catch {
            // Auth expiry must surface so the user is routed to re-login, matching
            // every other refresh path. Non-auth failures leave the prior grid
            // intact rather than blanking the section mid-session.
            _ = handleAuthError(error)
        }
    }

    /// Pure ranking for the "Genres to Explore" grid (#250), split out from
    /// the FFI hop so it's unit-testable without a live core. Keeps only
    /// genres present in the library (`song_count > 0`), ranks ascending by
    /// `song_count` (least-explored first) with a case-insensitive name
    /// tiebreaker for stable order, caps at 8 for the 4×2 grid, and carries
    /// the resolved Jellyfin UUID through into the local `Genre.id`.
    static func rankGenresToExplore(
        _ genres: [(id: String, name: String, songCount: UInt32)]
    ) -> [Genre] {
        Array(
            genres
                .filter { $0.songCount > 0 }
                .sorted {
                    if $0.songCount != $1.songCount { return $0.songCount < $1.songCount }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .prefix(8)
                .map { Genre(id: $0.id, name: $0.name) }
        )
    }

    /// Refresh the Search "Browse by Genre" tile grid (#247).
    ///
    /// Pulls one page of `/MusicGenres` (already filtered server-side to
    /// genres carrying Audio/Album/Artist items) and ranks them so the
    /// *biggest* genres lead — the dual of `refreshGenresToExplore`. Jellyfin's
    /// `/MusicGenres` projection carries `song_count` per genre, so we rank by
    /// descending count, tie-broken by name for a stable order, and cap at 12
    /// for the tile grid.
    ///
    /// Runs the sync `core.genres` FFI off the MainActor (gap pattern #2) and
    /// marshals the ranked result back. Failures leave the prior grid intact
    /// rather than blanking the section mid-session; auth expiry surfaces so
    /// the user is routed to re-login like every other refresh path.
    func refreshBrowseGenres() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                // limit: 500 matches `refreshGenresToExplore` / `resolvedGenreId`
                // — /MusicGenres sorts SortName ascending, so a smaller cap would
                // silently drop alphabetically-late genres from the ranking pool
                // (the test library has 254 genres).
                try core.genres(offset: 0, limit: 500)
            }.value
            // Project the FFI genres to plain tuples before ranking — passing the
            // `core.Genre` struct directly would force a `LyrebirdCore.Genre`
            // annotation, which the generated `open class LyrebirdCore` shadows
            // (module-vs-type name collision). Tuples keep the ranking helper
            // pure + testable.
            self.browseGenres = AppModel.rankBrowseGenres(
                page.items.map { (id: $0.id, name: $0.name, songCount: $0.songCount) }
            )
        } catch {
            _ = handleAuthError(error)
        }
    }

    /// Pure ranking for the "Browse by Genre" grid (#247), split out from the
    /// FFI hop so it's unit-testable without a live core. Keeps only genres
    /// present in the library (`song_count > 0`), ranks descending by
    /// `song_count` (biggest first) with a case-insensitive name tiebreaker for
    /// stable order, caps at 12 for the tile grid, and carries the resolved
    /// Jellyfin UUID through into the local `Genre.id`.
    static func rankBrowseGenres(
        _ genres: [(id: String, name: String, songCount: UInt32)]
    ) -> [Genre] {
        Array(
            genres
                .filter { $0.songCount > 0 }
                .sorted {
                    if $0.songCount != $1.songCount { return $0.songCount > $1.songCount }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .prefix(12)
                .map { Genre(id: $0.id, name: $0.name) }
        )
    }

    /// Shared helper: build a `GET /Items` request against the user's
    /// library with the given `sortBy` / `filters`, parse the response,
    /// and return a typed array of `Album`. Returns an empty array on
    /// any failure (auth, network, parse) so callers can stay
    /// conditionally-rendering shelves without an error-banner code path.
    ///
    /// TODO(core-#465): replace with a typed `core.items_query()` builder
    ///   once that FFI exists. This function's surface lines up
    ///   deliberately with the shape that builder will expose.
    func fetchAlbumsViaItemsQuery(
        sortBy: String,
        filters: String?,
        limit: UInt32,
        extraFields: [String],
        minDateLastSaved: String?
    ) async -> [Album] {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicAlbum",
            sortBy: sortBy,
            sortOrder: "Descending",
            filters: filters,
            limit: limit,
            extraFields: extraFields,
            minDateLastSaved: minDateLastSaved,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseAlbumsFromItems(data: data)
        } catch {
            Log.net.error("fetchAlbumsViaItemsQuery failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Like `fetchAlbumsViaItemsQuery` but also returns a map from album
    /// id to the server-reported `UserData.PlayCount` so "N plays" can
    /// render on the Quick Picks tile.
    func fetchAlbumsWithPlayCounts(
        sortBy: String,
        filters: String?,
        limit: UInt32,
        minDateLastSaved: String?
    ) async -> ([Album], [String: UInt32]) {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicAlbum",
            sortBy: sortBy,
            sortOrder: "Descending",
            filters: filters,
            limit: limit,
            extraFields: [],
            minDateLastSaved: minDateLastSaved,
            parentId: nil
        ) else { return ([], [:]) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return ([], [:])
            }
            return Self.parseAlbumsWithPlayCounts(data: data)
        } catch {
            Log.net.error("fetchAlbumsWithPlayCounts failed: \(error.localizedDescription, privacy: .public)")
            return ([], [:])
        }
    }

    /// Fetch Recently Added via `/Users/{id}/Items/Latest`. Returns both
    /// the album array and a per-album `DateCreated` map (used by the NEW
    /// badge on `RecentlyAddedTile`).
    func fetchLatestAlbumsWithDates(limit: UInt32) async -> ([Album], [String: Date]) {
        guard let session = session,
              let baseURL = URL(string: session.server.url),
              let authHeader = try? core.authHeader()
        else { return ([], [:]) }
        let userId = session.user.id
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userId)/Items/Latest"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "GroupItems", value: "true"),
            URLQueryItem(
                name: "Fields",
                value: "Genres,ProductionYear,DateCreated,ChildCount,PrimaryImageAspectRatio"
            ),
        ]
        guard let url = comps?.url else { return ([], [:]) }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return ([], [:])
            }
            // `/Items/Latest` returns a bare array, not the
            // `{Items, TotalRecordCount}` wrapper — parse accordingly.
            return Self.parseLatestAlbumsWithDates(data: data)
        } catch {
            Log.net.error("fetchLatestAlbumsWithDates failed: \(error.localizedDescription, privacy: .public)")
            return ([], [:])
        }
    }

    /// Fetch up to `limit` favorited audio tracks. Backs the
    /// "Shuffle All Favorites" CTA on the Home Favorites header (#55).
    func fetchFavoriteTracks(limit: UInt32) async -> [Track] {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "Random",
            sortOrder: "Ascending",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseTracksFromItems(data: data)
        } catch {
            Log.net.error("fetchFavoriteTracks failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
