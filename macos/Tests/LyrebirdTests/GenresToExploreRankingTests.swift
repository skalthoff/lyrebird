import XCTest

@testable import Lyrebird

/// Coverage for the Discover "Genres to Explore" ranking (#250).
///
/// `AppModel.rankGenresToExplore` is the pure half of `refreshGenresToExplore`,
/// split out from the FFI hop so the ranking contract can be asserted without a
/// live core: drop empty genres, rank least-explored (ascending `song_count`)
/// first with a name tiebreaker, cap at 8, and carry the resolved Jellyfin UUID
/// through to the local `Genre.id`.
@MainActor
final class GenresToExploreRankingTests: XCTestCase {

    private func genre(
        _ name: String,
        songs: UInt32,
        id: String? = nil
    ) -> (id: String, name: String, songCount: UInt32) {
        (id: id ?? "id-\(name)", name: name, songCount: songs)
    }

    func testRanksLeastPlayedFirst() {
        let ranked = AppModel.rankGenresToExplore([
            genre("Pop", songs: 500),
            genre("Jazz", songs: 12),
            genre("Ambient", songs: 3),
        ])
        XCTAssertEqual(ranked.map(\.name), ["Ambient", "Jazz", "Pop"])
    }

    func testDropsGenresWithNoSongs() {
        let ranked = AppModel.rankGenresToExplore([
            genre("Empty", songs: 0),
            genre("Real", songs: 4),
        ])
        XCTAssertEqual(ranked.map(\.name), ["Real"])
    }

    func testTieBrokenByCaseInsensitiveName() {
        let ranked = AppModel.rankGenresToExplore([
            genre("blues", songs: 7),
            genre("Ambient", songs: 7),
            genre("Country", songs: 7),
        ])
        XCTAssertEqual(ranked.map(\.name), ["Ambient", "blues", "Country"])
    }

    func testCapsAtEightForTheGrid() {
        let many = (1...20).map { genre("G\($0)", songs: UInt32($0)) }
        let ranked = AppModel.rankGenresToExplore(many)
        XCTAssertEqual(ranked.count, 8)
        // Least-explored eight, in ascending order.
        XCTAssertEqual(ranked.first?.name, "G1")
        XCTAssertEqual(ranked.last?.name, "G8")
    }

    func testCarriesResolvedUuidIntoId() {
        let ranked = AppModel.rankGenresToExplore([
            genre("Soul", songs: 5, id: "uuid-soul-123")
        ])
        XCTAssertEqual(ranked.first?.id, "uuid-soul-123")
    }
}
