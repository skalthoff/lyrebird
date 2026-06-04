import SwiftUI

// MARK: - Persisted window-state keys
//
// Keys are namespaced under `window.*` so they sit alongside (and never
// collide with) the `appearance.*` family in `PreferencesAppearance.swift`.
// They back `@SceneStorage`-driven restoration of the main window's chrome:
// the last-viewed root tab, the sidebar column visibility, and the queue
// inspector visibility. OS-provided size/position restoration is left to
// `WindowGroup` (see `LyrebirdApp` / #17); this layer only restores the
// *content* state the OS can't reach.
enum WindowStateKeys {
    /// Last-viewed root tab (`AppModel.Screen`).
    static let screen = "window.lastScreen"
    /// Sidebar column visibility (`NavigationSplitViewVisibility`).
    static let sidebar = "window.sidebarVisibility"
    /// Queue inspector open/closed.
    static let inspector = "window.inspectorVisible"
}

// MARK: - Stable codecs for @SceneStorage round-trips
//
// `@SceneStorage` and `@AppStorage` persist `RawRepresentable` values whose
// `RawValue` is a property-list type (here `String`). Neither `AppModel.Screen`
// nor `NavigationSplitViewVisibility` is `RawRepresentable`, so we give each a
// stable String codec rather than widening the enums themselves (Screen lives
// in the AppModel hotspot; NavigationSplitViewVisibility is an Apple type).
//
// The raw strings are an on-disk contract: renaming one silently resets every
// user's saved window state, so `WindowStateStoreTests` pins them.

extension AppModel.Screen {
    /// Stable on-disk identifier for `@SceneStorage`. Distinct from the Swift
    /// case name so a future case rename doesn't churn persisted state.
    var persistedRawValue: String {
        switch self {
        case .home: return "home"
        case .discover: return "discover"
        case .radio: return "radio"
        case .library: return "library"
        case .favorites: return "favorites"
        case .search: return "search"
        case .settings: return "settings"
        }
    }

    /// Decode a persisted identifier. Returns `nil` for unknown values (e.g.
    /// a key written by a newer build) so the caller's default kicks in.
    init?(persistedRawValue raw: String) {
        switch raw {
        case "home": self = .home
        case "discover": self = .discover
        case "radio": self = .radio
        case "library": self = .library
        case "favorites": self = .favorites
        case "search": self = .search
        case "settings": self = .settings
        default: return nil
        }
    }
}

extension NavigationSplitViewVisibility {
    /// Stable on-disk identifier for the sidebar column visibility. Only the
    /// states `MainShell` actually drives (`all` / `detailOnly`) plus the
    /// `automatic` default are encoded; anything else collapses to `automatic`
    /// so the store never persists a state the two-column shell can't honour.
    var persistedRawValue: String {
        switch self {
        case .all: return "all"
        case .detailOnly: return "detailOnly"
        default: return "automatic"
        }
    }

    /// Decode a persisted sidebar identifier. Returns `nil` for unknown values
    /// so the caller's default applies.
    init?(persistedRawValue raw: String) {
        switch raw {
        case "all": self = .all
        case "detailOnly": self = .detailOnly
        case "automatic": self = .automatic
        default: return nil
        }
    }
}

// MARK: - WindowStateStore

/// Pure, value-type resolver for the main window's restorable content state.
///
/// All of the launch-time decision logic lives here — free of SwiftUI scene
/// plumbing — so it can be exercised headlessly in `WindowStateStoreTests`.
/// `MainShell` owns the `@SceneStorage`/`@AppStorage` properties and feeds
/// their raw strings in; this type maps them to concrete values to apply.
///
/// Restore precedence for the sidebar (`initialSidebarVisibility`):
///   1. A persisted per-window visibility (the user explicitly toggled the
///      sidebar last session) wins — restoring *their* last layout is the
///      whole point of #10.
///   2. With no persisted state (first launch in this scene), fall back to the
///      Appearance pane's `Sidebar` preference, wiring the previously UI-only
///      `AppearanceSidebar` enum into real behaviour: `.hidden` opens collapsed,
///      `.visible` / `.auto_hide` open expanded.
struct WindowStateStore {
    /// Map an `AppearanceSidebar` preference to the column visibility a window
    /// should adopt when it has no persisted per-window state of its own.
    /// `.autoHide` reveals on hover at the OS level but still *starts* expanded,
    /// so it resolves to `.all` like `.visible`.
    static func defaultVisibility(for preference: AppearanceSidebar) -> NavigationSplitViewVisibility {
        switch preference {
        case .visible, .autoHide: return .all
        case .hidden: return .detailOnly
        }
    }

    /// Resolve the column visibility `MainShell` should apply on launch.
    ///
    /// - Parameters:
    ///   - persistedRaw: the `@SceneStorage` raw string for this scene, or an
    ///     empty string when nothing has been persisted yet.
    ///   - preferenceRaw: the `@AppStorage` `appearance.sidebar` raw string.
    static func initialSidebarVisibility(
        persistedRaw: String,
        preferenceRaw: String
    ) -> NavigationSplitViewVisibility {
        if let restored = NavigationSplitViewVisibility(persistedRawValue: persistedRaw) {
            return restored
        }
        let preference = AppearanceSidebar(rawValue: preferenceRaw) ?? .visible
        return defaultVisibility(for: preference)
    }

    /// Decode the persisted last-viewed root tab, falling back to `.library`
    /// (the app's cold-start default) for empty or unknown raw values.
    static func restoredScreen(persistedRaw: String) -> AppModel.Screen {
        AppModel.Screen(persistedRawValue: persistedRaw) ?? .library
    }

    /// Decode the persisted inspector visibility. Defaults to closed — the
    /// inspector is an opt-in surface (see `MainShell.isQueueInspectorOpen`).
    static func restoredInspectorVisible(persistedRaw: String?) -> Bool {
        persistedRaw == "true"
    }
}
