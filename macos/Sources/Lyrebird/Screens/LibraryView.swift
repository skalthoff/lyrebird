import AppKit
import SwiftUI
@preconcurrency import LyrebirdCore

/// Shared hover state for the Library grid. A single optional item ID lives
/// on the `LibraryView` root and gets read by every `AlbumCard` / `ArtistCard`,
/// so cells in the 5k+ library grid don't each carry their own
/// `@State var isHovering`. See #428.
///
/// `AlbumCard` is also rendered by `SearchView` without a container tracker —
/// the env default carries `isActive = false`, and cells fall back to a local
/// `@State` on that path so hover affordance keeps working outside the
/// library. The library path (`isActive = true`) uses the shared ID
/// exclusively and the cell's local state stays inert.
struct LibraryHoverBinding {
    var id: Binding<String?>
    /// `true` when a container lifted hover tracking up; cells on this path
    /// read/write the shared ID and ignore their local fallback state.
    var isActive: Bool

    static let inactive = LibraryHoverBinding(id: .constant(nil), isActive: false)
}

private struct LibraryHoverIDKey: EnvironmentKey {
    static let defaultValue = LibraryHoverBinding.inactive
}

extension EnvironmentValues {
    var libraryHoverID: LibraryHoverBinding {
        get { self[LibraryHoverIDKey.self] }
        set { self[LibraryHoverIDKey.self] = newValue }
    }
}

/// Library tab options. The active tab filters what the library grid shows
/// and drives the count subline. See `Chip` / `ChipRow` in
/// `Components/Chips.swift` and spec issue #212.
enum LibraryTab: Hashable, CaseIterable {
	case tracks, albums, artists, playlists, downloaded

	var label: String {
		switch self {
		case .tracks: return "Tracks"
		case .albums: return "Albums"
		case .artists: return "Artists"
		case .playlists: return "Playlists"
		case .downloaded: return "Downloaded"
		}
	}

	/// Lowercase noun used in the count subline ("42 albums").
	var countNoun: String {
		switch self {
		case .tracks: return "tracks"
		case .albums: return "albums"
		case .artists: return "artists"
		case .playlists: return "playlists"
		case .downloaded: return "downloaded"
		}
	}
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .grid
    /// Local mirror of `model.libraryTab`. Starts from whatever the sidebar /
    /// last session left it at, updates the model on chip taps so the sidebar
    /// selection (and a future back-nav into the library) land on the same
    /// tab the user last touched.
    @State private var selectedTab: LibraryTab = .albums
    /// Single shared hover ID for the grid. Published via
    /// `.libraryHoverID` env so every cell reads from (and writes to) the same
    /// binding — avoids N `@State`s on a 5k-item grid. See #428.
    @State private var hoverID: String?
    /// Active sort applied to the displayed library list. Re-orders the
    /// already-loaded `model.X` arrays client-side; the menu in the header
    /// drives this. Defaults to alphabetical to match the order the server
    /// returns by default (`SortName` ascending).
    @State private var sortOrder: LibrarySortOrder = .nameAscending
    /// Active client-side filter applied to the loaded library arrays before
    /// sorting. Edited via the filter popover in the header. See #214.
    @State private var filter = LibraryFilter()
    /// Drives the filter popover's presentation. Anchored to the filter icon.
    @State private var showFilter = false
    /// Row density for the Tracks tab, bound to the Appearance preference
    /// (#217). 48pt roomy / 36pt compact — see `AppearanceDensity`.
    @AppStorage(AppearanceKeys.density) private var densityRaw: String = AppearanceDensity.roomy.rawValue
    /// Track ids in the user's multi-selection on the Tracks tab. Empty means
    /// no selection; the selection banner is shown whenever it's non-empty.
    /// Cleared on Esc, on a bare click, and on switching chips. See #217.
    @State private var selectedTrackIds: Set<String> = []
    /// Anchor row index for Shift+Click range extension. Mirrors the pattern
    /// in `PlaylistDetailView`.
    @State private var anchorIndex: Int? = nil
    /// Persisted default sort applied to the Albums chip on first entry and
    /// whenever the user switches to it without having hand-picked a sort.
    /// Set in Preferences → Library. See `LibraryDefaults`.
    @AppStorage(LibraryDefaults.albumSortKey) private var defaultAlbumSort: LibrarySortOrder = .nameAscending
    /// Persisted default sort applied to the Tracks (Songs) chip. Same
    /// mechanics as `defaultAlbumSort`.
    @AppStorage(LibraryDefaults.songSortKey) private var defaultSongSort: LibrarySortOrder = .nameAscending
    /// Chips whose persisted default we've already applied this session, so
    /// re-entering a tab the user already customised doesn't clobber their
    /// manual sort choice. A tab is removed from the set when its persisted
    /// default changes in Preferences mid-session, so the new default re-applies
    /// on next entry (and immediately, if that tab is on screen).
    @State private var appliedDefaultTabs: Set<LibraryTab> = []

    private var density: AppearanceDensity {
        AppearanceDensity(rawValue: densityRaw) ?? .roomy
    }

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)]

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    chipRow
                    if model.isLoadingLibrary && model.albums.isEmpty {
                        ProgressView()
                            .tint(Theme.ink2)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        content
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                // Leave room for the floating selection banner so the last
                // rows aren't occluded while a selection is active.
                .padding(.bottom, selectedTracks.isEmpty ? 32 : 88)
            }
            .background(backgroundWash)

            if !selectedTracks.isEmpty {
                TrackSelectionBanner(
                    selection: selectedTracks,
                    onClear: clearSelection
                )
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTrackIds.isEmpty)
        // Esc clears the selection from anywhere in the view (the banner's ✕
        // also has the .escape shortcut for when it holds focus). See #217.
        .onKeyPress(.escape) {
            guard !selectedTrackIds.isEmpty else { return .ignored }
            clearSelection()
            return .handled
        }
        .environment(
            \.libraryHoverID,
            LibraryHoverBinding(id: $hoverID, isActive: true)
        )
        // Sync the local `selectedTab` with `model.libraryTab` so the
        // sidebar's Albums/Artists/Playlists libRows can deep-link into
        // a specific chip. `.onAppear` covers the case where the library
        // is entered fresh; `.onChange` covers the case where the user
        // is already on the library and the sidebar flips the tab.
        .onAppear {
            selectedTab = model.libraryTab
            applyDefaultSort(for: selectedTab)
            applyPendingDecadeFilter()
        }
        .onChange(of: model.libraryTab) { _, newValue in
            selectedTab = newValue
        }
        // A decade tile tapped while the Library is already on screen flips
        // `pendingLibraryYearRange` without re-running `.onAppear`; pick it up
        // here so the year filter still lands.
        .onChange(of: model.pendingLibraryYearRange) { _, _ in
            applyPendingDecadeFilter()
        }
        .onChange(of: selectedTab) { _, newValue in
            // Write-back so the sidebar's highlighted chip stays in sync.
            if model.libraryTab != newValue {
                model.libraryTab = newValue
            }
            // Switching chips abandons any track multi-selection — the rows
            // it referenced are no longer on screen. See #217.
            clearSelection()
            applyDefaultSort(for: newValue)
        }
        // `anchorIndex` is a positional cursor into the displayed list; a sort
        // or filter change reorders that list, so a stale anchor would extend a
        // Shift+Click range from the wrong row. The ID-based `selectedTrackIds`
        // survives the reorder, so only the anchor needs clearing. See #217.
        .onChange(of: sortOrder) { _, _ in anchorIndex = nil }
        .onChange(of: filter) { _, _ in anchorIndex = nil }
        // A change to a persisted default while this view is alive means the
        // user just edited Preferences → Library. Re-apply so the criterion
        // "changes reflect in list views" holds without a relaunch.
        .onChange(of: defaultAlbumSort) { _, _ in
            reapplyDefaultSort(for: .albums)
        }
        .onChange(of: defaultSongSort) { _, _ in
            reapplyDefaultSort(for: .tracks)
        }
    }

    /// The selected tracks resolved against the currently-sorted list, in
    /// display order. Used by the selection banner so its batch actions run
    /// on the same ordering the user sees.
    private var selectedTracks: [Track] {
        guard !selectedTrackIds.isEmpty else { return [] }
        return sortedTracks.filter { selectedTrackIds.contains($0.id) }
    }

    private func clearSelection() {
        selectedTrackIds = []
        anchorIndex = nil
    }

    /// Resolve a click on `index` within the sorted tracks list given the
    /// modifier state. Cmd toggles the hit row; Shift extends a contiguous
    /// range from the anchor; a bare click plays the row and resets the
    /// selection. Mirrors `PlaylistDetailView.handleRowClick`. See #217.
    ///
    /// The pure selection arithmetic lives in `TrackSelectionResolver.resolve`
    /// so it can be unit-tested without a View or an `AppModel`; this method is
    /// only the thin glue that applies the result to `@State` and fires the
    /// play side effect.
    private func handleTrackClick(index: Int, in tracks: [Track], modifiers: NSEvent.ModifierFlags) {
        let outcome = TrackSelectionResolver.resolve(
            clickedIndex: index,
            trackIds: tracks.map(\.id),
            currentSelection: selectedTrackIds,
            anchorIndex: anchorIndex,
            modifiers: modifiers
        )
        guard let outcome else { return }
        selectedTrackIds = outcome.selection
        anchorIndex = outcome.anchorIndex
        if outcome.shouldPlay {
            model.play(tracks: tracks, startIndex: index)
        }
    }

    /// Jellyfin's web UI lives at `/web/` on the server host. Falls back to
    /// `nil` if the user somehow lands here without a server URL so the empty
    /// state can hide the CTA.
    private var serverWebURL: URL? {
        let trimmed = model.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: "\(base)/web/")
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR LIBRARY")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .tracking(2)
                Text("Library")
                    .font(Theme.font(36, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                // Count subline — 11pt uppercase `ink3`. Updates live as the
                // user switches chips. Shows "N of M" while more pages exist
                // on the server; falls back to "N" once loaded == total.
                // See #212 / #429 / screen spec Issue 13.
                Text(countSubline)
                    .font(Theme.font(11, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(1.2)
                    .accessibilityLabel(countAccessibilityLabel)
            }
            Spacer()
            HStack(spacing: 8) {
                filterButton
                LibrarySortMenu(selection: $sortOrder)
                LibraryViewToggle(mode: $viewMode)
            }
        }
    }

    /// Filter icon that opens the 280pt filter popover. Carries a 10pt pink
    /// dot when at least one filter group is active. See #214 / screen spec
    /// Issue 15.
    private var filterButton: some View {
        Button {
            showFilter = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filter.isActive ? Theme.ink : Theme.ink2)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if filter.isActive {
                        Circle()
                            .fill(Theme.accentHot)
                            .frame(width: 10, height: 10)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter library")
        .accessibilityValue(
            filter.isActive
                ? "\(filter.activeGroupCount) filters active"
                : "No filters"
        )
        .popover(isPresented: $showFilter, arrowEdge: .bottom) {
            LibraryFilterPopover(
                filter: $filter,
                availableGenres: availableGenres,
                yearBounds: yearBounds,
                showDownloaded: model.supportsDownloads,
                onClose: { showFilter = false }
            )
        }
    }

    private var chipRow: some View {
        ChipRow(
            options: LibraryTab.allCases.map { (label: $0.label, tag: $0) },
            selection: $selectedTab
        )
    }

    /// Grid / list body for the currently selected chip. Albums, artists,
    /// tracks, and playlists all have live content today; Downloaded
    /// renders the shared empty state until the download engine lands
    /// (#70 / #222).
    ///
    /// Distance from the end of the grid at which the near-end
    /// `.onAppear` trigger fires a follow-up page. 20 is enough to overlap
    /// two screen-heights on a MacBook display, which is plenty of runway
    /// to hide round-trip latency.
    private let paginationTriggerDistance = 20

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .albums:
            if model.albums.isEmpty {
                EmptyLibraryState(serverUrl: serverWebURL)
            } else {
                let items = sortedAlbums
                VStack(alignment: .leading, spacing: 18) {
                    switch viewMode {
                    case .grid:
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, album in
                                AlbumCard(album: album)
                                    .onAppear {
                                        triggerLoadMoreAlbumsIfNeeded(atIndex: idx)
                                    }
                            }
                        }
                    case .list:
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, album in
                                LibraryListRow(album: album)
                                    .onAppear {
                                        triggerLoadMoreAlbumsIfNeeded(atIndex: idx)
                                    }
                            }
                        }
                    }
                    if model.isLoadingMoreAlbums {
                        paginationSpinner
                    }
                }
            }
        case .artists:
            if model.artists.isEmpty {
                EmptyLibraryState(serverUrl: serverWebURL)
            } else {
                let items = sortedArtists
                VStack(alignment: .leading, spacing: 18) {
                    switch viewMode {
                    case .grid:
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, artist in
                                ArtistCard(artist: artist)
                                    .onAppear {
                                        triggerLoadMoreArtistsIfNeeded(atIndex: idx)
                                    }
                            }
                        }
                    case .list:
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, artist in
                                LibraryListRow(artist: artist)
                                    .onAppear {
                                        triggerLoadMoreArtistsIfNeeded(atIndex: idx)
                                    }
                            }
                        }
                    }
                    if model.isLoadingMoreArtists {
                        paginationSpinner
                    }
                }
            }
        case .tracks:
            // Tracks read naturally as a list, not a grid, so `viewMode`
            // is intentionally ignored here — the All Tracks tab always
            // renders a dense list. Near-end pagination mirrors the
            // albums branch.
            if model.tracks.isEmpty {
                EmptyLibraryState(serverUrl: serverWebURL)
            } else {
                let items = sortedTracks
                VStack(alignment: .leading, spacing: 18) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, track in
                            TrackListRow(
                                track: track,
                                tracks: items,
                                index: idx,
                                isSelected: selectedTrackIds.contains(track.id),
                                onSelect: { modifiers in
                                    handleTrackClick(index: idx, in: items, modifiers: modifiers)
                                },
                                density: density
                            )
                            .onAppear {
                                triggerLoadMoreTracksIfNeeded(atIndex: idx)
                            }
                        }
                    }
                    if model.isLoadingMoreTracks {
                        paginationSpinner
                    }
                }
            }
        case .playlists:
            if model.playlists.isEmpty {
                EmptyLibraryState(serverUrl: serverWebURL)
            } else {
                let items = sortedPlaylists
                VStack(alignment: .leading, spacing: 18) {
                    switch viewMode {
                    case .grid:
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, playlist in
                                PlaylistCard(playlist: playlist)
                                    .onAppear {
                                        triggerLoadMorePlaylistsIfNeeded(atIndex: idx)
                                    }
                            }
                        }
                    case .list:
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, playlist in
                                LibraryListRow(playlist: playlist)
                                    .onAppear {
                                        triggerLoadMorePlaylistsIfNeeded(atIndex: idx)
                                    }
                            }
                        }
                    }
                    if model.isLoadingMorePlaylists {
                        paginationSpinner
                    }
                }
            }
        case .downloaded:
            // Placeholder until the per-tab surface lands. The chip row, header,
            // and count subline remain live so navigation feels responsive.
            EmptyLibraryState(serverUrl: serverWebURL)
        }
    }

    /// Bottom spinner shown while a follow-up page is in flight. Stays under
    /// the grid so interaction with already-loaded items isn't blocked.
    private var paginationSpinner: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(Theme.ink2)
                .scaleEffect(0.8)
            Spacer()
        }
        .padding(.vertical, 12)
        .accessibilityLabel("Loading more")
    }

    /// Fire `loadMoreAlbums` when the user scrolls into the last
    /// `paginationTriggerDistance` cells and there are more albums on the
    /// server than currently loaded. The view-level guard (and the matching
    /// guard in `AppModel.loadMoreAlbums`) together prevent concurrent Tasks
    /// from queuing up and re-firing once the flag clears. Fixes #589.
    private func triggerLoadMoreAlbumsIfNeeded(atIndex idx: Int) {
        let loaded = model.albums.count
        let total = Int(model.albumsTotal)
        guard total > loaded else { return }
        guard !model.isLoadingMoreAlbums else { return }
        let threshold = max(loaded - paginationTriggerDistance, 0)
        guard idx >= threshold else { return }
        Task { await model.loadMoreAlbums() }
    }

    /// Mirror of `triggerLoadMoreAlbumsIfNeeded` for the artists tab. The
    /// model guards against concurrent `loadMoreArtists` calls so firing
    /// this from many adjacent `.onAppear`s is safe.
    private func triggerLoadMoreArtistsIfNeeded(atIndex idx: Int) {
        let loaded = model.artists.count
        let total = Int(model.artistsTotal)
        guard total > loaded else { return }
        guard !model.isLoadingMoreArtists else { return }
        let threshold = max(loaded - paginationTriggerDistance, 0)
        guard idx >= threshold else { return }
        Task { await model.loadMoreArtists() }
    }

    /// Fire `loadMoreTracks` when the user scrolls into the last
    /// `paginationTriggerDistance` cells and there are more tracks on the
    /// server than currently loaded. Mirror of `triggerLoadMoreAlbumsIfNeeded`;
    /// see that function's docs for the concurrency guard rationale (#589).
    private func triggerLoadMoreTracksIfNeeded(atIndex idx: Int) {
        let loaded = model.tracks.count
        let total = Int(model.tracksTotal)
        guard total > loaded else { return }
        guard !model.isLoadingMoreTracks else { return }
        let threshold = max(loaded - paginationTriggerDistance, 0)
        guard idx >= threshold else { return }
        Task { await model.loadMoreTracks() }
    }

    /// Mirror of `triggerLoadMoreAlbumsIfNeeded` for the Playlists grid.
    /// Separate function rather than a parameterised helper so the guard
    /// arithmetic stays obvious at the call site. See #589 for the
    /// concurrency guard rationale.
    private func triggerLoadMorePlaylistsIfNeeded(atIndex idx: Int) {
        let loaded = model.playlists.count
        let total = Int(model.playlistsTotal)
        guard total > loaded else { return }
        guard !model.isLoadingMorePlaylists else { return }
        let threshold = max(loaded - paginationTriggerDistance, 0)
        guard idx >= threshold else { return }
        Task { await model.loadMorePlaylists() }
    }

    /// Count for a given tab. Albums, artists, tracks, and playlists have
    /// real counts; Downloaded is a stub pending the download engine (#70 /
    /// #222).
    private func tabCount(for tab: LibraryTab) -> Int {
        switch tab {
        case .albums: return model.albums.count
        case .artists: return model.artists.count
        case .tracks: return model.tracks.count
        case .playlists: return model.playlists.count
        case .downloaded: return 0
        }
    }

    /// Server-reported total for a given tab. Zero when not yet known or
    /// when the tab doesn't have a backing endpoint yet.
    private func tabTotal(for tab: LibraryTab) -> Int {
        switch tab {
        case .albums: return Int(model.albumsTotal)
        case .artists: return Int(model.artistsTotal)
        case .tracks: return Int(model.tracksTotal)
        case .playlists: return Int(model.playlistsTotal)
        case .downloaded: return 0
        }
    }

    /// 11pt uppercase count subline. Renders as `N of M` when the server
    /// total is known AND more items remain to load; otherwise falls back
    /// to plain `N`. Mirrors the spec's "{n} tracks · Sorted by {sort}" —
    /// sort hasn't been wired yet (#216), so for now the subline is just
    /// the count. Issue #429 / #212.
    private var countSubline: String {
        let count = tabCount(for: selectedTab)
        let total = tabTotal(for: selectedTab)
        if total > count {
            return "\(count) OF \(total) \(selectedTab.countNoun.uppercased())"
        }
        return "\(count) \(selectedTab.countNoun)".uppercased()
    }

    /// VoiceOver-friendly version of the count subline. Reads naturally
    /// as "42 of 5000 albums" rather than the uppercased + tracking-spaced
    /// display string.
    private var countAccessibilityLabel: String {
        let count = tabCount(for: selectedTab)
        let total = tabTotal(for: selectedTab)
        if total > count {
            return "\(count) of \(total) \(selectedTab.countNoun)"
        }
        return "\(count) \(selectedTab.countNoun)"
    }

    private var backgroundWash: some View {
        LinearGradient(
            colors: [Theme.primary.opacity(0.15), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .blur(radius: 80)
        .frame(height: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
    }

    // MARK: - Filter

    /// Genre names found across the loaded library, deduped and sorted A–Z.
    /// Pulled from whichever item arrays are populated so the genre checklist
    /// reflects what's actually loaded (the same paged-cache scope the rest of
    /// the filter operates on). See #214.
    private var availableGenres: [String] {
        var set = Set<String>()
        for album in model.albums { set.formUnion(album.genres) }
        for artist in model.artists { set.formUnion(artist.genres) }
        let cleaned = set
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(cleaned)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Release-year bounds discovered across loaded albums + tracks. `nil`
    /// when nothing carries a year, which hides the year group entirely.
    private var yearBounds: ClosedRange<Int>? {
        var years: [Int] = []
        years.append(contentsOf: model.albums.compactMap { $0.year.map(Int.init) })
        years.append(contentsOf: model.tracks.compactMap { $0.year.map(Int.init) })
        let valid = years.filter { $0 > 0 }
        guard let lo = valid.min(), let hi = valid.max(), lo < hi else { return nil }
        return lo...hi
    }

    /// Whether an album passes the active filter. Genre, year, and favorited
    /// apply to albums; format and duration are track-level and never exclude
    /// an album. Downloaded is a no-op until the download engine lands.
    private func passesFilter(_ album: Album) -> Bool {
        if !filter.genres.isEmpty,
            filter.genres.isDisjoint(with: Set(album.genres)) {
            return false
        }
        if let range = filter.yearRange {
            guard let year = album.year.map(Int.init), range.contains(year) else {
                return false
            }
        }
        if filter.onlyFavorited, !model.isFavorite(album: album) { return false }
        return true
    }

    /// Whether an artist passes the active filter. Only genre and favorited
    /// apply to artists; year/format/duration are not artist-level.
    private func passesFilter(_ artist: Artist) -> Bool {
        if !filter.genres.isEmpty,
            filter.genres.isDisjoint(with: Set(artist.genres)) {
            return false
        }
        if filter.onlyFavorited, !model.isFavorite(artist: artist) { return false }
        return true
    }

    /// Whether a track passes the active filter. Tracks carry every filter
    /// dimension except genre (not projected on the track payload), so genre
    /// is skipped here.
    private func passesFilter(_ track: Track) -> Bool {
        if let range = filter.yearRange {
            guard let year = track.year.map(Int.init), range.contains(year) else {
                return false
            }
        }
        if filter.onlyFavorited, !model.isFavorite(track: track) { return false }
        if !filter.formats.isEmpty {
            guard filter.formats.contains(where: { $0.matches(container: track.container) })
            else { return false }
        }
        if !filter.durations.isEmpty {
            let seconds = Double(track.runtimeTicks) / 10_000_000
            guard filter.durations.contains(where: { $0.matches(seconds: seconds) })
            else { return false }
        }
        return true
    }

    /// Whether a playlist passes the active filter. Only favorited applies.
    private func passesFilter(_ playlist: Playlist) -> Bool {
        if filter.onlyFavorited, !model.isFavorite(playlist: playlist) { return false }
        return true
    }

    // MARK: - Sort

    /// Loaded arrays narrowed to the active filter. Sorting operates on these
    /// so the displayed list is `filter → sort`; the raw `model.X` arrays stay
    /// untouched so pagination accounting (`loaded` vs `total`) is unaffected.
    /// When no filter is active these return the full arrays unchanged.
    private var filteredAlbums: [Album] {
        filter.isActive ? model.albums.filter(passesFilter) : model.albums
    }

    private var filteredArtists: [Artist] {
        filter.isActive ? model.artists.filter(passesFilter) : model.artists
    }

    private var filteredTracks: [Track] {
        filter.isActive ? model.tracks.filter(passesFilter) : model.tracks
    }

    private var filteredPlaylists: [Playlist] {
        filter.isActive ? model.playlists.filter(passesFilter) : model.playlists
    }

    /// Consume the one-shot decade window deep-linked from the Discover
    /// "Browse by Decade" row and fold it into the active filter. Forces
    /// the Albums chip (album items carry the `year` the filter keys on) and
    /// replaces any prior year constraint with the decade's `[start, start+9]`
    /// span. Other filter groups (genre, favorited, …) are preserved so the
    /// decade composes with whatever the user already had set. No-op when no
    /// window is pending, so an ordinary Library visit is untouched.
    private func applyPendingDecadeFilter() {
        guard let range = model.consumePendingLibraryYearRange() else { return }
        selectedTab = .albums
        filter.yearRange = range
    }

    /// Apply the persisted default sort for `tab` the first time the user
    /// lands on it. Albums and Tracks (Songs) each carry their own default
    /// set in Preferences → Library; the other chips keep whatever sort is
    /// active. Guarded by `appliedDefaultTabs` so re-entering a chip the
    /// user has manually re-sorted preserves their choice for the session.
    private func applyDefaultSort(for tab: LibraryTab) {
        guard !appliedDefaultTabs.contains(tab) else { return }
        switch tab {
        case .albums:
            sortOrder = defaultAlbumSort
            appliedDefaultTabs.insert(tab)
        case .tracks:
            sortOrder = defaultSongSort
            appliedDefaultTabs.insert(tab)
        case .artists, .playlists, .downloaded:
            break
        }
    }

    /// React to a mid-session change of a persisted default sort (the user
    /// edited Preferences → Library while the Library view is alive). Drop the
    /// affected tab's "already applied" flag so the new default takes effect on
    /// next entry, and re-apply right away if that tab is currently on screen —
    /// satisfying the "changes reflect in list views" criterion without
    /// clobbering a sort the user hand-picked from the header for a *different*
    /// tab.
    private func reapplyDefaultSort(for tab: LibraryTab) {
        appliedDefaultTabs.remove(tab)
        if selectedTab == tab {
            applyDefaultSort(for: tab)
        }
    }

    /// `filteredAlbums` re-ordered for the current `sortOrder`. The underlying
    /// model array is left untouched so pagination accounting (`loaded` vs
    /// `total`, threshold math) keeps working unchanged. Sort keys that
    /// don't apply to albums (`mostPlayed` for an album with no
    /// `userData.playCount`, `recentlyAdded` with no per-item creation date
    /// on the loaded shape) fall back through to the alphabetical tie-breaker
    /// so the list remains stable.
    private var sortedAlbums: [Album] {
        switch sortOrder {
        case .nameAscending:
            return filteredAlbums.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .nameDescending:
            return filteredAlbums.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .artist:
            return filteredAlbums.sorted { lhs, rhs in
                let cmp = lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName)
                if cmp == .orderedSame {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return cmp == .orderedAscending
            }
        case .random:
            return filteredAlbums.shuffled()
        case .recentlyAdded:
            // `Album` does not carry `DateCreated` on the paginated shape, so
            // preserve the server's load order (which is `SortName` asc by
            // default). Acts as a no-op fallback rather than a misleading
            // "newest first" promise.
            return filteredAlbums
        case .recentlyPlayed:
            return filteredAlbums.sorted { lhs, rhs in
                let lhsDate = lhs.userData?.lastPlayedAt ?? ""
                let rhsDate = rhs.userData?.lastPlayedAt ?? ""
                if lhsDate == rhsDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
        case .mostPlayed:
            return filteredAlbums.sorted { lhs, rhs in
                let lhsCount = lhs.userData?.playCount ?? 0
                let rhsCount = rhs.userData?.playCount ?? 0
                if lhsCount == rhsCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsCount > rhsCount
            }
        case .longest:
            return filteredAlbums.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks > rhs.runtimeTicks
            }
        case .shortest:
            return filteredAlbums.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks < rhs.runtimeTicks
            }
        case .yearAscending:
            return filteredAlbums.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? Int32.max
                let rhsYear = rhs.year ?? Int32.max
                if lhsYear == rhsYear {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsYear < rhsYear
            }
        case .yearDescending:
            return filteredAlbums.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? Int32.min
                let rhsYear = rhs.year ?? Int32.min
                if lhsYear == rhsYear {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsYear > rhsYear
            }
        }
    }

    /// `model.artists` re-ordered for the current `sortOrder`. Artists carry
    /// no year or runtime, so those modes fall back to alphabetical order;
    /// `mostPlayed` and `recentlyPlayed` consult `userData` when present.
    private var sortedArtists: [Artist] {
        switch sortOrder {
        case .nameDescending:
            return filteredArtists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .recentlyPlayed:
            return filteredArtists.sorted { lhs, rhs in
                let lhsDate = lhs.userData?.lastPlayedAt ?? ""
                let rhsDate = rhs.userData?.lastPlayedAt ?? ""
                if lhsDate == rhsDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
        case .mostPlayed:
            return filteredArtists.sorted { lhs, rhs in
                let lhsCount = lhs.userData?.playCount ?? 0
                let rhsCount = rhs.userData?.playCount ?? 0
                if lhsCount == rhsCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsCount > rhsCount
            }
        case .recentlyAdded:
            // No per-item date on the artist payload — keep server order.
            return filteredArtists
        case .random:
            return filteredArtists.shuffled()
        case .nameAscending, .artist, .longest, .shortest, .yearAscending, .yearDescending:
            // Year and runtime aren't carried for artists, and "Artist" is a
            // no-op on the artist list itself; treat all as alpha asc.
            return filteredArtists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// `model.tracks` re-ordered for the current `sortOrder`. Tracks carry
    /// `playCount`, `runtimeTicks`, `year`, and `userData.lastPlayedAt`, so
    /// every option is a real key.
    private var sortedTracks: [Track] {
        switch sortOrder {
        case .nameAscending:
            return filteredTracks.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .nameDescending:
            return filteredTracks.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .artist:
            return filteredTracks.sorted { lhs, rhs in
                let cmp = lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName)
                if cmp == .orderedSame {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return cmp == .orderedAscending
            }
        case .random:
            return filteredTracks.shuffled()
        case .recentlyAdded:
            return filteredTracks
        case .recentlyPlayed:
            return filteredTracks.sorted { lhs, rhs in
                let lhsDate = lhs.userData?.lastPlayedAt ?? ""
                let rhsDate = rhs.userData?.lastPlayedAt ?? ""
                if lhsDate == rhsDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
        case .mostPlayed:
            return filteredTracks.sorted { lhs, rhs in
                if lhs.playCount == rhs.playCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.playCount > rhs.playCount
            }
        case .longest:
            return filteredTracks.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks > rhs.runtimeTicks
            }
        case .shortest:
            return filteredTracks.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks < rhs.runtimeTicks
            }
        case .yearAscending:
            return filteredTracks.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? Int32.max
                let rhsYear = rhs.year ?? Int32.max
                if lhsYear == rhsYear {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsYear < rhsYear
            }
        case .yearDescending:
            return filteredTracks.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? Int32.min
                let rhsYear = rhs.year ?? Int32.min
                if lhsYear == rhsYear {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsYear > rhsYear
            }
        }
    }

    /// `model.playlists` re-ordered for the current `sortOrder`. Playlists
    /// carry only `name`, `runtimeTicks`, and `trackCount` on the loaded
    /// shape, so play-count and year modes fall back to alphabetical.
    private var sortedPlaylists: [Playlist] {
        switch sortOrder {
        case .nameDescending:
            return filteredPlaylists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .longest:
            return filteredPlaylists.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks > rhs.runtimeTicks
            }
        case .shortest:
            return filteredPlaylists.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks < rhs.runtimeTicks
            }
        case .recentlyAdded:
            return filteredPlaylists
        case .random:
            return filteredPlaylists.shuffled()
        case .nameAscending, .artist, .recentlyPlayed, .mostPlayed, .yearAscending, .yearDescending:
            return filteredPlaylists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

/// Stable `@AppStorage` keys for the user-facing Library preferences.
/// Centralised so `PreferencesLibrary` (which writes them) and the views that
/// read them never drift on a string literal. Defaults live at each read site
/// — the keys here are only the on-disk identifiers and must not be renamed
/// without a migration.
enum LibraryDefaults {
    /// `LibrarySortOrder` raw value — default sort for the Albums chip.
    static let albumSortKey = "library.defaultSort.albums"
    /// `LibrarySortOrder` raw value — default sort for the Songs/Tracks chip.
    static let songSortKey = "library.defaultSort.songs"
    /// `Bool` — show the leading track-number column in numbered track rows.
    static let showTrackNumbersKey = "library.showTrackNumbers"
    /// `Bool` — reveal a track's play count on row hover.
    static let showPlayCountOnHoverKey = "library.showPlayCountOnHover"
    /// `Bool` toggles for each optional sidebar library section.
    static let sidebarShowFavoritesKey = "library.sidebar.showFavorites"
    static let sidebarShowAlbumsKey = "library.sidebar.showAlbums"
    static let sidebarShowArtistsKey = "library.sidebar.showArtists"
    static let sidebarShowPlaylistsKey = "library.sidebar.showPlaylists"
}

/// Persisted selection for the Library list/grid toggle. Stored via
/// `@AppStorage("libraryViewMode")` — raw values are stable strings so future
/// tab-specific keys (`library.view.tracks` etc.) can share the same decoder.
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2.fill"
        case .list: return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid: return "Grid view"
        case .list: return "List view"
        }
    }
}

/// 2-segment control that toggles between list and grid. Matches the
/// design's 3pt padded `surface` pill with `border`. The active segment is
/// inked; the inactive one sits in `ink2`.
struct LibraryViewToggle: View {
    @Binding var mode: LibraryViewMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.list)
            segment(.grid)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library view")
    }

    private func segment(_ target: LibraryViewMode) -> some View {
        let active = mode == target
        return Button {
            mode = target
        } label: {
            Image(systemName: target.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
                .foregroundStyle(active ? Theme.bg : Theme.ink2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Theme.ink : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.accessibilityLabel)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Square grid tile used in the Library Albums tab. When a container has
/// lifted hover tracking (Library), hover state reads the single shared
/// `libraryHoverID` binding instead of a per-cell `@State` — that's the
/// key to keeping a 5k-item grid lightweight (see #428). When `AlbumCard`
/// renders outside the library (e.g. search results), `isActive` is false
/// and the cell falls back to a local `@State` so hover affordance is
/// preserved on those surfaces.
struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryHoverID) private var hoverTracker
    let album: Album
    /// Fallback hover flag for non-library hosts. Stays `false` forever when
    /// `hoverTracker.isActive` is true (library path), so it doesn't drive
    /// any view invalidations in the 5k-grid case.
    @State private var localHovering = false

    /// True when the container's shared hover tracker points at this album —
    /// or when we're on the fallback path and the cursor is over the cell.
    private var isHovering: Bool {
        if hoverTracker.isActive {
            return hoverTracker.id.wrappedValue == album.id
        }
        return localHovering
    }

    var body: some View {
        Button {
            model.navPath.append(AppModel.Route.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 400),
                        seed: album.name,
                        size: 180,
                        radius: 8,
                        // 180pt @ 3x = 540px — enough headroom for a 5K
                        // external display without decoding source (often
                        // 1024px+ from Jellyfin). See #427.
                        targetPixelSize: CGSize(width: 540, height: 540)
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)

                    Button { model.play(album: album) } label: {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 16))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.primary))
                            .shadow(color: Theme.primary.opacity(0.5), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
                    .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                    // Hover overlay isn't discoverable without a mouse, so
                    // name the play button explicitly for VoiceOver. See
                    // #331.
                    .accessibilityLabel("Play \(album.name)")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(album.artistName)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                        if let year = album.year {
                            Text("· \(String(year))")
                                .font(Theme.font(11, weight: .medium))
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Theme.surface : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hoverTracker.isActive {
                if hovering {
                    hoverTracker.id.wrappedValue = album.id
                } else if hoverTracker.id.wrappedValue == album.id {
                    hoverTracker.id.wrappedValue = nil
                }
            } else {
                localHovering = hovering
            }
        }
        .contextMenu { AlbumContextMenu(album: album) }
        // Outer "navigate to album" tap target. Reads as
        // "<album> by <artist>. Opens album detail." The inner play
        // button exposes itself separately for "play this album".
        .accessibilityLabel(albumAccessibilityLabel)
        .accessibilityHint("Opens album detail")
    }

    private var albumAccessibilityLabel: String {
        if let year = album.year, year > 0 {
            return "\(album.name) by \(album.artistName), \(year)"
        }
        return "\(album.name) by \(album.artistName)"
    }
}

/// The nine sort modes the Library header offers. Drives client-side
/// re-ordering of the already-loaded `model.X` arrays — the menu in the
/// Library header writes this; the `sortedAlbums` / `sortedArtists` /
/// `sortedTracks` / `sortedPlaylists` computed properties on `LibraryView`
/// read it.
///
/// `String`-backed so the choice can be persisted as a default-sort
/// preference via `@AppStorage` (see `PreferencesLibrary`). Raw values are
/// stable on-disk keys — never rename them without a migration; the `label`
/// is display-only and safe to edit.
enum LibrarySortOrder: String, Hashable, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case artist
    case recentlyAdded
    case recentlyPlayed
    case mostPlayed
    case longest
    case shortest
    case yearAscending
    case yearDescending
    case random

    var id: String { rawValue }

    /// Label shown in the menu, matching the spec's labels exactly.
    var label: String {
        switch self {
        case .nameAscending: return "A–Z"
        case .nameDescending: return "Z–A"
        case .artist: return "Artist"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .longest: return "Longest"
        case .shortest: return "Shortest"
        case .yearAscending: return "Year ↑"
        case .yearDescending: return "Year ↓"
        case .random: return "Random"
        }
    }
}

/// Native SwiftUI `Menu` that drives the Library's active sort. Renders the
/// nine options at 12pt and shows a checkmark on the active one. Wraps the
/// menu trigger in a `surface` pill that visually matches the adjacent
/// `LibraryViewToggle` so the two header controls read as a pair.
struct LibrarySortMenu: View {
    @Binding var selection: LibrarySortOrder

    var body: some View {
        Menu {
            ForEach(LibrarySortOrder.allCases, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
                .font(Theme.font(12, weight: .medium))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(selection.label)
                    .font(Theme.font(12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort library")
        .accessibilityValue(selection.label)
    }
}

/// Pure selection arithmetic for the Library Tracks tab multi-select (#217).
///
/// Extracted out of `LibraryView.handleTrackClick` so the Cmd-toggle /
/// Shift-range / bare-click-plays logic can be exercised by unit tests without
/// standing up a SwiftUI scene graph or an `AppModel`. The View layer keeps
/// only the `@State` mutation + the `model.play(...)` side effect.
enum TrackSelectionResolver {
    /// The next selection state plus whether the caller should start playback.
    struct Outcome: Equatable {
        var selection: Set<String>
        var anchorIndex: Int?
        var shouldPlay: Bool
    }

    /// Resolve a click on `clickedIndex` within `trackIds` given the current
    /// selection, anchor, and modifier flags.
    ///
    /// - Cmd: toggle the hit row in/out of the selection; re-anchor to it.
    /// - Shift: insert the contiguous range between the anchor (or the hit row
    ///   if there is no anchor) and the hit row; re-anchor to the hit row.
    /// - No modifier: clear the selection, anchor the hit row, and signal that
    ///   playback should start at it.
    ///
    /// Returns `nil` when `clickedIndex` is out of bounds, so the caller does
    /// nothing — matching the previous guard.
    static func resolve(
        clickedIndex: Int,
        trackIds: [String],
        currentSelection: Set<String>,
        anchorIndex: Int?,
        modifiers: NSEvent.ModifierFlags
    ) -> Outcome? {
        guard trackIds.indices.contains(clickedIndex) else { return nil }
        let clickedId = trackIds[clickedIndex]

        if modifiers.contains(.command) {
            var next = currentSelection
            if next.contains(clickedId) {
                next.remove(clickedId)
            } else {
                next.insert(clickedId)
            }
            return Outcome(selection: next, anchorIndex: clickedIndex, shouldPlay: false)
        } else if modifiers.contains(.shift) {
            let from = anchorIndex ?? clickedIndex
            let range = from <= clickedIndex ? from...clickedIndex : clickedIndex...from
            var next = currentSelection
            for i in range where trackIds.indices.contains(i) {
                next.insert(trackIds[i])
            }
            return Outcome(selection: next, anchorIndex: clickedIndex, shouldPlay: false)
        } else {
            return Outcome(selection: [], anchorIndex: clickedIndex, shouldPlay: true)
        }
    }
}
