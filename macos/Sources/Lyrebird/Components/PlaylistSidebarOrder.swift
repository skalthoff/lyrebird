import Foundation

/// Pure ordering logic for the sidebar's drag-to-reorder Playlists list (#317).
///
/// The sidebar lets the user drag playlist rows into a personal order and
/// collapse the whole section. Reorder persistence is deliberately
/// **client-only**: rather than asking the server to renumber playlists (a
/// `MoveItem` round-trip that can fail and is tracked separately), we keep an
/// ordered list of playlist ids in `@AppStorage` and *sort the live
/// `model.playlists` array by it* on every render. That makes the feature
/// impossible to desync from the server — the stored order is just a view
/// preference layered over whatever set of playlists the core hands us.
///
/// The hard parts are all set-reconciliation, not UI:
///   * the server set drifts (new playlists appear, old ones get deleted), so
///     the stored order must be reconciled against the current ids on every
///     read — unknown ids append in their server order, deleted ids prune;
///   * a `.onMove` from SwiftUI hands us `IndexSet` + destination against the
///     *displayed* (already-sorted) order, which we fold back into a fresh id
///     list to persist.
///
/// All of this is expressed as side-effect-free static functions over a CSV
/// string (the `@AppStorage` value) so the contract is unit-testable without
/// booting a SwiftUI scene or touching `UserDefaults`. The view owns the
/// `@AppStorage` string and feeds it through `order(ids:by:)` to sort and
/// through `applyingMove` / `reconciled` to compute the next stored value.
enum PlaylistSidebarOrder {

    // MARK: - CSV codec

    /// Decode the stored `@AppStorage` value into an ordered id list.
    ///
    /// Stored as a comma-separated string because `@AppStorage` can't persist
    /// an `[String]` directly. Empty / whitespace-only entries are dropped so a
    /// stray trailing comma or a freshly-initialised `""` default decodes to an
    /// empty list rather than a `[""]` ghost. Playlist ids are 32-char hex
    /// GUIDs and never contain commas, so a plain split is unambiguous.
    static func decode(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Encode an ordered id list back into the `@AppStorage` CSV value.
    static func encode(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    // MARK: - Reconciliation

    /// Reconcile a stored order against the set of ids the server currently
    /// knows about.
    ///
    /// Contract:
    ///   * ids present in both `stored` and `current` keep their stored
    ///     relative order;
    ///   * ids in `current` but not `stored` (new playlists) append, in their
    ///     `current` order, so a brand-new playlist lands at the bottom of the
    ///     user's arrangement rather than jumping to the top;
    ///   * ids in `stored` but not `current` (deleted playlists) are pruned;
    ///   * the result is duplicate-free even if the stored value was corrupt.
    ///
    /// The returned array is a permutation of `current`, so sorting by it is
    /// total — every live playlist has a slot.
    static func reconciled(stored: [String], current: [String]) -> [String] {
        let currentSet = Set(current)
        var seen = Set<String>()
        var result: [String] = []
        // Keep the stored order for ids that still exist, de-duplicating.
        for id in stored where currentSet.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        // Append any current ids the stored order didn't mention, in server
        // order. `seen` also guards `current` against its own duplicates.
        for id in current where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    /// Sort `items` by the stored order, reconciling first so new items land at
    /// the bottom and deleted ones can't strand a live item.
    ///
    /// Generic over the element so it works against the live `[Playlist]`
    /// without importing the FFI type here — the view passes a key path /
    /// closure to read each element's id. A stable partition preserves the
    /// server's relative order for the appended (previously-unseen) tail.
    static func order<Element>(
        _ items: [Element],
        by stored: [String],
        id: (Element) -> String
    ) -> [Element] {
        guard !items.isEmpty else { return [] }
        let currentIds = items.map(id)
        let ranked = reconciled(stored: stored, current: currentIds)
        // rank[id] → position; every live id is present because `reconciled`
        // returns a permutation of `currentIds`.
        var rank: [String: Int] = [:]
        rank.reserveCapacity(ranked.count)
        for (index, value) in ranked.enumerated() { rank[value] = index }
        // `sorted(by:)` isn't guaranteed stable, so sort on the (rank, original
        // index) pair to keep ties deterministic.
        return items.enumerated()
            .sorted { lhs, rhs in
                let lr = rank[id(lhs.element)] ?? Int.max
                let rr = rank[id(rhs.element)] ?? Int.max
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Move

    /// Fold a SwiftUI `.onMove(source:destination:)` into a fresh stored order.
    ///
    /// `displayedIds` is the id list in the order currently shown to the user
    /// (i.e. already sorted by `order(_:by:)`), and `source` / `destination`
    /// are exactly what `.onMove` hands the view. We apply the move to that
    /// displayed order and return the new full id list to persist — encoding the
    /// *entire* arrangement (not a sparse override) so the next reconcile is a
    /// straight pass-through.
    static func applyingMove(
        displayedIds: [String],
        source: IndexSet,
        destination: Int
    ) -> [String] {
        var ids = displayedIds
        ids.move(fromOffsets: source, toOffset: destination)
        return ids
    }
}
