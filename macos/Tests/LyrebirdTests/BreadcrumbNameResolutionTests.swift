import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the breadcrumb name-resolution chain: the loaded
/// `albums` / `artists` page first, then `resolvedNameCache` (seeded by
/// `resolveAlbum` / `resolveArtist` on drill-in from outside that page), then
/// nil so the trail renders an ellipsis. Before the fix a drill destination
/// reached from recently-played / discography / genre detail dead-ended at "…".
///
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore`; we redirect the
/// core's data dir to a throwaway temp dir via `XDG_DATA_HOME` so the test
/// never touches the real app database.
@MainActor
final class BreadcrumbNameResolutionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeAlbum(id: String, name: String) -> Album {
        Album(
            id: id, name: name, artistName: "Artist", artistId: nil, year: nil,
            trackCount: 0, runtimeTicks: 0, genres: [], imageTag: nil, userData: nil
        )
    }

    private func makeArtist(id: String, name: String) -> Artist {
        Artist(
            id: id, name: name, albumCount: 0, songCount: 0, genres: [],
            imageTag: nil, userData: nil
        )
    }

    func testAlbumNamePrefersLoadedPage() throws {
        let model = try AppModel()
        model.albums = [makeAlbum(id: "a1", name: "Page Album")]
        model.resolvedNameCache["a1"] = "Cache Album"

        XCTAssertEqual(model.breadcrumbAlbumName(id: "a1"), "Page Album")
    }

    func testAlbumNameFallsBackToResolvedCache() throws {
        let model = try AppModel()
        // Empty page (album drilled into from outside page 1).
        model.albums = []
        model.resolvedNameCache["a2"] = "Cache Album"

        XCTAssertEqual(model.breadcrumbAlbumName(id: "a2"), "Cache Album")
    }

    func testAlbumNameNilWhenUnknown() throws {
        let model = try AppModel()
        model.albums = []
        model.resolvedNameCache = [:]

        XCTAssertNil(model.breadcrumbAlbumName(id: "missing"))
    }

    func testArtistNamePrefersLoadedPage() throws {
        let model = try AppModel()
        model.artists = [makeArtist(id: "r1", name: "Page Artist")]
        model.resolvedNameCache["r1"] = "Cache Artist"

        XCTAssertEqual(model.breadcrumbArtistName(id: "r1"), "Page Artist")
    }

    func testArtistNameFallsBackToResolvedCache() throws {
        let model = try AppModel()
        model.artists = []
        model.resolvedNameCache["r2"] = "Cache Artist"

        XCTAssertEqual(model.breadcrumbArtistName(id: "r2"), "Cache Artist")
    }

    func testArtistNameNilWhenUnknown() throws {
        let model = try AppModel()
        model.artists = []
        model.resolvedNameCache = [:]

        XCTAssertNil(model.breadcrumbArtistName(id: "missing"))
    }
}
