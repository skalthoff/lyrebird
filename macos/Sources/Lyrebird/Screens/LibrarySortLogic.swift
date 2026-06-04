import Foundation
@preconcurrency import LyrebirdCore

/// Pure, View-free sort/filter/pagination logic for the Library grid.
///
/// Extracted out of `LibraryView` for the same reason `TrackSelectionResolver`
/// was: the arithmetic that decides display order, which rows survive a filter,
/// when a stable random order reshuffles, and when a near-end scroll should
/// page the server can all be exercised by unit tests without standing up a
/// SwiftUI scene graph or an `AppModel`. The View layer keeps only the
/// `@State` it memoizes the results into plus the side effects (`loadMore*`).
enum LibrarySortLogic {

    // MARK: - Sort

    /// Deterministic shuffle keyed on a per-session seed. Returns the same
    /// order for the same `(items, seed)` pair, so the `.random` sort stays
    /// stable across re-renders (it only changes when the seed is regenerated
    /// — i.e. when the user re-picks Random — or when the source array
    /// changes). Replaces the old `Array.shuffled()` that re-rolled on every
    /// access and made the grid visibly reorder on hover. See audit L871.
    ///
    /// The key is `SipHash` over `(id, seed)` via `Hasher`; ties (astronomically
    /// unlikely across UUID-shaped ids) fall back to the id itself so the order
    /// is total and reproducible.
    static func seededShuffle<T>(_ items: [T], seed: UUID, id: (T) -> String) -> [T] {
        items.sorted { lhs, rhs in
            let lid = id(lhs)
            let rid = id(rhs)
            let lh = shuffleKey(lid, seed: seed)
            let rh = shuffleKey(rid, seed: seed)
            if lh == rh { return lid < rid }
            return lh < rh
        }
    }

    private static func shuffleKey(_ id: String, seed: UUID) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(seed)
        hasher.combine(id)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    // MARK: - Pagination

    /// Whether a near-end scroll to `index` in the *displayed* (filtered +
    /// sorted) list should fire a follow-up page.
    ///
    /// The pre-fix code compared `index` (a position in the filtered list)
    /// against `loaded - distance` (a count of *raw* loaded items). An active
    /// filter shrinks the displayed list below `loaded`, so that threshold was
    /// never reached and pagination silently stalled (audit L578). The fix
    /// computes the threshold against `displayedCount` — the length of the list
    /// the user is actually scrolling — while the caller still gates on
    /// "more raw items remain on the server" (`loaded < total`) and "no page
    /// already in flight".
    static func shouldLoadMore(
        index: Int,
        displayedCount: Int,
        triggerDistance: Int
    ) -> Bool {
        guard displayedCount > 0 else { return false }
        let threshold = max(displayedCount - triggerDistance, 0)
        return index >= threshold
    }

    /// Whether to *eagerly* fetch the next page while a filter is active even
    /// though the visible window hasn't been scrolled to its end.
    ///
    /// Client-side filtering only sees the rows already paged in, so a filter
    /// that matches sparsely can leave the displayed list far shorter than the
    /// viewport — with no `.onAppear` near the end to drive `shouldLoadMore`,
    /// pagination would wedge and the result would be silently truncated
    /// (audit L783). When a filter is active, more raw items remain on the
    /// server (`loaded < total`), and the filtered list is still thin enough to
    /// risk under-filling the viewport, keep pulling pages until either the
    /// dataset is exhausted or enough matches accumulate.
    ///
    /// `prefetchTarget` is the number of filtered matches we try to have on
    /// hand before backing off; tuned to comfortably cover a tall window so the
    /// list doesn't visibly dribble in one page at a time.
    static func shouldEagerlyPageForFilter(
        filterActive: Bool,
        displayedCount: Int,
        loadedCount: Int,
        total: Int,
        prefetchTarget: Int
    ) -> Bool {
        guard filterActive else { return false }
        guard loadedCount < total else { return false }
        return displayedCount < prefetchTarget
    }
}

/// Which `LibrarySortOrder`s a given `LibraryTab` can actually honor, so the
/// header menu only offers orders the tab applies and the menu label never
/// misrepresents the real ordering (audit L196).
///
/// Artists carry no year/runtime and "Artist" is a no-op on the artist list,
/// so those collapse to alphabetical; playlists likewise lack year and
/// play-count. Rather than silently falling back (which made the menu lie),
/// the unsupported orders are removed from the menu for that tab, and a tab
/// switch that lands on an unsupported order snaps to a supported fallback.
extension LibrarySortOrder {
    /// The orders a tab offers, in canonical menu order.
    static func supportedOrders(for tab: LibraryTab) -> [LibrarySortOrder] {
        switch tab {
        case .albums, .tracks:
            // Albums and tracks carry every dimension the menu sorts on.
            return allCases
        case .artists:
            // No year/runtime; "Artist" is meaningless on the artist list.
            return [
                .nameAscending, .nameDescending,
                .recentlyPlayed, .mostPlayed, .random,
            ]
        case .playlists:
            // Playlists carry name + runtime only on the loaded shape.
            return [
                .nameAscending, .nameDescending,
                .longest, .shortest, .random,
            ]
        case .downloaded:
            // No backing list; sort is moot but keep name orders for symmetry.
            return [.nameAscending, .nameDescending]
        }
    }

    /// Whether `tab` can honor this order.
    func isSupported(by tab: LibraryTab) -> Bool {
        LibrarySortOrder.supportedOrders(for: tab).contains(self)
    }

    /// The order to fall back to when a tab can't honor the active one. Always
    /// the first supported order for the tab (alphabetical A–Z in every case),
    /// so the menu label stays truthful after a tab switch.
    static func fallback(for tab: LibraryTab) -> LibrarySortOrder {
        supportedOrders(for: tab).first ?? .nameAscending
    }
}

/// Memoized snapshot of the active tab's filter→sort result, held in
/// `LibraryView` `@State` and recomputed only when an input actually changes
/// (sort order, filter, tab, shuffle seed, or the source array). Holding the
/// already-sorted arrays here means the grid body, the A–Z rail's name/id maps,
/// and the count subline all read one precomputed list instead of each
/// re-deriving a full locale-aware sort per render. See audit L234 / L852.
///
/// Only the active tab's slice is populated; the others stay empty so a switch
/// doesn't sort four collections at once. Names and ids are precomputed
/// alongside the model arrays so the A–Z rail can't drift from what's rendered.
struct LibraryDisplayItems: Equatable {
    var albums: [Album] = []
    var artists: [Artist] = []
    var tracks: [Track] = []
    var playlists: [Playlist] = []

    /// Display-order names for the active tab (A–Z rail buckets read this).
    var names: [String] = []
    /// Display-order ids for the active tab, paired positionally with `names`.
    var ids: [String] = []
}
