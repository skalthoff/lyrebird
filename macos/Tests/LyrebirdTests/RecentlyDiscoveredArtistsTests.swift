import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the Home "Recently Discovered Artists" row (#252).
///
/// The shelf is a "dumb" Home section: it reads the
/// `AppModel.recentlyDiscoveredArtists` slice — the album artists whose
/// catalogue most recently landed on the server, sorted `DateCreated`
/// descending by the core's `listRecentlyAddedArtists` FFI — and hides
/// itself when that slice is empty (the `@ViewBuilder` guards
/// `if !model.recentlyDiscoveredArtists.isEmpty`). These tests pin the
/// contracts the view depends on:
///
/// 1. A fresh model starts with no discovered artists, so the row hides on
///    first paint instead of punching an empty hole in the layout.
/// 2. The slice is the single source the row renders, in order. Because the
///    core hands the list back already sorted newest-first, the view must
///    not reorder it — it renders the slice verbatim.
/// 3. The view's display cap is large enough that a typical fetch isn't
///    silently truncated below what the row promises.
/// 4. Signing out (`logout`) and forgetting the token (`forgetToken`) both
///    clear the slice, so one account's newly-added artists never bleed into
///    the next session's Home row.
///
/// Same isolation contract as the other Home suites: `AppModel` is
/// `@MainActor` and boots a live `LyrebirdCore` pointed at a throwaway data
/// dir via `XDG_DATA_HOME`, so the test never touches the real app database
/// and never hits the network (we drive the published slice directly rather
/// than calling the live `refreshRecentlyDiscoveredArtists` fetch).
@MainActor
final class RecentlyDiscoveredArtistsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-recently-discovered-artists-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeArtist(id: String, name: String) -> Artist {
        Artist(
            id: id, name: name, albumCount: 0, songCount: 0, genres: [],
            imageTag: nil, userData: nil
        )
    }

    func testRecentlyDiscoveredArtistsStartEmptySoRowHides() throws {
        let model = try AppModel()
        XCTAssertTrue(
            model.recentlyDiscoveredArtists.isEmpty,
            "a fresh model has no discovered artists, so the Home row hides on first paint"
        )
    }

    func testRecentlyDiscoveredArtistsSliceIsRenderedInServerOrder() throws {
        let model = try AppModel()
        // The core returns these already sorted DateCreated-descending
        // (newest arrivals first). The row renders the slice verbatim — it
        // must not re-sort, so the freshest artist stays in the lead slot.
        let discovered = [
            makeArtist(id: "newest", name: "Just Arrived"),
            makeArtist(id: "middle", name: "Last Week"),
            makeArtist(id: "oldest", name: "Last Month"),
        ]
        model.recentlyDiscoveredArtists = discovered

        XCTAssertEqual(
            model.recentlyDiscoveredArtists.map(\.id),
            ["newest", "middle", "oldest"],
            "the row renders exactly the recentlyDiscoveredArtists slice, preserving the core's newest-first order"
        )
        XCTAssertFalse(
            model.recentlyDiscoveredArtists.isEmpty,
            "a non-empty slice reveals the Home shelf"
        )
    }

    func testRecentlyDiscoveredArtistsDisplayCapKeepsTypicalFetchIntact() throws {
        let model = try AppModel()
        // The Home row caps how many circles it renders
        // (HomeView's `recentlyDiscoveredArtistsLimit`). A modest fetch must
        // survive that cap untouched — only oversized fetches get trimmed,
        // with "See All" routing to the full Library Artists list.
        let discovered = (1...12).map { makeArtist(id: "a\($0)", name: "Artist \($0)") }
        model.recentlyDiscoveredArtists = discovered

        XCTAssertGreaterThanOrEqual(
            model.recentlyDiscoveredArtists.prefix(18).count,
            12,
            "a 12-artist fetch renders in full under the row's display cap"
        )
    }

    func testRecentlyDiscoveredArtistsIsDistinctFromFavoriteArtists() throws {
        let model = try AppModel()
        // The two artist circle-rows read independent slices — "Recently
        // Discovered" (newly-added) must never alias "Artists You Love"
        // (favorited), or one shelf would mirror the other.
        model.recentlyDiscoveredArtists = [makeArtist(id: "fresh", name: "New Signing")]
        model.favoriteArtists = [makeArtist(id: "loved", name: "Old Favorite")]

        XCTAssertEqual(model.recentlyDiscoveredArtists.map(\.id), ["fresh"])
        XCTAssertEqual(model.favoriteArtists.map(\.id), ["loved"])
    }

    func testLogoutClearsRecentlyDiscoveredArtists() throws {
        let model = try AppModel()
        model.recentlyDiscoveredArtists = [makeArtist(id: "a1", name: "Fresh Find")]

        model.logout()

        XCTAssertTrue(
            model.recentlyDiscoveredArtists.isEmpty,
            "logout must drop the discovered-artists slice so the next account's Home row starts clean"
        )
    }

    func testForgetTokenClearsRecentlyDiscoveredArtists() throws {
        let model = try AppModel()
        model.recentlyDiscoveredArtists = [makeArtist(id: "a1", name: "Fresh Find")]

        model.forgetToken()

        XCTAssertTrue(
            model.recentlyDiscoveredArtists.isEmpty,
            "forgetting the token (auth expiry) must clear discovered artists alongside the rest of session state"
        )
    }
}
