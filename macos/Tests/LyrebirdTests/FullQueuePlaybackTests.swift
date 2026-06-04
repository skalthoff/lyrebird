import XCTest
import LyrebirdCore

@testable import Lyrebird

/// Pure-logic coverage for `FullQueuePlayback`, the resolver behind the
/// full-page Play Queue rows' tap-to-play behaviour (#81). Mirrors
/// `TrackSelectionResolverTests`: exercises every branch without a SwiftUI
/// scene graph or an `AppModel`.
///
/// Two regressions are pinned here:
///   * #134 — tapping Now Playing must NOT collapse the queue to one track.
///     The row is handed the full reconstructed queue at index 0.
///   * #340 — a duplicate track id (a song replayed in session history) must
///     start playback at the *tapped* row, not the first matching id.
final class FullQueuePlaybackTests: XCTestCase {

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

    // MARK: - reconstructedQueue (#134)

    func testReconstructedQueueOrdersCurrentThenUpNextThenAutoQueue() {
        let queue = FullQueuePlayback.reconstructedQueue(
            current: makeTrack("now"),
            upNextUserAdded: [makeTrack("u1"), makeTrack("u2")],
            upNextAutoQueue: [makeTrack("a1")]
        )
        XCTAssertEqual(queue.map(\.id), ["now", "u1", "u2", "a1"])
    }

    func testReconstructedQueueIsEmptyWhenNothingPlaying() {
        let queue = FullQueuePlayback.reconstructedQueue(
            current: nil,
            upNextUserAdded: [makeTrack("u1")],
            upNextAutoQueue: [makeTrack("a1")]
        )
        XCTAssertTrue(queue.isEmpty, "no current track => empty queue, nothing to seek")
    }

    func testTappingNowPlayingKeepsWholeQueueAtIndexZero() {
        // The bug (#134): the Now Playing row was handed `queue: [track]`, so a
        // tap rebuilt the queue with a single entry. With the reconstructed
        // queue + index 0, a tap re-seeks the current track and preserves
        // everything after it.
        let reconstructed = FullQueuePlayback.reconstructedQueue(
            current: makeTrack("now"),
            upNextUserAdded: [makeTrack("u1"), makeTrack("u2")],
            upNextAutoQueue: [makeTrack("a1")]
        )
        let plan = FullQueuePlayback.plan(
            queue: reconstructed,
            tappedIndex: 0,
            fallbackTrack: makeTrack("now")
        )
        XCTAssertEqual(plan.startIndex, 0)
        XCTAssertEqual(
            plan.tracks.map(\.id),
            ["now", "u1", "u2", "a1"],
            "tapping Now Playing must not collapse the queue (#134)"
        )
    }

    // MARK: - plan: position vs id resolution (#340)

    func testPlanUsesTappedPositionNotFirstMatchingId() {
        // Same id "a" appears at index 0 and index 2 (a song replayed in
        // session history). Tapping the second occurrence must start at index
        // 2 — `firstIndex(by id)` would have jumped to index 0.
        let queue = [makeTrack("a"), makeTrack("b"), makeTrack("a"), makeTrack("c")]
        let plan = FullQueuePlayback.plan(
            queue: queue,
            tappedIndex: 2,
            fallbackTrack: queue[2]
        )
        XCTAssertEqual(plan.startIndex, 2)
        XCTAssertEqual(plan.tracks.map(\.id), ["a", "b", "a", "c"])
    }

    func testPlanResolvesFirstOccurrenceWhenItIsTheTappedRow() {
        let queue = [makeTrack("a"), makeTrack("b"), makeTrack("a")]
        let plan = FullQueuePlayback.plan(
            queue: queue,
            tappedIndex: 0,
            fallbackTrack: queue[0]
        )
        XCTAssertEqual(plan.startIndex, 0)
        XCTAssertEqual(plan.tracks.count, 3)
    }

    func testPlanPreservesFullQueueForMidListTap() {
        let queue = (0..<10).map { makeTrack("t\($0)") }
        let plan = FullQueuePlayback.plan(
            queue: queue,
            tappedIndex: 7,
            fallbackTrack: queue[7]
        )
        XCTAssertEqual(plan.startIndex, 7)
        XCTAssertEqual(plan.tracks.count, 10, "the whole section stays queued so auto-advance continues")
    }

    // MARK: - plan: out-of-bounds fallback

    func testPlanFallsBackToSingleTrackForOutOfBoundsIndex() {
        let queue = [makeTrack("a"), makeTrack("b")]
        let plan = FullQueuePlayback.plan(
            queue: queue,
            tappedIndex: 5,
            fallbackTrack: makeTrack("z")
        )
        XCTAssertEqual(plan.startIndex, 0)
        XCTAssertEqual(plan.tracks.map(\.id), ["z"], "defensive fallback plays just the row's own track")
    }

    func testPlanFallsBackForEmptyQueue() {
        let plan = FullQueuePlayback.plan(
            queue: [],
            tappedIndex: 0,
            fallbackTrack: makeTrack("z")
        )
        XCTAssertEqual(plan.startIndex, 0)
        XCTAssertEqual(plan.tracks.map(\.id), ["z"])
    }
}
