import SwiftUI

/// Pure decision logic for the resizable, auto-hiding sidebar (#318).
///
/// `MainShell` drives `NavigationSplitView`'s `columnVisibility` from two
/// independent sources:
///   1. the user (the toolbar `Toggle Sidebar` button), and
///   2. the window width — narrow windows auto-collapse the rail to give the
///      detail column room, then auto-restore it when the window widens again.
///
/// The hard part is keeping those two from fighting: once a user has manually
/// hidden or shown the sidebar we must respect that and stop auto-driving it,
/// otherwise a manual reveal in a narrow window would immediately re-collapse
/// (and vice-versa). This type captures that contract as a single pure
/// reducer so the threshold behaviour is unit-testable without booting a
/// SwiftUI scene or introspecting `some View`.
///
/// The reducer is intentionally allocation-free and side-effect-free; the view
/// owns the `@State` and feeds the previous values back in on every width
/// change.
enum SidebarAutoHide {
    /// Window widths at or below this point collapse the sidebar; widths above
    /// it restore it. Chosen as ideal sidebar (252) + a comfortable minimum
    /// detail column (~420) so the auto-hide only kicks in when the two columns
    /// would genuinely crowd each other on a small window, not during normal
    /// resizing on a laptop display.
    static let collapseThreshold: CGFloat = 720

    /// Records whether the sidebar's current collapsed state was driven by
    /// auto-hide (vs. the user). Persisted-adjacent: the view keeps this in
    /// `@State`, the user-override flag in `@AppStorage`.
    struct State: Equatable {
        /// True while the sidebar is collapsed *because* the window is narrow —
        /// i.e. the collapse came from auto-hide, not a manual toggle. Only an
        /// auto-collapse is eligible for auto-restore when the window widens.
        var didAutoCollapse: Bool = false
        /// True once the user has manually toggled the sidebar. While set, the
        /// width-driven reducer leaves `columnVisibility` alone so auto-hide
        /// never overrides an explicit choice. A subsequent width change does
        /// not clear it — only an explicit `clearUserOverride()` (wired to a
        /// fresh manual toggle) does.
        var userDidOverride: Bool = false
    }

    /// The outcome of a width change: the visibility the view should adopt and
    /// the updated auto-hide bookkeeping. `visibility == nil` means "leave
    /// `columnVisibility` untouched" — used when the user override is active or
    /// when no transition is warranted, so the view doesn't stomp an in-flight
    /// animation with a redundant assignment.
    struct Decision: Equatable {
        var visibility: NavigationSplitViewVisibility?
        var state: State
    }

    /// Pure reducer. Given the new window `width`, the current `visibility`,
    /// and the prior `state`, returns whether to collapse / restore and the
    /// updated bookkeeping.
    ///
    /// Contract:
    ///   * If the user has manually overridden visibility, never auto-drive —
    ///     return `visibility: nil` and preserve the override flag.
    ///   * Otherwise, crossing below `collapseThreshold` collapses the rail
    ///     (recording that the collapse was automatic), and crossing back above
    ///     restores it — but *only* if the collapse was the one we made. A rail
    ///     the user left open in a narrow window (no override, already `.all`)
    ///     is left open; we don't retroactively collapse a window that was
    ///     already narrow without a width transition.
    static func decide(
        width: CGFloat,
        visibility: NavigationSplitViewVisibility,
        state: State
    ) -> Decision {
        // A manual choice wins until it's explicitly cleared. Don't touch
        // visibility, and don't disturb the auto-collapse bookkeeping.
        guard !state.userDidOverride else {
            return Decision(visibility: nil, state: state)
        }

        if width <= collapseThreshold {
            // Narrow: collapse if currently shown. If it's already collapsed we
            // leave it (and only claim the auto-collapse if we were the cause).
            if visibility != .detailOnly {
                var next = state
                next.didAutoCollapse = true
                return Decision(visibility: .detailOnly, state: next)
            }
            return Decision(visibility: nil, state: state)
        } else {
            // Wide: restore only the collapse we made. A user-collapsed rail is
            // guarded by `userDidOverride` above, so reaching here with
            // `didAutoCollapse == true` means it's safe to reopen.
            if state.didAutoCollapse {
                var next = state
                next.didAutoCollapse = false
                return Decision(visibility: .all, state: next)
            }
            return Decision(visibility: nil, state: state)
        }
    }

    /// Folds a manual toggle into the bookkeeping: the user has now taken
    /// explicit control, so future width changes must not auto-drive the rail.
    /// Clears the auto-collapse marker because any collapse is now the user's.
    static func registeringManualToggle(_ state: State) -> State {
        State(didAutoCollapse: false, userDidOverride: true)
    }

    /// Whether width-driven auto-hide should run for a given Appearance
    /// `Sidebar` preference. Only `.autoHide` opts in — that's the whole point
    /// of the preference, and it's what makes the three picker options
    /// behaviourally distinct (#318 / sidebar audit):
    ///
    ///   * `.autoHide` — the rail collapses on narrow windows and restores when
    ///     they widen (this reducer drives it).
    ///   * `.visible` — the rail stays put; width never collapses it.
    ///   * `.hidden` — starts collapsed (handled by `WindowStateStore`); the
    ///     width reducer doesn't force it open.
    ///
    /// Returning `false` means the view should skip the reducer entirely and
    /// leave `columnVisibility` to the user / restored state.
    static func isEnabled(for preference: AppearanceSidebar) -> Bool {
        preference == .autoHide
    }
}

/// Stable `@AppStorage` key for the sidebar auto-hide override (#318).
/// Centralised so the writer (`MainShell`) and any future reader never drift on
/// a string literal. Must not be renamed without a migration — a drift silently
/// resets every user's "I manually pinned the sidebar" preference.
enum SidebarDefaults {
    /// `Bool` — set once the user manually toggles the sidebar, after which
    /// width-driven auto-hide stops overriding their choice for the session's
    /// window. Persisted so the preference survives relaunch.
    static let userDidOverrideAutoHideKey = "sidebar.userDidOverrideAutoHide"
}
