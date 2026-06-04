import XCTest
@testable import Lyrebird
import LyrebirdCore

/// Coverage for `PlaylistSidebarOrder` — the pure ordering logic behind the
/// sidebar's drag-to-reorder + section-collapse Playlists list (#317).
///
/// Reorder persistence is intentionally client-only: the sidebar sorts the
/// live `model.playlists` array by a stored id list, so the contract that
/// matters is set-reconciliation, not any server round-trip. These tests pin:
///   * the CSV codec (`decode` / `encode`) the `@AppStorage` value rides on;
///   * `reconciled` — stored ids keep their order, new ids append, deleted ids
///     prune, duplicates collapse;
///   * `order` — the generic sort the sidebar applies to `[Playlist]`;
///   * `applyingMove` — folding a SwiftUI `.onMove` back into the stored order.
final class PlaylistSidebarOrderTests: XCTestCase {

    // MARK: - CSV codec

    /// A round trip through encode → decode preserves the id list verbatim.
    func testEncodeDecodeRoundTrip() {
        let ids = ["alpha", "bravo", "charlie"]
        XCTAssertEqual(PlaylistSidebarOrder.encode(ids), "alpha,bravo,charlie")
        XCTAssertEqual(PlaylistSidebarOrder.decode("alpha,bravo,charlie"), ids)
    }

    /// The empty `@AppStorage` default decodes to an empty list, not `[""]`.
    func testDecodeEmptyStringYieldsEmptyList() {
        XCTAssertEqual(PlaylistSidebarOrder.decode(""), [])
        XCTAssertEqual(PlaylistSidebarOrder.encode([]), "")
    }

    /// Stray / trailing commas and whitespace from a corrupt or hand-edited
    /// value are dropped rather than producing empty ghost ids.
    func testDecodeDropsBlankAndWhitespaceEntries() {
        XCTAssertEqual(PlaylistSidebarOrder.decode("a,,b, ,c,"), ["a", "b", "c"])
        XCTAssertEqual(PlaylistSidebarOrder.decode(" a , b "), ["a", "b"])
    }

    // MARK: - Reconciliation

    /// Ids present in both the stored order and the current server set keep
    /// their stored relative order — the whole point of persisting a reorder.
    func testReconcileKeepsStoredOrderForSurvivingIds() {
        let result = PlaylistSidebarOrder.reconciled(
            stored: ["c", "a", "b"],
            current: ["a", "b", "c"]
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    /// A brand-new playlist (in `current`, not in `stored`) appends at the
    /// bottom in server order rather than jumping to the top.
    func testReconcileAppendsNewIdsInServerOrder() {
        let result = PlaylistSidebarOrder.reconciled(
            stored: ["b", "a"],
            current: ["a", "b", "x", "y"]
        )
        XCTAssertEqual(result, ["b", "a", "x", "y"])
    }

    /// A deleted playlist (in `stored`, not in `current`) is pruned, and the
    /// survivors keep their order.
    func testReconcilePrunesDeletedIds() {
        let result = PlaylistSidebarOrder.reconciled(
            stored: ["a", "gone", "b"],
            current: ["a", "b"]
        )
        XCTAssertEqual(result, ["a", "b"])
    }

    /// The result is a permutation of `current` even when both lists are
    /// mangled: stored has a duplicate and a stale id, current has its own
    /// duplicate. Every live id appears exactly once.
    func testReconcileIsDuplicateFreePermutationOfCurrent() {
        let result = PlaylistSidebarOrder.reconciled(
            stored: ["b", "b", "stale", "a"],
            current: ["a", "b", "c", "c"]
        )
        XCTAssertEqual(result, ["b", "a", "c"])
        XCTAssertEqual(Set(result), Set(["a", "b", "c"]))
        XCTAssertEqual(result.count, Set(result).count, "no duplicates")
    }

    /// An empty stored order is the "server order" default: current passes
    /// straight through.
    func testReconcileEmptyStoredYieldsServerOrder() {
        let result = PlaylistSidebarOrder.reconciled(
            stored: [],
            current: ["a", "b", "c"]
        )
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    // MARK: - order(_:by:id:)

    /// The generic sort reorders a `[Playlist]` by the stored ids and appends
    /// an unranked (new) playlist at the bottom — the exact call the sidebar
    /// makes against `model.playlists`.
    func testOrderSortsPlaylistsByStoredOrderAppendingNew() {
        let playlists = [pl("a", "Alpha"), pl("b", "Bravo"), pl("c", "Charlie")]
        let ordered = PlaylistSidebarOrder.order(
            playlists,
            by: ["c", "a"],
            id: \.id
        )
        XCTAssertEqual(ordered.map(\.id), ["c", "a", "b"])
    }

    /// Sorting an empty list is a no-op (and doesn't trap on the rank lookup).
    func testOrderEmptyListReturnsEmpty() {
        let ordered = PlaylistSidebarOrder.order([Playlist](), by: ["a"], id: \.id)
        XCTAssertTrue(ordered.isEmpty)
    }

    /// With no stored order, playlists render in their incoming (server) order.
    func testOrderWithEmptyStoredPreservesInputOrder() {
        let playlists = [pl("a", "Alpha"), pl("b", "Bravo")]
        let ordered = PlaylistSidebarOrder.order(playlists, by: [], id: \.id)
        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
    }

    // MARK: - applyingMove

    /// Moving the last row to the front (drag up) produces the new full id list
    /// to persist. Mirrors SwiftUI's `.onMove(source:destination:)` semantics,
    /// where the destination is the index *before* removal.
    func testApplyingMoveReordersDisplayedIds() {
        let next = PlaylistSidebarOrder.applyingMove(
            displayedIds: ["a", "b", "c"],
            source: IndexSet(integer: 2),
            destination: 0
        )
        XCTAssertEqual(next, ["c", "a", "b"])
    }

    /// Moving the first row down past the second: `.onMove` destination is the
    /// post-removal target index, so source 0 → destination 2 lands "a" between
    /// "b" and "c".
    func testApplyingMoveDownShiftsCorrectly() {
        let next = PlaylistSidebarOrder.applyingMove(
            displayedIds: ["a", "b", "c"],
            source: IndexSet(integer: 0),
            destination: 2
        )
        XCTAssertEqual(next, ["b", "a", "c"])
    }

    /// A move folded back through the codec then reconciled is a stable
    /// pass-through: persisting the whole arrangement means the next render
    /// reproduces exactly the order the user dropped into.
    func testMovePersistsAsStableOrderThroughReconcile() {
        let moved = PlaylistSidebarOrder.applyingMove(
            displayedIds: ["a", "b", "c"],
            source: IndexSet(integer: 2),
            destination: 0
        )
        let raw = PlaylistSidebarOrder.encode(moved)
        let reconciled = PlaylistSidebarOrder.reconciled(
            stored: PlaylistSidebarOrder.decode(raw),
            current: ["a", "b", "c"]
        )
        XCTAssertEqual(reconciled, ["c", "a", "b"])
    }

    // MARK: - Fixture

    /// Minimal `Playlist` fixture — only `id` and `name` are load-bearing for
    /// ordering; the rest are zero/`nil`.
    private func pl(_ id: String, _ name: String) -> Playlist {
        Playlist(
            id: id,
            name: name,
            trackCount: 0,
            runtimeTicks: 0,
            imageTag: nil,
            userData: nil
        )
    }
}
