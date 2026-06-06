import Foundation
@preconcurrency import LyrebirdCore

/// Home-screen carousel loaders on `AppModel`: the "Jump Back In", "Recently
/// Added", "Quick Picks", "Favorite Albums / Artists", "Rediscover",
/// "Recently Discovered Artists", and "Suggestions" shelves, plus the
/// Shuffle-All-Favorites / Show-All-Favorites entry points.
///
/// The carousel result arrays are `@Observable` stored state on the main
/// `AppModel` class — stored properties can't live in an extension. These
/// loaders refresh that state off-main and write it back. Extensions of a
/// `@MainActor` type inherit its isolation, so every method here is
/// main-actor-bound just like the rest of the class.
extension AppModel {
    // MARK: - Home carousels (#49 / #51–#55)
    //
    // The Home carousels (#51 Jump Back In, #52 Recently Played, #53 Quick
    // Picks, #54 Recently Added, #55 Favorites) each need an `/Items` query
    // with a different `SortBy` / `Filters` combination. The core exposes
    // `list_albums` / `latest_albums` / `recently_played` for the
    // un-filtered variants, but the three new album-level shelves
    // (Jump Back In, Quick Picks, Favorites) rely on filter knobs the
    // core's current FFI doesn't expose. Rather than block Home on a new
    // `items_query` builder (BATCH-24), we inline the raw HTTP call here
    // via the session URL + `auth_header` and parse the subset of
    // `BaseItemDto` we care about. Swap to the typed builder when it lands.
    //
    // TODO(core-#465): retire these raw fetches in favour of a typed
    //   `core.items_query()` builder once it exists.

    /// Refresh the "Jump Back In" carousel (#51). Fetches up to 12 albums
    /// the user has played recently, sorted by `DatePlayed` descending and
    /// filtered to `IsPlayed`. Silent on error — an empty shelf is a fine
    /// first-time-user state.
    func refreshJumpBackIn() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "DatePlayed",
            filters: "IsPlayed",
            limit: 12,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.jumpBackIn = albums
    }

    /// Refresh the "Recently Added" carousel (#54). Uses the core's
    /// `latest_albums` FFI, which is already backed by Jellyfin's
    /// `/Users/{id}/Items/Latest` endpoint. Falls back to the empty
    /// `library_id` convention already used elsewhere (see
    /// `ensurePlaylistLibraryId`) until a real library resolver lands.
    /// Also parses `DateCreated` off the server so the tile can surface a
    /// "NEW" badge for albums created in the last 7 days.
    func refreshRecentlyAdded() async {
        // TODO(core-#465): the typed `latest_albums` FFI returns
        //   `PaginatedAlbums` without the `DateCreated` field that drives
        //   the NEW badge. Until the core surfaces that directly, fetch
        //   the same shape via `/Users/{id}/Items/Latest` and pull both
        //   the album list + per-item `DateCreated` out of one response.
        let (albums, dates) = await fetchLatestAlbumsWithDates(limit: 20)
        self.recentlyAdded = albums
        self.recentlyAddedDates = dates
    }

    /// Refresh the "Quick Picks" carousel (#53). Heavy-rotation albums
    /// over the last 30 days, sorted by `PlayCount` descending. The core
    /// doesn't yet expose a `min_date_played` filter, so this is an
    /// inlined `/Items` fetch. Also records per-album play counts so the
    /// tile can surface a "42 plays" badge on hover.
    func refreshQuickPicks() async {
        // Jellyfin doesn't ship a "date played > X" filter, but the
        // `MinDateLastSaved` parameter on /Items is a reasonable proxy —
        // it gates on "last touched by the user", which for our purposes
        // (filtering out stale top-played ancient history) lines up well.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let thirtyDaysAgo = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        let minDate = iso.string(from: thirtyDaysAgo)
        let (albums, playCounts) = await fetchAlbumsWithPlayCounts(
            sortBy: "PlayCount,SortName",
            filters: "IsPlayed",
            limit: 12,
            minDateLastSaved: minDate
        )
        self.quickPicks = albums
        self.quickPicksPlayCounts = playCounts
    }

    /// Refresh the "Favorites" carousel (#55). Fetches up to 50 favorite
    /// albums, stores the full set, and picks a random 12 to surface
    /// today. Re-shuffles whenever this is called — which happens on
    /// login, on an explicit pull-to-refresh, or on app relaunch.
    func refreshFavoriteAlbums() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "SortName",
            filters: "IsFavorite",
            limit: 50,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.favoriteAlbumsAll = albums
        self.favoriteAlbumsVisible = Array(albums.shuffled().prefix(12))
        // Hydrate the per-id favorite map so album detail / tile hearts are
        // correct from first paint without waiting for the user to toggle.
        for album in albums {
            favoriteById[album.id] = true
        }
    }

    /// Re-shuffle `favoriteAlbumsVisible` from the already-fetched
    /// `favoriteAlbumsAll`. Cheaper than a full refresh — used by the "see
    /// all" / reshuffle affordance when we want a new set without hitting
    /// the server.
    func reshuffleFavoriteAlbumsVisible() {
        self.favoriteAlbumsVisible = Array(favoriteAlbumsAll.shuffled().prefix(12))
    }

    /// Refresh the "Rediscover" carousel (#57). Fetches up to 12 albums the
    /// user has never played, filtered to `IsUnplayed` and sorted `Random`
    /// server-side so the row surfaces a different corner of the library on
    /// each cold launch / refresh rather than the same alphabetically-first
    /// dozen. Reuses `fetchAlbumsViaItemsQuery` — the `Descending` sort order
    /// it hardcodes is a no-op for `Random`. Best-effort: an empty result
    /// (a fully-played library) just leaves the shelf hidden.
    func refreshRediscover() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "Random",
            filters: "IsUnplayed",
            limit: 12,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.rediscover = albums
    }

    /// Refresh the "Artists You Love" carousel (#207). Reuses
    /// `loadFavoriteArtists` — the same favorites-driven fetch that backs
    /// the Favorites screen's Artists section — so the Home circle row and
    /// the Favorites grid stay in lock-step. The list arrives sorted by
    /// name; the view caps how many circles it renders. Best-effort: an
    /// empty or errored result just leaves the shelf hidden.
    func refreshFavoriteArtists() async {
        self.favoriteArtists = await loadFavoriteArtists(limit: 100)
    }

    /// Refresh the "Recently Discovered Artists" carousel (#252). Calls the
    /// `core.listRecentlyAddedArtists` FFI, which hits Jellyfin's
    /// `Artists/AlbumArtists` endpoint sorted `DateCreated` descending, so
    /// the row surfaces the album artists whose catalogue most recently
    /// landed on the server. Runs off the MainActor per the gap-#2 pattern
    /// so the Rust `Inner` mutex doesn't block the UI thread. Best-effort:
    /// an empty or errored result just leaves the shelf hidden. We request a
    /// few more than the view's display cap so the row stays full even if
    /// the freshest entries dedupe against another shelf later.
    func refreshRecentlyDiscoveredArtists() async {
        let fetched = await Task.detached(priority: .userInitiated) { [core] in
            (try? core.listRecentlyAddedArtists(offset: 0, limit: 24))?.items ?? []
        }.value
        self.recentlyDiscoveredArtists = fetched
    }

    /// Refresh the "You might like" discovery row (#145). Calls
    /// `core.suggestions()` which hits Jellyfin's `/Items/Suggestions`
    /// endpoint filtered to Audio + MusicAlbum/MusicArtist. Returns up to
    /// 20 tracks server-ranked by play history and social signals. Runs
    /// off the MainActor per the gap-#2 pattern so the Rust mutex doesn't
    /// block the UI thread. Silent on error — an empty shelf is a fine
    /// first-time-user state.
    func refreshSuggestions() async {
        let fetched = await Task.detached(priority: .userInitiated) { [core] in
            (try? core.suggestions(limit: 20)) ?? []
        }.value
        self.suggestions = fetched
    }

    /// Load every favorite track on the server and play them shuffled.
    /// Powers the "Shuffle All Favorites" CTA on the Home favorites header
    /// (#55). Fetches up to 500 favorite tracks in one shot — that's an
    /// order of magnitude above the typical power-user favorite library
    /// and more than enough to seed a shuffled listening session.
    func shuffleAllFavorites() {
        Task {
            let tracks = await fetchFavoriteTracks(limit: 500)
            guard !tracks.isEmpty else {
                // Silent no-op if the user has nothing favorited yet — the
                // empty state in the Favorites header explains how to
                // start favoriting.
                return
            }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Navigate to the full library scoped to favorites (#55 "See All").
    /// Open the dedicated Favorites screen. Used by the sidebar's
    /// Favorites row and the Home Favorites carousel "See all" CTA.
    func showAllFavorites() {
        selectTab(.favorites)
    }
}
