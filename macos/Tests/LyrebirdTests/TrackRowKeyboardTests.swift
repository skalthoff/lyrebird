import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for `TrackRow`'s extracted keyboard-handling decisions.
///
/// The arrow-key focus traversal and the Space-transport scoping are pulled
/// into `TrackRowKeyboard` so they can be exercised without realizing a live
/// SwiftUI view (mirrors `MenuBarNowPlayingTests`). These guard the two
/// behaviour fixes: arrow keys must only be *claimed* when focus can actually
/// move (otherwise default focus-ring traversal is restored), and Space must
/// only toggle transport from the active row.
final class TrackRowKeyboardTests: XCTestCase {

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "Artist",
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

    private func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map { makeTrack("\($0)") }
    }

    // MARK: focusTarget bounds

    func testFocusTargetMovesDownWithinBounds() {
        let tracks = makeTracks(3)
        XCTAssertEqual(
            TrackRowKeyboard.focusTarget(tracks: tracks, index: 0, delta: 1),
            tracks[1].id
        )
    }

    func testFocusTargetMovesUpWithinBounds() {
        let tracks = makeTracks(3)
        XCTAssertEqual(
            TrackRowKeyboard.focusTarget(tracks: tracks, index: 2, delta: -1),
            tracks[1].id
        )
    }

    func testFocusTargetReturnsNilPastTopEdge() {
        let tracks = makeTracks(3)
        // Up arrow on the first row has nowhere to go — the key should be
        // declined, not swallowed, so the OS can move the focus ring out of
        // the list.
        XCTAssertNil(TrackRowKeyboard.focusTarget(tracks: tracks, index: 0, delta: -1))
    }

    func testFocusTargetReturnsNilPastBottomEdge() {
        let tracks = makeTracks(3)
        XCTAssertNil(TrackRowKeyboard.focusTarget(tracks: tracks, index: 2, delta: 1))
    }

    func testFocusTargetReturnsNilForEmptySiblings() {
        // The regression this fixes: when no track list is threaded the row
        // must NOT claim the arrow key (previously it returned `.handled`
        // unconditionally, killing focus traversal even though nothing moved).
        XCTAssertNil(TrackRowKeyboard.focusTarget(tracks: [], index: 0, delta: 1))
        XCTAssertNil(TrackRowKeyboard.focusTarget(tracks: [], index: 0, delta: -1))
    }

    func testFocusTargetReturnsNilWhenIndexOutOfRange() {
        // Defensive: a stale index shouldn't crash or wrap.
        let tracks = makeTracks(2)
        XCTAssertNil(TrackRowKeyboard.focusTarget(tracks: tracks, index: 5, delta: 1))
        XCTAssertNil(TrackRowKeyboard.focusTarget(tracks: tracks, index: 5, delta: -1))
    }

    // MARK: Space transport scoping

    func testSpaceTogglesTransportOnlyOnActiveRow() {
        // Only the current player-target row claims Space; every other row
        // declines so the key isn't trapped away from default handling.
        XCTAssertTrue(TrackRowKeyboard.spaceTogglesTransport(isActive: true))
        XCTAssertFalse(TrackRowKeyboard.spaceTogglesTransport(isActive: false))
    }
}
