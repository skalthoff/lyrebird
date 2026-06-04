import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the Home "Rediscover" row (#57).
///
/// The shelf is a "dumb" Home section: it reads the `IsUnplayed`-driven
/// `AppModel.rediscover` slice and hides itself when that slice is empty
/// (the `@ViewBuilder` guards `if !model.rediscover.isEmpty`). These tests
/// pin the three contracts the view depends on:
///
/// 1. A fresh model starts with no rediscover albums, so the row hides on
///    first paint instead of punching an empty hole in the layout (and a
///    fully-played library, which yields an empty `IsUnplayed` result,
///    behaves the same way).
/// 2. The slice is the single source the row renders, in order.
/// 3. Signing out (`logout`) and forgetting the token (`forgetToken`) both
///    clear the slice, so one account's unplayed albums never bleed into
///    the next session's Home row.
///
/// Same isolation contract as the other Home/Favorites suites: `AppModel`
/// is `@MainActor` and boots a live `LyrebirdCore` pointed at a throwaway
/// data dir via `XDG_DATA_HOME`, so the test never touches the real app
/// database and never hits the network (we drive the published slice
/// directly rather than calling the live `refreshRediscover` fetch).
@MainActor
final class RediscoverTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-rediscover-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeAlbum(id: String, name: String) -> Album {
        Album(
            id: id, name: name, artistName: "Artist", artistId: nil, year: nil,
            trackCount: 0, runtimeTicks: 0, genres: [], imageTag: nil, userData: nil
        )
    }

    func testRediscoverStartsEmptySoRowHides() throws {
        let model = try AppModel()
        XCTAssertTrue(
            model.rediscover.isEmpty,
            "a fresh model (and a fully-played library) has no rediscover albums, so the Home row hides on first paint"
        )
    }

    func testRediscoverSliceIsRenderedInOrder() throws {
        let model = try AppModel()
        let unplayed = [
            makeAlbum(id: "u1", name: "Kind of Blue"),
            makeAlbum(id: "u2", name: "A Love Supreme"),
            makeAlbum(id: "u3", name: "Mingus Ah Um"),
        ]
        model.rediscover = unplayed

        XCTAssertEqual(
            model.rediscover.map(\.id),
            ["u1", "u2", "u3"],
            "the row renders exactly the rediscover slice, preserving the server's returned order"
        )
        XCTAssertFalse(
            model.rediscover.isEmpty,
            "a non-empty slice reveals the Home shelf"
        )
    }

    func testLogoutClearsRediscover() throws {
        let model = try AppModel()
        model.rediscover = [makeAlbum(id: "u1", name: "Spiritual Unity")]

        model.logout()

        XCTAssertTrue(
            model.rediscover.isEmpty,
            "logout must drop the rediscover slice so the next account's Home row starts clean"
        )
    }

    func testForgetTokenClearsRediscover() throws {
        let model = try AppModel()
        model.rediscover = [makeAlbum(id: "u1", name: "Ascension")]

        model.forgetToken()

        XCTAssertTrue(
            model.rediscover.isEmpty,
            "forgetting the token (auth expiry) must clear rediscover alongside the rest of session state"
        )
    }
}
