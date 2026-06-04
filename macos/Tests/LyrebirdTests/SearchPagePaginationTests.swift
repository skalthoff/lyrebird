import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the full Search page's pagination + scope accounting,
/// targeting the audit findings on `SearchView` / `AppModel`:
///
///  * Playlists are a permanently-empty scope today (`core.search` doesn't
///    return them) — `bucketSearchResults` must leave the bucket empty and
///    the scope is gated behind `supportsPlaylistSearch`.
///  * `searchPageHasMore` / `searchPageExhausted` must settle so the
///    "Load more" button can't stay live forever when the server's
///    `TotalRecordCount` counts types we don't page.
///  * `SearchScope.isServerPaged` distinguishes server-paged scopes
///    (artists / albums / tracks) from derived / not-yet-paged scopes
///    (genres / playlists), which must never consult the server signal.
///  * `runFullSearch` records the trimmed query in `searchPageActiveQuery`
///    without clobbering the user-facing `searchPageQuery` binding.
///
/// `AppModel` is `@MainActor`, so the suite is main-actor isolated. We
/// redirect the core's data dir to a throwaway temp dir via
/// `XDG_DATA_HOME` so the tests never touch the real app database, and we
/// drive the deterministic, network-free surfaces directly.
@MainActor
final class SearchPagePaginationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-search-page-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Fixtures

    private func makeTrack(id: String, name: String) -> Track {
        Track(
            id: id, name: name, albumId: nil, albumName: nil, artistName: "Artist",
            artistId: nil, indexNumber: nil, discNumber: nil, year: nil,
            runtimeTicks: 0, isFavorite: false, playCount: 0, container: nil,
            bitrate: nil, imageTag: nil, playlistItemId: nil, userData: nil
        )
    }

    private func makeAlbum(id: String, name: String, genres: [String] = []) -> Album {
        Album(
            id: id, name: name, artistName: "Artist", artistId: nil, year: nil,
            trackCount: 0, runtimeTicks: 0, genres: genres, imageTag: nil, userData: nil
        )
    }

    private func makeArtist(id: String, name: String, genres: [String] = []) -> Artist {
        Artist(
            id: id, name: name, albumCount: 0, songCount: 0, genres: genres,
            imageTag: nil, userData: nil
        )
    }

    private func results(
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = [],
        totalRecordCount: UInt32? = nil
    ) -> SearchResults {
        SearchResults(
            artists: artists,
            albums: albums,
            tracks: tracks,
            totalRecordCount: totalRecordCount ?? UInt32(artists.count + albums.count + tracks.count)
        )
    }

    // MARK: - Playlists are a permanently-empty bucket (gap-stub)

    func testBucketSearchResultsLeavesPlaylistsEmpty() {
        // The core `SearchResults` type has no playlists field — the
        // backend can't return them — so the bucket must come back empty.
        let buckets = AppModel.bucketSearchResults(
            results(
                artists: [makeArtist(id: "ar1", name: "A")],
                albums: [makeAlbum(id: "al1", name: "B")],
                tracks: [makeTrack(id: "t1", name: "C")]
            )
        )
        XCTAssertEqual(buckets[SearchScope.playlists.storageKey], [])
    }

    func testPlaylistsScopeHiddenWhileUnsupported() throws {
        // The Playlists scope must stay hidden until the core search backend
        // returns playlists, exactly like Genres are gated by the genre
        // capability. Default ships with playlist search unsupported.
        let model = try AppModel()
        XCTAssertFalse(
            model.supportsPlaylistSearch,
            "playlist search is off until core.search returns playlists"
        )
    }

    // MARK: - SearchScope.isServerPaged

    func testServerPagedScopes() {
        XCTAssertTrue(SearchScope.artists.isServerPaged)
        XCTAssertTrue(SearchScope.albums.isServerPaged)
        XCTAssertTrue(SearchScope.tracks.isServerPaged)
        // Derived / not-yet-paged scopes must never consult the server
        // has-more signal, otherwise their "Load more" is perpetual.
        XCTAssertFalse(SearchScope.genres.isServerPaged)
        XCTAssertFalse(SearchScope.playlists.isServerPaged)
    }

    // MARK: - searchPageHasMore / searchPageExhausted

    func testHasMoreFalseWhenLoadedReachesTotal() throws {
        let model = try AppModel()
        model.searchPageExhausted = false
        model.searchPageTotal = 50
        model.searchPageLoaded = 50
        XCTAssertFalse(
            model.searchPageHasMore,
            "caught up to the total — nothing more to fetch"
        )
    }

    func testHasMoreTrueWhenLoadedBelowTotalAndNotExhausted() throws {
        let model = try AppModel()
        model.searchPageExhausted = false
        model.searchPageTotal = 200
        model.searchPageLoaded = 100
        XCTAssertTrue(model.searchPageHasMore)
    }

    func testExhaustedFlagOverridesStaleTotal() throws {
        // The crux of the load-more bug: the server's TotalRecordCount can
        // count item types we don't page (or be deduped), so loaded can sit
        // permanently below total. Once a page adds nothing the exhausted
        // flag must force has-more to false so the button disappears.
        let model = try AppModel()
        model.searchPageTotal = 999     // server still claims more…
        model.searchPageLoaded = 100    // …but loaded is stuck below it
        model.searchPageExhausted = true
        XCTAssertFalse(
            model.searchPageHasMore,
            "exhausted flag must win over a never-reachable total"
        )
    }

    // MARK: - runFullSearch query handling

    func testRunFullSearchDoesNotClobberFieldBindingOnFailure() async throws {
        // No live server here, so `core.search` throws — but the contract
        // we care about holds regardless of network: `runFullSearch` must
        // never trim-and-write the user-facing field binding. The user may
        // have typed a trailing space mid-edit; deleting it under them is
        // the bug. The trimmed query lives in `searchPageActiveQuery`.
        let model = try AppModel()
        model.searchPageQuery = "radiohead "   // trailing space the user typed

        await model.runFullSearch(query: "radiohead ", scope: .all)

        XCTAssertEqual(
            model.searchPageQuery,
            "radiohead ",
            "the live field binding must be left exactly as the user typed it"
        )
        XCTAssertEqual(
            model.searchPageActiveQuery,
            "radiohead",
            "the trimmed query that drives results is recorded separately"
        )
    }

    func testRunFullSearchEmptyQueryClearsActiveQueryAndState() async throws {
        let model = try AppModel()
        model.searchPageActiveQuery = "stale"
        model.searchPageResults = [SearchScope.tracks.storageKey: [.track(makeTrack(id: "t", name: "x"))]]
        model.searchPageTotal = 5
        model.searchPageLoaded = 5
        model.searchPageExhausted = true

        await model.runFullSearch(query: "   ", scope: .all)

        XCTAssertEqual(model.searchPageActiveQuery, "", "whitespace-only query clears the active query")
        XCTAssertTrue(model.searchPageResults.isEmpty)
        XCTAssertEqual(model.searchPageTotal, 0)
        XCTAssertEqual(model.searchPageLoaded, 0)
        XCTAssertFalse(model.searchPageExhausted, "exhaustion resets on a fresh (empty) query")
    }
}
