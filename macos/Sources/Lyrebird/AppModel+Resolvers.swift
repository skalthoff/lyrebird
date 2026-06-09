import Foundation
@preconcurrency import LyrebirdCore

/// Cache-first resolvers and favorites loaders for the browse surfaces.
///
/// Resolves `Artist` / `Album` / `Playlist` records by id with a
/// cache-first read that falls back to a detached core FFI for ids past
/// the loaded library page, parses the minimal `BaseItemDto` subset each
/// hero needs, and backs the Favorites screen plus the artist-detail
/// shelves (discography, top tracks, similar artists, featuring playlists).
/// Per-session caches that hang off `AppModel` (`artistDetailCache`,
/// `artistAlbumsCache`, `resolvedNameCache`, …) live in `AppModel.swift`
/// so they can be cleared on logout.
extension AppModel {
    // MARK: - Favorites surface (#760)
    //
    // Public load helpers backing the dedicated Favorites screen. Each
    // returns the user's favorited items in stable, name-sorted order
    // (Random order on the Home shuffle CTA is the exception above).

    /// Fetch up to `limit` favorited audio tracks, sorted by name.
    /// Backs the "Songs" section of the Favorites screen. Returns an
    /// empty array on auth/network/parse failure.
    @discardableResult
    func loadFavoriteTracks(limit: UInt32 = 500) async -> [Track] {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "SortName",
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
            let tracks = Self.parseTracksFromItems(data: data)
            // Seed favoriteById so track hearts are correct on first paint.
            for track in tracks { favoriteById[track.id] = true }
            return tracks
        } catch {
            Log.tracks.error("loadFavoriteTracks failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Fetch up to `limit` favorited albums, sorted by name. Backs the
    /// "Albums" section of the Favorites screen.
    func loadFavoriteAlbums(limit: UInt32 = 500) async -> [Album] {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "SortName",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil
        )
        // Seed favoriteById so album hearts are correct on first paint.
        for album in albums { favoriteById[album.id] = true }
        return albums
    }

    /// Fetch up to `limit` favorited artists, sorted by name. Backs the
    /// "Artists" section of the Favorites screen.
    func loadFavoriteArtists(limit: UInt32 = 500) async -> [Artist] {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicArtist",
            sortBy: "SortName",
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
            let artists = Self.parseArtistsFromItems(data: data)
            // Seed favoriteById so artist hearts are correct on first paint.
            for artist in artists { favoriteById[artist.id] = true }
            return artists
        } catch {
            Log.app.error("loadFavoriteArtists failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func loadTracks(forAlbum albumID: String) async -> [Track] {
        if let cached = albumTracks[albumID] {
            Log.albums.debug("loadTracks(forAlbum:) cache hit album=\(albumID, privacy: .public) count=\(cached.count, privacy: .public)")
            return cached
        }
        let start = Date()
        Log.albums.info("loadTracks(forAlbum:) start album=\(albumID, privacy: .public)")
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.albumTracks(albumId: albumID)
            }.value
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.albums.info("loadTracks(forAlbum:) ok album=\(albumID, privacy: .public) count=\(tracks.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
            albumTracks[albumID] = tracks
            // Seed favoriteById from the server-authoritative `userData`
            // projection so heart UIs on other surfaces (search, queue,
            // now-playing) reflect the same state without each one having
            // to call `isFavorite(track:)` and pay the snapshot fallback.
            // Bool-only seeding (no `.removeValue`) is intentional: a `nil`
            // server projection should NOT clobber a cache value the user
            // just toggled.
            for track in tracks {
                if let userFav = track.userData?.isFavorite {
                    favoriteById[track.id] = userFav
                }
            }
            serverReachability.noteSuccess()
            return tracks
        } catch {
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.albums.error("loadTracks(forAlbum:) failed album=\(albumID, privacy: .public) ms=\(Int(elapsed), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .albumTracks)
            return []
        }
    }

    /// Resolve an `Artist` record by id — cache-first, falling back to
    /// `core.artistDetail` for libraries larger than the loaded
    /// `artists` page. Returns nil on error or missing id.
    ///
    /// Album/song counts come back as `0` from the FFI fallback because
    /// `ArtistDetail` doesn't carry those stats — the detail hero's
    /// "N albums · M songs" strip silently hides the zero-count lines
    /// rather than lying.
    func resolveArtist(id: String) async -> Artist? {
        if let cached = artists.first(where: { $0.id == id }) {
            resolvedNameCache[id] = cached.name
            return cached
        }
        guard let detail = await artistDetail(artistId: id) else { return nil }
        resolvedNameCache[id] = detail.name
        return Artist(
            id: detail.id,
            name: detail.name,
            albumCount: 0,
            songCount: 0,
            genres: detail.genres,
            imageTag: detail.imageTag,
            userData: nil
        )
    }

    /// Fetch the extended `ArtistDetail` record (biography / external links /
    /// backdrops) and memoize it per id for the session. Runs the synchronous
    /// FFI off the MainActor via `Task.detached` so the `Inner` mutex is never
    /// taken on the main thread (gap pattern #2). Returns `nil` on error so
    /// callers can render a graceful fallback rather than surfacing an alert.
    ///
    /// `resolveArtist(id:)` and the artist About section both go through here,
    /// so a cache-miss artist page open performs a single `core.artistDetail`
    /// round-trip rather than one per consumer.
    func artistDetail(artistId: String) async -> ArtistDetail? {
        if let cached = artistDetailCache[artistId] { return cached }
        do {
            let detail = try await Task.detached(priority: .userInitiated) { [core] in
                try core.artistDetail(artistId: artistId)
            }.value
            artistDetailCache[artistId] = detail
            return detail
        } catch {
            _ = handleAuthError(error)
            return nil
        }
    }

    /// Breadcrumb display name for an album id: the loaded `albums` page first,
    /// then `resolvedNameCache` (seeded by `resolveAlbum` on drill-in), then nil
    /// when neither knows the name so the caller can render an ellipsis.
    func breadcrumbAlbumName(id: String) -> String? {
        albums.first(where: { $0.id == id })?.name ?? resolvedNameCache[id]
    }

    /// Breadcrumb display name for an artist id, mirroring `breadcrumbAlbumName`.
    func breadcrumbArtistName(id: String) -> String? {
        artists.first(where: { $0.id == id })?.name ?? resolvedNameCache[id]
    }

    /// Resolve an `Album` record by id — cache-first, falling back to
    /// `core.fetchItem` for libraries larger than the loaded `albums`
    /// page. Returns nil on error or missing id.
    ///
    /// Parses a minimal subset of `BaseItemDto` — just the fields the
    /// hero needs (name, artist, year, runtime, image tag, genres).
    /// Track count falls back to 0 when the server didn't include
    /// `ChildCount`; `AlbumDetailView` re-counts the loaded tracklist
    /// in that case.
    func resolveAlbum(id: String) async -> Album? {
        if let cached = albums.first(where: { $0.id == id }) {
            resolvedNameCache[id] = cached.name
            return cached
        }
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: id,
                    fields: ["PrimaryImageAspectRatio", "Genres", "ProductionYear", "ChildCount", "RunTimeTicks"]
                )
            }.value
            let album = Self.parseAlbum(from: json)
            if let album { resolvedNameCache[id] = album.name }
            return album
        } catch {
            _ = handleAuthError(error)
            return nil
        }
    }

    static func parseAlbum(from json: String) -> Album? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let id = root["Id"] as? String,
              let name = root["Name"] as? String
        else { return nil }
        let artistName = (root["AlbumArtist"] as? String) ?? ""
        let year = (root["ProductionYear"] as? NSNumber).map { Int32(truncating: $0) }
        let runtimeTicks = (root["RunTimeTicks"] as? NSNumber)?.uint64Value ?? 0
        let trackCount = (root["ChildCount"] as? NSNumber)?.uint32Value ?? 0
        let genres = (root["Genres"] as? [String]) ?? []
        let imageTag = (root["ImageTags"] as? [String: String])?["Primary"]
        let artistId: String? = {
            guard let albumArtists = root["AlbumArtists"] as? [[String: Any]],
                  let first = albumArtists.first
            else { return nil }
            return first["Id"] as? String
        }()
        return Album(
            id: id,
            name: name,
            artistName: artistName,
            artistId: artistId,
            year: year,
            trackCount: trackCount,
            runtimeTicks: runtimeTicks,
            genres: genres,
            imageTag: imageTag,
            userData: nil
        )
    }

    /// Resolve a `Playlist` record by id — cache-first, falling back to
    /// `core.fetchItem` when the id isn't in the loaded `playlists` page.
    /// Mirror of `resolveArtist(id:)` / `resolveAlbum(id:)`. Lets
    /// `PlaylistView` render a hero for deep-linked playlists past the
    /// first library page. Returns nil on error or missing id.
    func resolvePlaylist(id: String) async -> Playlist? {
        if let cached = playlist(id: id) { return cached }
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: id,
                    fields: ["ChildCount", "RunTimeTicks", "PrimaryImageAspectRatio"]
                )
            }.value
            guard let parsed = Self.parsePlaylist(from: json) else { return nil }
            // Seed the cache so `model.playlist(id:)` works on the next
            // call without another FFI round-trip, and so breadcrumbs can
            // read the name.
            if !playlists.contains(where: { $0.id == parsed.id }) {
                playlists.append(parsed)
            }
            return parsed
        } catch {
            _ = handleAuthError(error)
            return nil
        }
    }

    static func parsePlaylist(from json: String) -> Playlist? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let id = root["Id"] as? String,
              let name = root["Name"] as? String
        else { return nil }
        // Defensive guard against the "Playlists > Playlists" case — if the
        // server hands back a CollectionFolder / UserView instead of a real
        // Playlist (id happens to match the library-view id), refuse it so
        // the UI falls through to "not found" instead of rendering the
        // folder's children as track rows.
        let kind = (root["Type"] as? String) ?? ""
        guard kind == "Playlist" else { return nil }
        let trackCount = (root["ChildCount"] as? NSNumber)?.uint32Value ?? 0
        let runtimeTicks = (root["RunTimeTicks"] as? NSNumber)?.uint64Value ?? 0
        let imageTag = (root["ImageTags"] as? [String: String])?["Primary"]
        return Playlist(
            id: id,
            name: name,
            trackCount: trackCount,
            runtimeTicks: runtimeTicks,
            imageTag: imageTag,
            userData: nil
        )
    }

    /// Every album where the given artist is the primary (album) artist.
    /// Server-scoped via `AlbumArtistIds`, so compilations / guest-spots
    /// don't leak into the Discography section. Drives
    /// `ArtistDetailView.artistAlbums` — replaces the stale
    /// `model.albums.filter { $0.artistId == artistID }` pattern that
    /// only searched the first page of 100 cached albums (#60).
    ///
    /// Results are cached per-artist for the session since the data is
    /// stable for the duration of the user's browsing session and the
    /// detail screen may be entered / left repeatedly.
    @discardableResult
    func loadArtistAlbums(artistId: String, limit: UInt32 = 200) async -> [Album] {
        // Soft cap of 200. Was 500 in rc7, but a "Various Artists" entry
        // returning the full 500 expands to a 4×125 fan-out across the
        // discography groups (Albums / Singles / Compilations / Live), each
        // rendered through a `LazyHStack`. On macOS 26.4 + M5 we observed
        // SwiftUI's HVStack layout cache OOM during `_ContiguousArrayBuffer`
        // allocation — the lazy stacks bound rendered tiles, but the parent
        // VStack's subview enumeration scales with the total. 200 is plenty
        // for any single artist; pagination for the long-tail compilations
        // case is a v1.x follow-up.
        if let cached = artistAlbumsCache[artistId] { return cached }
        let start = Date()
        Log.app.info("loadArtistAlbums start artist=\(artistId, privacy: .public) limit=\(limit, privacy: .public)")
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.albumsByArtist(artistId: artistId, offset: 0, limit: limit)
            }.value
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.app.info("loadArtistAlbums ok artist=\(artistId, privacy: .public) count=\(page.items.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
            artistAlbumsCache[artistId] = page.items
            serverReachability.noteSuccess()
            return page.items
        } catch {
            Log.app.error("loadArtistAlbums failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Albums the artist guests on — credited at the track level but not the
    /// album-artist (guest features, collaborations, "Various Artists"
    /// compilations). Drives the artist page "Appears On" rail (#224), the
    /// complement of `loadArtistAlbums`'s Discography. Backed by
    /// `core.appearsOnAlbums`, which scopes by `ArtistIds` on the server then
    /// subtracts the artist's own releases. Detached off the MainActor (gap
    /// pattern #2), cached per-artist for the session in `artistAppearsOnCache`
    /// (cleared on logout), and silently falls back to an empty rail on error
    /// — the rail collapses when empty, so an error reads as "no guest spots"
    /// rather than a broken section.
    @discardableResult
    func loadArtistAppearsOnAlbums(artistId: String, limit: UInt32 = 60) async -> [Album] {
        if let cached = artistAppearsOnCache[artistId] { return cached }
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.appearsOnAlbums(artistId: artistId, offset: 0, limit: limit)
            }.value
            artistAppearsOnCache[artistId] = page.items
            serverReachability.noteSuccess()
            return page.items
        } catch {
            // Silent fallback — don't surface errors for a secondary rail.
            Log.app.notice("loadArtistAppearsOnAlbums failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch the top 5 most-played tracks for an artist, driving the
    /// "Top Tracks" section on the artist detail screen (#229). Backed by
    /// `/Items?ArtistIds=<id>&SortBy=PlayCount,SortName&SortOrder=Descending,Ascending`
    /// on the server. Results are cached per-artist for the session. Errors
    /// are swallowed silently — an empty section is preferable to an error
    /// banner for a secondary widget on the artist page.
    @discardableResult
    func loadArtistTopTracks(artistId: String, limit: UInt32 = 5) async -> [Track] {
        if let cached = artistTopTracks[artistId] { return cached }
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.artistTopTracks(artistId: artistId, limit: limit)
            }.value
            artistTopTracks[artistId] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch artists similar to `artistId` via Jellyfin's
    /// `GET /Artists/{id}/Similar`. Results are cached for the session in
    /// `artistSimilarCache` and cleared on logout. Mirrors the shape of
    /// `loadArtistTopTracks` — detached FFI call, silent fallback. See #146.
    @discardableResult
    func loadSimilarArtists(artistId: String, limit: UInt32 = 12) async -> [Artist] {
        if let cached = artistSimilarCache[artistId] {
            Log.app.debug("loadSimilarArtists cache hit artist=\(artistId, privacy: .public) count=\(cached.count, privacy: .public)")
            return cached
        }
        let start = Date()
        Log.app.info("loadSimilarArtists start artist=\(artistId, privacy: .public)")
        do {
            let similar = try await Task.detached(priority: .userInitiated) { [core] in
                try core.similarArtists(artistId: artistId, limit: limit)
            }.value
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.app.info("loadSimilarArtists ok artist=\(artistId, privacy: .public) count=\(similar.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
            artistSimilarCache[artistId] = similar
            serverReachability.noteSuccess()
            return similar
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            Log.app.notice("loadSimilarArtists failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch the playlists whose track list features `artistId`, for the
    /// "Playlists featuring this artist" rail on the Artist detail screen.
    /// Backed by `core.playlistsContainingArtist`, which walks each
    /// playlist and matches the artist at the track level (guest features
    /// count). Cached for the session in `artistPlaylistsCache`, cleared on
    /// logout. Mirrors `loadSimilarArtists` — detached FFI call, silent
    /// fallback (the rail collapses when empty so an error reads as "no
    /// featuring playlists" rather than a broken section).
    @discardableResult
    func loadPlaylistsFeaturingArtist(artistId: String, limit: UInt32 = 6) async -> [Playlist] {
        if let cached = artistPlaylistsCache[artistId] { return cached }
        let libraryId = await ensurePlaylistLibraryId()
        do {
            let playlists = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistsContainingArtist(
                    playlistLibraryId: libraryId,
                    artistId: artistId,
                    limit: limit
                )
            }.value
            artistPlaylistsCache[artistId] = playlists
            serverReachability.noteSuccess()
            return playlists
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            Log.app.notice("loadPlaylistsFeaturingArtist failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }
}
