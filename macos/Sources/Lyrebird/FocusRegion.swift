import SwiftUI

/// The top-level keyboard-focus regions that Tab / Shift+Tab cycle between,
/// in forward-cycle order:
///
///   Sidebar → Content → Up Next inspector → Player bar → Search → (wrap)
///
/// This is the region-level counterpart to `SwitchControlGroup` (which labels
/// the accessibility-tree groups for Switch Control's "Group items" scan). The
/// two intentionally overlap on Sidebar / Content / Player Bar but `FocusRegion`
/// also models the two regions that are reachable by Tab but aren't permanent
/// shell containers — the conditionally-mounted Up Next inspector and the
/// toolbar Search field — so the Tab cycle and the region focus ring read from
/// one ordered source of truth.
///
/// macOS Full Keyboard Access already moves focus *within* a focusable subtree
/// with Tab; what it does not do is hop between these named regions with a
/// region-level focus ring. `MainShell` drives that hop explicitly off this
/// enum so the behaviour is identical whether or not the user has Full Keyboard
/// Access enabled (the acceptance criterion).
enum FocusRegion: String, CaseIterable, Hashable {
    case sidebar = "Sidebar"
    case content = "Content"
    case upNext = "Up Next"
    case playerBar = "Player Bar"
    case search = "Search"
}

/// Pure, view-free cycling logic for the Tab / Shift+Tab region traversal.
/// Factored out of `MainShell` so the ordering — and, critically, the
/// rule that the Up Next inspector is skipped when it isn't mounted — is
/// unit-testable without booting a SwiftUI scene.
enum FocusRegionCycle {
    /// Traversal direction. `.forward` is Tab; `.backward` is Shift+Tab.
    enum Direction {
        case forward
        case backward
    }

    /// The regions that are actually reachable right now, in cycle order. The
    /// Up Next inspector only participates when it is mounted
    /// (`inspectorPresent`); every other region is always present.
    ///
    /// Kept as a single ordered array so `next(...)` and the focus-ring wiring
    /// can't drift out of sync — both derive from this one list.
    static func order(inspectorPresent: Bool) -> [FocusRegion] {
        FocusRegion.allCases.filter { region in
            region != .upNext || inspectorPresent
        }
    }

    /// The region Tab / Shift+Tab should move to from `current`.
    ///
    /// - Wraps cyclically (Search → Sidebar on Tab; Sidebar → Search on
    ///   Shift+Tab) so traversal never dead-ends, matching macOS's
    ///   region-cycle convention.
    /// - Skips the Up Next inspector entirely when `inspectorPresent` is
    ///   `false`, so closing the inspector mid-traversal can't strand focus on
    ///   a region that no longer exists.
    /// - When `current` is `nil` (nothing focused yet) or is the now-absent
    ///   `.upNext`, a forward Tab enters at the first region (Sidebar) and a
    ///   backward Shift+Tab enters at the last (Search), so the very first Tab
    ///   press always lands somewhere sensible.
    static func next(
        from current: FocusRegion?,
        direction: Direction,
        inspectorPresent: Bool
    ) -> FocusRegion {
        let regions = order(inspectorPresent: inspectorPresent)
        // `order` always contains at least Sidebar/Content/PlayerBar/Search, so
        // `first`/`last` are non-nil; the fallback satisfies the compiler.
        guard let first = regions.first, let last = regions.last else {
            return .sidebar
        }

        guard let current, let idx = regions.firstIndex(of: current) else {
            // No current focus (or focus was on the now-unmounted inspector):
            // enter at the natural end for the direction.
            return direction == .forward ? first : last
        }

        switch direction {
        case .forward:
            let nextIdx = regions.index(after: idx)
            return nextIdx == regions.endIndex ? first : regions[nextIdx]
        case .backward:
            return idx == regions.startIndex ? last : regions[regions.index(before: idx)]
        }
    }
}
