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
    var scopedSearchFocusToken: Int = 0

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
    let searchPagePageSize: UInt32 = 100

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
    let libraryInitialPageSize: UInt32 = 100
    /// Follow-up page size for library lists. Larger than the initial page
    /// to keep round-trip count down once the user has committed to scrolling.
    let libraryPageSize: UInt32 = 200
    /// Initial page size for recently-played on the Home screen.
    let recentlyPlayedInitialPageSize: UInt32 = 20
    /// Page size when walking `playlist_tracks` to completion.
    let playlistPageSize: UInt32 = 200
    /// Hard cap on total tracks pulled from a single playlist to keep a
    /// pathological 50k-track playlist from holding the UI hostage. Callers
    /// that hit this see up to this many tracks; beyond that the rest is
    /// silently dropped. Easy to raise once a real use case complains.
    let playlistSafetyCap: Int = 5000
    /// Page size for the "Show all results" affordance in search.
    let searchPageSize: UInt32 = 50

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

    /// Monotonic counter bumped on every fresh `play(tracks:)`. Async radio
    /// entry points capture it before their FFI hop and re-check it after, so
    /// a slow Instant Mix that resolves *after* the user already started an
    /// album/playlist doesn't clobber that newer queue or stamp a stale
    /// `.radio` label onto it.
    var playbackGeneration: UInt64 = 0

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

    /// The device name Jellyfin sees for this client (the `Device="…"` auth
    /// header field). Seeded from the core in `init()` — which itself prefers a
    /// previously user-edited value persisted in the DB over the host-derived
    /// default — and edited via the login gear popover through
    /// `updateDeviceName(_:)` (#202).
    var deviceName: String = ""

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
    static let miniPlayerAlwaysOnTopKey = "miniPlayer.alwaysOnTop"

    /// UserDefaults key for the persisted transparent-when-inactive preference.
    /// Same `@Observable` → UserDefaults bridge as the always-on-top flag.
    static let miniPlayerTransparentWhenInactiveKey = "miniPlayer.transparentWhenInactive"

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

    /// Whether the Mini Player fades to semi-transparent when the app loses
    /// focus. Persisted across launches; write through
    /// `setMiniPlayerTransparentWhenInactive(_:)`. `MiniPlayerWindowConfigurator`
    /// reads this and re-applies `NSWindow.alphaValue` on
    /// `NSApplication.didBecomeActiveNotification` /
    /// `NSApplication.didResignActiveNotification`.
    var miniPlayerTransparentWhenInactive: Bool = UserDefaults.standard.bool(
        forKey: AppModel.miniPlayerTransparentWhenInactiveKey
    )

    // MARK: - Autoplay (queue end)

    /// UserDefaults key for the persisted "autoplay similar music when the
    /// queue ends" preference. Same `@Observable` → UserDefaults bridge as
    /// the mini-player flag above.
    static let autoplayWhenQueueEndsKey = "queue.autoplayWhenQueueEnds"

    /// Whether playback should extend with an Instant Mix of similar music
    /// when the user-added queue and its source tail run dry. Default **on**
    /// to match Apple Music / Spotify's endless-listening behaviour; users
    /// who dislike endless autoplay flip it off in the queue header and
    /// playback simply stops at the end of what they queued. Persisted across
    /// launches; read through `autoplayWhenQueueEndsDefault` so an unset key
    /// resolves to `true` rather than `bool(forKey:)`'s `false`.
    var autoplayWhenQueueEnds: Bool = AppModel.autoplayWhenQueueEndsDefault()

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
            config: CoreConfig(dataDir: "", deviceName: AppModel.defaultDeviceName())
        )
        self.core = core
        // The core prefers a previously user-edited name (persisted in its DB)
        // over the host-derived default we just passed, so read the resolved
        // value back rather than re-deriving it here (#202).
        self.deviceName = core.deviceName()
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
        // Streaming quality (#260): seed the engine's transcode ceiling from the
        // persisted Streaming Quality preference so the first track honours it
        // without waiting for a `play(tracks:)`. Defaults to 320 kbps when the
        // feature is gated off, leaving the streaming path unchanged.
        self.audio.maxStreamingBitrate = resolvedStreamingBitrate
    }

    /// Internal guard for `attemptRestoreSession` — the restore pass should
    /// run exactly once per app lifetime. Separate from `isRestoringSession`
    /// so the UI flag can be flipped without gating re-entry, and vice-versa.
    var hasAttemptedRestore = false

    // MARK: - Items query helpers

    /// Per-session cache for `artistDetail`. Cleared on `logout()` / `forgetToken()`.
    var artistDetailCache: [String: ArtistDetail] = [:]

    /// Album/artist id → display name, seeded by `resolveAlbum` / `resolveArtist`
    /// when they resolve an id past the loaded library page. The breadcrumb
    /// builder reads this so a drill destination reached from outside
    /// `albums` / `artists` (recently played, discography, genre detail) shows
    /// its name instead of "…". Cleared on `logout()` / `forgetToken()`.
    var resolvedNameCache: [String: String] = [:]

    /// Per-session cache for `loadArtistAlbums`. Cleared on `logout()`.
    var artistAlbumsCache: [String: [Album]] = [:]

    /// Per-session cache for `loadArtistAppearsOnAlbums` (the "Appears On"
    /// rail — albums the artist guests on, #224). Cleared on `logout()`.
    var artistAppearsOnCache: [String: [Album]] = [:]

    /// Memoized cache keyed on (itemID, tag, maxWidth). Each grid cell calls
    /// `imageURL` during every scroll-driven body recomputation; without this
    /// cache every cell crosses the UniFFI boundary (Swift → C → Rust) and
    /// locks `Inner` — an O(n) mutex hit per frame that serialized against
    /// every background `loadMore*` and caused the main-thread beach ball.
    /// The URL string is deterministic for a given (itemID, tag, maxWidth),
    /// so one FFI crossing per tuple is all we ever need.
    var imageURLCache: [String: URL?] = [:]

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
    var ambientPaletteCache: [String: String] = [:]

    /// In-flight palette samples, so two `NowPlayingView.task` invocations for
    /// the same id (e.g. a fast tab toggle) coalesce onto one Nuke decode +
    /// CIAreaAverage pass instead of racing two.
    var ambientPaletteTasks: [String: Task<AmbientPalette?, Never>] = [:]

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
