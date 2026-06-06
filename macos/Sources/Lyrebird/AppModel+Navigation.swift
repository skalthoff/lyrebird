import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Programmatic navigation entry points on `AppModel`: pushing `Route` values
/// onto the `NavigationStack` path, drilling into playlist / smart-playlist
/// detail, creating a new smart playlist, deep-linking the Library to a decade
/// (with the one-shot `pendingLibraryYearRange` hand-off), opening Now Playing
/// on its Lyrics tab, and jumping to the Discover screen.
///
/// `navPath` and `pendingLibraryYearRange` are `@Observable` stored state on the
/// main `AppModel` class — stored properties can't live in an extension — so
/// they remain there; these methods read and mutate that state. Extensions of a
/// `@MainActor` type inherit its isolation, so every method here is
/// main-actor-bound just like the rest of the class.
extension AppModel {
    /// Navigate to the playlist detail screen. Caches the playlist so
    /// `PlaylistView` can resolve it by id. Called from the Sidebar, Home
    /// shelves, and context menus as they start linking into playlist detail
    /// (#220 / #313 follow-ups).
    func goToPlaylist(_ playlist: Playlist) {
        if !playlists.contains(where: { $0.id == playlist.id }) {
            playlists.append(playlist)
        }
        navPath.append(Route.playlist(playlist.id))
    }

    /// Drill into a saved smart playlist's detail page (#77 / #238). The
    /// detail view evaluates the rules live from the library snapshot, so
    /// there's nothing to pre-fetch here.
    func goToSmartPlaylist(_ playlist: SmartPlaylist) {
        navPath.append(Route.smartPlaylist(playlist.id))
    }

    /// Create a new smart playlist from the sidebar's "New Smart Playlist…"
    /// entry: seed a draft, persist it immediately so it appears in the
    /// sidebar, and drill into its detail page (where the builder sheet can
    /// be opened to refine the rules). Returns the created playlist's id so
    /// callers / tests can address it.
    @discardableResult
    func createSmartPlaylist() -> UUID {
        let draft = SmartPlaylist.newDraft()
        smartPlaylists.add(draft)
        navPath.append(Route.smartPlaylist(draft.id))
        return draft.id
    }

    /// Programmatic drill-navigation entry point. Pushes a `Route` onto
    /// `navPath` so the new `NavigationStack` shell renders the matching
    /// destination. Views that want to drill into a detail screen should
    /// prefer this over manipulating `navPath` directly so there's a single
    /// seam to add side effects (analytics, breadcrumb history, etc.) later.
    ///
    /// Wired by the Artist detail page's Similar Artists tiles (BATCH-04)
    /// and the command palette.
    func navigate(to route: Route) {
        navPath.append(route)
    }

    /// Deep-link the Library to a decade. Stashes the inclusive
    /// `[start, start+9]` release-year window on `pendingLibraryYearRange`,
    /// forces the Albums chip (the only library tab whose items carry a year
    /// the filter keys on), and switches to the Library tab. `LibraryView`
    /// folds the pending window into its filter on appear and clears it, so
    /// the constraint is applied exactly once. Wired by the Discover "Browse
    /// by Decade" gradient tiles.
    func browseDecade(startingYear start: Int) {
        pendingLibraryYearRange = start...(start + 9)
        libraryTab = .albums
        selectTab(.library)
    }

    /// Read-and-clear the one-shot `pendingLibraryYearRange`. Returns the
    /// window the caller should apply (or `nil` when none is pending) and
    /// leaves the slot empty so a subsequent Library appearance doesn't
    /// re-impose a decade the user already navigated away from.
    func consumePendingLibraryYearRange() -> ClosedRange<Int>? {
        defer { pendingLibraryYearRange = nil }
        return pendingLibraryYearRange
    }

    /// Open the full Now Playing view on its Lyrics tab. Wired to the inline
    /// lyrics snippet in the Queue Inspector (#91) — tapping the snippet
    /// promotes the compact 3-line preview to the full-screen synced lyrics.
    /// Sets a one-shot `requestedNowPlayingTab` that `NowPlayingView` reads
    /// and clears on appear, then pushes the route (or no-ops the push if
    /// Now Playing is already on top so a second tap doesn't stack a copy).
    func openLyrics() {
        requestedNowPlayingTab = "Lyrics"
        if !isShowingNowPlaying {
            navigate(to: .nowPlaying)
        }
    }

    /// Navigate to the Discover screen. See #248.
    func goToDiscover() {
        selectTab(.discover)
    }
}
