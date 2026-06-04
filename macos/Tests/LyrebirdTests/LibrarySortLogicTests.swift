import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the pure Library sort/filter/pagination logic extracted out of
/// `LibraryView` (audit batch: L196, L578, L783, L871). These are deliberately
/// View- and `AppModel`-free — the SwiftUI glue stays thin and the arithmetic
/// that decides display order, when a stable random reshuffles, when a near-end
/// scroll pages the server, and which sort orders a tab offers is locked down
/// here. Mirrors the `TrackSelectionResolverTests` pattern.
final class LibrarySortLogicTests: XCTestCase {

    // MARK: - Fixtures

    private func album(_ id: String, _ name: String = "n") -> Album {
        Album(
            id: id, name: name, artistName: "a", artistId: nil, year: nil,
            trackCount: 0, runtimeTicks: 0, genres: [], imageTag: nil, userData: nil
        )
    }

    // MARK: - seededShuffle (audit L871)

    func testSeededShuffleIsStableForSameSeed() {
        let items = (0..<50).map { album("id-\($0)") }
        let seed = UUID()
        let a = LibrarySortLogic.seededShuffle(items, seed: seed, id: \.id)
        let b = LibrarySortLogic.seededShuffle(items, seed: seed, id: \.id)
        XCTAssertEqual(
            a.map(\.id), b.map(\.id),
            "the same (items, seed) pair must produce the same order so the grid doesn't reorder on every re-render/hover"
        )
    }

    func testSeededShuffleIsAPermutation() {
        let items = (0..<50).map { album("id-\($0)") }
        let shuffled = LibrarySortLogic.seededShuffle(items, seed: UUID(), id: \.id)
        XCTAssertEqual(
            Set(shuffled.map(\.id)), Set(items.map(\.id)),
            "a shuffle must preserve membership — no rows dropped or duplicated"
        )
        XCTAssertEqual(shuffled.count, items.count)
    }

    func testSeededShuffleDiffersAcrossSeeds() {
        // A re-roll (user re-picks Random) should generally change the order.
        // With 50 items the odds of two distinct seeds colliding are negligible.
        let items = (0..<50).map { album("id-\($0)") }
        let a = LibrarySortLogic.seededShuffle(items, seed: UUID(), id: \.id)
        let b = LibrarySortLogic.seededShuffle(items, seed: UUID(), id: \.id)
        XCTAssertNotEqual(
            a.map(\.id), b.map(\.id),
            "a fresh seed should reshuffle, so the explicit Random re-pick gesture visibly re-orders"
        )
    }

    func testSeededShuffleKeepsExistingRowsStableWhenItemsAppended() {
        // Appending a page must not reshuffle already-visible rows: the
        // relative order of the original ids is preserved under the same seed.
        let seed = UUID()
        let first = (0..<30).map { album("id-\($0)") }
        let firstOrder = LibrarySortLogic.seededShuffle(first, seed: seed, id: \.id)

        let appended = first + (30..<60).map { album("id-\($0)") }
        let secondOrder = LibrarySortLogic.seededShuffle(appended, seed: seed, id: \.id)

        let originalIds = Set(first.map(\.id))
        let projected = secondOrder.map(\.id).filter { originalIds.contains($0) }
        XCTAssertEqual(
            projected, firstOrder.map(\.id),
            "paging in more items must not visibly reorder the rows already on screen under Random"
        )
    }

    // MARK: - shouldLoadMore (audit L578)

    func testShouldLoadMoreFiresNearDisplayedEnd() {
        // 30 displayed rows, trigger distance 20 → threshold 10.
        XCTAssertFalse(LibrarySortLogic.shouldLoadMore(index: 9, displayedCount: 30, triggerDistance: 20))
        XCTAssertTrue(LibrarySortLogic.shouldLoadMore(index: 10, displayedCount: 30, triggerDistance: 20))
        XCTAssertTrue(LibrarySortLogic.shouldLoadMore(index: 29, displayedCount: 30, triggerDistance: 20))
    }

    func testShouldLoadMoreUsesDisplayedCountNotRawLoaded() {
        // The bug: a filter shrinks the displayed list to 5 while 200 raw rows
        // are loaded. The old code compared against `loaded - distance` (180),
        // which the index of the last filtered row (4) never reached, so
        // pagination stalled. Against the displayed count the last row trips it.
        let displayedCount = 5
        let lastIndex = displayedCount - 1
        XCTAssertTrue(
            LibrarySortLogic.shouldLoadMore(
                index: lastIndex, displayedCount: displayedCount, triggerDistance: 20
            ),
            "with a sparse filter the displayed tail must still trigger a page (audit L578)"
        )
    }

    func testShouldLoadMoreFalseForEmptyDisplayedList() {
        XCTAssertFalse(
            LibrarySortLogic.shouldLoadMore(index: 0, displayedCount: 0, triggerDistance: 20),
            "no rows means no near-end trigger — eager paging covers the empty-filter case instead"
        )
    }

    // MARK: - shouldEagerlyPageForFilter (audit L783)

    func testEagerPagingOffWhenNoFilter() {
        XCTAssertFalse(
            LibrarySortLogic.shouldEagerlyPageForFilter(
                filterActive: false, displayedCount: 0, loadedCount: 100, total: 20000, prefetchTarget: 60
            ),
            "no filter → ordinary scroll-driven pagination, no eager fetch"
        )
    }

    func testEagerPagingOnWhenFilterSparseAndMoreRemain() {
        XCTAssertTrue(
            LibrarySortLogic.shouldEagerlyPageForFilter(
                filterActive: true, displayedCount: 3, loadedCount: 100, total: 20000, prefetchTarget: 60
            ),
            "a sparse filter with the dataset far from exhausted must keep paging so results aren't silently truncated (audit L783)"
        )
    }

    func testEagerPagingStopsWhenEnoughMatchesAccumulated() {
        XCTAssertFalse(
            LibrarySortLogic.shouldEagerlyPageForFilter(
                filterActive: true, displayedCount: 60, loadedCount: 500, total: 20000, prefetchTarget: 60
            ),
            "once enough filtered matches are on hand, back off the eager fetch"
        )
    }

    func testEagerPagingStopsWhenDatasetExhausted() {
        XCTAssertFalse(
            LibrarySortLogic.shouldEagerlyPageForFilter(
                filterActive: true, displayedCount: 1, loadedCount: 20000, total: 20000, prefetchTarget: 60
            ),
            "no raw items left on the server → nothing to page even if matches are sparse"
        )
    }

    // MARK: - supportedOrders / fallback (audit L196)

    func testAlbumsAndTracksSupportEveryOrder() {
        XCTAssertEqual(
            Set(LibrarySortOrder.supportedOrders(for: .albums)),
            Set(LibrarySortOrder.allCases),
            "albums carry every sort dimension"
        )
        XCTAssertEqual(
            Set(LibrarySortOrder.supportedOrders(for: .tracks)),
            Set(LibrarySortOrder.allCases),
            "tracks carry every sort dimension"
        )
    }

    func testArtistsOmitYearRuntimeAndArtistOrders() {
        let supported = LibrarySortOrder.supportedOrders(for: .artists)
        for unsupported in [LibrarySortOrder.artist, .longest, .shortest, .yearAscending, .yearDescending, .recentlyAdded] {
            XCTAssertFalse(
                supported.contains(unsupported),
                "artists can't honor \(unsupported); offering it would make the menu label lie (audit L196)"
            )
        }
        XCTAssertTrue(supported.contains(.nameAscending))
        XCTAssertTrue(supported.contains(.mostPlayed))
    }

    func testPlaylistsOmitYearAndPlayCountOrders() {
        let supported = LibrarySortOrder.supportedOrders(for: .playlists)
        for unsupported in [LibrarySortOrder.artist, .mostPlayed, .recentlyPlayed, .yearAscending, .yearDescending, .recentlyAdded] {
            XCTAssertFalse(supported.contains(unsupported), "playlists can't honor \(unsupported)")
        }
        XCTAssertTrue(supported.contains(.longest))
        XCTAssertTrue(supported.contains(.shortest))
    }

    func testIsSupportedAndFallbackAgree() {
        for tab in LibraryTab.allCases {
            let fallback = LibrarySortOrder.fallback(for: tab)
            XCTAssertTrue(
                fallback.isSupported(by: tab),
                "the fallback order for \(tab) must itself be supported by \(tab)"
            )
        }
    }

    func testFallbackIsAlphabeticalForEveryTab() {
        for tab in LibraryTab.allCases {
            XCTAssertEqual(
                LibrarySortOrder.fallback(for: tab), .nameAscending,
                "A–Z is the truthful default when a tab can't honor the active sort"
            )
        }
    }

    func testUnsupportedOrderIsDetected() {
        XCTAssertFalse(
            LibrarySortOrder.yearDescending.isSupported(by: .artists),
            "year sort isn't an artist dimension"
        )
        XCTAssertTrue(
            LibrarySortOrder.nameDescending.isSupported(by: .artists),
            "Z–A is a real artist dimension"
        )
    }
}
