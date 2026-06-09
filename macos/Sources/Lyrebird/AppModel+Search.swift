import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

// MARK: - Search

/// Search surface for `AppModel`: the global combined-type search
/// (`search` / `loadMoreSearchResults`), the full Search page's scoped
/// search with per-scope buckets and pagination (`runFullSearch` /
/// `loadMoreFullSearch`), the recent-searches `@AppStorage` codec, and the
/// ⌘F / ⌘⇧F focus routing that aims a find request at an in-content scoped
/// search bar (Artist / Playlist detail) or falls back to the global Search
/// tab.
extension AppModel {
    /// Switch to the Search screen and request keyboard focus in the search
    /// field. Called from the ⌘F menu command. Writes both the legacy
    /// one-shot `requestSearchFocus` flag (which `SearchView` already observes)
    /// and the new `isSearchFieldFocused` mirror so toolbar / field bindings
    /// introduced by #7 can attach a `@FocusState` via `$model.isSearchFieldFocused`.
    func focusSearch() {
        selectTab(.search)
        requestSearchFocus = true
        isSearchFieldFocused = true
    }

    /// The active drill destination iff it owns a scoped (in-content) search
    /// bar — currently the Artist and Playlist detail pages. `nil` otherwise.
    /// Used by `requestFind` to address the focus request to exactly the
    /// top-of-stack route, and exposed for tests.
    var scopedSearchRoute: Route? {
        switch navPath.last {
        case .artist, .playlist, .smartPlaylist: return navPath.last
        default: return nil
        }
    }

    /// True when the active drill destination owns a scoped (in-content)
    /// search bar. Drives whether ⌘F focuses the in-view filter
    /// (`requestFind`) versus falling through to the global Search surface.
    var activeRouteSupportsScopedSearch: Bool {
        scopedSearchRoute != nil
    }

    /// ⌘F entry point. When the user is on a detail view that exposes a scoped
    /// search bar (Artist / Playlist), address a focus request to that exact
    /// route so only the on-top view pulls focus into its in-content filter.
    /// Otherwise fall back to the global Search surface. Global search remains
    /// directly reachable via ⌘⇧F regardless of context.
    func requestFind() {
        guard let route = scopedSearchRoute else {
            focusSearch()
            return
        }
        // Bump the token so a repeat ⌘F for the same route is still an
        // observable change for the owning view's `.onChange`.
        scopedSearchFocusToken &+= 1
        scopedSearchFocusRequest = ScopedSearchFocusRequest(route: route, token: scopedSearchFocusToken)
    }

    /// Called by a detail view in response to `scopedSearchFocusRequest`
    /// changing. Returns `true` iff the pending request targets `route` (so
    /// the caller should pull focus into its scoped bar) and, when it does,
    /// clears the request so a stale value can't re-fire on an unrelated
    /// state change. Views stacked under the top one (which carry a different
    /// route) get `false` and never steal focus.
    func consumeScopedSearchFocus(for route: Route) -> Bool {
        guard scopedSearchFocusRequest?.route == route else { return false }
        scopedSearchFocusRequest = nil
        return true
    }

    func search(_ query: String) async {
        searchQuery = query
        guard !query.isEmpty else {
            searchResults = nil
            searchResultsTotal = 0
            return
        }
        do {
            let results = try await Task.detached(priority: .userInitiated) { [core, searchPageSize] in
                try core.search(query: query, offset: 0, limit: searchPageSize)
            }.value
            self.searchResults = results
            self.searchResultsTotal = results.totalRecordCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Fetch the next page of the current search query and merge into
    /// `searchResults`. Jellyfin's combined-type `/Users/{id}/Items`
    /// endpoint doesn't let us fetch more of a single kind at a time, so
    /// this appends whichever of (artists, albums, tracks) the next page
    /// happens to contain. The "Show all N results" button in `SearchView`
    /// is the caller.
    ///
    /// Dedupes by id so the typed arrays don't accumulate duplicates if a
    /// row happens to overlap across paged responses (which can happen
    /// because Jellyfin's ordering is stable only per sort key).
    func loadMoreSearchResults() async {
        guard !isLoadingMoreSearch else { return }
        guard let current = searchResults, !searchQuery.isEmpty else { return }
        let loaded = current.artists.count + current.albums.count + current.tracks.count
        guard loaded < Int(searchResultsTotal) else { return }
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }
        let offset = UInt32(loaded)
        let query = searchQuery
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, searchPageSize] in
                try core.search(query: query, offset: offset, limit: searchPageSize)
            }.value
            // Merge with dedupe — see method doc.
            var artistSet = Set(current.artists.map(\.id))
            var albumSet = Set(current.albums.map(\.id))
            var trackSet = Set(current.tracks.map(\.id))
            var artists = current.artists
            var albums = current.albums
            var tracks = current.tracks
            for a in page.artists where artistSet.insert(a.id).inserted { artists.append(a) }
            for a in page.albums where albumSet.insert(a.id).inserted { albums.append(a) }
            for t in page.tracks where trackSet.insert(t.id).inserted { tracks.append(t) }
            self.searchResults = SearchResults(
                artists: artists,
                albums: albums,
                tracks: tracks,
                totalRecordCount: page.totalRecordCount
            )
            self.searchResultsTotal = page.totalRecordCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }


    /// Drive the full Search page (`SearchView`). Issues a combined-type
    /// search against Jellyfin, buckets results into `searchPageResults`
    /// by scope key, and stores the active scope so the view's scope chips
    /// can render without re-querying. Called on Return-key commit in the
    /// field, and again when the user taps a scope chip.
    ///
    /// The underlying `core.search` endpoint returns MusicArtist,
    /// MusicAlbum, and Audio mixed together with a single total — there
    /// is no per-kind pagination on the server. `searchPagePageSize` is
    /// large enough that each typed section typically fills well past the
    /// "~20 per category" the page aims for. Callers hit `loadMoreFullSearch`
    /// to request another combined page when the user has exhausted the
    /// local buffer within a section.
    ///
    /// Genres are derived client-side from the `genres` arrays on albums
    /// and artists since Jellyfin doesn't return them as standalone items
    /// on this endpoint. Playlists are likewise not returned today — the
    /// bucket stays empty until the core exposes them via `search`, at
    /// which point the view already knows how to render them.
    ///
    /// Issues: #86 (full results page), #242 (scope chips), #244 (sections
    /// layout), #245 (zero-results state).
    func runFullSearch(query: String, scope: SearchScope) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchScope = scope
        // Record the normalized query that drives the results, but do NOT
        // touch `searchPageQuery` — that's the live binding for the text
        // field, and writing a trimmed value back into it would delete a
        // space the user just typed mid-edit. The view owns the field text.
        searchPageActiveQuery = trimmed

        guard !trimmed.isEmpty else {
            searchPageResults = [:]
            searchPageTotal = 0
            searchPageLoaded = 0
            searchPageExhausted = false
            isLoadingFullSearch = false
            return
        }

        isLoadingFullSearch = true
        defer { isLoadingFullSearch = false }
        searchPageExhausted = false
        do {
            let pageSize = searchPagePageSize
            let results = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: trimmed, offset: 0, limit: pageSize)
            }.value
            searchPageResults = Self.bucketSearchResults(results)
            searchPageTotal = results.totalRecordCount
            searchPageLoaded = results.artists.count + results.albums.count + results.tracks.count
            // A first page that already returns fewer raw items than it
            // asked for means the server has nothing more — mark exhausted
            // so the per-section "Load more" can't promise a phantom page.
            let firstPageRaw = results.artists.count + results.albums.count + results.tracks.count
            if firstPageRaw < Int(pageSize) || searchPageLoaded >= Int(searchPageTotal) {
                searchPageExhausted = true
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Fetch another combined page for the current full-search query.
    /// Invoked by the "Load more" button on a scope tab when that tab has
    /// already revealed every buffered item but the server still reports
    /// more matches overall. Merges the new page into `searchPageResults`
    /// with per-id dedupe so flaky ordering on Jellyfin's side doesn't
    /// double a row. No-op when the buckets already cover `searchPageTotal`.
    func loadMoreFullSearch() async {
        // Page off the normalized query that produced the current results,
        // not the live field text (which the user may still be editing).
        guard !isLoadingFullSearch, !searchPageActiveQuery.isEmpty else { return }
        guard searchPageHasMore else { return }
        isLoadingFullSearch = true
        defer { isLoadingFullSearch = false }
        let offset = UInt32(searchPageLoaded)
        let query = searchPageActiveQuery
        do {
            let pageSize = searchPagePageSize
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: query, offset: offset, limit: pageSize)
            }.value

            var merged = searchPageResults
            let incoming = Self.bucketSearchResults(page)
            var addedNewItems = false
            for (key, newItems) in incoming {
                var existing = merged[key] ?? []
                var seen = Set(existing.map(\.id))
                for item in newItems where seen.insert(item.id).inserted {
                    existing.append(item)
                    addedNewItems = true
                }
                merged[key] = existing
            }
            searchPageResults = merged
            searchPageTotal = page.totalRecordCount
            let pageRaw = page.artists.count + page.albums.count + page.tracks.count
            searchPageLoaded += pageRaw
            // Exhaustion guard: `searchPageLoaded < searchPageTotal` alone
            // can never settle because `searchPageTotal` may count types we
            // don't page (or be deduped server-side). Treat the search as
            // done the moment a page returns no new deduplicated items, a
            // short raw page, or we've caught up to the total. This is what
            // keeps "Load more" from becoming a perpetual no-op.
            if !addedNewItems || pageRaw < Int(pageSize) || searchPageLoaded >= Int(searchPageTotal) {
                searchPageExhausted = true
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Partition a core `SearchResults` into the per-scope buckets the
    /// full search page renders. Genres are reconstructed from the
    /// `genres` arrays that Jellyfin attaches to albums and artists —
    /// we dedupe and alpha-sort so the Genres chip has something useful
    /// to show even though the API doesn't return genre items directly.
    nonisolated static func bucketSearchResults(_ results: SearchResults) -> [String: [SearchItem]] {
        var buckets: [String: [SearchItem]] = [:]
        buckets[SearchScope.artists.storageKey] = results.artists.map(SearchItem.artist)
        buckets[SearchScope.albums.storageKey] = results.albums.map(SearchItem.album)
        buckets[SearchScope.tracks.storageKey] = results.tracks.map(SearchItem.track)
        // Playlists aren't surfaced by the current `core.search` endpoint,
        // so this bucket stays empty and the Playlists scope is hidden in
        // the UI behind `supportsPlaylistSearch`. When core gains playlist
        // search, populate this from the response (e.g.
        // `results.playlists.map(SearchItem.playlist)`) and flip the flag.
        buckets[SearchScope.playlists.storageKey] = []
        // Genres: harvest distinct names from every album and artist in
        // the response. Uses case-insensitive de-dupe so "Rock" vs "rock"
        // collapse to a single chip-worthy entry.
        var seenGenres = Set<String>()
        var genreItems: [SearchItem] = []
        let allGenres = results.albums.flatMap(\.genres) + results.artists.flatMap(\.genres)
        for raw in allGenres {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard seenGenres.insert(key).inserted else { continue }
            genreItems.append(.genre(Genre(name: name)))
        }
        genreItems.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        buckets[SearchScope.genres.storageKey] = genreItems
        return buckets
    }

    /// Append a committed query to the recent-searches `@AppStorage` list,
    /// deduping and capping to the 10-most-recent. The view owns the
    /// storage binding; this helper mutates the decoded list in-place so
    /// the JSON round-trip stays in one place.
    ///
    /// Uses `String` (rather than `[String]`) storage because
    /// `@AppStorage` doesn't support arrays directly. The view decodes on
    /// read, encodes on write.
    static func addRecentSearch(_ query: String, into json: inout String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = decodeRecentSearches(json)
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > 10 {
            list = Array(list.prefix(10))
        }
        json = encodeRecentSearches(list)
    }

    /// Remove a single term from the recent-searches list. Used by the
    /// per-row × button in the empty-query state. Mutates the shared JSON
    /// string so the caller's `@AppStorage` binding picks up the change.
    static func removeRecentSearch(_ query: String, from json: inout String) {
        var list = decodeRecentSearches(json)
        list.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        json = encodeRecentSearches(list)
    }

    /// Reset the recent-searches list. Wired to the "Clear history" footer
    /// button under the recents list.
    static func clearRecentSearches(_ json: inout String) {
        json = "[]"
    }

    /// Decode the recents JSON into a plain `[String]`. Returns `[]` on
    /// malformed data so a stale shape from a prior build doesn't prevent
    /// the page from rendering.
    static func decodeRecentSearches(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    /// Encode a `[String]` back to the JSON string `@AppStorage` persists.
    private static func encodeRecentSearches(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s

    }

    // MARK: - Suggested searches (#87)

    /// Up to 5 artists surfaced in the Search page's "Suggested" section.
    ///
    /// Picks artists with the lowest play count (preferring `userData.playCount
    /// == 0`, i.e. never played) so the suggestions encourage exploration of
    /// neglected corners of the library. Falls back to any 5 artists when the
    /// whole library is uniformly played. The result is seeded by the current
    /// calendar day (UTC) so suggestions rotate daily without requiring a server
    /// round-trip — stable within a session, fresh the next morning.
    ///
    /// Uses the in-memory `artists` snapshot so no FFI call is needed on the
    /// search page hot-path. If the library hasn't loaded yet (empty array),
    /// returns an empty list and the suggestions section hides itself.
    var suggestedSearchArtists: [Artist] {
        guard !artists.isEmpty else { return [] }
        // Derive a stable daily seed from today's UTC date so the set
        // rotates overnight but stays consistent within one session.
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        // Split into explicitly-typed Int sub-expressions: the chained
        // optional-arithmetic + UInt64() conversion on one line trips the
        // Swift type-checker's "unable to type-check in reasonable time"
        // blowup on a clean build.
        let year: Int = today.year ?? 0
        let month: Int = today.month ?? 0
        let day: Int = today.day ?? 0
        let daySeed = UInt64(year * 10000 + month * 100 + day)
        // Prefer artists that have never been played; fall through to all
        // artists so the section still renders in fully-played libraries.
        let unplayed = artists.filter { ($0.userData?.playCount ?? 0) == 0 }
        let pool = unplayed.isEmpty ? artists : unplayed
        // Deterministic daily shuffle via a seeded LCG over the pool indices.
        // Each element is paired with a pseudo-random key, sorted by key, then
        // stripped — a Fisher-Yates-equivalent that is pure and allocation-light.
        var state = daySeed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let shuffled: [Artist] = pool.map { artist -> (UInt64, Artist) in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state, artist)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return Array(shuffled.prefix(5))
    }
}
