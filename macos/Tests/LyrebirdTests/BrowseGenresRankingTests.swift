import XCTest

@testable import Lyrebird

/// Coverage for the Search "Browse by Genre" ranking (#247).
///
/// `AppModel.rankBrowseGenres` is the pure half of `refreshBrowseGenres`, split
/// out from the FFI hop so the ranking contract can be asserted without a live
/// core: drop empty genres, rank biggest-first (descending `song_count`) with a
/// name tiebreaker, cap at 12, and carry the resolved Jellyfin UUID through to
/// the local `Genre.id`. The dual of `GenresToExploreRankingTests`.
@MainActor
final class BrowseGenresRankingTests: XCTestCase {

    private func genre(
        _ name: String,
        songs: UInt32,
        id: String? = nil
    ) -> (id: String, name: String, songCount: UInt32) {
        (id: id ?? "id-\(name)", name: name, songCount: songs)
    }

    func testRanksBiggestFirst() {
        let ranked = AppModel.rankBrowseGenres([
            genre("Ambient", songs: 3),
            genre("Jazz", songs: 12),
            genre("Pop", songs: 500),
        ])
        XCTAssertEqual(ranked.map(\.name), ["Pop", "Jazz", "Ambient"])
    }

    func testDropsGenresWithNoSongs() {
        let ranked = AppModel.rankBrowseGenres([
            genre("Empty", songs: 0),
            genre("Real", songs: 4),
        ])
        XCTAssertEqual(ranked.map(\.name), ["Real"])
    }

    func testTieBrokenByCaseInsensitiveName() {
        let ranked = AppModel.rankBrowseGenres([
            genre("blues", songs: 7),
            genre("Ambient", songs: 7),
            genre("Country", songs: 7),
        ])
        XCTAssertEqual(ranked.map(\.name), ["Ambient", "blues", "Country"])
    }

    func testCapsAtTwelveForTheGrid() {
        let many = (1...20).map { genre("G\($0)", songs: UInt32($0)) }
        let ranked = AppModel.rankBrowseGenres(many)
        XCTAssertEqual(ranked.count, 12)
        // Biggest twelve, in descending order.
        XCTAssertEqual(ranked.first?.name, "G20")
        XCTAssertEqual(ranked.last?.name, "G9")
    }

    func testCarriesResolvedUuidIntoId() {
        let ranked = AppModel.rankBrowseGenres([
            genre("Soul", songs: 5, id: "uuid-soul-123")
        ])
        XCTAssertEqual(ranked.first?.id, "uuid-soul-123")
    }
}
