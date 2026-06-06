import AppKit
import Foundation
import MediaPlayer
import Observation
import os
import SwiftUI
@preconcurrency import LyrebirdCore
import LyrebirdAudio

/// Top-level app state. Owns the Rust core and publishes a reactive surface
/// that SwiftUI views observe. All core calls go through here so views never
/// touch the FFI directly.
@Observable
@MainActor
final class AppModel {
    // MARK: - Core
    let core: LyrebirdCore
    let audio: AudioEngine
    let mediaSession: MediaSession
    let network: NetworkMonitor
    let serverReachability: ServerReachability

    // MARK: - Session
    var session: Session?
    var serverURL: String = ""
    var username: String = ""

    // MARK: - Navigation
    /// Active root tab. Drill destinations (album / artist / playlist /
    /// nowPlaying) live on `navPath` instead so back navigation is handled
    /// by `NavigationStack` natively. See #1 / #4.
    enum Screen: Hashable { case home, discover, radio, library, favorites, search, settings }
    var screen: Screen = .library

    /// Typed value-type for `NavigationStack` destinations. Root tabs and
    /// drill destinations are both representable so `Route` can address
    /// any surface in the app, but in production the path only ever
    /// holds drill entries — the active tab is `screen`. See #1 / #4.
    enum Route: Hashable {
        case home
        case discover
        case radio
        case library
        case favorites
        case search
        case settings
        case album(String)
        case artist(String)
        case playlist(String)
        /// A client-side smart playlist (#77 / #238), addressed by its local
        /// `SmartPlaylist.id`. The track set is evaluated live from the
        /// library snapshot rather than fetched, so this carries no server id.
        case smartPlaylist(UUID)
        case genre(Genre)
        case nowPlaying
        case fullQueue
    }

    /// Drill stack for the current tab. Empty when the user is on the root
    /// of a tab; gains entries as they push album / artist / playlist /
    /// nowPlaying detail views. `selectTab(_:)` resets this when the user
    /// flips tabs so the drill state doesn't leak across roots. Modeled as
    /// a typed `[Route]` array (rather than `NavigationPath`) so call sites
    /// can inspect the top of the stack — needed for the "toggle Now
    /// Playing" menu command and similar reversible drills. See #1 / #4.
    var navPath: [Route] = []

    /// Switch to a root tab and clear the drill stack. Use this from every
    /// sidebar / menu tab handler so drill state doesn't survive a tab
    /// change.
    func selectTab(_ tab: Screen) {
        screen = tab
        navPath = []
    }

    /// True when the full Now Playing view is the top of the drill stack.
    /// Used by the ⌘L menu toggle (see `LyrebirdApp.toggleNowPlaying`) so
    /// the second press pops back rather than stacking another copy.
    var isShowingNowPlaying: Bool {
        navPath.last == .nowPlaying
    }

    /// True when the full-page Play Queue view is the top of the drill
    /// stack. Used by the ⌘U menu toggle (see `LyrebirdApp.toggleFullQueue`)
    /// so the second press pops back rather than stacking another copy. See
    /// #81.
    var isShowingFullQueue: Bool {
        navPath.last == .fullQueue
    }

    /// Which chip is active on the Library screen. Driven by the sidebar's
    /// "Albums / Artists / Playlists" libRows so they can deep-link into a
    /// specific tab rather than always landing on the default. `LibraryView`
    /// mirrors this into its local `@State` on appear and writes back on
    /// user-chip-change so the sidebar selection persists across navigation.
    var libraryTab: LibraryTab = .albums

    /// One-shot inclusive release-year window the Library should pre-apply on
    /// its next appearance. Set by `browseDecade(_:)` (the Discover "Browse by
    /// Decade" row) so a tapped decade tile lands on the Library
    /// pre-filtered to that ten-year span. `LibraryView` reads this on appear /
    /// change and clears it via `consumePendingLibraryYearRange()` so the
    /// filter isn't re-imposed when the user later returns to the Library by
    /// other means.
    var pendingLibraryYearRange: ClosedRange<Int>?

    /// Screen the app was on before the user opened the full Now Playing
    /// view. `NowPlayingView` offers a "Back" affordance that pops to this
    /// value rather than unconditionally routing to `.library`, so a user
    /// who opened the full player from the Album detail page lands back
    /// there on exit. `nil` when we've never been anywhere interesting
    /// (first launch lands on `.library`, which is already the fallback).
    /// See #89.
    var previousScreen: Screen?

    /// Toggled by the ⌘F menu command to request that `SearchView` move
    /// keyboard focus into its text field. `SearchView` observes changes and
    /// resets the flag after focusing so subsequent ⌘F presses fire again
    /// even when already on the Search screen.
    var requestSearchFocus: Bool = false

    /// Mirror of `requestSearchFocus` published as a plain focus flag so
    /// toolbar / search fields can bind a SwiftUI `@FocusState` to it via the
    /// usual projected-value pattern. `focusSearch()` writes both (keeping the
    /// legacy flag alive for `SearchView`'s existing onChange handler) and
    /// observers are expected to reset it once focus has landed. See #7 / #104.
    var isSearchFieldFocused: Bool = false

    /// Route-addressed, one-shot focus request for the *scoped* in-content
    /// search bar on a detail page (Artist / Playlist). `requestFind()` sets
    /// this when ⌘F is pressed while such a view is the active drill
    /// destination.
    ///
    /// It carries the **target route** (not just a flag) so that when several
    /// scoped-search-capable views are simultaneously alive in the
    /// `NavigationStack` back-stack — e.g. Artist → Playlist, where SwiftUI
    /// keeps the pushed-under view instantiated — only the view whose own
    /// route matches `route` pulls focus. A bare `Bool` pulse made *every*
    /// live observer grab focus, so the off-screen page stole the focus state
    /// from the visible one.
    ///
    /// `token` is a monotonic counter bumped on every request so that a repeat
    /// ⌘F (same route, e.g. the bar is already open) still produces an
    /// observable change. The matching view consumes the request by calling
    /// `consumeScopedSearchFocus(for:)`, which clears it. Distinct from
    /// `isSearchFieldFocused`, which targets the full-screen global Search
    /// surface (⌘⇧F).
    var scopedSearchFocusRequest: ScopedSearchFocusRequest?

    /// A route-addressed request to focus a scoped search bar. Equatable so
    /// SwiftUI `.onChange` fires on each fresh request; the `token` guarantees
    /// a change even when the same `route` is requested twice in a row.
    struct ScopedSearchFocusRequest: Equatable {
        /// The drill destination that should receive focus. Only the view
        /// rendering this exact route (id included) responds.
        let route: Route
        /// Monotonic pulse counter so repeat requests for the same route are
        /// still observable changes.
        let token: Int
    }

    /// Monotonic backing counter for `ScopedSearchFocusRequest.token`.
    private var scopedSearchFocusToken: Int = 0

    /// Track id that currently has keyboard focus inside an arrow-navigable
    /// list row (Library Tracks tab, album / playlist detail). Set by
    /// `TrackListRow` / `TrackRow` when they gain focus and by arrow-key
    /// handlers when focus moves between siblings. `nil` when no list row is
    /// focused. Return plays the focused id; Space toggles global play/pause
    /// regardless. See #105.
    var focusedTrackId: String?

    // MARK: - Library
    var albums: [Album] = []
    var artists: [Artist] = []
    var tracks: [Track] = []
    /// Playlists known to the app — populated as the user navigates into
    /// playlist detail surfaces or hits a screen that needs them (e.g. the
    /// Library's Playlists tab, once #220 / #313 land). This is the source
    /// of truth for `PlaylistView` to look up a playlist by id when the
    /// shell routes `.playlist(id)`; upstream surfaces insert the playlist
    /// here on navigation so a subsequent `.playlist(id)` doesn't have to
    /// re-fetch. See #234.
    var playlists: [Playlist] = []
    /// Client-side smart playlists (#77 / #238). Rule-driven playlists that
    /// the app evaluates live over the in-memory library snapshot — no server
    /// round-trip. Persisted locally as JSON in Application Support by the
    /// store itself; all CRUD goes through it so disk stays in sync. The
    /// sidebar renders `smartPlaylists.playlists`; `SmartPlaylistDetailView`
    /// evaluates the selected one via `SmartPlaylistEvaluator`.
    let smartPlaylists = SmartPlaylistStore()
    var albumTracks: [String: [Track]] = [:]          // albumID → tracks
    /// Per-playlist track caches, mirroring `albumTracks`. Populated by
    /// `loadPlaylistTracks(playlist:)`; held for the session; cleared on
    /// logout. See #125 and #234.
    var playlistTracks: [String: [Track]] = [:]       // playlistID → tracks
    /// Tracks for the playlist currently on screen in `PlaylistDetailView`
    /// (#74 / #236). Separate from the keyed `playlistTracks` cache because
    /// the detail view mutates this list in response to remove / add / undo
    /// and needs a single observable array to drive the list rendering. The
    /// cache is refreshed from `playlistTracks[playlistId]` when present so
    /// repeat visits are instant.
    var currentPlaylistTracks: [Track] = []
    /// The most-recent optimistic removal from a playlist, held so the undo
    /// toast in `PlaylistDetailView` can restore it. Cleared when the 10s
    /// toast window lapses or the user taps Undo. See #74.
    var pendingPlaylistRemoval: PendingRemoval?
    /// Client-side overrides for playlist description. The server-side
    /// Jellyfin item carries `Overview`, but our core `Playlist` record
    /// doesn't expose it yet (see #130 / `update_playlist`). Until the FFI
    /// lands, the hero's click-to-edit description reads from and writes
    /// to this in-memory map so the interaction feels real; on the next
    /// session / core-refresh the override evaporates. See #234.
    var playlistDescriptions: [String: String] = [:]
    /// Cache of the top most-played tracks per artist id. Populated on demand
    /// by `loadArtistTopTracks(artistId:)` when the Artist detail screen
    /// opens. Held for the session; cleared on logout. See #229.
    var artistTopTracks: [String: [Track]] = [:]      // artistID → top tracks
    /// Cache of artists similar to a given artist id. Populated on demand by
    /// `loadSimilarArtists(artistId:)` when the Artist detail screen opens.
    /// Held for the session; cleared on logout. See #146.
    var artistSimilarCache: [String: [Artist]] = [:]  // artistID → similar artists
    /// Cache of playlists that feature a given artist in their track list.
    /// Populated on demand by `loadPlaylistsFeaturingArtist(artistId:)` when
    /// the Artist detail screen opens. Held for the session; cleared on
    /// logout.
    var artistPlaylistsCache: [String: [Playlist]] = [:]  // artistID → featuring playlists
    var recentlyPlayed: [Track] = []
    /// Tracks surfaced in the Discover "For You" carousel (#249). Today this
    /// is a best-effort fallback to the first 20 `recentlyPlayed` tracks. A
    /// real recommendations endpoint — seeded from listening history, minus
    /// already-played items, leaning on similar artists — is tracked as a
    /// follow-up on the core (no FFI exists yet; see `refreshForYou()` for
    /// the TODO).
    var forYou: [Track] = []
    /// Genres surfaced in the Discover "Genres to Explore" grid (#250). A
    /// 4×2 grid of up to 8 genres the user has explored the least, ranked by
    /// ascending `song_count` — the smallest-but-present genres bubble up so
    /// the surface nudges toward corners of the library the user hasn't dug
    /// into. Carries the resolved Jellyfin UUID in `Genre.id` (sourced
    /// straight from `core.genres`), so tapping a tile can navigate to the
    /// genre detail screen without re-resolving the name. Empty until
    /// `refreshGenresToExplore()` runs, and stays empty for a library with no
    /// genres so the section can hide rather than punch a blank hole.
    var genresToExplore: [Genre] = []
    /// Genres surfaced in the Search "Browse by Genre" tile grid (#247). The
    /// dual of `genresToExplore`: the *largest* genres in the library, ranked
    /// by descending `song_count` and capped at 12, so the empty-search page
    /// leads with the corners of the library the user is most likely to want
    /// to browse. Carries the resolved Jellyfin UUID in `Genre.id` (sourced
    /// straight from `core.genres`), so tapping a tile navigates to the genre
    /// detail screen without a name→UUID round-trip. Empty until
    /// `refreshBrowseGenres()` runs, and stays empty for a genre-less library
    /// so the section can hide rather than render a blank band.
    var browseGenres: [Genre] = []
    /// Last-played albums for the Home "Jump Back In" carousel (#51). Up to
    /// 12 albums the user has played recently, sorted by `DatePlayed` desc.
    /// Backed by a raw `/Items` fetch because the core's `ItemsQuery`
    /// builder (BATCH-24) hasn't landed yet. See `refreshJumpBackIn`.
    var jumpBackIn: [Album] = []
    /// Recently-added albums for the Home "Recently Added" carousel (#54).
    /// Up to 20 albums, sorted by `DateCreated` desc (server-side via
    /// `/Users/{id}/Items/Latest`). Wired through the existing
    /// `core.latestAlbums` FFI.
    var recentlyAdded: [Album] = []
    /// `DateCreated` for each album in `recentlyAdded`, keyed by album id.
    /// Drives the "NEW" badge on tiles within the last 7 days. Parsed
    /// alongside the album list in `refreshRecentlyAdded`.
    var recentlyAddedDates: [String: Date] = [:]
    /// "Quick Picks" — heavy-rotation albums over the last 30 days (#53).
    /// Sorted by server-side `PlayCount` desc with a client-side
    /// `DatePlayed > now - 30d` filter applied via Jellyfin's `MinDateLastSaved`.
    /// Up to 12 albums.
    var quickPicks: [Album] = []
    /// Play count per album in `quickPicks`, keyed by album id. Shown as a
    /// subtle "42 plays" badge on tile hover. Parsed out of the same `/Items`
    /// response that drives `quickPicks`.
    var quickPicksPlayCounts: [String: UInt32] = [:]
    /// Favorite albums for the Home "Favorites" carousel (#55). The full
    /// favorite set is fetched once per session and then shuffled down to
    /// 12 visible tiles — re-shuffled on each `refreshFavoriteAlbums` call
    /// so the carousel feels fresh on relaunch.
    var favoriteAlbumsAll: [Album] = []
    /// Currently-visible shuffled sample of `favoriteAlbumsAll`, capped at
    /// 12. Re-derived every time the backing set is refreshed so the view
    /// doesn't have to know about the shuffle.
    var favoriteAlbumsVisible: [Album] = []
    /// Favorite artists for the Home "Artists You Love" carousel (#207).
    /// A circle-card row of the artists the user has hearted, sorted by
    /// name (server-side `SortName` ascending via `loadFavoriteArtists`).
    /// Reuses the same favorites signal as the Favorites screen's Artists
    /// section, so the two never drift. Hidden in the Home layout when
    /// empty — a fresh user with no favorited artists sees no shelf.
    var favoriteArtists: [Artist] = []
    /// "Recently Discovered Artists" for the Home circle-card row (#252).
    /// The album artists whose catalogue most recently landed on the
    /// server, newest first — sorted server-side by `DateCreated`
    /// descending via the `core.listRecentlyAddedArtists` FFI (the
    /// `Artists/AlbumArtists` endpoint with a `DateCreated`-desc sort).
    /// Distinct from `recentlyAdded`, which surfaces newly-added *albums*:
    /// this row answers "whose music just showed up in my library?".
    /// Reuses `ArtistCard`. Capped at a modest count for the carousel and
    /// hidden when empty so a fresh / static library renders no shelf.
    var recentlyDiscoveredArtists: [Artist] = []
    /// "Rediscover" — albums the user has never played, for the Home shelf
    /// of the same name (#57). Backed by an `/Items` query filtered to
    /// `IsUnplayed` and sorted `Random` so the row surfaces a fresh,
    /// varied handful each session (the same shuffle-for-freshness shape
    /// as the Favorites carousel). Up to 12 albums. Hidden when empty so a
    /// fully-played library renders no shelf rather than a blank band.
    var rediscover: [Album] = []
    /// Server-curated "You might like" tracks for the Home discovery row
    /// (#145). Backed by `core.suggestions()`, which hits Jellyfin's
    /// `/Items/Suggestions` endpoint. Up to 20 tracks. Hidden until data
    /// arrives so first-time users don't see an empty shelf.
    var suggestions: [Track] = []
    var searchResults: SearchResults?
    var searchQuery: String = ""

    // MARK: - Full search page (#86 / #242 / #244 / #245 / #246)
    //
    // State specific to `SearchView`'s full-page surface. Kept distinct from
    // `searchResults` (which may later back the toolbar instant dropdown)
    // so the two can evolve independently — the page supports scope filters,
    // per-section pagination and persistent recents; the instant dropdown
    // is a lightweight top-result affordance.

    /// Per-scope buckets of results for the full search page. Keyed by the
    /// `SearchScope.storageKey` string ("artists", "albums", "tracks",
    /// "playlists", "genres") so it round-trips cleanly through
    /// `@Observable` without needing a dedicated record type. Missing keys
    /// render as "nothing here for this scope yet".
    var searchPageResults: [String: [SearchItem]] = [:]

    /// Raw, user-facing text of the full-search field. Bound directly to
    /// the `TextField` on `SearchView` (and the toolbar field on
    /// `MainShell`), so it must reflect exactly what the user typed —
    /// including any trailing/leading whitespace mid-edit. `runFullSearch`
    /// deliberately does NOT write a trimmed value back here, otherwise a
    /// debounced pass would silently delete a space the user just typed.
    /// The trimmed query that actually drove the results lives in
    /// `searchPageActiveQuery`.
    var searchPageQuery: String = ""

    /// The trimmed query that produced the current `searchPageResults`.
    /// Distinct from the user-facing `searchPageQuery` binding so that
    /// pagination (`loadMoreFullSearch`) and "what drove these results"
    /// checks read a stable, normalized value without ever mutating the
    /// text the user is editing. Stored separately from `searchQuery` so
    /// the page doesn't race with whatever the instant dropdown is showing.
    var searchPageActiveQuery: String = ""

    /// Scope chip the user has selected on the full search page. `.all`
    /// shows every section; anything else filters the page down to a single
    /// typed section. See #242.
    var activeSearchScope: SearchScope = .all

    /// Server-reported `TotalRecordCount` for the current page search.
    /// Used by "Load more" to decide whether a follow-up fetch would yield
    /// new rows from the server vs. just drawing from already-buffered
    /// bucket contents.
    var searchPageTotal: UInt32 = 0

    /// Combined count of raw items we've pulled from the server for this
    /// query. Paired with `searchPageTotal` to drive backend pagination
    /// when the visible-per-section cap runs out of buffered items.
    var searchPageLoaded: Int = 0

    /// A full-search pass is in flight. Views use this to show a spinner
    /// and to debounce re-entrant submits from the Return key.
    var isLoadingFullSearch: Bool = false

    /// Set once the server has nothing further to give for the current
    /// query: either `searchPageLoaded` has reached `searchPageTotal`, or
    /// a `loadMoreFullSearch` page came back with zero *new* deduplicated
    /// items in the paged buckets. The latter guard matters because
    /// `searchPageTotal` is the server's raw `TotalRecordCount` (it can
    /// count item types we don't page, or be deduplicated server-side),
    /// so `searchPageLoaded < searchPageTotal` can stay true after the
    /// server has actually returned everything it will. Without this flag
    /// the "Load more" button would stay live forever. Reset on every
    /// fresh `runFullSearch`.
    var searchPageExhausted: Bool = false

    /// Whether a follow-up `loadMoreFullSearch` could plausibly yield new
    /// rows from the server. False once we've hit the total or a page
    /// added nothing. Only meaningful for the server-paged scopes
    /// (artists / albums / tracks); derived scopes (genres) and
    /// not-yet-paged scopes (playlists) never consult this.
    var searchPageHasMore: Bool {
        !searchPageExhausted && searchPageLoaded < Int(searchPageTotal)
    }

    /// Combined page size for `runFullSearch`. Chosen so each typed
    /// section (artists / albums / tracks) usually gets well above the
    /// "~20 per category" the UI aims to display without needing a
    /// follow-up fetch. Jellyfin's `/Items` endpoint returns MusicArtist,
    /// MusicAlbum, and Audio in one response, so the bucket sizes vary by
    /// query — 100 is a practical middle ground.
    private let searchPagePageSize: UInt32 = 100

    /// Collection-view id of the Jellyfin "Playlists" library. Resolved
    /// lazily on first `refreshPlaylists()` — see `ensurePlaylistLibraryId`.
    /// Cached across the session; cleared on logout.
    ///
    /// Jellyfin scopes `user_playlists` / `public_playlists` by `ParentId`,
    /// so we need this before we can fetch anything. There is no FFI yet for
    /// listing the user's libraries (tracked in core issue separate from
    /// #483), so the current resolve is a pragmatic empty-string fallback:
    /// Jellyfin's `/Items` endpoint treats an empty `ParentId` as "root /
    /// any library the user can see", which happens to return playlists
    /// across the whole server. When a real `core.libraries()` FFI lands,
    /// swap this for a proper lookup.
    var playlistLibraryId: String?

    // MARK: - Pagination
    //
    // `*Total` mirrors the server's `TotalRecordCount` so views can render
    // "N of M" sublines and decide when to trigger a follow-up page. The
    // `isLoadingMore*` flags debounce near-end triggers so a fast scroll
    // through the grid doesn't fan out into duplicate in-flight fetches.
    //
    // Size of each page (see `libraryInitialPageSize` and `libraryPageSize`):
    // first paint uses 100 so the grid shows up fast; subsequent pages fetch
    // 200 to keep round-trip count low once the user has committed to browsing.

    /// Server-reported total album count for the current library.
    var albumsTotal: UInt32 = 0
    /// Server-reported total artist count for the current library.
    var artistsTotal: UInt32 = 0
    /// Server-reported total track count for the current library.
    var tracksTotal: UInt32 = 0
    /// Server-reported total playlist count for the current library.
    ///
    /// Caveat: `user_playlists` / `public_playlists` on the core filter the
    /// server's response client-side by `Path`, so this total is the raw
    /// server count across BOTH user- and public-owned playlists — i.e. an
    /// upper bound on what `items.count` will reach. See the core's
    /// `PaginatedPlaylists` docstring.
    var playlistsTotal: UInt32 = 0
    /// Server-reported total recently-played count (listening history size).
    var recentlyPlayedTotal: UInt32 = 0
    /// Server-reported total for the current search query across all item kinds.
    var searchResultsTotal: UInt32 = 0

    /// A follow-up albums page is in flight. Views check this to suppress
    /// duplicate near-end triggers and to show a bottom spinner.
    var isLoadingMoreAlbums: Bool = false
    /// A follow-up artists page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMoreArtists: Bool = false
    /// A follow-up tracks page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMoreTracks: Bool = false
    /// A follow-up playlists page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMorePlaylists: Bool = false
    /// A follow-up search page is in flight for the current query.
    var isLoadingMoreSearch: Bool = false

    /// First-paint size for library lists. Tuned smaller than subsequent
    /// pages so the grid renders quickly on login; raising this increases
    /// time-to-first-paint without measurable benefit.
    private let libraryInitialPageSize: UInt32 = 100
    /// Follow-up page size for library lists. Larger than the initial page
    /// to keep round-trip count down once the user has committed to scrolling.
    private let libraryPageSize: UInt32 = 200
    /// Initial page size for recently-played on the Home screen.
    private let recentlyPlayedInitialPageSize: UInt32 = 20
    /// Page size when walking `playlist_tracks` to completion.
    private let playlistPageSize: UInt32 = 200
    /// Hard cap on total tracks pulled from a single playlist to keep a
    /// pathological 50k-track playlist from holding the UI hostage. Callers
    /// that hit this see up to this many tracks; beyond that the rest is
    /// silently dropped. Easy to raise once a real use case complains.
    private let playlistSafetyCap: Int = 5000
    /// Page size for the "Show all results" affordance in search.
    private let searchPageSize: UInt32 = 50

    // MARK: - Player
    var status: PlayerStatus
    var pollTimer: Timer?
    /// Whether the menu-bar "while playing" visibility has been seeded since
    /// polling started. Lets the first poll apply the icon on a resume-into-
    /// playing launch instead of waiting for a pause/resume transition. See #266.
    var didApplyMenuBarPlayingState = false

    // MARK: - Scrobbling (#46)
    /// Decides when to fire a `playing_now` vs a durable `single` listen. Driven
    /// from the 1 Hz status poll; the actual POSTs go to the Rust core off the
    /// main actor. Pure value type — see `ScrobbleGate`.
    var scrobbleGate = ScrobbleGate()
    /// Mirrors `core.isScrobbleConfigured()` for the Preferences pane to read
    /// without a per-render FFI. Refreshed when the token changes and at launch.
    var scrobbleConnected: Bool = false

    // MARK: - Queue inspector (BATCH-07a, #79 / #80 / #282)
    //
    // Issue #282 — separate "Up Next" (user-added) from "Auto Queue" (what
    // will play after the user-added items run out). The core queue is a
    // flat list today (see `player::set_queue`), so the split lives only
    // in-app: `upNextAutoQueue` is derived from the core queue tail after
    // the current track, and `upNextUserAdded` is a client-side overlay
    // fed by `playNext(...)` / `addToQueue(...)` calls. When we gain a
    // proper core primitive (tracked as TODO(core-#282)), this shape stays
    // the same — only the `play(tracks:)` fan-out changes.

    /// User-added "Up Next" overlay — what the user explicitly queued via
    /// "Play Next" / "Add to Queue". Drained into actual playback as the
    /// engine advances past the current track. Reorderable and removable
    /// from the Queue Inspector (#80).
    var upNextUserAdded: [Queue] = []
    /// Auto-queue tail — the rest of the current playback source (album /
    /// playlist / radio) after the currently-playing track. Read-only in
    /// the inspector; double-click jumps to that track (#282). Derived
    /// from the core queue on every `play(tracks:)` for now.
    var upNextAutoQueue: [Queue] = []
    /// Human-readable label + id + kind for the source that populated
    /// `upNextAutoQueue`. Used by the inspector's "PLAYING FROM" header
    /// (#82 / BATCH-07b will expand this into a richer display). Nil when
    /// playback was started from an ad-hoc selection without a known
    /// source (e.g. a single track picked from "All Tracks").
    var currentContext: QueueContext?
    /// Show / hide the right-side queue inspector panel. Toggled by the
    /// Cmd+Opt+Q shortcut (#79) and the View ▸ "Show Queue" menu item.
    /// `toggleQueueInspector()` lives in the Queue-inspector section below.
    var isQueueInspectorOpen: Bool = false

    /// Mirror of `MainShell`'s `NavigationSplitView` column visibility, exposed
    /// so the View ▸ "Show Sidebar" menu item can render a checkmark that
    /// tracks the real rail state. `MainShell` is the source of truth — it owns
    /// the `@State columnVisibility` plus the width-driven auto-hide reducer —
    /// and writes this on every change (toolbar toggle, separator drag, restore).
    /// `true` whenever the sidebar column is showing (`.all` / `.doubleColumn`).
    var isSidebarVisible: Bool = true

    /// One-shot, monotonic request to flip the sidebar. The menu can't write
    /// `MainShell`'s private `columnVisibility` directly, and driving it through
    /// a plain `Bool` would fight the auto-hide reducer's own writes, so the
    /// menu bumps this counter and `MainShell` observes it and runs its
    /// existing `toggleSidebarManually()` (which records the manual override so
    /// width-driven auto-hide steps aside). Counter so a second request with the
    /// rail already in the requested state still produces an observable change.
    private(set) var sidebarToggleRequest: Int = 0

    /// Ask `MainShell` to toggle the sidebar. See `sidebarToggleRequest`.
    func requestSidebarToggle() {
        sidebarToggleRequest += 1
    }

    /// Tracks played earlier in *this app session*, most-recent first. The
    /// full-page Play Queue view (⌘U, #81) renders this above Now Playing as
    /// a "Recently in this session" block so the user can re-queue something
    /// they just heard. Distinct from `recentlyPlayed`, which is the server's
    /// cross-device listening history — this is purely in-memory and resets
    /// on sign-out. Capped at `sessionPlayHistoryLimit`; populated by the
    /// status-poll track-change hook in `startPolling`.
    var sessionPlayHistory: [Track] = []

    /// Hard cap on `sessionPlayHistory`. The acceptance criteria call for the
    /// last 50 played tracks; trimming on every append keeps the array (and
    /// the view that renders it) bounded regardless of session length.
    let sessionPlayHistoryLimit = 50

    /// Contributors on the currently-playing track, sourced from Jellyfin's
    /// `Item.People` field. Populated by `fetchCurrentTrackDetails()` on
    /// track changes and cleared when the track stops. See #279.
    var currentTrackPeople: [Person] = []
    /// The track id that `currentTrackPeople` was fetched for, so we can
    /// skip redundant network calls when the status poll fires with the
    /// same track still playing.
    var currentTrackPeopleForId: String?

    /// Parsed lyrics for the currently-playing track, if any. Populated by
    /// `fetchCurrentTrackLyrics()` on track changes and cleared when the
    /// track stops. `nil` while a fetch is pending or when no lyrics have
    /// been requested yet; empty array when the server answered but had no
    /// lyrics. The Lyrics tab of the Now Playing view uses the
    /// `nil` / empty distinction to render a loading state vs. a "No
    /// lyrics available" placeholder. See #91, #273, #287, #288.
    var currentLyrics: [LyricLine]?
    /// Track id that `currentLyrics` was fetched for, to skip redundant
    /// network calls while the same track keeps playing. Mirrors
    /// `currentTrackPeopleForId`.
    var currentLyricsForId: String?

    /// One-shot request to land the Now Playing view on a specific tab when
    /// it next appears. Set by `openLyrics()` (the inline lyrics snippet's
    /// "open full lyrics" tap) and consumed — then cleared — by
    /// `NowPlayingView.onAppear`. `nil` means "use the default tab". Kept as
    /// a raw string rather than the view-local `Tab` enum so AppModel doesn't
    /// take a dependency on a screen type. See #91.
    var requestedNowPlayingTab: String?

    /// In-flight debounced VoiceOver track-change announcement (#342).
    /// Stored so a rapid next / next / next collapses to a single
    /// announcement: each call cancels the previous pending task before the
    /// 300ms window elapses, so only the final track is spoken (the
    /// cancel-previous debounce idiom).
    var trackAnnounceTask: Task<Void, Never>?

    // MARK: - Loading / errors
    var isLoggingIn = false
    var isLoadingLibrary = false
    var errorMessage: String?

    /// Set during the one-shot `attemptRestoreSession` pass at launch. `RootView`
    /// renders a minimal loading state while this is true so we don't briefly
    /// flash `LoginView` on cold start even though a valid session is about to
    /// be rehydrated from the keychain.
    ///
    /// Starts `true` so the very first render (which happens before
    /// `RootView.task` fires) shows the loading splash rather than a
    /// one-frame flash of `LoginView`. `attemptRestoreSession` flips this to
    /// `false` once the restore pass is done — either a session was
    /// rehydrated or there was nothing to restore.
    var isRestoringSession = true

    /// Set when a core call fails because the server rejected our token
    /// (HTTP 401) or the core reports no-longer-authenticated. Drives the
    /// modal prompt in `MainShell`. Reset after the user dismisses the sheet
    /// or signs back in. Auto-reauth (reissuing credentials silently) is
    /// tracked separately in #440 — this flag only powers the prompt.
    var authExpired: Bool = false

    /// Toggled `true` for a brief window when a track fails to stream, so the
    /// `PlayerBar` can flash a 10% danger tint as a peripheral-vision cue.
    /// `StreamErrorToast` is the foreground surface; this flag is the
    /// subtle accompanying signal (see issue #302).
    ///
    /// The toast + flash pair is published here so the reliability wiring
    /// (`BATCH-21`) can flip it without reaching into view code. `PlayerBar`
    /// observes the flag via the usual `@Environment(AppModel.self)` channel;
    /// callers that raise an error should flip this on, then flip it off
    /// after ~2s (the flash duration). No animation is driven from here — the
    /// consumer owns the tween.
    var streamErrorFlash: Bool = false

    /// Playlist the user asked to delete from a context menu. Observed by
    /// `MainShell` to present a `.confirmationDialog`; cleared when the
    /// user confirms or dismisses. Single-shot rather than a list because
    /// the dialog is modal — only one can be pending at a time. See #131.
    var playlistPendingDelete: Playlist?

    // MARK: - Sidebar playlist edit (BATCH-06b, #71 / #75)
    //
    // The sidebar surfaces a compact "Playlists" section with inline edit
    // affordances: ⌘N creates a new playlist row in edit mode, and the
    // right-click context menu's Rename action flips an existing row into
    // the same edit mode. Both paths funnel through a single pair of state
    // variables so only one row can be in edit mode at a time.
    //
    // `sidebarEditingPlaylistId` is `nil` when no row is in edit mode; the
    // sentinel value `sidebarNewPlaylistSentinel` (below) means "a new
    // playlist placeholder, no id yet"; any other string is the id of the
    // existing playlist being renamed. `sidebarEditingDraft` mirrors the
    // TextField contents so the Sidebar can bind to the observable model
    // without managing its own @State copy.

    /// Sentinel used for the in-progress "new playlist" placeholder row
    /// before the user commits a name. Picked to never collide with a real
    /// Jellyfin item id (which are 32-char hex GUIDs).
    static let sidebarNewPlaylistSentinel = "__lyrebird_new_playlist__"

    /// Id of the playlist currently in inline edit mode in the sidebar.
    /// `nil` when no row is being edited; `sidebarNewPlaylistSentinel` when
    /// a brand-new placeholder row is showing a TextField; otherwise the
    /// id of the existing playlist being renamed.
    var sidebarEditingPlaylistId: String?

    /// Draft text for the sidebar's inline TextField. Shared between the
    /// Cmd+N "new playlist" row and the Rename affordance so only one edit
    /// can be active at a time.
    var sidebarEditingDraft: String = ""

    /// Playlist ids that have a duplicate-in-progress server round trip in
    /// flight. The sidebar row shows a small spinner while its id is in
    /// this set. Cleared on success or error. See `duplicatePlaylist`.
    var sidebarCopyingPlaylistIds: Set<String> = []

    // MARK: - Mini Player (⌘⌥P)

    /// UserDefaults key for the persisted always-on-top preference. AppModel is
    /// `@Observable` rather than a SwiftUI `View`, so it can't use `@AppStorage`
    /// directly — we mirror the value into `miniPlayerAlwaysOnTop` and write
    /// through on each change, the same JSON/UserDefaults bridge idiom the
    /// pinned-stations store uses.
    private static let miniPlayerAlwaysOnTopKey = "miniPlayer.alwaysOnTop"

    /// Whether the detached Mini Player window is currently open.
    /// `LyrebirdApp` observes this and drives `openWindow` / `dismissWindow`
    /// for the `mini-player` scene. The ⌘⌥P menu `Toggle` writes this flag
    /// directly (and AppKit draws its checkmark from it), and `RootView`'s
    /// `willCloseNotification` observer clears it when the window is closed by
    /// ⌘W / Window > Close so the menu state can't drift out of sync. The
    /// window is borderless chrome owned by `MiniPlayerView`; this flag is the
    /// single source of truth for its presence so the command's checkmark and
    /// the open window never diverge.
    var isMiniPlayerVisible: Bool = false

    /// Whether the Mini Player floats above other windows. Persisted across
    /// launches and surfaced as a toggle in the mini player's settings menu,
    /// matching Apple Music's MiniPlayer "Always on Top". Initialised from
    /// `UserDefaults`; write through `setMiniPlayerAlwaysOnTop(_:)` so the
    /// stored value and the live window level stay consistent.
    var miniPlayerAlwaysOnTop: Bool = UserDefaults.standard.bool(forKey: AppModel.miniPlayerAlwaysOnTopKey)

    /// Toggle the Mini Player window. Wired to the ⌘⌥P menu command; flipping
    /// the flag is enough — `LyrebirdApp` translates the change into the
    /// matching `openWindow` / `dismissWindow` call for the `mini-player`
    /// scene.
    func toggleMiniPlayer() {
        isMiniPlayerVisible.toggle()
    }

    /// Set + persist the always-on-top preference. `MiniPlayerWindowConfigurator`
    /// reads `miniPlayerAlwaysOnTop` and re-applies the window level on change.
    func setMiniPlayerAlwaysOnTop(_ on: Bool) {
        miniPlayerAlwaysOnTop = on
        UserDefaults.standard.set(on, forKey: AppModel.miniPlayerAlwaysOnTopKey)
    }

    // MARK: - Autoplay (queue end)

    /// UserDefaults key for the persisted "autoplay similar music when the
    /// queue ends" preference. Same `@Observable` → UserDefaults bridge as
    /// the mini-player flag above.
    private static let autoplayWhenQueueEndsKey = "queue.autoplayWhenQueueEnds"

    /// Whether playback should extend with an Instant Mix of similar music
    /// when the user-added queue and its source tail run dry. Default **on**
    /// to match Apple Music / Spotify's endless-listening behaviour; users
    /// who dislike endless autoplay flip it off in the queue header and
    /// playback simply stops at the end of what they queued. Persisted across
    /// launches; read through `autoplayWhenQueueEndsDefault` so an unset key
    /// resolves to `true` rather than `bool(forKey:)`'s `false`.
    var autoplayWhenQueueEnds: Bool = AppModel.autoplayWhenQueueEndsDefault()

    /// Resolve the persisted autoplay flag, defaulting to `true` when the key
    /// has never been written. `UserDefaults.bool(forKey:)` returns `false`
    /// for a missing key, which would silently invert this feature's "default
    /// on" contract, so we probe for the object first.
    private static func autoplayWhenQueueEndsDefault() -> Bool {
        guard UserDefaults.standard.object(forKey: autoplayWhenQueueEndsKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoplayWhenQueueEndsKey)
    }

    /// Set + persist the autoplay-at-queue-end preference. Wired to the queue
    /// header toggle; `handleTrackEnded` reads `autoplayWhenQueueEnds` when
    /// the queue runs dry to decide whether to extend with an Instant Mix or
    /// stop.
    func setAutoplayWhenQueueEnds(_ on: Bool) {
        autoplayWhenQueueEnds = on
        UserDefaults.standard.set(on, forKey: AppModel.autoplayWhenQueueEndsKey)
    }

    /// Close the Mini Player and bring the full window forward, honouring the
    /// "closing returns to full window" contract. Used by the mini player's
    /// settings-menu and hover "return" affordances. Clearing the flag lets
    /// `LyrebirdApp` dismiss the scene; activating the app raises the main
    /// `WindowGroup` window back to the foreground.
    func returnToFullWindow() {
        isMiniPlayerVisible = false
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Drill the **main** window to a detail `Route` from the detached Mini
    /// Player, raising the full window first so the navigation is visible.
    ///
    /// The Mini Player floats in its own borderless window (optionally
    /// always-on-top), so a bare `navigate(to:)` would push onto the main
    /// window's `NavigationStack` while that window stays buried behind
    /// everything else — the user would tap album art and see nothing move.
    /// Activating the app raises the main `WindowGroup` window back to the
    /// foreground the same way `returnToFullWindow` does, *then* we drill.
    /// Unlike `returnToFullWindow` this intentionally leaves
    /// `isMiniPlayerVisible` untouched: clicking through to a detail page is
    /// not a request to dismiss the mini player, so an always-on-top widget
    /// keeps floating over the now-foregrounded detail view (the Apple Music /
    /// Spotify mini-widget contract).
    ///
    /// Routing through one seam (rather than letting `MiniPlayerView` poke
    /// `navPath` + `NSApp` itself) keeps the activate-then-navigate ordering in
    /// a single testable place and matches `openLyrics` / `navigate(to:)`.
    func openInMainWindowFromMiniPlayer(_ route: Route) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        navigate(to: route)
    }

    // MARK: - Command Palette (⌘K)

    /// Whether the command-palette overlay is currently visible. Toggled by
    /// the ⌘K menu command and by the palette itself on Esc / row commit.
    /// Driven out of `AppModel` rather than `MainShell` so the overlay can
    /// sit above every screen (Home, Library, Now Playing, and the auth
    /// sheet's host) from one place, and so the menu command doesn't need a
    /// SwiftUI `@Environment(AppModel.self)` round-trip. See #305 / #306 /
    /// #307 / #309.
    var isCommandPaletteOpen: Bool = false

    /// Whether the Instant Mix seed-picker sheet is presented. Flipped by
    /// the "New Instant Mix…" menu command (`presentInstantMixPicker`) and
    /// cleared when the sheet dismisses or a mix is generated. Mounted on
    /// `MainShell` so the picker floats over whichever screen is active.
    /// The engine behind it (`playInstantMix` / `startGenreRadio`) was
    /// already wired; this flag only drives the seed-picker UI. See #327.
    var isShowingInstantMixPicker: Bool = false

    /// Display name of the most recently generated Instant Mix seed (e.g.
    /// "Radiohead", "OK Computer", "Jazz"). Surfaced as the sheet's
    /// "Last mix" hint so a re-open offers a one-tap regenerate without
    /// re-searching. `nil` until the first mix is generated this session.
    /// See #327.
    var instantMixSeedLabel: String?

    /// Whether the first-run feature tour (coach marks) overlay is presented.
    /// `MainShell` also auto-shows the tour on first launch via its own
    /// `@AppStorage` flag; this flag is the *explicit re-open* channel for the
    /// Help ▸ "Show Tour" command, so a returning user can replay it without
    /// resetting the persisted seen flag. Driven out of `AppModel` (like
    /// `isCommandPaletteOpen`) so the menu command doesn't need a SwiftUI
    /// environment round-trip. See #113 and `FeatureTour` / `FeatureTourOverlay`.
    var isFeatureTourPresented: Bool = false

    // MARK: - Command Palette recents + pinned (#308)
    //
    // The empty-query palette shows Pinned actions first, then the most
    // recently run actions, then the remaining static roster. Both lists are
    // persisted as JSON `[String]` (action ids) in `UserDefaults` — the same
    // `@Observable` → UserDefaults bridge the mini-player flag (above) and the
    // recent-searches list use, since `@Observable` can't reach `@AppStorage`
    // directly. Storing ids (not the `PaletteAction` structs) keeps the store
    // decoupled from the live roster: an id that no longer resolves (e.g. a
    // capability-gated action whose flag is now off) is simply skipped when
    // the palette rebuilds its rows, and the persisted entry is harmless.

    /// UserDefaults key for the JSON-encoded recent-action-id list.
    static let paletteRecentActionIdsKey = "palette.recentActionIds"

    /// UserDefaults key for the JSON-encoded pinned-action-id list.
    static let palettePinnedActionIdsKey = "palette.pinnedActionIds"

    /// How many recently-run actions to retain. Five keeps the empty-query
    /// "Recent" group short enough to scan at a glance without pushing the
    /// full roster below the fold of the 360pt results scroll.
    static let paletteRecentActionsCap = 5

    /// Most-recently-run palette action ids, newest first. Mirrored into
    /// `UserDefaults` through `recordPaletteActionUsage(id:)`; initialised
    /// from the persisted JSON so recents survive relaunch.
    var paletteRecentActionIds: [String] =
        AppModel.decodePaletteActionIds(
            UserDefaults.standard.string(forKey: AppModel.paletteRecentActionIdsKey) ?? "[]"
        )

    /// Pinned palette action ids, in user-pin order (newest pin first).
    /// Mirrored into `UserDefaults` through `pinPaletteAction` /
    /// `unpinPaletteAction`; initialised from the persisted JSON.
    var palettePinnedActionIds: [String] =
        AppModel.decodePaletteActionIds(
            UserDefaults.standard.string(forKey: AppModel.palettePinnedActionIdsKey) ?? "[]"
        )

    init() throws {
        let core = try LyrebirdCore(
            config: CoreConfig(dataDir: "", deviceName: "Lyrebird macOS")
        )
        self.core = core
        self.audio = AudioEngine(core: core)
        self.mediaSession = MediaSession()
        self.network = NetworkMonitor()
        self.serverReachability = ServerReachability()
        self.status = core.status()
        self.audio.onTrackEnded = { [weak self] in
            self?.handleTrackEnded()
        }
        // Hand the engine and the media session the things they need
        // from us *after* all stored properties are initialized. The
        // MediaSession is the single writer of MPNowPlayingInfoCenter;
        // the engine pushes state transitions to it.
        self.mediaSession.attach(delegate: self)
        self.audio.mediaSession = self.mediaSession
        self.audio.delegate = self
        // Seed the engine with the persisted output-device selection
        // so the first track honours it without waiting for the Preferences
        // pane to mount. An empty/absent value means "follow system default".
        let savedDeviceUID = UserDefaults.standard.string(forKey: AudioOutputDevices.preferenceKey) ?? ""
        self.audio.outputDeviceUID = savedDeviceUID.isEmpty ? nil : savedDeviceUID
        // Seed the engine with the persisted ReplayGain / pre-gain selection so
        // the first track is normalized without waiting for the Preferences
        // pane to mount (#42). `.off` (the default) leaves the level untouched.
        self.audio.normalizationMode = AppModel.normalizationMode(forStoredValue: UserDefaults.standard.string(forKey: AppModel.normalizationKey))
        self.audio.normalizationPreGainDb = UserDefaults.standard.double(forKey: AppModel.preGainKey)
        // Seed the scrobble-connected flag from the core's persisted token so
        // the Preferences pane shows the right state on first open.
        self.scrobbleConnected = core.isScrobbleConfigured()
        // Offline playback (#819): only let the engine prefer a local copy when
        // the downloads feature is live. With `supportsDownloads == false` this
        // stays false, so `AudioEngine.play` never queries the core for a local
        // path and the streaming path is byte-for-byte unchanged.
        self.audio.offlinePlaybackEnabled = supportsDownloads
    }

    // MARK: - Network

    /// Re-evaluates network reachability and, if a session exists, kicks off a
    /// library refetch. Wired to the offline banner's `Retry` button.
    func retryNetwork() {
        network.retry()
        guard session != nil else { return }
        Task { await refreshLibrary() }
    }

    /// Clears the server-reachability failure counter and retries the library
    /// fetch. Wired to the server-unreachable banner's `Retry` button.
    /// Resetting up-front means the banner disappears while the user waits;
    /// if the refetch fails again, the error flow in `refreshLibrary` will
    /// re-accumulate failures and the banner will come back.
    func retryServer() {
        serverReachability.reset()
        guard session != nil else { return }
        Task { await refreshLibrary() }
    }

    // MARK: - Session

    func login(url: String, username: String, password: String) async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let session = try await Task.detached(priority: .userInitiated) { [core] in
                try core.login(url: url, username: username, password: password)
            }.value
            self.session = session
            self.serverURL = url
            self.username = username
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
            await refreshDownloads()
        } catch {
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .login)
        }
    }

    /// Rehydrate the previous session from on-disk settings + the keychain
    /// token. Called once from `RootView.task` on cold start. No-ops when the
    /// core has nothing to restore (first launch, post-logout, etc.); in that
    /// case `RootView` falls through to `LoginView`.
    ///
    /// Silent on errors: the core's `resume_session` is best-effort, so if the
    /// local state is inconsistent we log and let the user sign in again
    /// rather than blocking the app. Library fetches against the restored
    /// session go through the regular `handleAuthError` flow, so a 401 on the
    /// first call surfaces the auth-expired sheet just like a mid-session
    /// expiry. Silent reauth is the rest of #440.
    func attemptRestoreSession() async {
        // Run at most once per AppModel lifetime. `hasAttemptedRestore`
        // flips the first time this runs so re-renders of `RootView` that
        // re-fire `.task` don't repeat the restore pass.
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        guard session == nil else {
            isRestoringSession = false
            return
        }
        defer { isRestoringSession = false }
        do {
            let restored = try await Task.detached(priority: .userInitiated) { [core] in
                try core.resumeSession()
            }.value
            guard let session = restored else { return }
            self.session = session
            self.serverURL = session.server.url
            self.username = session.user.name
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
            await refreshDownloads()
        } catch {
            // Best-effort: leave `session == nil` so RootView renders LoginView.
            // No banner — the user sees the login form, which is already the
            // recovery path, and the library refetch after a manual sign-in
            // will noisily surface any persistent server problem.
            Log.auth.error("attemptRestoreSession failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Internal guard for `attemptRestoreSession` — the restore pass should
    /// run exactly once per app lifetime. Separate from `isRestoringSession`
    /// so the UI flag can be flipped without gating re-entry, and vice-versa.
    private var hasAttemptedRestore = false

    func logout() {
        audio.stop()
        // core.logout() does a blocking POST /Sessions/Logout; fire it off
        // the main actor so the UI clears immediately and the user isn't
        // staring at a stalled window for the network round-trip.
        Task.detached(priority: .userInitiated) { [core] in
            try? core.logout()
        }
        session = nil
        imageURLCache.removeAll()
        albums = []
        artists = []
        tracks = []
        playlists = []
        playlistLibraryId = nil
        albumTracks = [:]
        playlistTracks = [:]
        currentPlaylistTracks = []
        pendingPlaylistRemoval = nil
        playlistDescriptions = [:]
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
        sidebarCopyingPlaylistIds = []
        playlistPendingDelete = nil
        artistTopTracks = [:]
        artistSimilarCache = [:]
        artistPlaylistsCache = [:]
        artistAlbumsCache = [:]
        artistDetailCache = [:]
        resolvedNameCache = [:]
        ambientPaletteCache.removeAll()
        ambientPaletteTasks.values.forEach { $0.cancel() }
        ambientPaletteTasks.removeAll()
        recentlyPlayed = []
        forYou = []
        genresToExplore = []
        browseGenres = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        favoriteArtists = []
        recentlyDiscoveredArtists = []
        rediscover = []
        suggestions = []
        searchResults = nil
        searchQuery = ""

        searchPageResults = [:]
        searchPageQuery = ""
        searchPageActiveQuery = ""
        activeSearchScope = .all
        searchPageTotal = 0
        searchPageLoaded = 0
        searchPageExhausted = false
        isLoadingFullSearch = false

        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
        sessionPlayHistory = []
        // Clear the in-memory download snapshot. On-disk files are intentionally
        // NOT removed — they're keyed by track id and rehydrate via
        // `refreshDownloads()` on the next sign-in. See #819.
        downloadStateById = [:]
        downloads = []
        downloadStats = nil
        downloadsInFlight = []
        resetPaginationState()
        stopPolling()
    }

    /// Drop the stored access token (keychain + in-memory session) without
    /// clearing the remembered server URL / username, so the user can re-auth
    /// against the same server by re-entering only their password. Called
    /// when the user taps "Sign in" on the auth-expired sheet. Note: the
    /// caller still owns toggling `authExpired` off and nilling `session`.
    ///
    /// Unlike `logout`, this goes through the core's `forget_token` which
    /// keeps `last_server_url` / `last_username` on disk for the login-form
    /// prefill and only drops the credential store token plus the id settings
    /// that key into it. So a subsequent `attemptRestoreSession` on next launch
    /// short-circuits to `None` (safe), and the form is pre-populated.
    func forgetToken() {
        audio.stop()
        try? core.forgetToken()
        albums = []
        artists = []
        tracks = []
        playlists = []
        playlistLibraryId = nil
        albumTracks = [:]
        playlistTracks = [:]
        currentPlaylistTracks = []
        pendingPlaylistRemoval = nil
        playlistDescriptions = [:]
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
        sidebarCopyingPlaylistIds = []
        playlistPendingDelete = nil
        artistTopTracks = [:]
        artistSimilarCache = [:]
        artistPlaylistsCache = [:]
        artistAlbumsCache = [:]
        artistDetailCache = [:]
        resolvedNameCache = [:]
        ambientPaletteCache.removeAll()
        ambientPaletteTasks.values.forEach { $0.cancel() }
        ambientPaletteTasks.removeAll()
        recentlyPlayed = []
        forYou = []
        genresToExplore = []
        browseGenres = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        favoriteArtists = []
        recentlyDiscoveredArtists = []
        rediscover = []
        suggestions = []
        searchResults = nil
        searchQuery = ""

        searchPageResults = [:]
        searchPageQuery = ""
        searchPageActiveQuery = ""
        activeSearchScope = .all
        searchPageTotal = 0
        searchPageLoaded = 0
        searchPageExhausted = false
        isLoadingFullSearch = false

        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
        sessionPlayHistory = []
        resetPaginationState()
        stopPolling()
    }

    /// Clear all pagination counters and in-flight flags. Kept in one place
    /// so the two clear-the-session entry points (`logout`, `forgetToken`)
    /// stay in sync.
    private func resetPaginationState() {
        albumsTotal = 0
        artistsTotal = 0
        tracksTotal = 0
        playlistsTotal = 0
        recentlyPlayedTotal = 0
        searchResultsTotal = 0
        isLoadingMoreAlbums = false
        isLoadingMoreArtists = false
        isLoadingMoreTracks = false
        isLoadingMorePlaylists = false
        isLoadingMoreSearch = false
    }

    /// Flag the session as expired. The UI surfaces this via the auth-expired
    /// modal in `MainShell`. Idempotent — second hits within a session are
    /// no-ops while the prompt is still visible.
    func markAuthExpired() {
        guard !authExpired else { return }
        audio.stop()
        stopPolling()
        authExpired = true
    }

    /// Inspect an error from a core call and, if it's the core's
    /// `NotAuthenticated` / `Auth` variant (both meaning the token's dead
    /// or never existed), mark the session expired and return `true` so the
    /// caller knows to skip its generic error surfacing.
    ///
    /// Post-BATCH-24 the Rust `LyrebirdError` is a typed enum split by HTTP
    /// class — 401 responses surface as `Auth`, the retry-layer fallback is
    /// `AuthExpired`, and a missing token is `NotAuthenticated` — so we can
    /// match variants directly instead of parsing the Display message.
    ///
    /// Call-sites that do NOT match auth go on to call
    /// `LyrebirdErrorPresenter.message(for:context:)` (see #351) to turn the
    /// raw Display string into localized banner copy.
    ///
    /// `internal` (not `private`) so AppModel extension files in other source
    /// files (e.g. `AppModel+Downloads.swift`) can route their FFI failures
    /// through the same auth-expiry interception.
    func handleAuthError(_ error: Error) -> Bool {
        guard let err = error as? LyrebirdError else { return false }
        switch err {
        case .NotAuthenticated, .Auth, .AuthExpired:
            markAuthExpired()
            return true
        default:
            return false
        }
    }

    // MARK: - Library

    func refreshLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        // Fetch albums, artists, tracks, and playlists in parallel. Previously
        // the album/artist calls were sequential, doubling time-to-first-paint
        // on every fresh session; `async let` lets all round-trips overlap.
        // Playlists are wired in alongside so switching to the Playlists chip
        // doesn't trigger a first-paint spinner. The smaller
        // `libraryInitialPageSize` (100 vs. the old 200) is a further
        // first-paint win — the grid fills the viewport with 100 and the
        // per-tab `loadMore*` paths take over when the user scrolls.
        //
        // Playlists go through their own try/catch because the library id
        // resolution can fail independently (no playlist library on the
        // server, or an error from a hypothetical future `core.libraries()`)
        // and we don't want that to sink the albums/artists/tracks fetch.
        async let albumsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listAlbums(offset: 0, limit: libraryInitialPageSize)
        }.value
        async let artistsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listArtists(offset: 0, limit: libraryInitialPageSize)
        }.value
        async let tracksPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listTracks(musicLibraryId: nil, offset: 0, limit: libraryInitialPageSize)
        }.value
        async let playlistsResult: Void = refreshPlaylists()
        // Each loader gets its own try/catch so one failure (typically a
        // transient 5xx on a single endpoint) doesn't drop the other two.
        // Before, the tuple-destructure `try await (a, b, c)` cancelled the
        // assignments for all three on any single error — Library rendered
        // empty even when two of the three endpoints succeeded.
        var anySucceeded = false
        do {
            let albums = try await albumsPage
            self.albums = albums.items
            self.albumsTotal = albums.totalCount
            anySucceeded = true
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
        do {
            let artists = try await artistsPage
            self.artists = artists.items
            self.artistsTotal = artists.totalCount
            anySucceeded = true
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
        do {
            let tracks = try await tracksPage
            self.tracks = tracks.items
            self.tracksTotal = tracks.totalCount
            anySucceeded = true
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
        if anySucceeded {
            serverReachability.noteSuccess()
        }
        _ = await playlistsResult
        await refreshRecentlyPlayed()
        await refreshForYou()
        await refreshGenresToExplore()
        await refreshBrowseGenres()
        // Home screen carousels (#49 / #51–#55). Kicked off after the main
        // library so first paint isn't blocked on these secondary shelves.
        // Each of these is best-effort — empty or errored rows just hide in
        // the Home layout.
        await refreshJumpBackIn()
        await refreshRecentlyAdded()
        await refreshQuickPicks()
        await refreshFavoriteAlbums()
        await refreshFavoriteArtists()
        await refreshRecentlyDiscoveredArtists()
        await refreshRediscover()
        await refreshSuggestions()
    }

    /// Fetch the next page of albums and append to `albums`. No-op when a
    /// page is already in flight or when the local count has caught up to
    /// `albumsTotal`. Called from `LibraryView`'s near-end `.onAppear`
    /// trigger — see `LibraryView.swift`.
    func loadMoreAlbums() async {
        guard !isLoadingMoreAlbums else { return }
        guard albumsTotal == 0 || albums.count < Int(albumsTotal) else { return }
        isLoadingMoreAlbums = true
        defer { isLoadingMoreAlbums = false }
        let offset = UInt32(albums.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listAlbums(offset: offset, limit: libraryPageSize)
            }.value
            self.albums.append(contentsOf: page.items)
            self.albumsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Fetch the next page of artists and append to `artists`. Mirror of
    /// `loadMoreAlbums` — see its docs for the trigger contract.
    func loadMoreArtists() async {
        guard !isLoadingMoreArtists else { return }
        guard artistsTotal == 0 || artists.count < Int(artistsTotal) else { return }
        isLoadingMoreArtists = true
        defer { isLoadingMoreArtists = false }
        let offset = UInt32(artists.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listArtists(offset: offset, limit: libraryPageSize)
            }.value
            self.artists.append(contentsOf: page.items)
            self.artistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Refetch the first page of library tracks for the All Tracks tab.
    /// Called from `refreshLibrary` (inline as an `async let`) on session
    /// establishment, and available for an explicit retry path later.
    /// Matches `refreshRecentlyPlayed` in shape — stores items + total.
    func refreshTracks() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.listTracks(musicLibraryId: nil, offset: 0, limit: libraryInitialPageSize)
            }.value
            self.tracks = page.items
            self.tracksTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Fetch the next page of tracks and append to `tracks`. Mirror of
    /// `loadMoreAlbums` — see its docs for the trigger contract.
    func loadMoreTracks() async {
        guard !isLoadingMoreTracks else { return }
        guard tracksTotal == 0 || tracks.count < Int(tracksTotal) else { return }
        isLoadingMoreTracks = true
        defer { isLoadingMoreTracks = false }
        let offset = UInt32(tracks.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listTracks(musicLibraryId: nil, offset: offset, limit: libraryPageSize)
            }.value
            self.tracks.append(contentsOf: page.items)
            self.tracksTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
        }
    }

    /// Resolve (and cache) the `ParentId` to scope playlist queries by.
    ///
    /// Calls `core.playlistLibraryId()` once, which hits
    /// `/Users/{id}/Views` and picks the CollectionFolder whose
    /// `CollectionType == "playlists"`. On failure we fall back to the
    /// empty string — Jellyfin's `/Items` endpoint treats an empty
    /// `ParentId` as "no filter", and the client-side `Path`-based filter
    /// in `user_playlists` / `public_playlists` still yields a correct set,
    /// just with more server-side work.
    private func ensurePlaylistLibraryId() async -> String {
        if let cached = playlistLibraryId { return cached }
        let resolved: String
        do {
            resolved = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistLibraryId()
            }.value
        } catch {
            Log.net.error("ensurePlaylistLibraryId: core.playlistLibraryId() failed (\(error.localizedDescription, privacy: .public)); falling back to empty ParentId.")
            resolved = ""
        }
        playlistLibraryId = resolved
        return resolved
    }

    /// Fetch the first page of user-owned playlists for the Library screen's
    /// Playlists chip. Wired into `refreshLibrary` so the chip is populated
    /// before the user clicks it. Parallels `loadMoreAlbums` for the error
    /// / auth / reachability story.
    ///
    /// Uses `user_playlists` (user-owned) rather than `public_playlists`. The
    /// Playlists tab spec (#212) describes "your playlists"; a separate
    /// "Community" affordance for public playlists is a future concern.
    func refreshPlaylists() async {
        let libraryId = await ensurePlaylistLibraryId()
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.userPlaylists(
                    playlistLibraryId: libraryId,
                    offset: 0,
                    limit: libraryInitialPageSize
                )
            }.value
            self.playlists = page.items
            self.playlistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            // Silent-ish: don't clobber the albums/artists error banner if
            // both fail in the same refresh. The Playlists tab empty state
            // already explains "nothing to see here" when `playlists` is
            // empty.
            Log.net.error("refreshPlaylists failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetch the next page of playlists and append to `playlists`. Mirror
    /// of `loadMoreAlbums` — see its docs for the trigger contract.
    ///
    /// Server-side total caveat: `user_playlists` filters results client-
    /// side by `Path`, so `playlistsTotal` is an upper bound on the raw
    /// server count, not on `playlists.count`. The `<` guard below uses the
    /// raw total deliberately — stopping at `playlists.count >= total` is
    /// safe even when the two drift, because the server itself won't return
    /// more items past its total and we'd bail on an empty page anyway.
    func loadMorePlaylists() async {
        guard !isLoadingMorePlaylists else { return }
        guard playlistsTotal == 0 || playlists.count < Int(playlistsTotal) else { return }
        isLoadingMorePlaylists = true
        defer { isLoadingMorePlaylists = false }
        let libraryId = await ensurePlaylistLibraryId()
        let offset = UInt32(playlists.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.userPlaylists(
                    playlistLibraryId: libraryId,
                    offset: offset,
                    limit: libraryPageSize
                )
            }.value
            self.playlists.append(contentsOf: page.items)
            self.playlistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistsLoad)
        }
    }

    /// Fetch the user's recently played tracks for the Home screen carousel
    /// (#206). Passes `nil` for the music library id so the core returns
    /// tracks across all music libraries the user can see. Failures are
    /// swallowed silently — an empty carousel is preferable to an error
    /// banner for a best-effort Home widget.
    ///
    /// Stores `totalCount` alongside the page so a future "See all" view can
    /// expand the carousel without issuing another count query.
    func refreshRecentlyPlayed() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, recentlyPlayedInitialPageSize] in
                try core.recentlyPlayed(
                    musicLibraryId: nil,
                    offset: 0,
                    limit: recentlyPlayedInitialPageSize
                )
            }.value
            self.recentlyPlayed = page.items
            self.recentlyPlayedTotal = page.totalCount
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            _ = handleAuthError(error)
        }
    }

    /// Load ALL tracks on a playlist by paging through `playlist_tracks` in
    /// chunks of `playlistPageSize` until `totalCount` is reached or the
    /// `playlistSafetyCap` is hit. Returns as soon as any page fails. No UI
    /// wiring calls this yet (playlist detail screen is #313 et al), but the
    /// FFI is now paginated so the caller that lands it can rely on "pass
    /// this a playlist id and get every track". See #125 / #429.
    func loadAllPlaylistTracks(playlistID: String) async -> [Track] {
        var all: [Track] = []
        var offset: UInt32 = 0
        let limit = playlistPageSize
        let cap = playlistSafetyCap
        do {
            while all.count < cap {
                let page = try await Task.detached(priority: .userInitiated) { [core] in
                    try core.playlistTracks(
                        playlistId: playlistID,
                        offset: offset,
                        limit: limit
                    )
                }.value
                all.append(contentsOf: page.items)
                if page.items.isEmpty { break }
                if all.count >= Int(page.totalCount) { break }
                offset = UInt32(all.count)
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return all }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistLoad)
        }
        return all
    }

    /// Refresh the Discover "For You" carousel (#249). Until the core exposes
    /// a real recommendations endpoint (e.g. Jellyfin Items/Suggestions or a
    /// client-side "artists similar to top-3 played, minus already-played"
    /// algorithm per research/06-screen-specs.md), this is a best-effort
    /// stub that mirrors the first 20 recently played tracks so the shelf is
    /// never empty for an active listener. If `recentlyPlayed` is empty the
    /// carousel hides itself rather than showing nothing-of-interest.
    ///
    /// TODO: replace this stub with a real `core.recommendations(limit: 20)`
    /// FFI call once it lands. At that point the view layer stays unchanged —
    /// only the body of this method needs swapping.
    func refreshForYou() async {
        // Best-effort fallback: reuse the recently played tracks we already
        // fetched. Capped at 20 so the carousel stays tight even if the core
        // later starts returning a longer list.
        self.forYou = Array(recentlyPlayed.prefix(20))
    }

    /// Refresh the Discover "Genres to Explore" grid (#250).
    ///
    /// Pulls one page of `/MusicGenres` (already filtered server-side to
    /// genres that carry Audio/Album/Artist items), keeps only those present
    /// in the library (`song_count > 0`), then ranks them so the *least*
    /// explored bubble to the top. Jellyfin's `/MusicGenres` projection
    /// carries no per-genre play count, so we approximate "least-played" with
    /// ascending `song_count` (the smallest real genres are the ones a user
    /// is least likely to have worked through), tie-broken by name for a
    /// stable order. Capped at 8 to fill the 4×2 grid.
    ///
    /// Runs the sync `core.genres` FFI off the MainActor (gap pattern #2) and
    /// marshals the ranked result back. Failures leave the prior grid intact
    /// rather than blanking the section mid-session.
    func refreshGenresToExplore() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                // limit: 500 matches `resolvedGenreId`'s fetch — /MusicGenres sorts
                // SortName ascending, so a smaller cap would silently drop
                // alphabetically-late genres from the ranking pool (the test
                // library has 254 genres).
                try core.genres(offset: 0, limit: 500)
            }.value
            // Project the FFI genres to plain tuples before ranking. Passing the
            // `core.Genre` struct directly would force a `LyrebirdCore.Genre`
            // annotation, which the generated `open class LyrebirdCore` shadows
            // (module-vs-type name collision — same reason `resolvedGenreId`
            // tuple-extracts). Tuples keep the ranking helper pure + testable.
            self.genresToExplore = AppModel.rankGenresToExplore(
                page.items.map { (id: $0.id, name: $0.name, songCount: $0.songCount) }
            )
        } catch {
            // Auth expiry must surface so the user is routed to re-login, matching
            // every other refresh path. Non-auth failures leave the prior grid
            // intact rather than blanking the section mid-session.
            _ = handleAuthError(error)
        }
    }

    /// Pure ranking for the "Genres to Explore" grid (#250), split out from
    /// the FFI hop so it's unit-testable without a live core. Keeps only
    /// genres present in the library (`song_count > 0`), ranks ascending by
    /// `song_count` (least-explored first) with a case-insensitive name
    /// tiebreaker for stable order, caps at 8 for the 4×2 grid, and carries
    /// the resolved Jellyfin UUID through into the local `Genre.id`.
    static func rankGenresToExplore(
        _ genres: [(id: String, name: String, songCount: UInt32)]
    ) -> [Genre] {
        Array(
            genres
                .filter { $0.songCount > 0 }
                .sorted {
                    if $0.songCount != $1.songCount { return $0.songCount < $1.songCount }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .prefix(8)
                .map { Genre(id: $0.id, name: $0.name) }
        )
    }

    /// Refresh the Search "Browse by Genre" tile grid (#247).
    ///
    /// Pulls one page of `/MusicGenres` (already filtered server-side to
    /// genres carrying Audio/Album/Artist items) and ranks them so the
    /// *biggest* genres lead — the dual of `refreshGenresToExplore`. Jellyfin's
    /// `/MusicGenres` projection carries `song_count` per genre, so we rank by
    /// descending count, tie-broken by name for a stable order, and cap at 12
    /// for the tile grid.
    ///
    /// Runs the sync `core.genres` FFI off the MainActor (gap pattern #2) and
    /// marshals the ranked result back. Failures leave the prior grid intact
    /// rather than blanking the section mid-session; auth expiry surfaces so
    /// the user is routed to re-login like every other refresh path.
    func refreshBrowseGenres() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                // limit: 500 matches `refreshGenresToExplore` / `resolvedGenreId`
                // — /MusicGenres sorts SortName ascending, so a smaller cap would
                // silently drop alphabetically-late genres from the ranking pool
                // (the test library has 254 genres).
                try core.genres(offset: 0, limit: 500)
            }.value
            // Project the FFI genres to plain tuples before ranking — passing the
            // `core.Genre` struct directly would force a `LyrebirdCore.Genre`
            // annotation, which the generated `open class LyrebirdCore` shadows
            // (module-vs-type name collision). Tuples keep the ranking helper
            // pure + testable.
            self.browseGenres = AppModel.rankBrowseGenres(
                page.items.map { (id: $0.id, name: $0.name, songCount: $0.songCount) }
            )
        } catch {
            _ = handleAuthError(error)
        }
    }

    /// Pure ranking for the "Browse by Genre" grid (#247), split out from the
    /// FFI hop so it's unit-testable without a live core. Keeps only genres
    /// present in the library (`song_count > 0`), ranks descending by
    /// `song_count` (biggest first) with a case-insensitive name tiebreaker for
    /// stable order, caps at 12 for the tile grid, and carries the resolved
    /// Jellyfin UUID through into the local `Genre.id`.
    static func rankBrowseGenres(
        _ genres: [(id: String, name: String, songCount: UInt32)]
    ) -> [Genre] {
        Array(
            genres
                .filter { $0.songCount > 0 }
                .sorted {
                    if $0.songCount != $1.songCount { return $0.songCount > $1.songCount }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .prefix(12)
                .map { Genre(id: $0.id, name: $0.name) }
        )
    }

    // MARK: - Items query helpers

    /// Shared helper: build a `GET /Items` request against the user's
    /// library with the given `sortBy` / `filters`, parse the response,
    /// and return a typed array of `Album`. Returns an empty array on
    /// any failure (auth, network, parse) so callers can stay
    /// conditionally-rendering shelves without an error-banner code path.
    ///
    /// TODO(core-#465): replace with a typed `core.items_query()` builder
    ///   once that FFI exists. This function's surface lines up
    ///   deliberately with the shape that builder will expose.
    func fetchAlbumsViaItemsQuery(
        sortBy: String,
        filters: String?,
        limit: UInt32,
        extraFields: [String],
        minDateLastSaved: String?
    ) async -> [Album] {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicAlbum",
            sortBy: sortBy,
            sortOrder: "Descending",
            filters: filters,
            limit: limit,
            extraFields: extraFields,
            minDateLastSaved: minDateLastSaved,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseAlbumsFromItems(data: data)
        } catch {
            Log.net.error("fetchAlbumsViaItemsQuery failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Like `fetchAlbumsViaItemsQuery` but also returns a map from album
    /// id to the server-reported `UserData.PlayCount` so "N plays" can
    /// render on the Quick Picks tile.
    func fetchAlbumsWithPlayCounts(
        sortBy: String,
        filters: String?,
        limit: UInt32,
        minDateLastSaved: String?
    ) async -> ([Album], [String: UInt32]) {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicAlbum",
            sortBy: sortBy,
            sortOrder: "Descending",
            filters: filters,
            limit: limit,
            extraFields: [],
            minDateLastSaved: minDateLastSaved,
            parentId: nil
        ) else { return ([], [:]) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return ([], [:])
            }
            return Self.parseAlbumsWithPlayCounts(data: data)
        } catch {
            Log.net.error("fetchAlbumsWithPlayCounts failed: \(error.localizedDescription, privacy: .public)")
            return ([], [:])
        }
    }

    /// Fetch Recently Added via `/Users/{id}/Items/Latest`. Returns both
    /// the album array and a per-album `DateCreated` map (used by the NEW
    /// badge on `RecentlyAddedTile`).
    func fetchLatestAlbumsWithDates(limit: UInt32) async -> ([Album], [String: Date]) {
        guard let session = session,
              let baseURL = URL(string: session.server.url),
              let authHeader = try? core.authHeader()
        else { return ([], [:]) }
        let userId = session.user.id
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userId)/Items/Latest"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "GroupItems", value: "true"),
            URLQueryItem(
                name: "Fields",
                value: "Genres,ProductionYear,DateCreated,ChildCount,PrimaryImageAspectRatio"
            ),
        ]
        guard let url = comps?.url else { return ([], [:]) }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return ([], [:])
            }
            // `/Items/Latest` returns a bare array, not the
            // `{Items, TotalRecordCount}` wrapper — parse accordingly.
            return Self.parseLatestAlbumsWithDates(data: data)
        } catch {
            Log.net.error("fetchLatestAlbumsWithDates failed: \(error.localizedDescription, privacy: .public)")
            return ([], [:])
        }
    }

    /// Fetch up to `limit` favorited audio tracks. Backs the
    /// "Shuffle All Favorites" CTA on the Home Favorites header (#55).
    func fetchFavoriteTracks(limit: UInt32) async -> [Track] {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "Random",
            sortOrder: "Ascending",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseTracksFromItems(data: data)
        } catch {
            Log.net.error("fetchFavoriteTracks failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Favorites surface (#760)
    //
    // Public load helpers backing the dedicated Favorites screen. Each
    // returns the user's favorited items in stable, name-sorted order
    // (Random order on the Home shuffle CTA is the exception above).

    /// Fetch up to `limit` favorited audio tracks, sorted by name.
    /// Backs the "Songs" section of the Favorites screen. Returns an
    /// empty array on auth/network/parse failure.
    @discardableResult
    func loadFavoriteTracks(limit: UInt32 = 500) async -> [Track] {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "SortName",
            sortOrder: "Ascending",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            let tracks = Self.parseTracksFromItems(data: data)
            // Seed favoriteById so track hearts are correct on first paint.
            for track in tracks { favoriteById[track.id] = true }
            return tracks
        } catch {
            Log.tracks.error("loadFavoriteTracks failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Fetch up to `limit` favorited albums, sorted by name. Backs the
    /// "Albums" section of the Favorites screen.
    func loadFavoriteAlbums(limit: UInt32 = 500) async -> [Album] {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "SortName",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil
        )
        // Seed favoriteById so album hearts are correct on first paint.
        for album in albums { favoriteById[album.id] = true }
        return albums
    }

    /// Fetch up to `limit` favorited artists, sorted by name. Backs the
    /// "Artists" section of the Favorites screen.
    func loadFavoriteArtists(limit: UInt32 = 500) async -> [Artist] {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicArtist",
            sortBy: "SortName",
            sortOrder: "Ascending",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            let artists = Self.parseArtistsFromItems(data: data)
            // Seed favoriteById so artist hearts are correct on first paint.
            for artist in artists { favoriteById[artist.id] = true }
            return artists
        } catch {
            Log.app.error("loadFavoriteArtists failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func loadTracks(forAlbum albumID: String) async -> [Track] {
        if let cached = albumTracks[albumID] {
            Log.albums.debug("loadTracks(forAlbum:) cache hit album=\(albumID, privacy: .public) count=\(cached.count, privacy: .public)")
            return cached
        }
        let start = Date()
        Log.albums.info("loadTracks(forAlbum:) start album=\(albumID, privacy: .public)")
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.albumTracks(albumId: albumID)
            }.value
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.albums.info("loadTracks(forAlbum:) ok album=\(albumID, privacy: .public) count=\(tracks.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
            albumTracks[albumID] = tracks
            // Seed favoriteById from the server-authoritative `userData`
            // projection so heart UIs on other surfaces (search, queue,
            // now-playing) reflect the same state without each one having
            // to call `isFavorite(track:)` and pay the snapshot fallback.
            // Bool-only seeding (no `.removeValue`) is intentional: a `nil`
            // server projection should NOT clobber a cache value the user
            // just toggled.
            for track in tracks {
                if let userFav = track.userData?.isFavorite {
                    favoriteById[track.id] = userFav
                }
            }
            serverReachability.noteSuccess()
            return tracks
        } catch {
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.albums.error("loadTracks(forAlbum:) failed album=\(albumID, privacy: .public) ms=\(Int(elapsed), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .albumTracks)
            return []
        }
    }

    /// Resolve an `Artist` record by id — cache-first, falling back to
    /// `core.artistDetail` for libraries larger than the loaded
    /// `artists` page. Returns nil on error or missing id.
    ///
    /// Album/song counts come back as `0` from the FFI fallback because
    /// `ArtistDetail` doesn't carry those stats — the detail hero's
    /// "N albums · M songs" strip silently hides the zero-count lines
    /// rather than lying.
    func resolveArtist(id: String) async -> Artist? {
        if let cached = artists.first(where: { $0.id == id }) {
            resolvedNameCache[id] = cached.name
            return cached
        }
        guard let detail = await artistDetail(artistId: id) else { return nil }
        resolvedNameCache[id] = detail.name
        return Artist(
            id: detail.id,
            name: detail.name,
            albumCount: 0,
            songCount: 0,
            genres: detail.genres,
            imageTag: detail.imageTag,
            userData: nil
        )
    }

    /// Fetch the extended `ArtistDetail` record (biography / external links /
    /// backdrops) and memoize it per id for the session. Runs the synchronous
    /// FFI off the MainActor via `Task.detached` so the `Inner` mutex is never
    /// taken on the main thread (gap pattern #2). Returns `nil` on error so
    /// callers can render a graceful fallback rather than surfacing an alert.
    ///
    /// `resolveArtist(id:)` and the artist About section both go through here,
    /// so a cache-miss artist page open performs a single `core.artistDetail`
    /// round-trip rather than one per consumer.
    func artistDetail(artistId: String) async -> ArtistDetail? {
        if let cached = artistDetailCache[artistId] { return cached }
        do {
            let detail = try await Task.detached(priority: .userInitiated) { [core] in
                try core.artistDetail(artistId: artistId)
            }.value
            artistDetailCache[artistId] = detail
            return detail
        } catch {
            _ = handleAuthError(error)
            return nil
        }
    }

    /// Per-session cache for `artistDetail`. Cleared on `logout()` / `forgetToken()`.
    private var artistDetailCache: [String: ArtistDetail] = [:]

    /// Album/artist id → display name, seeded by `resolveAlbum` / `resolveArtist`
    /// when they resolve an id past the loaded library page. The breadcrumb
    /// builder reads this so a drill destination reached from outside
    /// `albums` / `artists` (recently played, discography, genre detail) shows
    /// its name instead of "…". Cleared on `logout()` / `forgetToken()`.
    var resolvedNameCache: [String: String] = [:]

    /// Breadcrumb display name for an album id: the loaded `albums` page first,
    /// then `resolvedNameCache` (seeded by `resolveAlbum` on drill-in), then nil
    /// when neither knows the name so the caller can render an ellipsis.
    func breadcrumbAlbumName(id: String) -> String? {
        albums.first(where: { $0.id == id })?.name ?? resolvedNameCache[id]
    }

    /// Breadcrumb display name for an artist id, mirroring `breadcrumbAlbumName`.
    func breadcrumbArtistName(id: String) -> String? {
        artists.first(where: { $0.id == id })?.name ?? resolvedNameCache[id]
    }

    /// Resolve an `Album` record by id — cache-first, falling back to
    /// `core.fetchItem` for libraries larger than the loaded `albums`
    /// page. Returns nil on error or missing id.
    ///
    /// Parses a minimal subset of `BaseItemDto` — just the fields the
    /// hero needs (name, artist, year, runtime, image tag, genres).
    /// Track count falls back to 0 when the server didn't include
    /// `ChildCount`; `AlbumDetailView` re-counts the loaded tracklist
    /// in that case.
    func resolveAlbum(id: String) async -> Album? {
        if let cached = albums.first(where: { $0.id == id }) {
            resolvedNameCache[id] = cached.name
            return cached
        }
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: id,
                    fields: ["PrimaryImageAspectRatio", "Genres", "ProductionYear", "ChildCount", "RunTimeTicks"]
                )
            }.value
            let album = Self.parseAlbum(from: json)
            if let album { resolvedNameCache[id] = album.name }
            return album
        } catch {
            _ = handleAuthError(error)
            return nil
        }
    }

    static func parseAlbum(from json: String) -> Album? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let id = root["Id"] as? String,
              let name = root["Name"] as? String
        else { return nil }
        let artistName = (root["AlbumArtist"] as? String) ?? ""
        let year = (root["ProductionYear"] as? NSNumber).map { Int32(truncating: $0) }
        let runtimeTicks = (root["RunTimeTicks"] as? NSNumber)?.uint64Value ?? 0
        let trackCount = (root["ChildCount"] as? NSNumber)?.uint32Value ?? 0
        let genres = (root["Genres"] as? [String]) ?? []
        let imageTag = (root["ImageTags"] as? [String: String])?["Primary"]
        let artistId: String? = {
            guard let albumArtists = root["AlbumArtists"] as? [[String: Any]],
                  let first = albumArtists.first
            else { return nil }
            return first["Id"] as? String
        }()
        return Album(
            id: id,
            name: name,
            artistName: artistName,
            artistId: artistId,
            year: year,
            trackCount: trackCount,
            runtimeTicks: runtimeTicks,
            genres: genres,
            imageTag: imageTag,
            userData: nil
        )
    }

    /// Resolve a `Playlist` record by id — cache-first, falling back to
    /// `core.fetchItem` when the id isn't in the loaded `playlists` page.
    /// Mirror of `resolveArtist(id:)` / `resolveAlbum(id:)`. Lets
    /// `PlaylistView` render a hero for deep-linked playlists past the
    /// first library page. Returns nil on error or missing id.
    func resolvePlaylist(id: String) async -> Playlist? {
        if let cached = playlist(id: id) { return cached }
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: id,
                    fields: ["ChildCount", "RunTimeTicks", "PrimaryImageAspectRatio"]
                )
            }.value
            guard let parsed = Self.parsePlaylist(from: json) else { return nil }
            // Seed the cache so `model.playlist(id:)` works on the next
            // call without another FFI round-trip, and so breadcrumbs can
            // read the name.
            if !playlists.contains(where: { $0.id == parsed.id }) {
                playlists.append(parsed)
            }
            return parsed
        } catch {
            _ = handleAuthError(error)
            return nil
        }
    }

    static func parsePlaylist(from json: String) -> Playlist? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let id = root["Id"] as? String,
              let name = root["Name"] as? String
        else { return nil }
        // Defensive guard against the "Playlists > Playlists" case — if the
        // server hands back a CollectionFolder / UserView instead of a real
        // Playlist (id happens to match the library-view id), refuse it so
        // the UI falls through to "not found" instead of rendering the
        // folder's children as track rows.
        let kind = (root["Type"] as? String) ?? ""
        guard kind == "Playlist" else { return nil }
        let trackCount = (root["ChildCount"] as? NSNumber)?.uint32Value ?? 0
        let runtimeTicks = (root["RunTimeTicks"] as? NSNumber)?.uint64Value ?? 0
        let imageTag = (root["ImageTags"] as? [String: String])?["Primary"]
        return Playlist(
            id: id,
            name: name,
            trackCount: trackCount,
            runtimeTicks: runtimeTicks,
            imageTag: imageTag,
            userData: nil
        )
    }

    /// Every album where the given artist is the primary (album) artist.
    /// Server-scoped via `AlbumArtistIds`, so compilations / guest-spots
    /// don't leak into the Discography section. Drives
    /// `ArtistDetailView.artistAlbums` — replaces the stale
    /// `model.albums.filter { $0.artistId == artistID }` pattern that
    /// only searched the first page of 100 cached albums (#60).
    ///
    /// Results are cached per-artist for the session since the data is
    /// stable for the duration of the user's browsing session and the
    /// detail screen may be entered / left repeatedly.
    @discardableResult
    func loadArtistAlbums(artistId: String, limit: UInt32 = 200) async -> [Album] {
        // Soft cap of 200. Was 500 in rc7, but a "Various Artists" entry
        // returning the full 500 expands to a 4×125 fan-out across the
        // discography groups (Albums / Singles / Compilations / Live), each
        // rendered through a `LazyHStack`. On macOS 26.4 + M5 we observed
        // SwiftUI's HVStack layout cache OOM during `_ContiguousArrayBuffer`
        // allocation — the lazy stacks bound rendered tiles, but the parent
        // VStack's subview enumeration scales with the total. 200 is plenty
        // for any single artist; pagination for the long-tail compilations
        // case is a v1.x follow-up.
        if let cached = artistAlbumsCache[artistId] { return cached }
        let start = Date()
        Log.app.info("loadArtistAlbums start artist=\(artistId, privacy: .public) limit=\(limit, privacy: .public)")
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.albumsByArtist(artistId: artistId, offset: 0, limit: limit)
            }.value
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.app.info("loadArtistAlbums ok artist=\(artistId, privacy: .public) count=\(page.items.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
            artistAlbumsCache[artistId] = page.items
            serverReachability.noteSuccess()
            return page.items
        } catch {
            Log.app.error("loadArtistAlbums failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Per-session cache for `loadArtistAlbums`. Cleared on `logout()`.
    private var artistAlbumsCache: [String: [Album]] = [:]

    /// Fetch the top 5 most-played tracks for an artist, driving the
    /// "Top Tracks" section on the artist detail screen (#229). Backed by
    /// `/Items?ArtistIds=<id>&SortBy=PlayCount,SortName&SortOrder=Descending,Ascending`
    /// on the server. Results are cached per-artist for the session. Errors
    /// are swallowed silently — an empty section is preferable to an error
    /// banner for a secondary widget on the artist page.
    @discardableResult
    func loadArtistTopTracks(artistId: String, limit: UInt32 = 5) async -> [Track] {
        if let cached = artistTopTracks[artistId] { return cached }
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.artistTopTracks(artistId: artistId, limit: limit)
            }.value
            artistTopTracks[artistId] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch artists similar to `artistId` via Jellyfin's
    /// `GET /Artists/{id}/Similar`. Results are cached for the session in
    /// `artistSimilarCache` and cleared on logout. Mirrors the shape of
    /// `loadArtistTopTracks` — detached FFI call, silent fallback. See #146.
    @discardableResult
    func loadSimilarArtists(artistId: String, limit: UInt32 = 12) async -> [Artist] {
        if let cached = artistSimilarCache[artistId] {
            Log.app.debug("loadSimilarArtists cache hit artist=\(artistId, privacy: .public) count=\(cached.count, privacy: .public)")
            return cached
        }
        let start = Date()
        Log.app.info("loadSimilarArtists start artist=\(artistId, privacy: .public)")
        do {
            let similar = try await Task.detached(priority: .userInitiated) { [core] in
                try core.similarArtists(artistId: artistId, limit: limit)
            }.value
            let elapsed = Date().timeIntervalSince(start) * 1000
            Log.app.info("loadSimilarArtists ok artist=\(artistId, privacy: .public) count=\(similar.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
            artistSimilarCache[artistId] = similar
            serverReachability.noteSuccess()
            return similar
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            Log.app.notice("loadSimilarArtists failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch the playlists whose track list features `artistId`, for the
    /// "Playlists featuring this artist" rail on the Artist detail screen.
    /// Backed by `core.playlistsContainingArtist`, which walks each
    /// playlist and matches the artist at the track level (guest features
    /// count). Cached for the session in `artistPlaylistsCache`, cleared on
    /// logout. Mirrors `loadSimilarArtists` — detached FFI call, silent
    /// fallback (the rail collapses when empty so an error reads as "no
    /// featuring playlists" rather than a broken section).
    @discardableResult
    func loadPlaylistsFeaturingArtist(artistId: String, limit: UInt32 = 6) async -> [Playlist] {
        if let cached = artistPlaylistsCache[artistId] { return cached }
        let libraryId = await ensurePlaylistLibraryId()
        do {
            let playlists = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistsContainingArtist(
                    playlistLibraryId: libraryId,
                    artistId: artistId,
                    limit: limit
                )
            }.value
            artistPlaylistsCache[artistId] = playlists
            serverReachability.noteSuccess()
            return playlists
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            Log.app.notice("loadPlaylistsFeaturingArtist failed artist=\(artistId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch the ordered tracks for a playlist, preserving the server-side
    /// playlist order. Mirrors `loadTracks(forAlbum:)` — results are cached
    /// for the session, scoped to `playlistTracks[playlist.id]`. Backed by
    /// `LyrebirdCore.playlistTracks` (core's `playlist_tracks`, see #125).
    ///
    /// We ask for up to 500 entries, which covers the vast majority of
    /// playlists; paging the tail is a follow-up alongside virtualization of
    /// the track list itself (see #234's spec — the hero ships first, the
    /// long-playlist scroll optimization is a later polish pass).
    @discardableResult
    func loadPlaylistTracks(playlist: Playlist) async -> [Track] {
        if let cached = playlistTracks[playlist.id] { return cached }
        do {
            let playlistID = playlist.id
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistTracks(playlistId: playlistID, offset: 0, limit: 500)
            }.value
            let tracks = page.items
            playlistTracks[playlist.id] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistTracks)
            return []
        }
    }

    /// Look up a cached `Playlist` by id. Returns `nil` if no upstream surface
    /// has inserted one — the caller (`PlaylistView`) renders a minimal
    /// fallback in that case until playlist listing lands (#220).
    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Load the ordered track list for `playlistId` and publish it on
    /// `currentPlaylistTracks` so `PlaylistDetailView` can drive its list and
    /// multi-select surface off a single observable array. See #74 / #236.
    ///
    /// Hits the keyed `playlistTracks` cache first so switching back to a
    /// playlist you just left is instant. On a miss, delegates to
    /// `core.playlistTracks(playlistId:)` for up to 500 entries — same cap as
    /// `loadPlaylistTracks(playlist:)`. Errors surface through the usual
    /// auth / reachability / error-banner path.
    ///
    /// Pass `forceRefresh: true` to bypass the cache and re-fetch from the
    /// server — required after a mutation (e.g. drop-to-add) that changed the
    /// track list but couldn't reconstruct full `Track` rows locally.
    func loadPlaylistTracks(playlistId: String, forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = playlistTracks[playlistId] {
            currentPlaylistTracks = cached
            return
        }
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistTracks(playlistId: playlistId, offset: 0, limit: 500)
            }.value
            playlistTracks[playlistId] = page.items
            currentPlaylistTracks = page.items
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistTracks)
        }
    }

    /// Remove tracks from a playlist by entry id (the track id, since the
    /// core's FFI doesn't yet surface playlist-entry ids — see #128).
    ///
    /// Applied optimistically: rows disappear from `currentPlaylistTracks`
    /// and `playlistTracks[playlistId]` immediately, the removed tracks
    /// are stashed on `pendingPlaylistRemoval` so the 10-second undo window
    /// can put them back via `undoRemoveFromPlaylist`, and the real
    /// `DELETE /Playlists/{id}/Items` call is fired off the main actor.
    /// Track-counts on the in-memory `Playlist` are kept consistent so the
    /// hero stat doesn't lie.
    ///
    /// `entryIds` are track `id`s (the underlying `ItemId`). The server call
    /// needs `PlaylistItemId`s — we resolve those from
    /// `currentPlaylistTracks` before firing the request, so every removed
    /// track must have been loaded with its `playlistItemId` set (i.e.
    /// fetched via `core.playlistTracks`, not synthesized ad-hoc).
    func removeFromPlaylist(playlistId: String, entryIds: [String]) {
        guard !entryIds.isEmpty else { return }
        let removing = Set(entryIds)
        let removed = currentPlaylistTracks.filter { removing.contains($0.id) }
        guard !removed.isEmpty else { return }
        let playlistItemIds = removed.compactMap { $0.playlistItemId }
        // Server call requires playlistItemIds. If any removed track lacks
        // one, the whole batch can't be reconciled with the server. Bail
        // BEFORE the optimistic mutation so there's nothing to roll back —
        // surface a banner so the user knows the action didn't persist.
        // (Earlier we mutated then rolled back, but the rollback restored
        // from the already-mutated array — net no-op.)
        guard !playlistItemIds.isEmpty else {
            errorMessage = "Couldn't remove this track from the playlist. Try refreshing the playlist."
            return
        }
        currentPlaylistTracks.removeAll { removing.contains($0.id) }
        playlistTracks[playlistId] = currentPlaylistTracks
        pendingPlaylistRemoval = PendingRemoval(
            playlistId: playlistId,
            tracks: removed
        )
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            let newCount = max(0, Int(p.trackCount) - removed.count)
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: UInt32(newCount),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag,
                userData: p.userData
            )
        }
        // Capture the optimistic state so we can roll back on server failure.
        // Without this rollback the local list and server diverge silently —
        // user sees the row vanish, refreshes the playlist, row reappears,
        // and the action looks like a phantom event. Same bug class as the
        // rc4-rc5 favorite-not-pushed report.
        let removedSnapshot = removed
        let playlistRef = playlistId
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.removeFromPlaylist(
                        playlistId: playlistRef,
                        entryIds: playlistItemIds
                    )
                }.value
                self?.serverReachability.noteSuccess()
            } catch {
                guard let self else { return }
                if self.handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    self.serverReachability.noteFailure()
                }
                // Rollback: restore the rows + the trackCount we just decremented.
                self.currentPlaylistTracks.append(contentsOf: removedSnapshot)
                self.playlistTracks[playlistRef] = self.currentPlaylistTracks
                if let idx = self.playlists.firstIndex(where: { $0.id == playlistRef }) {
                    let p = self.playlists[idx]
                    self.playlists[idx] = Playlist(
                        id: p.id,
                        name: p.name,
                        trackCount: p.trackCount + UInt32(removedSnapshot.count),
                        runtimeTicks: p.runtimeTicks,
                        imageTag: p.imageTag,
                        userData: p.userData
                    )
                }
                self.pendingPlaylistRemoval = nil
                self.errorMessage = LyrebirdErrorPresenter.message(
                    for: error,
                    context: .playlistTracks
                )
            }
        }
    }

    /// Restore a previously-removed batch by re-adding via `core.addToPlaylist`.
    /// Called from the undo toast in `PlaylistDetailView`. Clears
    /// `pendingPlaylistRemoval` on success; leaves it intact on failure so
    /// the user can retry by tapping Undo again.
    func undoRemoveFromPlaylist() {
        guard let pending = pendingPlaylistRemoval else { return }
        let ids = pending.tracks.map(\.id)
        let playlistId = pending.playlistId
        pendingPlaylistRemoval = nil
        // Optimistically re-insert so the list pops back immediately. The
        // server call below is the actual durability guarantee.
        let existingIds = Set(currentPlaylistTracks.map(\.id))
        let reinserted = pending.tracks.filter { !existingIds.contains($0.id) }
        currentPlaylistTracks.append(contentsOf: reinserted)
        playlistTracks[playlistId] = currentPlaylistTracks
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: p.trackCount + UInt32(reinserted.count),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag,
                userData: p.userData
            )
        }
        // Capture the count of optimistically-reinserted tracks so we can
        // roll back on server failure. Without this the playlist's count is
        // inflated locally vs. server.
        let reinsertedCount = reinserted.count
        let playlistRef = playlistId
        let reinsertedIds = Set(reinserted.map(\.id))
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.addToPlaylist(playlistId: playlistRef, itemIds: ids, position: nil)
                }.value
                self?.serverReachability.noteSuccess()
            } catch {
                guard let self else { return }
                if self.handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    self.serverReachability.noteFailure()
                }
                // Roll back the optimistic re-insert: drop the rows we
                // just added and decrement the playlist count.
                self.currentPlaylistTracks.removeAll { reinsertedIds.contains($0.id) }
                self.playlistTracks[playlistRef] = self.currentPlaylistTracks
                if let idx = self.playlists.firstIndex(where: { $0.id == playlistRef }) {
                    let p = self.playlists[idx]
                    let newCount = max(0, Int(p.trackCount) - reinsertedCount)
                    self.playlists[idx] = Playlist(
                        id: p.id,
                        name: p.name,
                        trackCount: UInt32(newCount),
                        runtimeTicks: p.runtimeTicks,
                        imageTag: p.imageTag,
                        userData: p.userData
                    )
                }
                self.errorMessage = LyrebirdErrorPresenter.message(
                    for: error,
                    context: .playlistTracks
                )
            }
        }
    }

    /// Append tracks to a playlist by id. Backs the drop-to-add handler on
    /// `PlaylistDetailView` and any future "Add to playlist" affordance. See
    /// #236. Updates the in-memory caches optimistically and fires the core
    /// call in a detached task.
    ///
    /// We only know the bare track ids here, not full `Track` records, so the
    /// visible list can't be appended to optimistically. Instead, on a
    /// successful add we invalidate `playlistTracks[playlistId]` and — when
    /// that playlist is the one currently on screen — re-fetch it so the new
    /// rows actually appear. Without this the drop "succeeds" but the list
    /// keeps showing the pre-drop tracks (the cache was never refreshed).
    func addToPlaylist(playlistId: String, trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        let ids = trackIds
        // Is this the playlist currently on screen? `currentPlaylistTracks` is
        // populated from `playlistTracks[playlistId]` whenever a playlist
        // loads, so matching id sequences means the detail view is showing it
        // and needs a re-fetch once the add lands.
        let isShowingThisPlaylist = playlistTracks[playlistId]?.map(\.id) == currentPlaylistTracks.map(\.id)
        // Optimistically bump the count BEFORE the FFI call so the drop
        // visually lands without waiting for the round-trip. We don't know
        // the full `Track` records for ids that aren't already resident, so
        // we only bump the count on the in-memory `Playlist` and leave the
        // list alone — a follow-up `loadPlaylistTracks` (the caller usually
        // fires one after a drop) will reconcile.
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: p.trackCount + UInt32(trackIds.count),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag,
                userData: p.userData
            )
        }
        let bumpedCount = trackIds.count
        let playlistRef = playlistId
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.addToPlaylist(playlistId: playlistRef, itemIds: ids, position: nil)
                }.value
                guard let self else { return }
                self.serverReachability.noteSuccess()
                // The add persisted but we only had bare ids, so the cached
                // rows are now stale (missing the new tracks). Invalidate the
                // cache and, if this playlist is on screen, re-fetch so the
                // dropped tracks actually appear in the list.
                self.playlistTracks[playlistRef] = nil
                if isShowingThisPlaylist {
                    await self.loadPlaylistTracks(playlistId: playlistRef, forceRefresh: true)
                }
            } catch {
                guard let self else { return }
                if self.handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    self.serverReachability.noteFailure()
                }
                // Roll back the optimistic count bump so the in-memory
                // Playlist record stays in sync with the server.
                if let idx = self.playlists.firstIndex(where: { $0.id == playlistRef }) {
                    let p = self.playlists[idx]
                    let newCount = max(0, Int(p.trackCount) - bumpedCount)
                    self.playlists[idx] = Playlist(
                        id: p.id,
                        name: p.name,
                        trackCount: UInt32(newCount),
                        runtimeTicks: p.runtimeTicks,
                        imageTag: p.imageTag,
                        userData: p.userData
                    )
                }
                self.errorMessage = LyrebirdErrorPresenter.message(
                    for: error,
                    context: .playlistTracks
                )
            }
        }
    }

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


    /// Switch to the Search screen and request keyboard focus in the search
    /// field. Called from the ⌘F menu command. Writes both the legacy
    /// one-shot `requestSearchFocus` flag (which `SearchView` already observes)
    /// and the new `isSearchFieldFocused` mirror so toolbar / field bindings
    /// introduced by #7 can attach a `@FocusState` via `$model.isSearchFieldFocused`.
    func focusSearch() {
        selectTab(.search)
        requestSearchFocus = true
        isSearchFieldFocused = true
    }

    /// The active drill destination iff it owns a scoped (in-content) search
    /// bar — currently the Artist and Playlist detail pages. `nil` otherwise.
    /// Used by `requestFind` to address the focus request to exactly the
    /// top-of-stack route, and exposed for tests.
    var scopedSearchRoute: Route? {
        switch navPath.last {
        case .artist, .playlist, .smartPlaylist: return navPath.last
        default: return nil
        }
    }

    /// True when the active drill destination owns a scoped (in-content)
    /// search bar. Drives whether ⌘F focuses the in-view filter
    /// (`requestFind`) versus falling through to the global Search surface.
    var activeRouteSupportsScopedSearch: Bool {
        scopedSearchRoute != nil
    }

    /// ⌘F entry point. When the user is on a detail view that exposes a scoped
    /// search bar (Artist / Playlist), address a focus request to that exact
    /// route so only the on-top view pulls focus into its in-content filter.
    /// Otherwise fall back to the global Search surface. Global search remains
    /// directly reachable via ⌘⇧F regardless of context.
    func requestFind() {
        guard let route = scopedSearchRoute else {
            focusSearch()
            return
        }
        // Bump the token so a repeat ⌘F for the same route is still an
        // observable change for the owning view's `.onChange`.
        scopedSearchFocusToken &+= 1
        scopedSearchFocusRequest = ScopedSearchFocusRequest(route: route, token: scopedSearchFocusToken)
    }

    /// Called by a detail view in response to `scopedSearchFocusRequest`
    /// changing. Returns `true` iff the pending request targets `route` (so
    /// the caller should pull focus into its scoped bar) and, when it does,
    /// clears the request so a stale value can't re-fire on an unrelated
    /// state change. Views stacked under the top one (which carry a different
    /// route) get `false` and never steal focus.
    func consumeScopedSearchFocus(for route: Route) -> Bool {
        guard scopedSearchFocusRequest?.route == route else { return false }
        scopedSearchFocusRequest = nil
        return true
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

    /// Kick off a library-seeded Instant Mix from the Discover screen's CTA.
    /// Seeds off the currently-playing track if there is one; otherwise a
    /// random recently-played track; otherwise a random album. Keeps the
    /// action productive regardless of state.
    func startInstantMix() {
        let seedId: String? = {
            if let current = status.currentTrack { return current.id }
            if let recent = recentlyPlayed.first { return recent.id }
            return albums.first?.id
        }()
        guard let seedId else {
            errorMessage = "Nothing to seed a mix from yet — play a track first."
            return
        }
        playInstantMix(seedId: seedId)
    }

    /// Start a radio station seeded from a pinned-station subject (#253). The
    /// Home "Pinned Stations" row routes artist / mood / mix tiles here; the
    /// stored id is a real Jellyfin item id (or a mood/mix seed), which
    /// `core.instantMix` accepts polymorphically. Genre and playlist tiles
    /// take their own routes (`browseGenre` / `navigate(to:.playlist)`).
    func startStationRadio(seedId: String) {
        playInstantMix(seedId: seedId)
    }

    /// Re-seed the Instant Mix with a different track than the current one.
    /// Picks a random track from `recentlyPlayed` excluding the currently-
    /// playing track, so "Generate new mix" actually sounds different. Falls
    /// back to `startInstantMix` when there is nothing else to pick from.
    func regenerateInstantMix() {
        let currentId = status.currentTrack?.id
        let candidates = recentlyPlayed.filter { $0.id != currentId }
        if let seed = candidates.randomElement() {
            playInstantMix(seedId: seed.id)
        } else {
            startInstantMix()
        }
    }

    /// Present the Instant Mix seed-picker sheet (#327). The sheet lets the
    /// user search for and pick any track / album / artist / genre to seed a
    /// fresh radio station, rather than relying on the implicit "currently
    /// playing" seed that `startInstantMix` uses. Mounted on `MainShell`
    /// driven by `isShowingInstantMixPicker`; wired to the View ▸ "New
    /// Instant Mix…" menu command.
    func presentInstantMixPicker() {
        isShowingInstantMixPicker = true
    }

    /// Generate an Instant Mix from an explicitly chosen seed (#327). The
    /// seed-picker sheet hands back a heterogeneous `SearchItem`; we dispatch
    /// on its case because the seed id semantics differ:
    ///
    /// - Tracks / albums / artists carry a real Jellyfin UUID, so they feed
    ///   `playInstantMix` directly.
    /// - Genres surfaced by search only carry the display name as their id
    ///   (`Genre.init(name:)`), so they route through `startGenreRadio`,
    ///   which resolves the name → real UUID before seeding. Playlists aren't
    ///   offered as a seed by the picker today, but fall through to the
    ///   direct path should the picker ever surface one.
    ///
    /// Records the seed's display name in `instantMixSeedLabel` so a re-open
    /// of the picker can offer a one-tap regenerate, then dismisses the sheet.
    func generateInstantMix(seed: SearchItem) {
        switch seed {
        case .track(let t):
            instantMixSeedLabel = t.name
            playInstantMix(seedId: t.id)
        case .album(let a):
            instantMixSeedLabel = a.name
            playInstantMix(seedId: a.id)
        case .artist(let a):
            instantMixSeedLabel = a.name
            playInstantMix(seedId: a.id)
        case .playlist(let p):
            instantMixSeedLabel = p.name
            playInstantMix(seedId: p.id)
        case .genre(let g):
            instantMixSeedLabel = g.name
            startGenreRadio(genre: g)
        }
        isShowingInstantMixPicker = false
    }

    /// Read-only search used by the Instant Mix seed picker (#327). Returns a
    /// raw `SearchResults` without touching any of the page-level search
    /// state (`searchResults`, `searchPageResults`, …) so opening the picker
    /// never disturbs the standalone Search screen the user may have set up.
    /// The FFI hop runs off the MainActor per CLAUDE.md gap pattern #2;
    /// errors collapse to `nil` because the picker treats "no matches" and
    /// "search failed" identically (an empty candidate list), and a flaky
    /// keystroke shouldn't raise an error banner mid-typing.
    func searchSeeds(query: String, limit: UInt32 = 20) async -> SearchResults? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { [core] in
            try? core.search(query: trimmed, offset: 0, limit: limit)
        }.value
    }

    /// Common driver for every "Start Radio" entry point. `core.instantMix`
    /// is polymorphic — any item id (track, album, artist, genre, playlist)
    /// works. Wraps the FFI hop in `Task.detached` so the main actor doesn't
    /// block on a network round-trip.
    func playInstantMix(seedId: String, limit: UInt32 = 50) {
        Task {
            do {
                let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                    try core.instantMix(itemId: seedId, limit: limit)
                }.value
                guard !tracks.isEmpty else { return }
                play(tracks: tracks, startIndex: 0)
            } catch {
                if handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = "Couldn't start radio: \(error.localizedDescription)"
            }
        }
    }

    /// Shuffle the entire library — loads tracks from a handful of random
    /// albums, interleaves them into one queue, shuffles, and plays.
    ///
    /// Powers the "Shuffle All" CTA on the Home greeting header (#204). The
    /// core doesn't expose a "list every track" primitive yet (see #465), so
    /// we draw from the albums already loaded on the Home screen and assemble
    /// a queue of up to ~200 tracks. Good enough as a "play my library"
    /// affordance until a server-side random-songs endpoint lands.
    func shuffleLibrary() {
        guard !albums.isEmpty else { return }
        Task {
            // Draw from a random sample of albums so repeat presses don't
            // always yield the same seed set. Cap the sample so we don't
            // fan-out hundreds of `albumTracks` calls in a single tap.
            let sampleSize = min(albums.count, 25)
            let sampled = Array(albums.shuffled().prefix(sampleSize))
            var collected: [Track] = []
            for album in sampled {
                let tracks = await loadTracks(forAlbum: album.id)
                collected.append(contentsOf: tracks)
                // Cap total queue length — mirrors other "play a lot" flows.
                if collected.count >= 200 { break }
            }
            guard !collected.isEmpty else { return }
            play(tracks: collected.shuffled(), startIndex: 0)
        }
    }

    func search(_ query: String) async {
        searchQuery = query
        guard !query.isEmpty else {
            searchResults = nil
            searchResultsTotal = 0
            return
        }
        do {
            let results = try await Task.detached(priority: .userInitiated) { [core, searchPageSize] in
                try core.search(query: query, offset: 0, limit: searchPageSize)
            }.value
            self.searchResults = results
            self.searchResultsTotal = results.totalRecordCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Fetch the next page of the current search query and merge into
    /// `searchResults`. Jellyfin's combined-type `/Users/{id}/Items`
    /// endpoint doesn't let us fetch more of a single kind at a time, so
    /// this appends whichever of (artists, albums, tracks) the next page
    /// happens to contain. The "Show all N results" button in `SearchView`
    /// is the caller.
    ///
    /// Dedupes by id so the typed arrays don't accumulate duplicates if a
    /// row happens to overlap across paged responses (which can happen
    /// because Jellyfin's ordering is stable only per sort key).
    func loadMoreSearchResults() async {
        guard !isLoadingMoreSearch else { return }
        guard let current = searchResults, !searchQuery.isEmpty else { return }
        let loaded = current.artists.count + current.albums.count + current.tracks.count
        guard loaded < Int(searchResultsTotal) else { return }
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }
        let offset = UInt32(loaded)
        let query = searchQuery
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, searchPageSize] in
                try core.search(query: query, offset: offset, limit: searchPageSize)
            }.value
            // Merge with dedupe — see method doc.
            var artistSet = Set(current.artists.map(\.id))
            var albumSet = Set(current.albums.map(\.id))
            var trackSet = Set(current.tracks.map(\.id))
            var artists = current.artists
            var albums = current.albums
            var tracks = current.tracks
            for a in page.artists where artistSet.insert(a.id).inserted { artists.append(a) }
            for a in page.albums where albumSet.insert(a.id).inserted { albums.append(a) }
            for t in page.tracks where trackSet.insert(t.id).inserted { tracks.append(t) }
            self.searchResults = SearchResults(
                artists: artists,
                albums: albums,
                tracks: tracks,
                totalRecordCount: page.totalRecordCount
            )
            self.searchResultsTotal = page.totalRecordCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }


    /// Drive the full Search page (`SearchView`). Issues a combined-type
    /// search against Jellyfin, buckets results into `searchPageResults`
    /// by scope key, and stores the active scope so the view's scope chips
    /// can render without re-querying. Called on Return-key commit in the
    /// field, and again when the user taps a scope chip.
    ///
    /// The underlying `core.search` endpoint returns MusicArtist,
    /// MusicAlbum, and Audio mixed together with a single total — there
    /// is no per-kind pagination on the server. `searchPagePageSize` is
    /// large enough that each typed section typically fills well past the
    /// "~20 per category" the page aims for. Callers hit `loadMoreFullSearch`
    /// to request another combined page when the user has exhausted the
    /// local buffer within a section.
    ///
    /// Genres are derived client-side from the `genres` arrays on albums
    /// and artists since Jellyfin doesn't return them as standalone items
    /// on this endpoint. Playlists are likewise not returned today — the
    /// bucket stays empty until the core exposes them via `search`, at
    /// which point the view already knows how to render them.
    ///
    /// Issues: #86 (full results page), #242 (scope chips), #244 (sections
    /// layout), #245 (zero-results state).
    func runFullSearch(query: String, scope: SearchScope) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchScope = scope
        // Record the normalized query that drives the results, but do NOT
        // touch `searchPageQuery` — that's the live binding for the text
        // field, and writing a trimmed value back into it would delete a
        // space the user just typed mid-edit. The view owns the field text.
        searchPageActiveQuery = trimmed

        guard !trimmed.isEmpty else {
            searchPageResults = [:]
            searchPageTotal = 0
            searchPageLoaded = 0
            searchPageExhausted = false
            isLoadingFullSearch = false
            return
        }

        isLoadingFullSearch = true
        defer { isLoadingFullSearch = false }
        searchPageExhausted = false
        do {
            let pageSize = searchPagePageSize
            let results = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: trimmed, offset: 0, limit: pageSize)
            }.value
            searchPageResults = Self.bucketSearchResults(results)
            searchPageTotal = results.totalRecordCount
            searchPageLoaded = results.artists.count + results.albums.count + results.tracks.count
            // A first page that already returns fewer raw items than it
            // asked for means the server has nothing more — mark exhausted
            // so the per-section "Load more" can't promise a phantom page.
            let firstPageRaw = results.artists.count + results.albums.count + results.tracks.count
            if firstPageRaw < Int(pageSize) || searchPageLoaded >= Int(searchPageTotal) {
                searchPageExhausted = true
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Fetch another combined page for the current full-search query.
    /// Invoked by the "Load more" button on a scope tab when that tab has
    /// already revealed every buffered item but the server still reports
    /// more matches overall. Merges the new page into `searchPageResults`
    /// with per-id dedupe so flaky ordering on Jellyfin's side doesn't
    /// double a row. No-op when the buckets already cover `searchPageTotal`.
    func loadMoreFullSearch() async {
        // Page off the normalized query that produced the current results,
        // not the live field text (which the user may still be editing).
        guard !isLoadingFullSearch, !searchPageActiveQuery.isEmpty else { return }
        guard searchPageHasMore else { return }
        isLoadingFullSearch = true
        defer { isLoadingFullSearch = false }
        let offset = UInt32(searchPageLoaded)
        let query = searchPageActiveQuery
        do {
            let pageSize = searchPagePageSize
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: query, offset: offset, limit: pageSize)
            }.value

            var merged = searchPageResults
            let incoming = Self.bucketSearchResults(page)
            var addedNewItems = false
            for (key, newItems) in incoming {
                var existing = merged[key] ?? []
                var seen = Set(existing.map(\.id))
                for item in newItems where seen.insert(item.id).inserted {
                    existing.append(item)
                    addedNewItems = true
                }
                merged[key] = existing
            }
            searchPageResults = merged
            searchPageTotal = page.totalRecordCount
            let pageRaw = page.artists.count + page.albums.count + page.tracks.count
            searchPageLoaded += pageRaw
            // Exhaustion guard: `searchPageLoaded < searchPageTotal` alone
            // can never settle because `searchPageTotal` may count types we
            // don't page (or be deduped server-side). Treat the search as
            // done the moment a page returns no new deduplicated items, a
            // short raw page, or we've caught up to the total. This is what
            // keeps "Load more" from becoming a perpetual no-op.
            if !addedNewItems || pageRaw < Int(pageSize) || searchPageLoaded >= Int(searchPageTotal) {
                searchPageExhausted = true
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Partition a core `SearchResults` into the per-scope buckets the
    /// full search page renders. Genres are reconstructed from the
    /// `genres` arrays that Jellyfin attaches to albums and artists —
    /// we dedupe and alpha-sort so the Genres chip has something useful
    /// to show even though the API doesn't return genre items directly.
    nonisolated static func bucketSearchResults(_ results: SearchResults) -> [String: [SearchItem]] {
        var buckets: [String: [SearchItem]] = [:]
        buckets[SearchScope.artists.storageKey] = results.artists.map(SearchItem.artist)
        buckets[SearchScope.albums.storageKey] = results.albums.map(SearchItem.album)
        buckets[SearchScope.tracks.storageKey] = results.tracks.map(SearchItem.track)
        // Playlists aren't surfaced by the current `core.search` endpoint,
        // so this bucket stays empty and the Playlists scope is hidden in
        // the UI behind `supportsPlaylistSearch`. When core gains playlist
        // search, populate this from the response (e.g.
        // `results.playlists.map(SearchItem.playlist)`) and flip the flag.
        buckets[SearchScope.playlists.storageKey] = []
        // Genres: harvest distinct names from every album and artist in
        // the response. Uses case-insensitive de-dupe so "Rock" vs "rock"
        // collapse to a single chip-worthy entry.
        var seenGenres = Set<String>()
        var genreItems: [SearchItem] = []
        let allGenres = results.albums.flatMap(\.genres) + results.artists.flatMap(\.genres)
        for raw in allGenres {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard seenGenres.insert(key).inserted else { continue }
            genreItems.append(.genre(Genre(name: name)))
        }
        genreItems.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        buckets[SearchScope.genres.storageKey] = genreItems
        return buckets
    }

    /// Append a committed query to the recent-searches `@AppStorage` list,
    /// deduping and capping to the 10-most-recent. The view owns the
    /// storage binding; this helper mutates the decoded list in-place so
    /// the JSON round-trip stays in one place.
    ///
    /// Uses `String` (rather than `[String]`) storage because
    /// `@AppStorage` doesn't support arrays directly. The view decodes on
    /// read, encodes on write.
    static func addRecentSearch(_ query: String, into json: inout String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = decodeRecentSearches(json)
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > 10 {
            list = Array(list.prefix(10))
        }
        json = encodeRecentSearches(list)
    }

    /// Remove a single term from the recent-searches list. Used by the
    /// per-row × button in the empty-query state. Mutates the shared JSON
    /// string so the caller's `@AppStorage` binding picks up the change.
    static func removeRecentSearch(_ query: String, from json: inout String) {
        var list = decodeRecentSearches(json)
        list.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        json = encodeRecentSearches(list)
    }

    /// Reset the recent-searches list. Wired to the "Clear history" footer
    /// button under the recents list.
    static func clearRecentSearches(_ json: inout String) {
        json = "[]"
    }

    /// Decode the recents JSON into a plain `[String]`. Returns `[]` on
    /// malformed data so a stale shape from a prior build doesn't prevent
    /// the page from rendering.
    static func decodeRecentSearches(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    /// Encode a `[String]` back to the JSON string `@AppStorage` persists.
    private static func encodeRecentSearches(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s

    }

    /// Memoized cache keyed on (itemID, tag, maxWidth). Each grid cell calls
    /// `imageURL` during every scroll-driven body recomputation; without this
    /// cache every cell crosses the UniFFI boundary (Swift → C → Rust) and
    /// locks `Inner` — an O(n) mutex hit per frame that serialized against
    /// every background `loadMore*` and caused the main-thread beach ball.
    /// The URL string is deterministic for a given (itemID, tag, maxWidth),
    /// so one FFI crossing per tuple is all we ever need.
    private var imageURLCache: [String: URL?] = [:]

    func imageURL(for itemID: String, tag: String?, maxWidth: UInt32 = 400) -> URL? {
        let key = Self.imageURLCacheKey(itemID: itemID, tag: tag, maxWidth: maxWidth)
        if let cached = imageURLCache[key] { return cached }
        let result: URL?
        if let s = try? core.imageUrl(itemId: itemID, tag: tag, maxWidth: maxWidth) {
            result = URL(string: s)
        } else {
            result = nil
        }
        imageURLCache[key] = result
        return result
    }

    /// The `imageURLCache` key for a given (itemID, tag, maxWidth) tuple.
    /// Kept in one place so `imageURL` and `resolveImageURLs` can't drift.
    /// `nonisolated` so the off-main `resolveImageURLs` batch can build keys
    /// inside its `Task.detached` without hopping back to the MainActor.
    nonisolated private static func imageURLCacheKey(
        itemID: String, tag: String?, maxWidth: UInt32
    ) -> String {
        "\(itemID)|\(tag ?? "")|\(maxWidth)"
    }

    /// Resolve a batch of image URLs **off the main thread** and return them
    /// as an `[itemID: URL?]` map, caching each result so a subsequent
    /// `imageURL(for:)` for the same tuple is a pure cache hit.
    ///
    /// Eager carousels (e.g. the artist Discography, which can hold up to
    /// ~200 album tiles) would otherwise call the synchronous `imageURL`
    /// inside each tile body on first render — taking the Rust `Inner` mutex
    /// on the MainActor once per tile, serialized against every background
    /// load (gap pattern #2). Resolving the whole batch in a single
    /// `Task.detached` hop keeps every mutex acquisition off the main thread;
    /// callers then hand each tile its pre-resolved URL so the per-cell sync
    /// FFI never runs. Already-cached tuples are served from the cache and
    /// never re-cross the FFI boundary.
    func resolveImageURLs(
        for items: [(id: String, tag: String?)],
        maxWidth: UInt32 = 400
    ) async -> [String: URL?] {
        var resolved: [String: URL?] = [:]
        var pending: [(id: String, tag: String?)] = []
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            let key = Self.imageURLCacheKey(itemID: item.id, tag: item.tag, maxWidth: maxWidth)
            if let cached = imageURLCache[key] {
                resolved[item.id] = cached
            } else {
                pending.append(item)
            }
        }
        guard !pending.isEmpty else { return resolved }

        let computed = await Task.detached(priority: .userInitiated) { [core] in
            pending.map { item -> (String, String, URL?) in
                let key = Self.imageURLCacheKey(itemID: item.id, tag: item.tag, maxWidth: maxWidth)
                let url = (try? core.imageUrl(itemId: item.id, tag: item.tag, maxWidth: maxWidth))
                    .flatMap(URL.init(string:))
                return (item.id, key, url)
            }
        }.value

        for (id, key, url) in computed {
            imageURLCache[key] = url
            resolved[id] = url
        }
        return resolved
    }

    // MARK: - Ambient palette (#271)

    /// Per-album ambient-wash palette, memoized for the session. Keyed by
    /// album id (or track id when an album-less track is playing) so the
    /// Core Image sample runs **once** per cover, never per render pass —
    /// gap pattern #2: sampling artwork on every Now Playing repaint would
    /// burn the GPU and re-decode the image needlessly.
    ///
    /// Stored as the opaque `AmbientPalette.encoded` string rather than the
    /// `Color`-bearing struct so the entry is a plain value type and survives
    /// any future move to a persistent cache without a bespoke codable surface.
    private var ambientPaletteCache: [String: String] = [:]

    /// In-flight palette samples, so two `NowPlayingView.task` invocations for
    /// the same id (e.g. a fast tab toggle) coalesce onto one Nuke decode +
    /// CIAreaAverage pass instead of racing two.
    private var ambientPaletteTasks: [String: Task<AmbientPalette?, Never>] = [:]

    /// Resolve the ambient palette for a now-playing item — cache-first, then
    /// a single off-main Nuke decode + Core Image average (`PaletteSampler`).
    ///
    /// Returns `nil` when there's no artwork URL or extraction fails; callers
    /// (`NowPlayingView`) treat that as "no palette" and `AmbientWash` falls
    /// back to the theme wash, so the player is never bare. The decode itself
    /// runs off the MainActor inside `PaletteSampler.sample` (it `await`s
    /// Nuke's pipeline), so this never blocks the main thread.
    func ambientPalette(forItemId itemId: String, imageTag: String?) async -> AmbientPalette? {
        if let encoded = ambientPaletteCache[itemId] {
            return AmbientPalette(encoded: encoded)
        }
        if let existing = ambientPaletteTasks[itemId] {
            return await existing.value
        }
        guard let url = imageURL(for: itemId, tag: imageTag, maxWidth: 512) else {
            return nil
        }

        let task = Task<AmbientPalette?, Never> {
            await PaletteSampler.sample(from: url)
        }
        ambientPaletteTasks[itemId] = task
        let palette = await task.value
        ambientPaletteTasks[itemId] = nil
        if let palette {
            ambientPaletteCache[itemId] = palette.encoded
        }
        return palette
    }

    // MARK: - Favorite cache

    /// In-memory favorite flag keyed by item id (album/track/artist/playlist).
    /// Populated lazily: when the user toggles the heart on the album detail
    /// screen we record the server's authoritative return value here, and the
    /// UI reads this map rather than passing fragile per-screen state around.
    ///
    /// Not persisted across launches — the server is the source of truth and
    /// a fresh load refetches. A future #133 follow-up hydrates this from
    /// the initial library fetch so favourites show up without a per-item
    /// round-trip.
    var favoriteById: [String: Bool] = [:]

    /// Bumps every time `setFavorite(...)` resolves on the server. Views that
    /// list favorites can `.task(id: model.favoriteChangeToken)` to refetch
    /// without polling.
    var favoriteChangeToken: UInt64 = 0

    // MARK: - Offline downloads (#819)
    //
    // The download state of every track the user has interacted with, mirrored
    // into an in-memory snapshot so per-cell row views (`TrackRow`) can read a
    // downloading / done badge WITHOUT a synchronous core FFI on the main
    // thread (CLAUDE.md runtime gap #2). The dictionary is the single source the
    // UI reads; the FFI is consulted only off-main when a download is enqueued,
    // finishes, is deleted, or when `refreshDownloadSnapshot()` rehydrates it.
    //
    // Keyed by track id. Absence means "no download record" (the common case),
    // which `downloadState(forTrackId:)` reports as `nil`. All of this is inert
    // while `supportsDownloads` is false — nothing populates the map, so every
    // lookup returns `nil` and the UI shows no download affordances.

    /// Per-track download lifecycle, keyed by track id. Read by row views; never
    /// holds the core mutex on the main thread.
    var downloadStateById: [String: DownloadState] = [:]

    /// The full list of download records (any state), newest-enqueued first.
    /// Drives the Downloads area. Refreshed from `core.listDownloads()` off-main
    /// via `refreshDownloads()`.
    var downloads: [DownloadEntry] = []

    /// Aggregate offline-storage figures (used / budget / count) for the
    /// Downloads preferences pane. Refreshed alongside `downloads`.
    var downloadStats: DownloadStats?

    /// Set of track ids with an enqueue/fetch currently in flight, so the UI can
    /// show an immediate spinner before the core flips the row to `downloading`,
    /// and so a double-tap doesn't kick a second concurrent fetch.
    var downloadsInFlight: Set<String> = []

    /// In-memory played flag keyed by item id (track / album / playlist).
    /// Mirrors `favoriteById` — populated lazily from
    /// `track.userData?.played` and stamped with the server's authoritative
    /// answer after every `mark_played` / `mark_unplayed` call. Used to
    /// drive the "played" glyph in track rows and to compute the toggle
    /// target state in `toggleMarkPlayed(tracks:)`. See #133.
    var playedById: [String: Bool] = [:]

    /// Toggle the favorite flag for an album on the Jellyfin server. Reads
    /// the current state from `favoriteById` (falling back to `false` on a
    /// cold start) and calls the opposite side of `set_favorite` /
    /// `unset_favorite` on the core. The returned [`FavoriteState`] is the
    /// server's authoritative answer and is written back to `favoriteById`
    /// so the heart glyph reflects the saved state.
    ///
    /// Errors surface the generic `errorMessage` banner — a failed toggle is
    /// rare enough that swallowing it would hide real trouble (token
    /// revoked, network flapping), but not so load-bearing that we want a
    /// modal.
    func toggleFavorite(album: Album) {
        Task { await setFavorite(itemId: album.id, enabled: !isFavorite(album: album)) }
    }

    /// Toggle the favorite flag for a track. Same contract as
    /// `toggleFavorite(album:)` — see its doc for the state-cache semantics.
    func toggleFavorite(track: Track) {
        Task { await setFavorite(itemId: track.id, enabled: !isFavorite(track: track)) }
    }

    /// Check the local favorite-state cache. Returns `false` when the item
    /// hasn't been toggled this session AND no snapshot is available — the
    /// snapshot-aware overloads `isFavorite(track:)` / `isFavorite(album:)` /
    /// `isFavorite(artist:)` are preferred at call sites that have a model
    /// object on hand because they read the server-authoritative
    /// `userData.isFavorite` from the snapshot when the cache is cold.
    func isFavorite(id: String) -> Bool {
        favoriteById[id] ?? false
    }

    /// Snapshot-aware favorite check for tracks. Reads the in-memory cache
    /// first (toggled-this-session is authoritative), then falls back to
    /// the server-authoritative `track.userData?.isFavorite` projection,
    /// then to the legacy top-level `track.isFavorite` mirror. This is the
    /// preferred read for any heart-glyph UI that has the `Track` value on
    /// hand: it shows the correct state on first paint for already-favorited
    /// tracks (the cache-only `isFavorite(id:)` returns `false` until the
    /// user toggles, which makes the next tap appear to no-op against the
    /// server). See the rc6 favorite-cache seeding fix.
    func isFavorite(track: Track) -> Bool {
        if let cached = favoriteById[track.id] { return cached }
        if let userFav = track.userData?.isFavorite { return userFav }
        return track.isFavorite
    }

    /// Snapshot-aware favorite check for albums. Mirrors
    /// `isFavorite(track:)` — falls back to `album.userData?.isFavorite`
    /// when the cache is cold so the album-detail heart shows the correct
    /// state on first paint. `Album` has no legacy top-level `isFavorite`
    /// mirror so the final fallback is `false`.
    func isFavorite(album: Album) -> Bool {
        if let cached = favoriteById[album.id] { return cached }
        return album.userData?.isFavorite ?? false
    }

    /// Snapshot-aware favorite check for playlists. Mirrors
    /// `isFavorite(album:)` — falls back to `playlist.userData?.isFavorite`
    /// when the cache is cold so the playlist-detail heart shows the correct
    /// state on first paint.
    func isFavorite(playlist: Playlist) -> Bool {
        if let cached = favoriteById[playlist.id] { return cached }
        return playlist.userData?.isFavorite ?? false
    }

    /// Snapshot-aware favorite check for artists. Mirrors
    /// `isFavorite(track:)` — falls back to `artist.userData?.isFavorite`.
    func isFavorite(artist: Artist) -> Bool {
        if let cached = favoriteById[artist.id] { return cached }
        return artist.userData?.isFavorite ?? false
    }

    /// Internal helper — hits `set_favorite` / `unset_favorite` on the core
    /// and mirrors the server's answer into `favoriteById`. `internal` (not
    /// `private`) so the `toggleFavorite(...)` wrappers — some now in
    /// `AppModel+*` extension files (e.g. `AppModel+Playlists.swift`) — can
    /// route through it; the `toggleFavorite(...)` API stays the preferred
    /// entry point so the desired-state boolean is always computed at the
    /// call site.
    func setFavorite(itemId: String, enabled: Bool) async {
        Log.tracks.info("setFavorite item=\(itemId, privacy: .public) target=\(enabled, privacy: .public)")
        do {
            let state = try await Task.detached(priority: .userInitiated) { [core] in
                if enabled {
                    return try core.setFavorite(itemId: itemId)
                } else {
                    return try core.unsetFavorite(itemId: itemId)
                }
            }.value
            Log.tracks.info("setFavorite ok item=\(itemId, privacy: .public) server=\(state.isFavorite, privacy: .public)")
            favoriteById[itemId] = state.isFavorite
            favoriteChangeToken &+= 1
            serverReachability.noteSuccess()
            // If the app UI just favorited the currently-playing track, sync
            // Control Center's like indicator — only the remote-command path
            // self-refreshes otherwise (#460).
            if status.currentTrack?.id == itemId {
                mediaSession.refreshTransportState()
            }
        } catch {
            Log.tracks.error("setFavorite failed item=\(itemId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .favorite)
        }
    }

    /// Read the locally-cached played state for an item id. Mirrors
    /// `isFavorite(id:)`; used by row views + `toggleMarkPlayed(tracks:)`
    /// to compute the target state for a multi-select toggle. See #133.
    func isPlayed(id: String) -> Bool {
        playedById[id] ?? false
    }

    /// Internal helper — hits `mark_played` / `mark_unplayed` on the core
    /// and mirrors the server's answer (full `UserItemData`) into
    /// `playedById`. Mirrors `setFavorite(itemId:enabled:)` in shape so a
    /// single-item toggle has a single failure path. See #133.
    func setPlayed(itemId: String, played: Bool) async {
        do {
            let state = try await Task.detached(priority: .userInitiated) { [core] in
                try core.setPlayed(itemId: itemId, played: played)
            }.value
            playedById[itemId] = state.played
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .markPlayed)
        }
    }

    /// Download every track on the album for offline playback (#819).
    /// Resolves the album's tracks (cache-or-fetch), then hands them to the
    /// shared `downloadTracks` pipeline. Gated behind `supportsDownloads`; a
    /// no-op when the feature is dormant.
    func enqueueDownload(album: Album) {
        guard supportsDownloads else { return }
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            await downloadTracks(tracks)
        }
    }

    /// Append a batch of tracks to an existing playlist via `add_to_playlist`
    /// on the core. Used by the album detail popover (#222) and any other
    /// caller that has already resolved a target playlist. Returns `true` on
    /// success so UI can dismiss the popover / show a confirmation tick.
    ///
    /// Errors surface on `errorMessage` rather than throwing so the popover
    /// can stay presentation-only. An empty `trackIds` short-circuits before
    /// the FFI hop since the server would reject it anyway.
    @discardableResult
    func addToPlaylist(trackIds: [String], playlistId: String) async -> Bool {
        guard !trackIds.isEmpty else { return false }
        do {
            try await Task.detached(priority: .userInitiated) { [core] in
                try core.addToPlaylist(playlistId: playlistId, itemIds: trackIds, position: nil)
            }.value
            serverReachability.noteSuccess()
            return true
        } catch {
            if handleAuthError(error) { return false }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playlistAdd)
            return false
        }
    }

    /// Fetch the album's hydrated detail fields (label, premiere date, and
    /// aggregated People credits) via `fetch_item`. Returned as a compact
    /// [`AlbumDetail`] value type so the view layer can render the
    /// liner-note credits section (#65) without a second parse pass.
    ///
    /// Silent on errors: the liner-note section degrades to whatever fields
    /// are present on the cached `Album` so a 404 or a stripped-down server
    /// doesn't take down the whole detail page.
    func loadAlbumDetail(albumId: String) async -> AlbumDetail {
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: albumId,
                    fields: ["People", "Studios", "PremiereDate", "DateCreated", "ProductionYear", "Overview"]
                )
            }.value
            return Self.parseAlbumDetail(from: json)
        } catch {
            _ = handleAuthError(error)
            return AlbumDetail(label: nil, releaseDate: nil, people: [], overview: nil)
        }
    }

    /// Parse the subset of the album item JSON that the liner-note section
    /// cares about. Static + internal so tests can hit it without wiring
    /// the full model. Missing fields become `nil`; the parser never throws.
    static func parseAlbumDetail(from json: String) -> AlbumDetail {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AlbumDetail(label: nil, releaseDate: nil, people: [], overview: nil)
        }

        // Jellyfin ships `Studios` as an array of `{ Name, Id }` objects. Pick
        // the first non-empty label — servers with multiple labels tend to
        // list the primary one first.
        let label: String? = {
            guard let studios = root["Studios"] as? [[String: Any]] else { return nil }
            for entry in studios {
                if let name = entry["Name"] as? String {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }()

        // `PremiereDate` is an ISO 8601 string; fall back to `DateCreated`
        // if absent. We only keep the yyyy-MM-dd portion since the hero
        // already shows the year and the liner-note section wants "Released
        // 19 Apr 2013".
        let releaseDate: Date? = {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for key in ["PremiereDate", "DateCreated"] {
                if let raw = root[key] as? String, !raw.isEmpty {
                    if let d = iso.date(from: raw) { return d }
                    iso.formatOptions = [.withInternetDateTime]
                    if let d = iso.date(from: raw) { return d }
                }
            }
            return nil
        }()

        let people: [Person] = {
            guard let raw = root["People"] as? [[String: Any]] else { return [] }
            return raw.compactMap { entry in
                let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let type = (entry["Type"] as? String) ?? ""
                let rawId = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let id = rawId.isEmpty ? nil : rawId
                guard !name.isEmpty else { return nil }
                return Person(name: name, type: type, id: id)
            }
        }()

        // Editorial blurb (#68). Kept raw here — the album detail view runs it
        // through the same HTML strip as the artist bio before display.
        // Whitespace-only collapses to `nil` so the "About this album" section
        // never renders an empty shell.
        let overview: String? = {
            guard let raw = root["Overview"] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : raw
        }()

        return AlbumDetail(label: label, releaseDate: releaseDate, people: people, overview: overview)
    }

    /// Navigate to the artist detail screen for this album's artist, if known.
    func goToArtist(album: Album) {
        guard let artistID = album.artistId else { return }
        navPath.append(Route.artist(artistID))
    }

    /// Navigate to the album's own detail screen. Used when the menu is
    /// invoked from a surface other than the album detail itself (e.g. a
    /// track row that links back to its album).
    func goToAlbum(album: Album) {
        navPath.append(Route.album(album.id))
    }

    /// Kick off an Instant Mix ("album radio") seeded by this album.
    func startAlbumRadio(album: Album) {
        playInstantMix(seedId: album.id)
    }

    /// Mark the album as played server-side. Matches Jellyfin web's
    /// "Mark Played" affordance: the album's `UserData.Played` flips and
    /// `LastPlayedDate` stamps, but per-track `PlayCount` is **not**
    /// incremented (Jellyfin doesn't cascade the operation to children).
    /// `playedById[album.id]` flips immediately for the optimistic glyph
    /// flip, then reconciles with the server's authoritative response. See #133.
    func markAllAsPlayed(album: Album) {
        let target = !isPlayed(id: album.id)
        playedById[album.id] = target
        Task { await setPlayed(itemId: album.id, played: target) }
    }

    /// Append every track on the album to a user-picked playlist. Loads
    /// the tracklist (cached) then routes through the async
    /// `addToPlaylist(trackIds:playlistId:)` path.
    func addAlbumToPlaylist(album: Album, playlist: Playlist) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            await addToPlaylist(trackIds: tracks.map(\.id), playlistId: playlist.id)
        }
    }

    // MARK: - Track info sheet

    /// Track being shown in the info sheet, or `nil` when the sheet is
    /// dismissed. Mounted via `.sheet(item:)` on `MainShell` so any screen
    /// can request the modal without owning a presentation anchor. See #95.
    var trackInfoSubject: Track?

    // MARK: - Genre / radio state

    /// Cache of /MusicGenres results keyed by display name → Jellyfin UUID.
    /// Populated lazily on the first genre-action call. ~291 entries on a
    /// real library — one page of 500 covers it. The Swift `Genre` carries
    /// `id == name` because Album/Artist records only ship the bare name,
    /// so this map is the only path to the real UUID. Stored as a flat
    /// `[String: String]` rather than `[String: LyrebirdCore.Genre]` to
    /// avoid the module/class name collision — `LyrebirdCore.Genre` parses
    /// as a member of the `LyrebirdCore` *class* (which doesn't have one)
    /// rather than the `LyrebirdCore` *module*. The UUID is the only field
    /// we need anyway. `internal` (not `private`) so the moved
    /// `resolvedGenreId` in `AppModel+Genre.swift` can populate/read it.
    var _genreIdsByName: [String: String] = [:]
    var _genresLoaded: Bool = false

    /// Subset of `Mood.all` whose tag returns at least one track in this
    /// library. Empty until `probeAvailableMoods()` runs; the Mood radio row
    /// hides itself while empty so a library with no mood tags doesn't render
    /// a dead band. Moods are sourced from tags "if present" per the spec.
    var availableMoods: [Mood] = []

}

// MARK: - Queue models (BATCH-07a)

/// One entry in the Queue Inspector's lists. Thin wrapper around `Track`
/// that carries a per-instance `queueId` so the same track can be queued
/// more than once and still be individually addressable by `onMove` /
/// remove. `Track.id` is the Jellyfin item id and would collide on repeats.
struct Queue: Identifiable, Hashable {
    /// Stable per-queue-instance id. Not the track id — see struct doc.
    let id: UUID
    /// Underlying audio track.
    let track: Track

    init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}

/// Source that populated the current auto-queue tail — what the inspector's
/// "PLAYING FROM {source}" header describes. Kept minimal on purpose; #82
/// and BATCH-07b will flesh out the richer label / link treatment.
struct QueueContext: Hashable {
    /// Display name (e.g. album title, playlist name, artist name).
    let name: String
    /// Jellyfin item id for the source, when known. Nil for ad-hoc
    /// selections (e.g. shuffle-all-favorites) without a single target.
    let id: String?
    /// What kind of surface started playback. Drives the icon + route
    /// behavior the header uses when the user clicks the source label.
    let sourceType: ContextSourceType
}

/// Classification of what started the current playback. See `QueueContext`.
enum ContextSourceType: String, Hashable {
    case album
    case playlist
    case artist
    case genre
    case search
    case radio
    case other
}

/// One batch of tracks removed from a playlist, kept around long enough for
/// the `PlaylistDetailView` undo toast to restore them. See #74.
struct PendingRemoval {
    let playlistId: String
    let tracks: [Track]
}

// MARK: - Convenience

extension Track {
    var durationSeconds: Double {
        Double(runtimeTicks) / 10_000_000.0
    }
    var durationFormatted: String {
        DurationFormatter.colon(durationSeconds)
    }
    /// Spelled-out duration ("3 minutes 5 seconds") for VoiceOver
    /// `accessibilityValue` on track-duration labels. See #349.
    var durationAccessibilityValue: String {
        DurationFormatter.spokenAccessibility(durationSeconds)
    }
}

// `.sheet(item:)` requires Identifiable; Track's `id: String` already plays
// the role so the conformance is a one-liner. Used by the track-info sheet
// (#95) and any future per-track modal driven off optional `Track?` state.
extension Track: @retroactive Identifiable {}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Client-side genre record used by the full search page and the instant-mix
/// seed picker. Jellyfin returns genres as bare strings on `Album`/`Artist`
/// today, so an `id` is derived from the name until a proper `MusicGenre`
/// item shape lands in core (see `GenreContextMenu`'s TODO for #823).
struct Genre: Hashable, Identifiable, Sendable {
    let id: String
    let name: String

    init(name: String) {
        self.name = name
        // Name doubles as id — genres are unique by label in Jellyfin's
        // surface and we don't have the real collection ids yet.
        self.id = name
    }

    /// Memberwise init used by the Wave 2 name→UUID resolver
    /// (`AppModel.resolvedGenreId(forName:)`): once the real Jellyfin id has
    /// been fetched from `/MusicGenres`, we rebuild the Swift `Genre` with
    /// the real UUID in `id` so downstream FFI calls (`tracksByGenre`,
    /// `itemsByGenre`, `instantMix`) get a UUID instead of the display
    /// name. See #823 Wave 2.
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Heterogeneous search "thing". Wraps the four core record types plus
/// `Genre` so a single callback can carry enough context for routing
/// (navigate vs. play) without per-type callbacks. Used by the full search
/// page (`SearchView`) and the instant-mix seed picker (`InstantMixSheet`).
///
/// `title` / `playCount` are derived so any generic ranking / comparison
/// over a mixed candidate list stays type-agnostic.
enum SearchItem: Hashable, Sendable {
    case artist(Artist)
    case album(Album)
    case track(Track)
    case playlist(Playlist)
    case genre(Genre)

    var id: String {
        switch self {
        case .artist(let a): return "artist:\(a.id)"
        case .album(let a): return "album:\(a.id)"
        case .track(let t): return "track:\(t.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        case .genre(let g): return "genre:\(g.id)"
        }
    }

    var title: String {
        switch self {
        case .artist(let a): return a.name
        case .album(let a): return a.name
        case .track(let t): return t.name
        case .playlist(let p): return p.name
        case .genre(let g): return g.name
        }
    }

    /// Human-readable type label rendered on the hero card. "Artist" /
    /// "Album" / "Track" / "Playlist" / "Genre" per the spec in #243.
    var typeLabel: String {
        switch self {
        case .artist: return "Artist"
        case .album: return "Album"
        case .track: return "Track"
        case .playlist: return "Playlist"
        case .genre: return "Genre"
        }
    }

    /// Play count used as the secondary ranking key. Only tracks carry
    /// one today; everything else returns 0 so the comparator still does
    /// the right thing in a generic `.min(by:)`.
    var playCount: UInt32 {
        if case .track(let t) = self { return t.playCount }
        return 0
    }
}

/// Hydrated album fields fetched on demand by
/// `AppModel.loadAlbumDetail(albumId:)`. Lives in the AppModel file because
/// its parser does; the album detail screen is the only consumer today.
struct AlbumDetail: Equatable {
    /// First non-empty entry in Jellyfin's `Studios` array — treated as the
    /// record label in the liner-note section. `nil` when the field is
    /// absent or empty.
    let label: String?
    /// Album release date parsed from `PremiereDate` (falling back to
    /// `DateCreated`). `nil` when neither is parseable, in which case the
    /// liner-note section leans on the cached `Album.year` for "Released".
    let releaseDate: Date?
    /// Aggregated `People` array from the album item — composers,
    /// producers, mixers, engineers, etc. The album detail view groups
    /// these by role. Empty when the server didn't populate `People` (a
    /// surprising number don't).
    let people: [Person]
    /// Editorial blurb from Jellyfin's album `Overview` field (populated
    /// by metadata plugins such as TheAudioDB / MusicBrainz). May carry
    /// light HTML; the view HTML-strips it before display and hides the
    /// "About this album" section entirely when it's `nil`/empty (#68).
    let overview: String?
}

// MARK: - Full search page types
//
// Types owned by the full `SearchView` page. Kept in the AppModel file so
// the ranker / bucketer that produce them live in the same place as the
// state they drive.

/// Scope chip on the full search page. Distinct from any instant-dropdown
/// scoping — this is the "I committed to a search, now let me filter
/// sections" tab. Spec: #242.
///
/// `storageKey` is the string used as the `searchPageResults` dictionary
/// key. `All` is a virtual scope that unions the typed buckets, so it
/// doesn't correspond to a storage bucket.
enum SearchScope: String, Hashable, CaseIterable, Sendable {
    case all
    case artists
    case albums
    case tracks
    case playlists
    case genres

    /// Label rendered on the chip and in accessibility text.
    var label: String {
        switch self {
        case .all: return "All"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .tracks: return "Tracks"
        case .playlists: return "Playlists"
        case .genres: return "Genres"
        }
    }

    /// Key into `AppModel.searchPageResults`. `all` has no bucket — the
    /// page renders every scope's bucket in sequence when `.all` is active.
    var storageKey: String {
        rawValue
    }

    /// Section header copy shown above the bucket on the full page. Singular
    /// vs plural matches the label; kept as a property so copy changes land
    /// in one place.
    var sectionHeader: String {
        label
    }

    /// Whether this scope's rows come from the server's paged `search`
    /// response (so a "Load more" can fetch a follow-up page), or are
    /// derived / not-yet-paged locally (so "Load more" can only ever
    /// reveal more of the already-buffered bucket). Genres are harvested
    /// client-side from album/artist `genres`; playlists aren't returned
    /// by `core.search` at all. Both must ignore the global server
    /// has-more signal, otherwise their button would be perpetual.
    var isServerPaged: Bool {
        switch self {
        case .artists, .albums, .tracks, .all: return true
        case .genres, .playlists: return false
        }
    }
}

// NOTE: `SearchItem` is defined above with `case genre(Genre)`. The
// full-page search surface below uses that same type — the duplicate
// `case genre(String)` variant originally added here was collapsed into the
// canonical enum when #535 (which introduced `Genre`) landed alongside this PR.

// MARK: - MediaSessionDelegate

/// Bridge between `MediaSession` (owns MPNowPlayingInfoCenter and
/// MPRemoteCommandCenter) and the rest of the app. Keeping the command
/// handlers here means a Bluetooth headset, Control Center click, or media
/// key all run the exact same code path as the on-screen buttons — no
/// duplicate transport logic. See issues #29 / #31.
extension AppModel: MediaSessionDelegate {
    var currentStatus: PlayerStatus { status }

    func mediaSessionTogglePlayPause() { togglePlayPause() }
    func mediaSessionPlay() {
        // Remote "play" may fire after a pause (resume) or at end-of-track
        // (restart). Reuse the existing togglePlayPause logic so the two
        // cases stay in one place.
        switch status.state {
        case .playing: return
        case .paused: resume()
        case .ended, .stopped, .idle, .loading:
            if let track = status.currentTrack {
                playCurrent(track)
            }
        }
    }
    func mediaSessionPause() { pause() }
    func mediaSessionStop() { stop() }
    func mediaSessionSkipNext() { skipNext() }
    func mediaSessionSkipPrevious() { skipPrevious() }
    func mediaSessionSeek(toSeconds seconds: Double) { audio.seek(toSeconds: seconds) }

    func mediaSessionSetShuffle(_ on: Bool) {
        // Push the flag into the core so `PlayerStatus.shuffle` stays the
        // source of truth for every surface (Queue Inspector header,
        // menu-bar toggle, Control Center). The platform layer doesn't
        // reorder the queue here — that's up to whatever fed the queue in
        // the first place.
        core.setShuffle(on: on)
        refreshStatus()
        // Mirror the new mode out to Control Center / AVRCP. The remote-command
        // callbacks self-refresh, but this method is also driven by the command
        // palette and the Queue Inspector header, which are not (#460).
        mediaSession.refreshTransportState()
    }

    func mediaSessionSetRepeatMode(_ mode: RepeatMode) {
        core.setRepeatMode(mode: mode)
        refreshStatus()
        mediaSession.refreshTransportState()
    }

    func mediaSessionToggleFavorite() -> Bool? {
        // The command fires against the currently-playing track; without
        // one we signal `.noActionableNowPlayingItem` back to the remote
        // surface via a `nil` return.
        guard let track = status.currentTrack else { return nil }
        let previous = isFavorite(track: track)
        let target = !previous
        // Optimistic local update so the heart glyph responds instantly.
        favoriteById[track.id] = target
        let trackId = track.id
        Task {
            do {
                let state = try await Task.detached(priority: .userInitiated) { [core] in
                    if target {
                        return try core.setFavorite(itemId: trackId)
                    } else {
                        return try core.unsetFavorite(itemId: trackId)
                    }
                }.value
                favoriteById[trackId] = state.isFavorite
                serverReachability.noteSuccess()
                // Reconcile the remote-command surface with the server's
                // authoritative answer (handles the edge case where the server
                // disagrees with the local optimistic flip).
                MPRemoteCommandCenter.shared().likeCommand.isActive = state.isFavorite
            } catch {
                if handleAuthError(error) { return }
                // Rollback the optimistic flip — restore the previous state
                // in both the local cache and the Control Center widget.
                favoriteById[trackId] = previous
                MPRemoteCommandCenter.shared().likeCommand.isActive = previous
                errorMessage = "Favorite toggle failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
        return target
    }

    func mediaSessionCurrentTrackIsFavorite() -> Bool {
        guard let track = status.currentTrack else { return false }
        // Snapshot-aware read: cache (toggled-this-session) → server snapshot
        // → legacy mirror. The core doesn't update the playing track's
        // `isFavorite` on a toggle, so this is fresher than the raw snapshot.
        return isFavorite(track: track)
    }

    func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL? {
        imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: maxWidth)
    }
    func mediaSessionAuthorizationHeader() -> String? {
        try? core.authHeader()
    }
}

// MARK: - AudioEngine transport callbacks

extension AppModel: AudioEngineDelegate {
    func audioEngineDidStall() {
        errorMessage = "Stalled, retrying…"
    }

    func audioEngineDidFail(_ message: String) {
        errorMessage = message
    }

    /// Stall recovery rebuilds the current item via `replaceCurrentItem`,
    /// which evicts any pre-loaded next-track item from the queue. Re-arm
    /// gapless playback by preloading the upcoming track again — the same
    /// core-queue lookahead (`nextTrackForPreload`) the normal end-of-track
    /// advance uses, so both paths splice the track that actually plays next.
    func audioEngineDidRecover() {
        armNextTrackPreload()
    }
}

// MARK: - MediaSession status nudge

extension AppModel {
    /// Pull the latest `PlayerStatus` snapshot out of the core and hand it
    /// to `MediaSession` so the remote-control surface reflects any
    /// just-applied change (shuffle, repeat, favorite). The polling timer
    /// refreshes this on a cadence, but command handlers want the round-trip
    /// to feel synchronous — without this, Control Center's shuffle toggle
    /// can flicker back to the previous state on the next redraw.
    fileprivate func refreshStatus() {
        self.status = core.status()
    }
}
