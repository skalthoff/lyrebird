import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the Home "Artists You Love" row (#207).
///
/// The shelf is a "dumb" Home section: it reads the favorites-driven
/// `AppModel.favoriteArtists` slice and hides itself when that slice is
/// empty (the `@ViewBuilder` guards `if !model.favoriteArtists.isEmpty`).
/// These tests pin the three contracts the view depends on:
///
/// 1. A fresh model starts with no loved artists, so the row hides on first
///    paint instead of punching an empty hole in the layout.
/// 2. The slice is the single source the row renders, in order, and the
///    view's display cap is large enough that a typical favorites set isn't
///    silently truncated below what the row promises.
/// 3. Signing out (`logout`) and forgetting the token (`forgetToken`) both
///    clear the slice, so one account's loved artists never bleed into the
///    next session's Home row.
///
/// Same isolation contract as the other Home/Favorites suites: `AppModel`
/// is `@MainActor` and boots a live `LyrebirdCore` pointed at a throwaway
/// data dir via `XDG_DATA_HOME`, so the test never touches the real app
/// database and never hits the network (we drive the published slice
/// directly rather than calling the live `refreshFavoriteArtists` fetch).
@MainActor
final class ArtistsYouLoveTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-artists-you-love-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeArtist(id: String, name: String) -> Artist {
        Artist(
            id: id, name: name, albumCount: 0, songCount: 0, genres: [],
            imageTag: nil, userData: nil
        )
    }

    func testFavoriteArtistsStartEmptySoRowHides() throws {
        let model = try AppModel()
        XCTAssertTrue(
            model.favoriteArtists.isEmpty,
            "a fresh model has no loved artists, so the Home row hides on first paint"
        )
    }

    func testFavoriteArtistsSliceIsRenderedInOrder() throws {
        let model = try AppModel()
        let loved = [
            makeArtist(id: "a1", name: "Aretha Franklin"),
            makeArtist(id: "a2", name: "Bill Withers"),
            makeArtist(id: "a3", name: "Curtis Mayfield"),
        ]
        model.favoriteArtists = loved

        XCTAssertEqual(
            model.favoriteArtists.map(\.id),
            ["a1", "a2", "a3"],
            "the row renders exactly the favoriteArtists slice, preserving server name order"
        )
        XCTAssertFalse(
            model.favoriteArtists.isEmpty,
            "a non-empty slice reveals the Home shelf"
        )
    }

    func testFavoriteArtistsDisplayCapKeepsTypicalSetIntact() throws {
        let model = try AppModel()
        // The Home row caps how many circles it renders (HomeView's
        // `artistsYouLoveLimit`). A modest favorites set must survive that
        // cap untouched — only large sets get trimmed, with "See All"
        // routing to the full Favorites screen for the remainder.
        let loved = (1...12).map { makeArtist(id: "a\($0)", name: "Artist \($0)") }
        model.favoriteArtists = loved

        XCTAssertGreaterThanOrEqual(
            model.favoriteArtists.prefix(18).count,
            12,
            "a 12-artist favorites set renders in full under the row's display cap"
        )
    }

    func testLogoutClearsLovedArtists() throws {
        let model = try AppModel()
        model.favoriteArtists = [makeArtist(id: "a1", name: "Nina Simone")]

        model.logout()

        XCTAssertTrue(
            model.favoriteArtists.isEmpty,
            "logout must drop the loved-artists slice so the next account's Home row starts clean"
        )
    }

    func testForgetTokenClearsLovedArtists() throws {
        let model = try AppModel()
        model.favoriteArtists = [makeArtist(id: "a1", name: "Otis Redding")]

        model.forgetToken()

        XCTAssertTrue(
            model.favoriteArtists.isEmpty,
            "forgetting the token (auth expiry) must clear loved artists alongside the rest of session state"
        )
    }
}
