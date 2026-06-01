import XCTest
import LyrebirdCore

@testable import Lyrebird

/// Coverage for `AppModel.recordSessionPlay`, which backs the full Play Queue
/// view's recent-history section (#81). Two invariants from the acceptance
/// criteria: consecutive duplicates collapse, and the list is capped at 50
/// entries (newest first).
///
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore`; we redirect the
/// core data dir to a throwaway temp dir via `XDG_DATA_HOME` so tests never
/// touch the real database (mirrors `MiniPlayerStateTests`).
@MainActor
final class SessionPlayHistoryTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 0,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    func testInsertsNewestFirst() throws {
        let model = try AppModel()
        model.recordSessionPlay(makeTrack("a"))
        model.recordSessionPlay(makeTrack("b"))
        XCTAssertEqual(model.sessionPlayHistory.map(\.id), ["b", "a"])
    }

    func testConsecutiveDuplicateIsCollapsed() throws {
        let model = try AppModel()
        model.recordSessionPlay(makeTrack("a"))
        model.recordSessionPlay(makeTrack("a"))
        XCTAssertEqual(model.sessionPlayHistory.map(\.id), ["a"])
    }

    func testNonConsecutiveRepeatIsKept() throws {
        let model = try AppModel()
        model.recordSessionPlay(makeTrack("a"))
        model.recordSessionPlay(makeTrack("b"))
        model.recordSessionPlay(makeTrack("a"))
        XCTAssertEqual(model.sessionPlayHistory.map(\.id), ["a", "b", "a"])
    }

    func testCapsAtFiftyKeepingMostRecent() throws {
        let model = try AppModel()
        for i in 0..<60 {
            model.recordSessionPlay(makeTrack("t\(i)"))
        }
        XCTAssertEqual(model.sessionPlayHistory.count, 50)
        XCTAssertEqual(model.sessionPlayHistory.first?.id, "t59", "newest retained at head")
        XCTAssertEqual(model.sessionPlayHistory.last?.id, "t10", "oldest beyond the cap dropped")
    }
}
