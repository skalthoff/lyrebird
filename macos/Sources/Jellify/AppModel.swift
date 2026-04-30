import AppKit
import Foundation
import MediaPlayer
import Observation
import os
import SwiftUI
@preconcurrency import JellifyCore
import JellifyAudio

/// Top-level app state. Owns the Rust core and publishes a reactive surface
/// that SwiftUI views observe. All core calls go through here so views never
/// touch the FFI directly.
@Observable
@MainActor
final class AppModel {
    // MARK: - Core
    let core: JellifyCore
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
    enum Screen: Hashable { case home, discover, library, favorites, search, settings }
    var screen: Screen = .library

    /// Typed value-type for `NavigationStack` destinations. Root tabs and
    /// drill destinations are both representable so `Route` can address
    /// any surface in the app, but in production the path only ever
    /// holds drill entries — the active tab is `screen`. See #1 / #4.
    enum Route: Hashable {
        case home
        case discover
        case library
        case favorites
        case search
        case settings
        case album(String)
        case artist(String)
        case playlist(String)
        case nowPlaying
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
    /// Used by the ⌘L menu toggle (see `JellifyApp.toggleNowPlaying`) so
    /// the second press pops back rather than stacking another copy.
    var isShowingNowPlaying: Bool {
        navPath.last == .nowPlaying
    }

    /// Which chip is active on the Library screen. Driven by the sidebar's
    /// "Albums / Artists / Playlists" libRows so they can deep-link into a
    /// specific tab rather than always landing on the default. `LibraryView`
    /// mirrors this into its local `@State` on appear and writes back on
    /// user-chip-change so the sidebar selection persists across navigation.
    var libraryTab: LibraryTab = .albums

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
    var recentlyPlayed: [Track] = []
    /// Tracks surfaced in the Discover "For You" carousel (#249). Today this
    /// is a best-effort fallback to the first 20 `recentlyPlayed` tracks. A
    /// real recommendations endpoint — seeded from listening history, minus
    /// already-played items, leaning on similar artists — is tracked as a
    /// follow-up on the core (no FFI exists yet; see `refreshForYou()` for
    /// the TODO).
    var forYou: [Track] = []
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
    /// Server-curated "You might like" tracks for the Home discovery row
    /// (#145). Backed by `core.suggestions()`, which hits Jellyfin's
    /// `/Items/Suggestions` endpoint. Up to 20 tracks. Hidden until data
    /// arrives so first-time users don't see an empty shelf.
    var suggestions: [Track] = []
    var searchResults: SearchResults?
    var searchQuery: String = ""

    /// Instant-search payload rendered by `SearchInstantDropdown` while the
    /// user is typing in the toolbar / search field. Distinct from
    /// `searchResults` (which backs the full Search screen) so a live
    /// dropdown and the committed "see all results" surface don't trample
    /// each other. Always safe to read — empty until a non-empty query
    /// arrives. See #85 / #241 / #243.
    var instantSearchResults: InstantSearchResults = .empty

    /// In-flight debounced instant-search task. Published so re-entrant
    /// callers (each keystroke invokes `runInstantSearch`) can cancel the
    /// previous pass before kicking off a new one. Storing the handle as
    /// state rather than a local makes the cancel-previous pattern trivial
    /// regardless of which view / keystroke triggered the original fetch.
    var searchTask: Task<Void, Never>?

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

    /// The query that drove `searchPageResults`. Stored separately from
    /// `searchQuery` so the page doesn't race with whatever the instant
    /// dropdown is showing when that surface lands.
    var searchPageQuery: String = ""

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
    /// Cmd+Opt+Q shortcut (#79).
    var isQueueInspectorOpen: Bool = false

    /// Contributors on the currently-playing track, sourced from Jellyfin's
    /// `Item.People` field. Populated by `fetchCurrentTrackDetails()` on
    /// track changes and cleared when the track stops. See #279.
    var currentTrackPeople: [Person] = []
    /// The track id that `currentTrackPeople` was fetched for, so we can
    /// skip redundant network calls when the status poll fires with the
    /// same track still playing.
    private var currentTrackPeopleForId: String?

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
    private var currentLyricsForId: String?

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
    static let sidebarNewPlaylistSentinel = "__jellify_new_playlist__"

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

    // MARK: - Command Palette (⌘K)

    /// Whether the command-palette overlay is currently visible. Toggled by
    /// the ⌘K menu command and by the palette itself on Esc / row commit.
    /// Driven out of `AppModel` rather than `MainShell` so the overlay can
    /// sit above every screen (Home, Library, Now Playing, and the auth
    /// sheet's host) from one place, and so the menu command doesn't need a
    /// SwiftUI `@Environment(AppModel.self)` round-trip. See #305 / #306 /
    /// #307 / #309.
    var isCommandPaletteOpen: Bool = false

    /// A single verb entry in the command palette's action list. See
    /// `paletteActions` for the live roster and `executePaletteAction(id:)`
    /// for the dispatcher. Actions are intentionally held by id + closure
    /// rather than by enum so the registry can grow without rippling
    /// through view code. See #307.
    struct PaletteAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let symbol: String
        let run: () -> Void
    }

    /// Static verb list surfaced by the command palette. Computed so the
    /// play/pause entry swaps labels based on the current playback state —
    /// re-evaluated on every palette render since the model publishes
    /// `status` changes. See #307.
    var paletteActions: [PaletteAction] {
        let isPlaying = status.state == .playing
        let hasTrack = status.currentTrack != nil
        var actions: [PaletteAction] = []

        // Transport. "Play" / "Pause" swap so the user sees the action that
        // actually fires rather than a generic "Toggle Play/Pause".
        if hasTrack {
            if isPlaying {
                actions.append(PaletteAction(
                    id: "playback.pause",
                    title: "Pause",
                    symbol: "pause.fill",
                    run: { [weak self] in self?.pause() }
                ))
            } else {
                actions.append(PaletteAction(
                    id: "playback.play",
                    title: "Play",
                    symbol: "play.fill",
                    run: { [weak self] in self?.togglePlayPause() }
                ))
            }
        } else {
            // No loaded track — still surface "Play" so ⌘K → Play has a
            // landing pad (it's a no-op until a track is loaded). Using
            // `togglePlayPause` keeps the behavior consistent with the
            // Space-bar shortcut (both no-op in this state).
            actions.append(PaletteAction(
                id: "playback.play",
                title: "Play",
                symbol: "play.fill",
                run: { [weak self] in self?.togglePlayPause() }
            ))
        }
        actions.append(PaletteAction(
            id: "playback.playNext",
            title: "Play Next",
            symbol: "text.line.first.and.arrowtriangle.forward",
            run: { [weak self] in
                guard let track = self?.status.currentTrack else { return }
                self?.playNext(tracks: [track])
            }
        ))
        actions.append(PaletteAction(
            id: "playback.addToQueue",
            title: "Add to Queue",
            symbol: "text.badge.plus",
            run: { [weak self] in
                guard let track = self?.status.currentTrack else { return }
                self?.addToQueue(tracks: [track])
            }
        ))

        // Navigation. Keep parity with the Go menu (⌘1 / ⌘2 / Discover).
        actions.append(PaletteAction(
            id: "nav.library",
            title: "Go to Library",
            symbol: "music.note.list",
            run: { [weak self] in self?.selectTab(.library) }
        ))
        actions.append(PaletteAction(
            id: "nav.home",
            title: "Go to Home",
            symbol: "house",
            run: { [weak self] in self?.selectTab(.home) }
        ))
        actions.append(PaletteAction(
            id: "nav.discover",
            title: "Go to Discover",
            symbol: "sparkles",
            run: { [weak self] in self?.goToDiscover() }
        ))
        actions.append(PaletteAction(
            id: "nav.favorites",
            title: "Go to Favorites",
            symbol: "heart",
            run: { [weak self] in self?.selectTab(.favorites) }
        ))

        // Preferences. macOS exposes the Settings scene through the standard
        // Application menu (⌘,); from the palette we mirror that by opening
        // the scene directly rather than routing through `screen = .settings`
        // (which is unused today).
        actions.append(PaletteAction(
            id: "app.openPreferences",
            title: "Open Preferences",
            symbol: "gearshape",
            run: {
                // `showSettingsWindow:` is the documented selector for
                // opening the Settings scene from outside a menu command.
                // Fall back to the legacy Preferences selector for older
                // macOS versions that don't respond to the newer one.
                if #available(macOS 14, *) {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                } else {
                    NSApp.sendAction(
                        Selector(("showPreferencesWindow:")),
                        to: nil,
                        from: nil
                    )
                }
            }
        ))

        // Playback toggles (#34): flip shuffle / cycle repeat via the
        // palette entries. Both feed the same core setters that Control
        // Center's `MPChangeShuffleModeCommand` / `MPChangeRepeatModeCommand`
        // handlers drive, so all three surfaces stay consistent.
        actions.append(PaletteAction(
            id: "playback.toggleShuffle",
            title: "Toggle Shuffle",
            symbol: "shuffle",
            run: { [weak self] in
                guard let self else { return }
                self.mediaSessionSetShuffle(!self.status.shuffle)
            }
        ))
        actions.append(PaletteAction(
            id: "playback.toggleRepeat",
            title: "Toggle Repeat",
            symbol: "repeat",
            run: { [weak self] in
                guard let self else { return }
                // Cycle off -> all -> one -> off to match Apple Music's
                // long-press menu ordering — "all" is the most frequently
                // wanted step up from "off".
                let next: RepeatMode = {
                    switch self.status.repeatMode {
                    case .off: return .all
                    case .all: return .one
                    case .one: return .off
                    }
                }()
                self.mediaSessionSetRepeatMode(next)
            }
        ))

        // Queue verb — wired via core.clearQueue (#282).
        actions.append(PaletteAction(
            id: "queue.clear",
            title: "Clear Queue",
            symbol: "trash",
            run: { [weak self] in
                // #282: wipe the queue but keep the currently playing track
                // as a single-item queue so playback doesn't stop.
                self?.core.clearQueue()
                if let core = self?.core {
                    self?.status = core.status()
                }
            }
        ))
        if supportsDownloads {
            actions.append(PaletteAction(
                id: "download.current",
                title: "Download Current",
                symbol: "arrow.down.circle",
                run: { [weak self] in
                    guard self?.status.currentTrack != nil else { return }
                    // TODO(#70): wire to the download engine once it lands.
                    Log.app.notice("Download Current — not yet wired (see #70)")
                }
            ))
        }

        return actions
    }

    /// Look up a palette action by id and run it. Called by `CommandPalette`
    /// on ↩ commit. Also closes the palette on success, mirroring the
    /// "execute and dismiss" behavior users expect from Spotlight-style
    /// launchers. See #307.
    func executePaletteAction(id: String) {
        guard let action = paletteActions.first(where: { $0.id == id }) else { return }
        action.run()
        isCommandPaletteOpen = false
    }

    init() throws {
        let core = try JellifyCore(
            config: CoreConfig(dataDir: "", deviceName: "Jellify macOS")
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
        } catch {
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .login)
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
        artistAlbumsCache = [:]
        recentlyPlayed = []
        forYou = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        suggestions = []
        searchResults = nil
        searchQuery = ""

        instantSearchResults = .empty
        searchTask?.cancel()
        searchTask = nil
        searchPageResults = [:]
        searchPageQuery = ""
        activeSearchScope = .all
        searchPageTotal = 0
        searchPageLoaded = 0
        isLoadingFullSearch = false

        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
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
        artistAlbumsCache = [:]
        recentlyPlayed = []
        forYou = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        suggestions = []
        searchResults = nil
        searchQuery = ""

        instantSearchResults = .empty
        searchTask?.cancel()
        searchTask = nil
        searchPageResults = [:]
        searchPageQuery = ""
        activeSearchScope = .all
        searchPageTotal = 0
        searchPageLoaded = 0
        isLoadingFullSearch = false

        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
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
    /// Post-BATCH-24 the Rust `JellifyError` is a typed enum split by HTTP
    /// class — 401 responses surface as `Auth`, the retry-layer fallback is
    /// `AuthExpired`, and a missing token is `NotAuthenticated` — so we can
    /// match variants directly instead of parsing the Display message.
    ///
    /// Call-sites that do NOT match auth go on to call
    /// `JellifyErrorPresenter.message(for:context:)` (see #351) to turn the
    /// raw Display string into localized banner copy.
    private func handleAuthError(_ error: Error) -> Bool {
        guard let err = error as? JellifyError else { return false }
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
        }
        if anySucceeded {
            serverReachability.noteSuccess()
        }
        _ = await playlistsResult
        await refreshRecentlyPlayed()
        await refreshForYou()
        // Home screen carousels (#49 / #51–#55). Kicked off after the main
        // library so first paint isn't blocked on these secondary shelves.
        // Each of these is best-effort — empty or errored rows just hide in
        // the Home layout.
        await refreshJumpBackIn()
        await refreshRecentlyAdded()
        await refreshQuickPicks()
        await refreshFavoriteAlbums()
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
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
            self.errorMessage = JellifyErrorPresenter.message(for: error, context: .playlistsLoad)
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .playlistLoad)
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

    // MARK: - Home carousels (#49 / #51–#55)
    //
    // The Home carousels (#51 Jump Back In, #52 Recently Played, #53 Quick
    // Picks, #54 Recently Added, #55 Favorites) each need an `/Items` query
    // with a different `SortBy` / `Filters` combination. The core exposes
    // `list_albums` / `latest_albums` / `recently_played` for the
    // un-filtered variants, but the three new album-level shelves
    // (Jump Back In, Quick Picks, Favorites) rely on filter knobs the
    // core's current FFI doesn't expose. Rather than block Home on a new
    // `items_query` builder (BATCH-24), we inline the raw HTTP call here
    // via the session URL + `auth_header` and parse the subset of
    // `BaseItemDto` we care about. Swap to the typed builder when it lands.
    //
    // TODO(core-#465): retire these raw fetches in favour of a typed
    //   `core.items_query()` builder once it exists.

    /// Refresh the "Jump Back In" carousel (#51). Fetches up to 12 albums
    /// the user has played recently, sorted by `DatePlayed` descending and
    /// filtered to `IsPlayed`. Silent on error — an empty shelf is a fine
    /// first-time-user state.
    func refreshJumpBackIn() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "DatePlayed",
            filters: "IsPlayed",
            limit: 12,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.jumpBackIn = albums
    }

    /// Refresh the "Recently Added" carousel (#54). Uses the core's
    /// `latest_albums` FFI, which is already backed by Jellyfin's
    /// `/Users/{id}/Items/Latest` endpoint. Falls back to the empty
    /// `library_id` convention already used elsewhere (see
    /// `ensurePlaylistLibraryId`) until a real library resolver lands.
    /// Also parses `DateCreated` off the server so the tile can surface a
    /// "NEW" badge for albums created in the last 7 days.
    func refreshRecentlyAdded() async {
        // TODO(core-#465): the typed `latest_albums` FFI returns
        //   `PaginatedAlbums` without the `DateCreated` field that drives
        //   the NEW badge. Until the core surfaces that directly, fetch
        //   the same shape via `/Users/{id}/Items/Latest` and pull both
        //   the album list + per-item `DateCreated` out of one response.
        let (albums, dates) = await fetchLatestAlbumsWithDates(limit: 20)
        self.recentlyAdded = albums
        self.recentlyAddedDates = dates
    }

    /// Refresh the "Quick Picks" carousel (#53). Heavy-rotation albums
    /// over the last 30 days, sorted by `PlayCount` descending. The core
    /// doesn't yet expose a `min_date_played` filter, so this is an
    /// inlined `/Items` fetch. Also records per-album play counts so the
    /// tile can surface a "42 plays" badge on hover.
    func refreshQuickPicks() async {
        // Jellyfin doesn't ship a "date played > X" filter, but the
        // `MinDateLastSaved` parameter on /Items is a reasonable proxy —
        // it gates on "last touched by the user", which for our purposes
        // (filtering out stale top-played ancient history) lines up well.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let thirtyDaysAgo = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        let minDate = iso.string(from: thirtyDaysAgo)
        let (albums, playCounts) = await fetchAlbumsWithPlayCounts(
            sortBy: "PlayCount,SortName",
            filters: "IsPlayed",
            limit: 12,
            minDateLastSaved: minDate
        )
        self.quickPicks = albums
        self.quickPicksPlayCounts = playCounts
    }

    /// Refresh the "Favorites" carousel (#55). Fetches up to 50 favorite
    /// albums, stores the full set, and picks a random 12 to surface
    /// today. Re-shuffles whenever this is called — which happens on
    /// login, on an explicit pull-to-refresh, or on app relaunch.
    func refreshFavoriteAlbums() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "SortName",
            filters: "IsFavorite",
            limit: 50,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.favoriteAlbumsAll = albums
        self.favoriteAlbumsVisible = Array(albums.shuffled().prefix(12))
        // Hydrate the per-id favorite map so album detail / tile hearts are
        // correct from first paint without waiting for the user to toggle.
        for album in albums {
            favoriteById[album.id] = true
        }
    }

    /// Re-shuffle `favoriteAlbumsVisible` from the already-fetched
    /// `favoriteAlbumsAll`. Cheaper than a full refresh — used by the "see
    /// all" / reshuffle affordance when we want a new set without hitting
    /// the server.
    func reshuffleFavoriteAlbumsVisible() {
        self.favoriteAlbumsVisible = Array(favoriteAlbumsAll.shuffled().prefix(12))
    }

    /// Refresh the "You might like" discovery row (#145). Calls
    /// `core.suggestions()` which hits Jellyfin's `/Items/Suggestions`
    /// endpoint filtered to Audio + MusicAlbum/MusicArtist. Returns up to
    /// 20 tracks server-ranked by play history and social signals. Runs
    /// off the MainActor per the gap-#2 pattern so the Rust mutex doesn't
    /// block the UI thread. Silent on error — an empty shelf is a fine
    /// first-time-user state.
    func refreshSuggestions() async {
        let fetched = await Task.detached(priority: .userInitiated) { [core] in
            (try? core.suggestions(limit: 20)) ?? []
        }.value
        self.suggestions = fetched
    }

    /// Load every favorite track on the server and play them shuffled.
    /// Powers the "Shuffle All Favorites" CTA on the Home favorites header
    /// (#55). Fetches up to 500 favorite tracks in one shot — that's an
    /// order of magnitude above the typical power-user favorite library
    /// and more than enough to seed a shuffled listening session.
    func shuffleAllFavorites() {
        Task {
            let tracks = await fetchFavoriteTracks(limit: 500)
            guard !tracks.isEmpty else {
                // Silent no-op if the user has nothing favorited yet — the
                // empty state in the Favorites header explains how to
                // start favoriting.
                return
            }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Navigate to the full library scoped to favorites (#55 "See All").
    /// Open the dedicated Favorites screen. Used by the sidebar's
    /// Favorites row and the Home Favorites carousel "See all" CTA.
    func showAllFavorites() {
        selectTab(.favorites)
    }

    /// Shared helper: build a `GET /Items` request against the user's
    /// library with the given `sortBy` / `filters`, parse the response,
    /// and return a typed array of `Album`. Returns an empty array on
    /// any failure (auth, network, parse) so callers can stay
    /// conditionally-rendering shelves without an error-banner code path.
    ///
    /// TODO(core-#465): replace with a typed `core.items_query()` builder
    ///   once that FFI exists. This function's surface lines up
    ///   deliberately with the shape that builder will expose.
    private func fetchAlbumsViaItemsQuery(
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
    private func fetchAlbumsWithPlayCounts(
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
    private func fetchLatestAlbumsWithDates(limit: UInt32) async -> ([Album], [String: Date]) {
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
    private func fetchFavoriteTracks(limit: UInt32) async -> [Track] {
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

    /// Build an authenticated `GET /Items` request against the current
    /// session's server. Returns `nil` when there is no session or the
    /// core refuses to hand out an auth header. Keeps the URL
    /// construction boilerplate in one place so each caller can just
    /// specify the filter knobs it cares about.
    private func buildItemsQuery(
        includeItemTypes: String,
        sortBy: String,
        sortOrder: String,
        filters: String?,
        limit: UInt32,
        extraFields: [String],
        minDateLastSaved: String?,
        parentId: String?
    ) -> URLRequest? {
        guard let session = session,
              let baseURL = URL(string: session.server.url),
              let authHeader = try? core.authHeader()
        else { return nil }
        let userId = session.user.id
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userId)/Items"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(
                name: "Fields",
                value: (["Genres", "ProductionYear", "ChildCount", "PrimaryImageAspectRatio", "UserData"] + extraFields)
                    .joined(separator: ",")
            ),
        ]
        if let filters, !filters.isEmpty {
            queryItems.append(URLQueryItem(name: "Filters", value: filters))
        }
        if let minDateLastSaved {
            queryItems.append(URLQueryItem(name: "MinDateLastSaved", value: minDateLastSaved))
        }
        if let parentId, !parentId.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        comps?.queryItems = queryItems
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parse the `{ Items: [...], TotalRecordCount: ... }` envelope
    /// Jellyfin returns for `/Users/{id}/Items` into our typed `Album`
    /// array. Only the fields `Album` carries are extracted; everything
    /// else is dropped. Returns `[]` on any parse failure.
    private static func parseAlbumsFromItems(data: Data) -> [Album] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.albumFromDTO($0) }
    }

    /// Like `parseAlbumsFromItems` but also extracts `UserData.PlayCount`
    /// per item into the returned map.
    private static func parseAlbumsWithPlayCounts(data: Data) -> ([Album], [String: UInt32]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return ([], [:]) }
        var albums: [Album] = []
        var plays: [String: UInt32] = [:]
        for entry in items {
            guard let album = Self.albumFromDTO(entry) else { continue }
            albums.append(album)
            if let userData = entry["UserData"] as? [String: Any],
               let playCount = userData["PlayCount"] as? Int, playCount > 0 {
                plays[album.id] = UInt32(playCount)
            }
        }
        return (albums, plays)
    }

    /// Parse the bare `BaseItemDto[]` response from
    /// `/Users/{id}/Items/Latest` into an album list + per-album
    /// `DateCreated` map. The NEW badge on `RecentlyAddedTile` reads the
    /// date map.
    private static func parseLatestAlbumsWithDates(data: Data) -> ([Album], [String: Date]) {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return ([], [:]) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var albums: [Album] = []
        var dates: [String: Date] = [:]
        for entry in items {
            guard let album = Self.albumFromDTO(entry) else { continue }
            albums.append(album)
            if let raw = entry["DateCreated"] as? String {
                if let d = iso.date(from: raw) {
                    dates[album.id] = d
                } else {
                    iso.formatOptions = [.withInternetDateTime]
                    if let d = iso.date(from: raw) {
                        dates[album.id] = d
                    }
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                }
            }
        }
        return (albums, dates)
    }

    /// Parse a Jellyfin `BaseItemDto` (from a `/Items` response) into the
    /// typed `Album` the core produces. Returns `nil` when the minimum
    /// required fields (`Id`, `Name`) aren't present so we don't render
    /// blank tiles.
    /// Parse `{ Items: [...] }` into typed `Artist` values. Mirror of
    /// `parseAlbumsFromItems` — used by the Favorites screen's "Artists"
    /// section. See `loadFavoriteArtists`.
    private static func parseArtistsFromItems(data: Data) -> [Artist] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.artistFromDTO($0) }
    }

    /// Project a Jellyfin `BaseItemDto` into the typed `Artist` shape.
    /// `albumCount` / `songCount` come back from the server when they're
    /// available; defaults to 0 otherwise so the tile count line stays
    /// renderable.
    private static func artistFromDTO(_ entry: [String: Any]) -> Artist? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let albumCount: UInt32 = {
            if let c = entry["AlbumCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let songCount: UInt32 = {
            if let c = entry["SongCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let genres: [String] = (entry["Genres"] as? [String]) ?? []
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        return Artist(
            id: id,
            name: name,
            albumCount: albumCount,
            songCount: songCount,
            genres: genres,
            imageTag: imageTag,
            userData: nil
        )
    }

    private static func albumFromDTO(_ entry: [String: Any]) -> Album? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let artistName = (entry["AlbumArtist"] as? String)
            ?? (entry["Artists"] as? [String])?.first
            ?? ""
        let artistId: String? = {
            if let id = entry["AlbumArtistId"] as? String, !id.isEmpty { return id }
            if let items = entry["AlbumArtists"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        let year: Int32? = {
            if let y = entry["ProductionYear"] as? Int, y > 0 { return Int32(y) }
            return nil
        }()
        let trackCount: UInt32 = {
            if let c = entry["ChildCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let runtimeTicks: UInt64 = {
            if let t = entry["RunTimeTicks"] as? Int64, t >= 0 { return UInt64(t) }
            if let t = entry["RunTimeTicks"] as? Int, t >= 0 { return UInt64(t) }
            return 0
        }()
        let genres: [String] = (entry["Genres"] as? [String]) ?? []
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        // `user_data` landed on `Album` in BATCH-24 — clients that build
        // Albums from a local `BaseItemDto` can pass `nil` to reproduce the
        // old behaviour; callers that have a richer `UserData` projection
        // should populate the struct directly.
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
            // DTO parser doesn't request `Fields=UserData`, so the
            // server-authoritative projection is absent here. Favourite /
            // play-count consumers read the legacy convenience mirrors
            // (`isFavorite` / `playCount`) where those are set.
            userData: nil
        )
    }

    /// Parse the `{ Items: [...] }` envelope into typed `Track` values.
    /// Mirrors `parseAlbumsFromItems` but targets audio tracks — used by
    /// `fetchFavoriteTracks` for the Shuffle All Favorites CTA.
    private static func parseTracksFromItems(data: Data) -> [Track] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.trackFromDTO($0) }
    }

    /// Turn a `BaseItemDto` (audio track) into the typed `Track` record.
    /// Returns `nil` on missing `Id`/`Name` so blank rows don't land in
    /// the shuffle queue.
    private static func trackFromDTO(_ entry: [String: Any]) -> Track? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let albumId = (entry["AlbumId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let albumName = (entry["Album"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let artistName = (entry["AlbumArtist"] as? String)
            ?? (entry["Artists"] as? [String])?.first
            ?? ""
        let artistId: String? = {
            if let items = entry["ArtistItems"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            if let items = entry["AlbumArtists"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        let indexNumber: UInt32? = {
            if let n = entry["IndexNumber"] as? Int, n > 0 { return UInt32(n) }
            return nil
        }()
        let discNumber: UInt32? = {
            if let n = entry["ParentIndexNumber"] as? Int, n > 0 { return UInt32(n) }
            return nil
        }()
        let year: Int32? = {
            if let y = entry["ProductionYear"] as? Int, y > 0 { return Int32(y) }
            return nil
        }()
        let runtimeTicks: UInt64 = {
            if let t = entry["RunTimeTicks"] as? Int64, t >= 0 { return UInt64(t) }
            if let t = entry["RunTimeTicks"] as? Int, t >= 0 { return UInt64(t) }
            return 0
        }()
        let userData = entry["UserData"] as? [String: Any]
        let isFavorite = (userData?["IsFavorite"] as? Bool) ?? false
        let playCount: UInt32 = {
            if let c = userData?["PlayCount"] as? Int, c > 0 { return UInt32(c) }
            return 0
        }()
        let container = (entry["Container"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bitrate: UInt32? = {
            if let b = entry["Bitrate"] as? Int, b > 0 { return UInt32(b) }
            return nil
        }()
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        // `user_data` landed on `Track` in BATCH-24 — see `albumFromDTO`
        // above for the same pattern.
        return Track(
            id: id,
            name: name,
            albumId: albumId,
            albumName: albumName,
            artistName: artistName,
            artistId: artistId,
            indexNumber: indexNumber,
            discNumber: discNumber,
            year: year,
            runtimeTicks: runtimeTicks,
            isFavorite: isFavorite,
            playCount: playCount,
            container: container,
            bitrate: bitrate,
            imageTag: imageTag,
            playlistItemId: nil,
            // DTO parser doesn't request `Fields=UserData`, so the
            // server-authoritative projection is absent. Legacy mirrors
            // `isFavorite` / `playCount` are populated above from whatever
            // the BaseItemDto carried.
            userData: nil
        )
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .albumTracks)
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
        if let cached = artists.first(where: { $0.id == id }) { return cached }
        do {
            let detail = try await Task.detached(priority: .userInitiated) { [core] in
                try core.artistDetail(artistId: id)
            }.value
            return Artist(
                id: detail.id,
                name: detail.name,
                albumCount: 0,
                songCount: 0,
                genres: detail.genres,
                imageTag: detail.imageTag,
                userData: nil
            )
        } catch {
            _ = handleAuthError(error)
            return nil
        }
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
        if let cached = albums.first(where: { $0.id == id }) { return cached }
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: id,
                    fields: ["PrimaryImageAspectRatio", "Genres", "ProductionYear", "ChildCount", "RunTimeTicks"]
                )
            }.value
            return Self.parseAlbum(from: json)
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
            imageTag: imageTag
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

    /// Fetch the ordered tracks for a playlist, preserving the server-side
    /// playlist order. Mirrors `loadTracks(forAlbum:)` — results are cached
    /// for the session, scoped to `playlistTracks[playlist.id]`. Backed by
    /// `JellifyCore.playlistTracks` (core's `playlist_tracks`, see #125).
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .playlistTracks)
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
    func loadPlaylistTracks(playlistId: String) async {
        if let cached = playlistTracks[playlistId] {
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .playlistTracks)
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
                imageTag: p.imageTag
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
                        imageTag: p.imageTag
                    )
                }
                self.pendingPlaylistRemoval = nil
                self.errorMessage = JellifyErrorPresenter.message(
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
                imageTag: p.imageTag
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
                        imageTag: p.imageTag
                    )
                }
                self.errorMessage = JellifyErrorPresenter.message(
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
    func addToPlaylist(playlistId: String, trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        let ids = trackIds
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
                imageTag: p.imageTag
            )
        }
        let bumpedCount = trackIds.count
        let playlistRef = playlistId
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
                        imageTag: p.imageTag
                    )
                }
                self.errorMessage = JellifyErrorPresenter.message(
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

    /// Common driver for every "Start Radio" entry point. `core.instantMix`
    /// is polymorphic — any item id (track, album, artist, genre, playlist)
    /// works. Wraps the FFI hop in `Task.detached` so the main actor doesn't
    /// block on a network round-trip.
    private func playInstantMix(seedId: String, limit: UInt32 = 50) {
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .search)
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .search)
        }
    }


    /// Debounced instant search for the dropdown shown under the toolbar
    /// search field. Cancels any previous in-flight pass, waits 250ms for
    /// more keystrokes, then hits `core.search`. On success we rank a
    /// single "top result" by exact-title > prefix > contains (ties broken
    /// by play count when available, then alpha) and split the rest into
    /// typed sections for the dropdown to render.
    ///
    /// Empty / whitespace-only queries short-circuit to `.empty` and
    /// cancel any pending fetch so the dropdown clears instantly.
    ///
    /// Spec: #85 (instant dropdown), #241 (debounced fetch), #243 (hero
    /// top result). Deliberately uses the existing `core.search` endpoint
    /// — a leaner `/Search/Hints` path is tracked separately; swapping
    /// here is a one-line change when that lands.
    func runInstantSearch(query: String) {
        // Cancel whatever was in flight — the user either typed another
        // character or cleared the field. Either way, the old result is
        // stale.
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            instantSearchResults = .empty
            searchTask = nil
            return
        }

        searchTask = Task { [weak self, core] in
            // 250ms debounce — if another keystroke fires the task is
            // cancelled before we ever hit the network.
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }

            // Instant dropdown is tuned for speed, not completeness —
            // 20 items is enough to populate every section without
            // hauling the whole "see all" page down on each keystroke.
            let results: SearchResults
            do {
                results = try await Task.detached(priority: .userInitiated) {
                    try core.search(query: trimmed, offset: 0, limit: 20)
                }.value
            } catch {
                // Instant search failures are cosmetic — the full Search
                // screen still surfaces the "real" error on submit. Swallow
                // here so a flaky network doesn't keep firing error banners
                // for every keystroke.
                return
            }
            if Task.isCancelled { return }

            guard let self else { return }
            await MainActor.run {
                let top = Self.pickTopResult(query: trimmed, results: results)
                self.instantSearchResults = InstantSearchResults(
                    topResult: top,
                    artists: results.artists,
                    albums: results.albums,
                    tracks: results.tracks,
                    // Playlists and genres are not yet surfaced by
                    // `core.search` (today it returns Audio / MusicAlbum /
                    // MusicArtist only). TODO(core): expand the search
                    // endpoint to include Playlist + MusicGenre so the
                    // instant dropdown can render those sections.
                    playlists: [],
                    genres: []
                )
            }
        }
    }

    /// Pick the single "top result" for the hero card.
    ///
    /// Ranking, strongest → weakest: exact case-insensitive title match,
    /// then prefix match, then substring match. Ties are broken by play
    /// count (only tracks carry one today) and finally by alphabetical
    /// order so the choice is deterministic across keystrokes.
    nonisolated static func pickTopResult(query: String, results: SearchResults) -> SearchItem? {
        let q = query.lowercased()
        var candidates: [SearchItem] = []
        candidates.reserveCapacity(results.artists.count + results.albums.count + results.tracks.count)
        candidates.append(contentsOf: results.artists.map(SearchItem.artist))
        candidates.append(contentsOf: results.albums.map(SearchItem.album))
        candidates.append(contentsOf: results.tracks.map(SearchItem.track))
        guard !candidates.isEmpty else { return nil }

        // Lower sort key wins. `(rank, -playCount, name)` so we can call
        // `.min(by:)` without an ad-hoc comparator per tier.
        func rank(for name: String) -> Int {
            let lower = name.lowercased()
            if lower == q { return 0 }
            if lower.hasPrefix(q) { return 1 }
            if lower.contains(q) { return 2 }
            return 3
        }

        return candidates.min { a, b in
            let ra = rank(for: a.title)
            let rb = rank(for: b.title)
            if ra != rb { return ra < rb }
            // Play count — only tracks carry one. Treat non-tracks as 0.
            let pa = a.playCount
            let pb = b.playCount
            if pa != pb { return pa > pb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
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
        searchPageQuery = trimmed

        guard !trimmed.isEmpty else {
            searchPageResults = [:]
            searchPageTotal = 0
            searchPageLoaded = 0
            isLoadingFullSearch = false
            return
        }

        isLoadingFullSearch = true
        defer { isLoadingFullSearch = false }
        do {
            let pageSize = searchPagePageSize
            let results = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: trimmed, offset: 0, limit: pageSize)
            }.value
            searchPageResults = Self.bucketSearchResults(results)
            searchPageTotal = results.totalRecordCount
            searchPageLoaded = results.artists.count + results.albums.count + results.tracks.count
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = JellifyErrorPresenter.message(for: error, context: .search)
        }
    }

    /// Fetch another combined page for the current full-search query.
    /// Invoked by the "Load more" button on a scope tab when that tab has
    /// already revealed every buffered item but the server still reports
    /// more matches overall. Merges the new page into `searchPageResults`
    /// with per-id dedupe so flaky ordering on Jellyfin's side doesn't
    /// double a row. No-op when the buckets already cover `searchPageTotal`.
    func loadMoreFullSearch() async {
        guard !isLoadingFullSearch, !searchPageQuery.isEmpty else { return }
        guard searchPageLoaded < Int(searchPageTotal) else { return }
        isLoadingFullSearch = true
        defer { isLoadingFullSearch = false }
        let offset = UInt32(searchPageLoaded)
        let query = searchPageQuery
        do {
            let pageSize = searchPagePageSize
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: query, offset: offset, limit: pageSize)
            }.value

            var merged = searchPageResults
            let incoming = Self.bucketSearchResults(page)
            for (key, newItems) in incoming {
                var existing = merged[key] ?? []
                var seen = Set(existing.map(\.id))
                for item in newItems where seen.insert(item.id).inserted {
                    existing.append(item)
                }
                merged[key] = existing
            }
            searchPageResults = merged
            searchPageTotal = page.totalRecordCount
            searchPageLoaded += page.artists.count + page.albums.count + page.tracks.count
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = JellifyErrorPresenter.message(for: error, context: .search)
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
        // Playlists aren't surfaced by the current `core.search` endpoint.
        // Leave the bucket absent; the view renders an empty scope state
        // for the user when the Playlists chip is active.
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
        let key = "\(itemID)|\(tag ?? "")|\(maxWidth)"
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

    // MARK: - Playback

    func play(tracks: [Track], startIndex: Int = 0) {
        do {
            _ = try core.setQueue(tracks: tracks, startIndex: UInt32(startIndex))
            guard let first = tracks[safe: startIndex] else { return }
            try audio.play(track: first)
            errorMessage = nil
        } catch {
            if handleAuthError(error) { return }
            errorMessage = JellifyErrorPresenter.message(for: error, context: .playback)
        }
    }

    func play(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle an album — loads tracks, randomises order, then plays from top.
    func shuffle(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert an album's tracks immediately after the currently-playing track.
    /// Uses the `core.playNext` primitive wired in for #282. When nothing is
    /// currently playing, falls back to `play(album:)` so the album actually
    /// starts instead of silently queueing into an empty player.
    func playNext(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.playNext(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

    /// Append an album's tracks to the end of the queue. Uses the
    /// `core.addToQueue` primitive wired in for #282; when nothing is playing
    /// falls back to `play(album:)` so we don't end up with a loaded queue
    /// but no playhead.
    func addToQueue(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.addToQueue(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

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

    /// Snapshot-aware favorite check for artists. Mirrors
    /// `isFavorite(track:)` — falls back to `artist.userData?.isFavorite`.
    func isFavorite(artist: Artist) -> Bool {
        if let cached = favoriteById[artist.id] { return cached }
        return artist.userData?.isFavorite ?? false
    }

    /// Internal helper — hits `set_favorite` / `unset_favorite` on the core
    /// and mirrors the server's answer into `favoriteById`. Kept private so
    /// the public API stays `toggleFavorite(...)` and the desired-state
    /// boolean is always computed at the call site.
    private func setFavorite(itemId: String, enabled: Bool) async {
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
        } catch {
            Log.tracks.error("setFavorite failed item=\(itemId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = JellifyErrorPresenter.message(for: error, context: .favorite)
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
    private func setPlayed(itemId: String, played: Bool) async {
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .markPlayed)
        }
    }

    /// Enqueue a download of every track on the album.
    /// TODO: #70, #222 — there is no download engine yet; this is a logging
    /// stub so the UI action has a landing pad.
    func enqueueDownload(album: Album) {
        // TODO: #70 / #222 — download engine not yet wired.
        Log.app.notice("enqueueDownload(album:) not yet wired — see #70 / #222")
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
            errorMessage = JellifyErrorPresenter.message(for: error, context: .playlistAdd)
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
                    fields: ["People", "Studios", "PremiereDate", "DateCreated", "ProductionYear"]
                )
            }.value
            return Self.parseAlbumDetail(from: json)
        } catch {
            _ = handleAuthError(error)
            return AlbumDetail(label: nil, releaseDate: nil, people: [])
        }
    }

    /// Parse the subset of the album item JSON that the liner-note section
    /// cares about. Static + internal so tests can hit it without wiring
    /// the full model. Missing fields become `nil`; the parser never throws.
    static func parseAlbumDetail(from json: String) -> AlbumDetail {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AlbumDetail(label: nil, releaseDate: nil, people: [])
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

        return AlbumDetail(label: label, releaseDate: releaseDate, people: people)
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

    /// Present the album metadata editor. Admin-only once the sheet lands.
    /// TODO: #96 / #222 — metadata editor sheet not yet implemented.
    func requestEditAlbum(album: Album) {
        // TODO(#96): metadata editor sheet not yet implemented.
        Log.app.notice("requestEditAlbum(album:) not yet wired — see #96 / #222")
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

    // MARK: - Sharing

    /// Jellyfin web URL for an album, e.g.
    /// `https://server.example.com/web/#/details?id=<albumId>`.
    func webURL(for album: Album) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(album.id)")
    }

    /// Copy the album's web URL to the system pasteboard.
    func copyShareLink(album: Album) {
        guard let url = webURL(for: album) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the album in the Jellyfin web UI.
    func openInJellyfin(album: Album) {
        guard let url = webURL(for: album) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Artist actions

    /// Play every track in an artist's catalog (album → disc → track order).
    /// Caps at the soft 500-track ceiling — prolific artists may have more,
    /// but the player gets a deterministic prefix that matches what
    /// `tracks_by_artist` returned. See #156.
    func playAll(artist: Artist) {
        Task {
            let tracks = await loadTracks(forArtist: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle every track in an artist's catalog. Loads in catalog order,
    /// shuffles client-side, plays from the head. Same 500-track soft cap
    /// as `playAll(artist:)`. See #156.
    func shuffle(artist: Artist) {
        Task {
            let tracks = await loadTracks(forArtist: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Internal helper — fetch the first page of an artist's catalog via the
    /// `tracks_by_artist` FFI. Mirrors `loadTracks(forAlbum:)` in shape so
    /// `playAll(artist:)` / `shuffle(artist:)` collapse to a one-liner. The
    /// 500-row limit is a deliberate soft cap to keep the FFI / queue under
    /// a single round-trip. See #156.
    private func loadTracks(forArtist artistId: String) async -> [Track] {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.tracksByArtist(artistId: artistId, offset: 0, limit: 500)
            }.value
            return page.items
        } catch {
            if !handleAuthError(error) {
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
            }
            return []
        }
    }

    /// Play the artist's top tracks (play-count-weighted). Fetches the
    /// top 5 via the core, then starts playback from the first. See #229.
    func playTopTracks(artist: Artist) {
        Task {
            let tracks = await loadArtistTopTracks(artistId: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Toggle the favorite flag for an artist on the Jellyfin server.
    /// Jellyfin's `/Users/{id}/FavoriteItems/{id}` endpoint is polymorphic,
    /// so the same `set_favorite` / `unset_favorite` FFI used for albums
    /// and tracks works on artist ids too.
    func toggleFavorite(artist: Artist) {
        Task { await setFavorite(itemId: artist.id, enabled: !isFavorite(artist: artist)) }
    }

    /// Toggle the follow flag for an artist. Routes through `setFavorite`
    /// since Jellyfin's `/Users/{id}/FavoriteItems/{id}` endpoint is the
    /// correct server primitive for "following" an artist — the vocabulary
    /// differs but the data is the same `IsFavorite` flag on the artist item.
    func toggleFollow(artist: Artist) {
        Task { await setFavorite(itemId: artist.id, enabled: !isFavorite(artist: artist)) }
    }

    /// `true` when the user has favorited/followed this artist.
    /// Snapshot-aware so first-paint state matches the server even before
    /// the user toggles — see `isFavorite(artist:)` for the fallback chain.
    func isFollowing(artist: Artist) -> Bool {
        isFavorite(artist: artist)
    }

    /// Insert a handful of the artist's top tracks immediately after the
    /// currently-playing track. Uses the `core.playNext` primitive wired
    /// in for #282. Falls back silently when there are no top tracks to load.
    func playNextArtist(artist: Artist) {
        Task {
            let tracks = await loadArtistTopTracks(artistId: artist.id)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.playNext(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

    /// Navigate to the artist detail screen. Used when the menu is invoked
    /// from a surface other than the artist detail itself (e.g. a track
    /// row whose secondary line is the artist).
    func goToArtistPage(artist: Artist) {
        navPath.append(Route.artist(artist.id))
    }

    /// Kick off an Instant Mix ("artist radio") seeded by this artist.
    func startArtistRadio(artist: Artist) {
        playInstantMix(seedId: artist.id)
    }

    /// Navigate to the artist detail screen, anchored on the discography.
    /// The artist detail screen itself is tracked in #58 / #60 / #408; for now
    /// we just route to `.artist(id)` and let that view (when it lands) pick
    /// up the discography anchor.
    func goToDiscography(artist: Artist) {
        navPath.append(Route.artist(artist.id))
    }

    /// Show artists similar to this one. Navigates to the artist detail page
    /// and pre-warms the similar-artists cache so the row is ready when the
    /// view appears. Backed by `core.similarArtists` via `loadSimilarArtists`.
    /// See #146.
    func showSimilar(artist: Artist) {
        Task {
            await loadSimilarArtists(artistId: artist.id)
        }
        navPath.append(Route.artist(artist.id))
    }

    // MARK: - Artist sharing

    /// Jellyfin web URL for an artist, e.g.
    /// `https://server.example.com/web/#/details?id=<artistId>`.
    func webURL(for artist: Artist) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(artist.id)")
    }

    /// Copy the artist's web URL to the system pasteboard.
    func copyShareLink(artist: Artist) {
        guard let url = webURL(for: artist) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the artist in the Jellyfin web UI.
    func openInJellyfin(artist: Artist) {
        guard let url = webURL(for: artist) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Playlist actions
    //
    // Parallels the album actions above. Issue #313.
    //
    // Playback actions are live now that `playlist_tracks` has landed (#125;
    // see `loadPlaylistTracks`). Mutation actions (favorite, download,
    // rename, delete) remain TODO stubs pending follow-up FFI work:
    // favorites (#133), download engine (#70), `update_playlist` (#130),
    // `delete_playlist` (#131). The UI is wired up now so that when each
    // backing endpoint lands the action just needs its stub swapped for a
    // real call.

    /// Fetch a playlist's tracks and start playback from the top.
    func play(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle a playlist — loads tracks, randomises order, then plays from
    /// the top. Mirrors `shuffle(album:)`.
    func shuffle(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert a playlist's tracks immediately after the currently-playing track.
    /// Wired to `core.playNext` for #282. Falls back to `play(playlist:)`
    /// when nothing is currently playing so the menu item still does the
    /// obvious thing.
    func playNext(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.playNext(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

    /// Append a playlist's tracks to the end of the queue. Wired to
    /// `core.addToQueue` for #282. Falls back to `play(playlist:)` when
    /// nothing is currently playing.
    func addToQueue(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            if status.currentTrack == nil {
                play(tracks: tracks, startIndex: 0)
                return
            }
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.addToQueue(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

    /// Toggle the favorite flag for a playlist on the Jellyfin server.
    /// TODO: #133, #222 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(playlist: Playlist) {
        // `/Users/{id}/FavoriteItems/{id}` is polymorphic, so the same
        // set/unset-favorite FFI used for albums/tracks works on playlists.
        Task { await setFavorite(itemId: playlist.id, enabled: !isFavorite(id: playlist.id)) }
    }

    /// Enqueue a download of every track in the playlist.
    /// TODO: #70, #222 — there is no download engine yet; this is a logging
    /// stub so the UI action has a landing pad.
    func enqueueDownload(playlist: Playlist) {
        // TODO: #70 / #222 — download engine not yet wired.
        Log.app.notice("enqueueDownload(playlist:) not yet wired — see #70 / #222")
    }

    /// Flip the sidebar's inline TextField onto an existing playlist row so
    /// the user can rename it in-place. Mirrors the #71 Cmd+N flow —
    /// Escape / blur-without-change cancels, Return commits through
    /// `commitSidebarPlaylistEdit` which dispatches to `renamePlaylist`.
    /// See BATCH-06b / issue #75.
    func requestRename(playlist: Playlist) {
        sidebarEditingPlaylistId = playlist.id
        sidebarEditingDraft = playlist.name
    }

    /// Present a delete confirmation for a playlist. Alias for
    /// `confirmDelete(playlist:)`, kept for historical call sites.
    func requestDelete(playlist: Playlist) {
        confirmDelete(playlist: playlist)
    }

    /// Raise a delete-confirmation dialog for a playlist. Sets
    /// `playlistPendingDelete`, which `MainShell` observes to present a
    /// `.confirmationDialog` with clear "Delete <playlist name>?" copy.
    /// The actual delete happens in `performDeletePending()` once the user
    /// confirms.
    func confirmDelete(playlist: Playlist) {
        playlistPendingDelete = playlist
    }

    /// Execute the pending playlist deletion, if any. Called from the
    /// confirmation dialog's destructive button. Delegates to
    /// `deletePlaylist(id:)` which owns the stub + local-remove behaviour.
    func performDeletePending() {
        guard let target = playlistPendingDelete else { return }
        playlistPendingDelete = nil
        deletePlaylist(id: target.id)
    }

    /// Dismiss the pending delete dialog without deleting anything.
    func cancelDeletePending() {
        playlistPendingDelete = nil
    }

    /// Duplicate a playlist: create a new playlist named "<original> Copy"
    /// and populate it with the same track ids. Fires-and-forgets on the
    /// main actor; the sidebar row shows a progress indicator for the
    /// source playlist while the round trip is in flight (see
    /// `sidebarCopyingPlaylistIds`). See BATCH-06b / issues #75 / #126.
    func requestDuplicate(playlist: Playlist) {
        Task { await duplicatePlaylist(id: playlist.id) }
    }

    /// Present a save panel and write the playlist to disk as an `.m3u8` file.
    /// Fetches the playlist's tracks via `playlist_tracks` FFI, then builds an
    /// extended M3U file with `#EXTINF` metadata per track. Stream URLs are
    /// written without auth tokens so the file is safe to share (#76).
    func exportPlaylist(playlist: Playlist) {
        Task {
            // Fetch tracks before opening the panel so we know the export
            // will succeed before the user picks a save location.
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else {
                errorMessage = "No tracks to export for \"\(playlist.name)\"."
                return
            }

            // Build the extended M3U content. runtimeTicks is in 100-nanosecond
            // units; divide by 10_000_000 to get whole seconds for #EXTINF.
            var lines: [String] = ["#EXTM3U"]
            let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
            for track in tracks {
                let durationSec = Int(track.runtimeTicks / 10_000_000)
                let inf = "#EXTINF:\(durationSec),\(track.artistName) - \(track.name)"
                // Use the auth-free universal-stream path: no query parameters,
                // no api_key. Works with servers that allow unauthenticated
                // download (many local setups), and is safe to share even when
                // that's not the case.
                let streamPath = "\(base)/Audio/\(track.id)/universal"
                lines.append(inf)
                lines.append(streamPath)
            }
            let m3u8Content = lines.joined(separator: "\n") + "\n"

            // Present the save panel on the main actor.
            let panel = NSSavePanel()
            panel.title = "Export Playlist as .m3u8"
            panel.nameFieldStringValue = "\(playlist.name).m3u8"
            panel.allowedContentTypes = [.init(filenameExtension: "m3u8") ?? .plainText]
            panel.canCreateDirectories = true

            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }

            do {
                try m3u8Content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Rename a playlist in place from the playlist hero's click-to-edit
    /// title (#234). Thin wrapper around `renamePlaylist(id:, newName:)`
    /// so the hero and the sidebar share a single code path.
    func renamePlaylist(_ playlist: Playlist, newName: String) {
        renamePlaylist(id: playlist.id, newName: newName)
    }

    /// Update the description (Jellyfin `Overview`) for a playlist from the
    /// hero's click-to-edit description editor (#234). The core `Playlist`
    /// record doesn't expose `Overview` yet, so the new text lives in the
    /// in-memory `playlistDescriptions` map keyed by playlist id.
    ///
    /// TODO: #130 — switch this to `core.updatePlaylist(playlistId:, overview:)`
    /// once the FFI lands, and drop `playlistDescriptions` entirely in favour
    /// of a `description: Option<String>` field on `Playlist` in
    /// `core/src/models.rs`.
    func updatePlaylistDescription(_ playlist: Playlist, newDescription: String) {
        let trimmed = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // TODO: #130 — persist via `core.updatePlaylist` once available.
        Log.app.notice("updatePlaylistDescription(\(playlist.id, privacy: .public)) not yet persisted — see #130")
        if trimmed.isEmpty {
            playlistDescriptions.removeValue(forKey: playlist.id)
        } else {
            playlistDescriptions[playlist.id] = trimmed
        }
    }

    // MARK: - Sidebar playlist CRUD (BATCH-06b, #71 / #73 / #75)

    /// Drop a placeholder row into edit mode so Cmd+N feels instant. The
    /// placeholder is identified by `sidebarNewPlaylistSentinel`; the
    /// sidebar renders a single TextField in its slot. Committing via
    /// `commitSidebarPlaylistEdit` turns this into a real `create_playlist`
    /// call; Escape / empty-blur bails out via `cancelSidebarPlaylistEdit`.
    /// See issue #71.
    func beginNewPlaylist() {
        sidebarEditingPlaylistId = Self.sidebarNewPlaylistSentinel
        sidebarEditingDraft = ""
    }

    /// Dismiss the inline TextField without saving. Used for Escape /
    /// blur-with-empty-text on a new-playlist row, and for blur-without-
    /// change on a rename-in-progress row.
    func cancelSidebarPlaylistEdit() {
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
    }

    /// Commit the current sidebar draft. Branches on the editing id:
    ///   - `sidebarNewPlaylistSentinel` → `createPlaylist(name:)`;
    ///   - any other id → `renamePlaylist(id:, newName:)`.
    /// An empty or whitespace-only draft is treated as cancel, matching
    /// macOS Finder conventions for inline rename. See #71 / #75.
    func commitSidebarPlaylistEdit() async {
        guard let editingId = sidebarEditingPlaylistId else { return }
        let trimmed = sidebarEditingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear the edit state up-front so the TextField unmounts before the
        // async create / rename completes; prevents the view from appearing
        // "stuck" on slow networks.
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
        guard !trimmed.isEmpty else { return }
        if editingId == Self.sidebarNewPlaylistSentinel {
            await createPlaylist(name: trimmed)
        } else {
            renamePlaylist(id: editingId, newName: trimmed)
        }
    }

    /// Create a new (empty) playlist on the server and prepend it to the
    /// in-memory `playlists` list so the sidebar surfaces it immediately.
    /// Backed by `core.createPlaylist(name:, itemIds:)` — see #126.
    /// A thin optimistic update: if the core call fails we fall back to
    /// an `errorMessage` and do not insert the row.
    func createPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let newId = try await Task.detached(priority: .userInitiated) { [core] in
                try core.createPlaylist(name: trimmed, itemIds: [], position: nil)
            }.value
            // The core returns only the id; build a minimal `Playlist`
            // record client-side rather than refetching. An `imageTag` of
            // `nil` falls through to the gradient placeholder until the
            // next library refresh picks up the server's Primary tag.
            let newPlaylist = Playlist(
                id: newId,
                name: trimmed,
                trackCount: 0,
                runtimeTicks: 0,
                imageTag: nil
            )
            playlists.insert(newPlaylist, at: 0)
        } catch {
            errorMessage = "Create playlist failed: \(error.localizedDescription)"
        }
    }

    /// Rename a playlist by id. Optimistically updates the in-memory list
    /// first for instant UI feedback, then persists to the server via
    /// `core.renamePlaylist`. On failure the old name is restored and
    /// `errorMessage` surfaces the failure.
    func renamePlaylist(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let existing = playlists[idx]
        guard trimmed != existing.name else { return }
        // Optimistic update so the sidebar / hero reflects the new name
        // before the network round-trip completes.
        playlists[idx] = Playlist(
            id: existing.id,
            name: trimmed,
            trackCount: existing.trackCount,
            runtimeTicks: existing.runtimeTicks,
            imageTag: existing.imageTag
        )
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.renamePlaylist(playlistId: id, newName: trimmed)
                }.value
                serverReachability.noteSuccess()
            } catch {
                if handleAuthError(error) { return }
                // Rollback the optimistic rename on failure.
                if let rollbackIdx = playlists.firstIndex(where: { $0.id == id }) {
                    playlists[rollbackIdx] = existing
                }
                errorMessage = "Rename failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
    }

    /// Duplicate a playlist: create "<original> Copy" and seed it with the
    /// same tracks via `add_to_playlist`. Shows a per-row spinner while the
    /// two round trips are in flight (tracked in
    /// `sidebarCopyingPlaylistIds`). No-op if the source playlist isn't in
    /// the in-memory list. See #75 / #126.
    func duplicatePlaylist(id: String) async {
        guard let source = playlists.first(where: { $0.id == id }) else { return }
        sidebarCopyingPlaylistIds.insert(id)
        defer { sidebarCopyingPlaylistIds.remove(id) }

        // Gather every track id on the source playlist so the copy starts
        // with the same contents. `loadAllPlaylistTracks` already walks the
        // server in pages and caps pathological playlists at the safety
        // limit — reusing it keeps behaviour consistent with what the
        // user sees in the detail view.
        let tracks = await loadAllPlaylistTracks(playlistID: source.id)
        let trackIds = tracks.map(\.id)
        let copyName = "\(source.name) Copy"
        do {
            let newId = try await Task.detached(priority: .userInitiated) { [core] in
                try core.createPlaylist(name: copyName, itemIds: trackIds, position: nil)
            }.value
            // Core's `create_playlist` can accept seed items directly; the
            // `itemIds` path above covers the common case. We still build a
            // fresh `Playlist` record locally rather than refetch.
            let newPlaylist = Playlist(
                id: newId,
                name: copyName,
                trackCount: UInt32(trackIds.count),
                runtimeTicks: source.runtimeTicks,
                imageTag: nil
            )
            playlists.insert(newPlaylist, at: 0)
            // Prime the tracks cache so the detail view doesn't have to
            // re-walk the server the first time the user opens the copy.
            if !tracks.isEmpty {
                playlistTracks[newId] = tracks
            }
        } catch {
            errorMessage = "Duplicate playlist failed: \(error.localizedDescription)"
        }
    }

    /// Delete a playlist. Optimistically removes the playlist from
    /// the in-memory list for instant UI feedback, then persists the
    /// deletion to the server via `core.deletePlaylist`. On failure
    /// the playlist is re-inserted at its original position and
    /// `errorMessage` surfaces the failure.
    func deletePlaylist(id: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let removed = playlists[idx]
        let removedTracks = playlistTracks[id]
        let removedDescription = playlistDescriptions[id]
        // Optimistic drop.
        playlists.remove(at: idx)
        playlistTracks.removeValue(forKey: id)
        playlistDescriptions.removeValue(forKey: id)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.deletePlaylist(playlistId: id)
                }.value
                serverReachability.noteSuccess()
            } catch {
                if handleAuthError(error) { return }
                // Rollback the optimistic delete on failure.
                let insertIdx = min(idx, playlists.count)
                playlists.insert(removed, at: insertIdx)
                if let tracks = removedTracks { playlistTracks[id] = tracks }
                if let desc = removedDescription { playlistDescriptions[id] = desc }
                errorMessage = "Delete failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
    }

    /// Resolve a dropped track id (from the drag-reorder affordance in
    /// `PlaylistReorderHandle`) back to an index and dispatch the move.
    /// Separated from `moveTrackInPlaylist` so the drop delegate doesn't
    /// need to hold an index snapshot that could go stale by the time the
    /// async `NSItemProvider` callback fires.
    func applyPlaylistDrop(playlistId: String, trackId: String, destinationIndex: Int) {
        guard let tracks = playlistTracks[playlistId] else { return }
        guard let sourceIndex = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        moveTrackInPlaylist(playlistId: playlistId, from: sourceIndex, to: destinationIndex)
    }

    /// Reorder a track within a playlist. Applies the move to the local
    /// cache immediately (optimistic update), then calls
    /// `core.reorderPlaylistTrack` to persist the new position on the server.
    /// Requires the moved track to carry a `playlistItemId` — if it doesn't
    /// (e.g. old cached data pre-dating the `PlaylistItemId` field), the move
    /// is local-only and an error is logged.
    ///
    /// Indices are relative to the current cached order in
    /// `playlistTracks[playlistId]`. The semantics match SwiftUI's native
    /// `Array.move(fromOffsets:toOffset:)` so the detail view can feed its
    /// drop position straight through.
    func moveTrackInPlaylist(playlistId: String, from: Int, to: Int) {
        guard var tracks = playlistTracks[playlistId] else { return }
        guard from >= 0, from < tracks.count else { return }
        // SwiftUI's `move(fromOffsets:toOffset:)` accepts `to` as an
        // insertion index in the pre-move list, so the valid range is
        // [0, tracks.count]. `from == to` and `from + 1 == to` are both
        // no-ops — bail early to avoid a needless assignment + notify.
        guard to >= 0, to <= tracks.count else { return }
        guard to != from, to != from + 1 else { return }
        let movedTrack = tracks[from]
        tracks.remove(at: from)
        let insertIndex = to > from ? to - 1 : to
        tracks.insert(movedTrack, at: insertIndex)
        playlistTracks[playlistId] = tracks
        // Keep currentPlaylistTracks in sync if this playlist is currently shown.
        if !currentPlaylistTracks.isEmpty {
            currentPlaylistTracks = tracks
        }
        // Persist the reorder to the server if the track carries a PlaylistItemId.
        guard let playlistItemId = movedTrack.playlistItemId else {
            Log.app.notice("moveTrackInPlaylist(\(playlistId, privacy: .public)) — track missing PlaylistItemId, local-only")
            return
        }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [core] in
                    try core.reorderPlaylistTrack(
                        playlistId: playlistId,
                        playlistItemId: playlistItemId,
                        newIndex: UInt32(insertIndex)
                    )
                }.value
                serverReachability.noteSuccess()
            } catch {
                if handleAuthError(error) { return }
                errorMessage = "Reorder failed: \(error.localizedDescription)"
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
            }
        }
    }

    // MARK: - Playlist sharing

    /// Jellyfin web URL for a playlist, e.g.
    /// `https://server.example.com/web/#/details?id=<playlistId>`. The Jellyfin
    /// web UI uses the same `details` route for albums, artists, and playlists.
    func webURL(for playlist: Playlist) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(playlist.id)")
    }

    /// Copy the playlist's web URL to the system pasteboard.
    func copyShareLink(playlist: Playlist) {
        guard let url = webURL(for: playlist) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the playlist in the Jellyfin web UI.
    func openInJellyfin(playlist: Playlist) {
        guard let url = webURL(for: playlist) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Track actions
    //
    // Backing calls for `TrackContextMenu`. Accept `[Track]` rather than a
    // single `Track` so the same surface handles single-row and multi-select
    // invocations — spec in #95 / #310 / #315. Most of these are TODO stubs
    // pending follow-up FFI work (queue primitives #282, favorites #133,
    // download engine #70, mark-played #133, song radio #144, metadata
    // editor #96).

    /// Insert a selection of tracks immediately after the currently-playing
    /// track. Wired to `core.playNext` for #282; when nothing is playing
    /// falls back to `play(tracks:)` so the menu item always does something.
    func playNext(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if status.currentTrack == nil {
            play(tracks: tracks, startIndex: 0)
            return
        }
        Task {
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.playNext(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

    /// Append a selection of tracks to the end of the queue. Wired to
    /// `core.addToQueue` for #282; when nothing is playing falls back to
    /// `play(tracks:)`.
    func addToQueue(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if status.currentTrack == nil {
            play(tracks: tracks, startIndex: 0)
            return
        }
        Task {
            _ = try? await Task.detached(priority: .userInitiated) { [core] in
                core.addToQueue(tracks: tracks)
            }.value
            self.status = core.status()
        }
    }

    /// Kick off an Instant Mix ("song radio") seeded by a single track.
    /// Kick off an Instant Mix ("song radio") seeded by this track.
    func startSongRadio(track: Track) {
        playInstantMix(seedId: track.id)
    }

    /// Append a selection of tracks to a user-picked playlist.
    /// Route-through to the async `addToPlaylist(trackIds:playlistId:)`
    /// so every context menu **Add to Playlist** entry actually hits the
    /// server.
    func addTracksToPlaylist(tracks: [Track], playlist: Playlist) {
        guard !tracks.isEmpty else { return }
        Task { await addToPlaylist(trackIds: tracks.map(\.id), playlistId: playlist.id) }
    }

    /// Navigate to the album detail screen for this track's album.
    func goToAlbum(track: Track) {
        guard let albumID = track.albumId else { return }
        navPath.append(Route.album(albumID))
    }

    /// Navigate to the artist detail screen for this track's artist.
    func goToArtist(track: Track) {
        guard let artistID = track.artistId else { return }
        navPath.append(Route.artist(artistID))
    }

    /// Present the per-track info sheet (title, album, year, runtime,
    /// codec/bitrate, play count). Read-only landing — edit-in-place is
    /// tracked under #96 and arrives separately. The sheet itself lives at
    /// `Components/TrackInfoSheet.swift`; mounting happens on `MainShell`
    /// driven by `trackInfoSubject`. See #95.
    func showTrackInfo(track: Track) {
        trackInfoSubject = track
    }

    /// Track being shown in the info sheet, or `nil` when the sheet is
    /// dismissed. Mounted via `.sheet(item:)` on `MainShell` so any screen
    /// can request the modal without owning a presentation anchor. See #95.
    var trackInfoSubject: Track?

    /// Remove a selection of tracks from a specific playlist. Used by the
    /// multi-select context menu when scoped to a playlist detail view.
    /// Delegates to `removeFromPlaylist(playlistId:entryIds:)` which also
    /// handles the optimistic UI + server sync.
    func removeTracksFromPlaylist(tracks: [Track], playlist: Playlist) {
        guard !tracks.isEmpty else { return }
        removeFromPlaylist(playlistId: playlist.id, entryIds: tracks.map(\.id))
    }

    /// Toggle favorite across every track in the selection. If every track
    /// is already favorited, this unfavorites them all; otherwise favorites
    /// the un-favorited subset.
    func toggleFavorite(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let allFavorited = tracks.allSatisfy { isFavorite(track: $0) }
        let target = !allFavorited
        // Fire each toggle on its own task so partial success is preserved —
        // one rate-limit or 500 doesn't poison the rest of the selection.
        for track in tracks {
            // Skip tracks already in the target state so we don't retoggle.
            guard isFavorite(track: track) != target else { continue }
            Task { await setFavorite(itemId: track.id, enabled: target) }
        }
    }

    /// Toggle the download state of every track in the selection.
    /// TODO(#70): download engine not yet wired.
    func toggleDownload(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // TODO(#70): download engine not yet wired.
        Log.app.notice("toggleDownload(tracks: \(tracks.count, privacy: .public)) not yet wired — see #70")
    }

    /// Toggle the played flag across a multi-select of tracks. Target
    /// state is "everyone unplayed" if **all** selected tracks are
    /// currently played; otherwise "everyone played". This matches the
    /// menubar / context-menu convention where a single click on a
    /// mixed selection commits to one direction. Each track's flip is
    /// optimistic locally and reconciled against the server's response;
    /// failures don't abort the rest of the batch. See #133.
    func toggleMarkPlayed(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // Decide target: prefer the cached value, fall back to the track's
        // embedded user_data, finally `false` if nothing is known. Mark
        // played unless every track is *already* played.
        let allPlayed = tracks.allSatisfy { track in
            if let cached = playedById[track.id] { return cached }
            return track.userData?.played ?? false
        }
        let target = !allPlayed
        // Optimistic flip on the whole selection so the glyph updates instantly.
        for track in tracks { playedById[track.id] = target }
        Task {
            for track in tracks {
                await setPlayed(itemId: track.id, played: target)
            }
        }
    }

    // MARK: - Track sharing

    /// Jellyfin web URL for a single track. Jellyfin's web UI uses the
    /// same `details` route for every item type, so this mirrors
    /// `webURL(for album:)` / `webURL(for playlist:)`.
    func webURL(for track: Track) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(track.id)")
    }

    /// Copy the track's web URL to the system pasteboard.
    func copyShareLink(track: Track) {
        guard let url = webURL(for: track) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Genre actions
    //
    // Backing calls for `GenreContextMenu`. The core doesn't yet expose a
    // Genre type (genres are surfaced as bare strings on `Album`/`Artist`
    // today). All four actions are TODO stubs pending follow-up work
    // (#144 radio, #318 genre detail screen, #248 / #249 Home pinning).

    /// Navigate to the genre's browse view.
    /// TODO(#318): genre detail screen not yet implemented.
    func browseGenre(genre: String) {
        // TODO(#318): genre detail screen not yet implemented.
        Log.app.notice("browseGenre(\(genre, privacy: .public)) not yet wired — see #318")
    }

    /// Kick off an Instant Mix seeded by a genre.
    func startGenreRadio(genre: String) {
        playInstantMix(seedId: genre)
    }

    /// Shuffle every track tagged with the given genre.
    /// TODO(#318): genre-scoped track list FFI not yet wired.
    func shuffleGenre(genre: String) {
        // TODO(#318): genre-scoped track list FFI not yet wired.
        Log.app.notice("shuffleGenre(\(genre, privacy: .public)) not yet wired — see #318")
    }

    /// Pin a genre tile to the Home screen so the user can one-click-browse.
    /// TODO(#248 / #249): Home personalization (pinned tiles) not yet wired.
    func pinGenreToHome(genre: String) {
        // TODO(#248): pinned tiles not yet wired.
        Log.app.notice("pinGenreToHome(\(genre, privacy: .public)) not yet wired — see #248 / #249")
    }

    func pause() { audio.pause() }
    func resume() { audio.resume() }
    func stop() { audio.stop() }

    func skipNext() {
        if let next = core.skipNext() {
            playCurrent(next)
        } else {
            stop()
        }
    }

    func skipPrevious() {
        if let prev = core.skipPrevious() {
            playCurrent(prev)
        }
    }

    func setVolume(_ v: Float) { audio.setVolume(v) }

    /// Seek the current track by a relative offset (seconds). Negative rewinds,
    /// positive fast-forwards. Clamped to `[0, duration]` so the seek never
    /// overshoots the track's own bounds; routes through `audio.seek` exactly
    /// like the scrubber / `mediaSessionSeek` so the `MPNowPlayingInfoCenter`
    /// widget gets the same one-writer update. Wired to the ⌘⇧← / ⌘⇧→ menu
    /// shortcuts and the list row "skip back/forward" affordances. See #6.
    func seek(by delta: Double) {
        guard status.currentTrack != nil else { return }
        let duration = max(0, status.durationSeconds)
        let target = status.positionSeconds + delta
        let clamped = max(0, duration > 0 ? min(target, duration) : target)
        audio.seek(toSeconds: clamped)
    }

    /// Absolute seek used by the PlayerBar's scrubber Slider (#332). Same
    /// clamping + one-writer routing as `seek(by:)`, but takes an absolute
    /// position rather than a delta so the Slider's drag handle can bind
    /// straight through.
    func seek(toSeconds target: Double) {
        guard status.currentTrack != nil else { return }
        let duration = max(0, status.durationSeconds)
        let clamped = max(0, duration > 0 ? min(target, duration) : target)
        audio.seek(toSeconds: clamped)
    }

    func togglePlayPause() {
        switch status.state {
        case .playing: pause()
        case .paused: resume()
        case .ended, .stopped, .idle, .loading:
            // End-of-track or other non-active states: restart the current
            // track so ⌘-Space after a song ends does the obvious thing.
            if let track = status.currentTrack {
                playCurrent(track)
            }
        }
    }

    private func playCurrent(_ track: Track) {
        do {
            try audio.play(track: track)
        } catch {
            if handleAuthError(error) { return }
            errorMessage = JellifyErrorPresenter.message(for: error, context: .playback)
        }
    }

    private func handleTrackEnded() {
        // Advance to the next track in the queue if there is one.
        if let next = core.skipNext() {
            playCurrent(next)
        }
    }

    // MARK: - Now Playing details

    /// Fetch detail fields (currently just `People`) for the track that is
    /// playing right now and publish the result on `currentTrackPeople` so
    /// the Now Playing credits block can render them. See #279.
    ///
    /// Safe to call repeatedly — if the current track hasn't changed since
    /// the last successful fetch, this is a no-op. On auth errors the
    /// central `handleAuthError` path triggers the re-login prompt; other
    /// errors are swallowed silently because Credits is a secondary
    /// widget and an empty state reads better than an error banner.
    func fetchCurrentTrackDetails() async {
        guard let track = status.currentTrack else {
            currentTrackPeople = []
            currentTrackPeopleForId = nil
            return
        }
        // Already have details for this track — skip.
        if currentTrackPeopleForId == track.id { return }
        let id = track.id
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(itemId: id, fields: ["People"])
            }.value
            // Ignore the response if the user skipped to a different track
            // while we were awaiting.
            guard status.currentTrack?.id == id else { return }
            currentTrackPeople = Self.parsePeople(from: json)
            currentTrackPeopleForId = id
        } catch {
            _ = handleAuthError(error)
            // Silent fallback — credits is a best-effort block.
        }
    }

    /// Parse Jellyfin's `Item.People` array out of the raw JSON returned by
    /// `core.fetchItem`. Each person comes back as
    /// `{ "Name": string, "Type": string, "Role": string, ... }`; only
    /// `Name` and `Type` are retained (see `Person`). Entries missing a
    /// non-empty `Name` are dropped so we don't render blank rows.
    static func parsePeople(from json: String) -> [Person] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["People"] as? [[String: Any]]
        else {
            return []
        }
        return raw.compactMap { entry in
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let type = (entry["Type"] as? String) ?? ""
            let rawId = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = rawId.isEmpty ? nil : rawId
            guard !name.isEmpty else { return nil }
            return Person(name: name, type: type, id: id)
        }
    }

    /// Load lyrics for the currently-playing track and publish them on
    /// `currentLyrics`. Supports both LRC (timestamped) and plain-text
    /// bodies via the core `Lyrics` record — `LyricsView` renders the
    /// right layout based on `is_synced`. See #91, #273, #287, #288.
    ///
    /// Safe to call repeatedly — short-circuits when the current track
    /// id already matches the last successful fetch. Cleared on track
    /// change by the polling loop (see `startPolling`).
    func fetchCurrentTrackLyrics() async {
        guard let track = status.currentTrack else {
            currentLyrics = nil
            currentLyricsForId = nil
            return
        }
        if currentLyricsForId == track.id { return }
        let id = track.id
        do {
            let lyrics = try await Task.detached(priority: .userInitiated) { [core] in
                try core.lyrics(trackId: id)
            }.value
            guard status.currentTrack?.id == id else { return }
            if let lyrics {
                // The FFI `LyricLine` has `timeSeconds: Double`; internal
                // `LyricLine` uses `Double?` for the "untimed" case (plain
                // text). When the server reports `is_synced == false` the
                // payload is typically a single line with `time_seconds == 0.0`
                // — preserve the nil-timestamp convention so LyricsView
                // doesn't auto-scroll a static blob.
                currentLyrics = lyrics.lines.enumerated().map { idx, line in
                    LyricLine(
                        id: idx,
                        timestamp: lyrics.isSynced ? line.timeSeconds : nil,
                        text: line.text
                    )
                }
            } else {
                currentLyrics = []
            }
            currentLyricsForId = id
        } catch {
            _ = handleAuthError(error)
            guard status.currentTrack?.id == id else { return }
            currentLyrics = []
            currentLyricsForId = id
        }
    }

    // MARK: - Status polling

    /// Drive the status poll loop. The timer fires at a 1s cadence (was
    /// 500ms in rc<=10 — every tick takes the Rust core's `parking_lot`
    /// mutex on the MainActor and republishes `@Observable` state, which
    /// SwiftUI treats as a redraw signal even when the actual values
    /// didn't change).
    ///
    /// rc11 also tried to skip the tick body entirely when
    /// `status.state != .playing`, but `pause()` / `resume()` /
    /// `skipNext()` / `skipPrevious()` delegate straight to
    /// `AudioEngine` and never call `refreshStatus()` — so after the
    /// first user-driven pause the local `status.state` stayed `.paused`
    /// forever and the PlayerBar froze: clicking play resumed audio
    /// audibly but no UI signaled the transition (rc12 regression
    /// caught by the user). The energy win from this skip was small
    /// compared to the dominant `timeObserver` rate-zero skip in
    /// `JellifyAudio/AudioEngine`, so rc13 keeps the 1s cadence and
    /// drops the gate. Idle wakes/hour:
    ///   rc<=10: ~14,400 (500ms pollTimer + 500ms timeObserver)
    ///   rc11/12: ~0 paused, but UI broke
    ///   rc13:    ~3,600 paused (1s pollTimer ticks; timeObserver
    ///            still skips when `player.rate == 0`)
    /// — which still clears the macOS "high energy use" badge while
    /// keeping the player UI live.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let before = self.status.currentTrack?.id
                let beforeQueuePos = self.status.queuePosition
                let beforeQueueLen = self.status.queueLength
                self.status = self.core.status()
                let after = self.status.currentTrack?.id
                // Trigger a details refetch when the track changes. Scoped
                // to the polling loop so skipping via the PlayerBar,
                // media keys, or end-of-track auto-advance all get it
                // for free.
                if before != after {
                    if after == nil {
                        self.currentTrackPeople = []
                        self.currentTrackPeopleForId = nil
                        self.currentLyrics = nil
                        self.currentLyricsForId = nil
                    } else {
                        Task { await self.fetchCurrentTrackDetails() }
                        Task { await self.fetchCurrentTrackLyrics() }
                    }
                }
                // Keep MediaSession's queue index in sync when a skip
                // happens. `AudioEngine.play(track:)` already fires
                // `trackChanged` for the new item; `queueChanged` handles
                // the case where the queue length shifts without a new
                // track starting (e.g. future `setQueue` on the current).
                // Elapsed time is intentionally NOT pushed on every tick
                // (see issue #48 — the widget interpolates from
                // `elapsed + wallclock * rate`).
                if beforeQueuePos != self.status.queuePosition
                    || beforeQueueLen != self.status.queueLength {
                    self.mediaSession.queueChanged()
                }
            }
        }
        // Pin the timer to .common so it keeps firing while the user is
        // dragging a slider or interacting with menus (the default
        // .default mode is suspended during those tracking loops).
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Queue inspector (BATCH-07a)

    /// Toggle the right-side Queue Inspector panel. Bound to the Cmd+Opt+Q
    /// keyboard shortcut via `MainShell`. See #79.
    func toggleQueueInspector() {
        isQueueInspectorOpen.toggle()
    }

    /// Reorder the user-added "Up Next" list. Uses the same `IndexSet` → Int
    /// contract as SwiftUI `List.onMove`, so the inspector can wire this up
    /// directly. See #80.
    ///
    /// Today this only reorders the in-app overlay because the core has no
    /// `reorder_queue` primitive. When that lands (TODO(core-#282)), this
    /// should also push the new order down to `core.setQueue` so the
    /// engine's view of "what plays next" matches the inspector.
    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNextUserAdded.move(fromOffsets: source, toOffset: destination)
        // Sync the reordered user-added list to the Rust core (#565).
        // Rebuild a flat track array — current track at index 0, then the
        // reordered Up Next overlay, then the auto-queue tail — and hand it
        // back to `core.setQueue` with startIndex 0 so the engine keeps
        // playing the current track while honouring the new order for
        // everything that follows. The `try?` silences the throw so a core
        // hiccup (e.g. session not ready) doesn't crash the UI.
        var allTracks: [Track] = []
        if let current = status.currentTrack { allTracks.append(current) }
        allTracks.append(contentsOf: upNextUserAdded.map(\.track))
        allTracks.append(contentsOf: upNextAutoQueue.map(\.track))
        guard !allTracks.isEmpty else { return }
        try? core.setQueue(tracks: allTracks, startIndex: 0)
    }

    /// Remove one entry from the user-added "Up Next" list by its stable
    /// per-item `queueId`. Uses `queueId` rather than `track.id` so users
    /// can queue the same track twice and still remove a single instance.
    /// See #80.
    func removeFromUpNext(id: UUID) {
        upNextUserAdded.removeAll { $0.id == id }
        // TODO(core-#282): drop the corresponding entry in the core queue
        // once we have an addressable `remove_from_queue` primitive.
    }

    // MARK: - Queue actions (BATCH-07b, #284)

    /// Empty both the user-added "Up Next" overlay and the auto-queue tail.
    /// The Queue Inspector's Clear action lands here behind a confirmation
    /// dialog so an accidental click can't wipe a long queue. Does not
    /// touch the currently-playing track — only what comes after. See #284.
    ///
    /// The core queue itself still holds the original list (no primitive
    /// for truncation yet, tracked as TODO(core-#282)); clearing here means
    /// the inspector goes empty but the engine can continue auto-advancing
    /// through the underlying album/playlist. We don't reach into
    /// `core.setQueue` because truncating on remove would also cancel the
    /// currently-playing track on most engines.
    func clearQueue() {
        upNextUserAdded.removeAll()
        upNextAutoQueue.removeAll()
        // Pause playback immediately so no phantom track continues (#567).
        // AVPlayer still has the current item loaded after the queue arrays
        // are cleared — pausing is the robust fix since stop() tears down
        // the player item and would break resumption.
        //
        // We intentionally do *not* reach into the core's queue here: the
        // only primitive available is `set_queue`, which rejects an empty
        // vec with `InvalidIndex` (see `Player::set_queue` in player.rs).
        // The earlier `try? core.setQueue(tracks: [], startIndex: 0)` was
        // a silent no-op and is removed. Core-side queue truncation is
        // tracked as TODO(core-#282); until then, any auto-advance is
        // gated by the paused AVPlayer above.
        audio.pause()
    }

    /// Serialize the current queue (currently-playing + user-added + auto
    /// tail) into a freshly-created playlist on the server. Called from
    /// the Queue Inspector's Save action (#284) after the user picks a
    /// name.
    ///
    /// Implementation: `core.create_playlist(name:, itemIds:)` accepts an
    /// initial `itemIds` payload, so we try it in a single FFI hop and
    /// then chase with `add_to_playlist` to cover older Jellyfin builds
    /// that rewrite `ItemIds` to empty on create. After a successful save,
    /// the local `playlists` cache picks up the new entry on next library
    /// refresh — we don't eagerly fetch it here to keep the action snappy.
    ///
    /// Errors surface on `errorMessage` so the caller sheet can stay
    /// presentation-only. Empty queues short-circuit — creating an empty
    /// playlist from the queue inspector would be nonsensical.
    func saveQueueAsPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Build the track id list in the order the user sees: current →
        // user-added → auto tail. `Set` de-duplicates in case the same
        // track appears twice (e.g. queued and also present in the auto
        // tail); first-seen order is preserved for clarity.
        var seen = Set<String>()
        var ids: [String] = []
        if let current = status.currentTrack {
            if seen.insert(current.id).inserted { ids.append(current.id) }
        }
        for entry in upNextUserAdded {
            if seen.insert(entry.track.id).inserted { ids.append(entry.track.id) }
        }
        for entry in upNextAutoQueue {
            if seen.insert(entry.track.id).inserted { ids.append(entry.track.id) }
        }
        guard !ids.isEmpty else { return }
        do {
            let newId = try await Task.detached(priority: .userInitiated) { [core] in
                try core.createPlaylist(name: trimmed, itemIds: ids, position: nil)
            }.value
            // Some older Jellyfin builds ignore the initial `ItemIds` on
            // `create_playlist` and return an empty playlist. Follow up
            // with `add_to_playlist` as a best-effort top-up so the saved
            // queue always lands with its tracks, regardless of server
            // version. `add_to_playlist` on a server that did honor the
            // initial ids would duplicate entries — we accept that
            // tradeoff over silently dropping the saved queue on older
            // servers.
            if !newId.isEmpty {
                _ = await addToPlaylist(trackIds: ids, playlistId: newId)
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Save queue failed: \(error.localizedDescription)"
        }
    }

    /// Shuffle the user-added "Up Next" list in place. The Queue
    /// Inspector's Shuffle action lands here (#284). The currently-playing
    /// track is not part of `upNextUserAdded` — it lives on
    /// `status.currentTrack` and is unaffected by this call.
    ///
    /// A short-list guard keeps the UI honest: shuffling one item (or
    /// none) is a no-op, so we don't waste a pass.
    func shuffleUpNext() {
        guard upNextUserAdded.count > 1 else { return }
        upNextUserAdded.shuffle()
        // TODO(core-#282): when `reorder_queue` / `shuffle_queue` exists,
        // push the new order down so the engine plays in the shuffled
        // order rather than its original load order.
    }

    /// Navigate to the source that started the current auto queue. Wired
    /// from the PlayerBar's "Playing from {source}" label (#82). No-ops
    /// when `currentContext` has no navigable id (ad-hoc selections, radio
    /// seeds) or an unsupported `sourceType`.
    func goToPlayingFromSource() {
        guard let context = currentContext, let id = context.id, !id.isEmpty else { return }
        switch context.sourceType {
        case .playlist:
            if let playlist = playlists.first(where: { $0.id == id }) {
                goToPlaylist(playlist)
            } else {
                navPath.append(Route.playlist(id))
            }
        case .album:
            navPath.append(Route.album(id))
        case .artist:
            navPath.append(Route.artist(id))
        case .genre, .search, .radio, .other:
            // No dedicated surface for these source types yet — do nothing
            // rather than route to a placeholder. The label itself is
            // rendered non-clickable when this branch would be hit.
            break
        }
    }

    /// Whether the current playback source has a navigable target. Drives
    /// the clickable / non-clickable styling on the PlayerBar's "Playing
    /// from" label (#82). Genre / search / radio / other don't have a
    /// single detail surface today, so the label reads as plain text on
    /// those.
    var currentContextIsNavigable: Bool {
        guard let context = currentContext, let id = context.id, !id.isEmpty else { return false }
        switch context.sourceType {
        case .album, .artist, .playlist: return true
        case .genre, .search, .radio, .other: return false
        }
    }
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
        let total = Int(durationSeconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
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

/// Client-side genre record used by `InstantSearchResults` and the search
/// dropdown's genre row. Jellyfin returns genres as bare strings on
/// `Album`/`Artist` today, so an `id` is derived from the name until a
/// proper `MusicGenre` item shape lands in core (see `GenreContextMenu`'s
/// TODO for #318).
struct Genre: Hashable, Identifiable, Sendable {
    let id: String
    let name: String

    init(name: String) {
        self.name = name
        // Name doubles as id — genres are unique by label in Jellyfin's
        // surface and we don't have the real collection ids yet.
        self.id = name
    }
}

/// Heterogeneous "thing" returned by the instant-search dropdown. Wraps the
/// four core record types plus `Genre` so the dropdown's `onPickItem`
/// callback can carry enough context for routing without per-type
/// callbacks.
///
/// `title` / `playCount` are derived so the ranking algorithm in
/// `AppModel.pickTopResult` can stay generic.
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

/// Aggregate payload for the instant-search dropdown. Split into typed
/// sections so the dropdown can render each without re-partitioning, and
/// carries a pre-ranked `topResult` so the hero card doesn't need to
/// re-run the ranker on every view update. See `AppModel.runInstantSearch`.
struct InstantSearchResults: Sendable {
    let topResult: SearchItem?
    let artists: [Artist]
    let albums: [Album]
    let tracks: [Track]
    let playlists: [Playlist]
    let genres: [Genre]

    static let empty = InstantSearchResults(
        topResult: nil,
        artists: [],
        albums: [],
        tracks: [],
        playlists: [],
        genres: []
    )

    /// True when every section is empty — the dropdown uses this to
    /// decide between rendering results vs. a minimal "no matches" state.
    var isEmpty: Bool {
        topResult == nil
            && artists.isEmpty
            && albums.isEmpty
            && tracks.isEmpty
            && playlists.isEmpty
            && genres.isEmpty
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
}

// NOTE: `SearchItem` is defined above (next to `InstantSearchResults`) with
// `case genre(Genre)`. The full-page search surface below uses that same
// type — the duplicate `case genre(String)` variant originally added here
// was collapsed into the canonical enum when #535 (instant dropdown, which
// introduced `Genre`) landed alongside this PR.

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
    }

    func mediaSessionSetRepeatMode(_ mode: RepeatMode) {
        core.setRepeatMode(mode: mode)
        refreshStatus()
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

    func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL? {
        imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: maxWidth)
    }
    func mediaSessionAuthorizationHeader() -> String? {
        try? core.authHeader()
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
