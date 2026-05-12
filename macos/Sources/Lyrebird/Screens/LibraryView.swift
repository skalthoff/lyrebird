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

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)]

    var body: some View {
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
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
        .environment(
            \.libraryHoverID,
            LibraryHoverBinding(id: $hoverID, isActive: true)
        )
        // Sync the local `selectedTab` with `model.libraryTab` so the
        // sidebar's Albums/Artists/Playlists libRows can deep-link into
        // a specific chip. `.onAppear` covers the case where the library
        // is entered fresh; `.onChange` covers the case where the user
        // is already on the library and the sidebar flips the tab.
        .onAppear { selectedTab = model.libraryTab }
        .onChange(of: model.libraryTab) { _, newValue in
            selectedTab = newValue
        }
        .onChange(of: selectedTab) { _, newValue in
            // Write-back so the sidebar's highlighted chip stays in sync.
            if model.libraryTab != newValue {
                model.libraryTab = newValue
            }
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
                LibrarySortMenu(selection: $sortOrder)
                LibraryViewToggle(mode: $viewMode)
            }
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
                            TrackListRow(track: track, tracks: items, index: idx)
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

    // MARK: - Sort

    /// `model.albums` re-ordered for the current `sortOrder`. The underlying
    /// model array is left untouched so pagination accounting (`loaded` vs
    /// `total`, threshold math) keeps working unchanged. Sort keys that
    /// don't apply to albums (`mostPlayed` for an album with no
    /// `userData.playCount`, `recentlyAdded` with no per-item creation date
    /// on the loaded shape) fall back through to the alphabetical tie-breaker
    /// so the list remains stable.
    private var sortedAlbums: [Album] {
        switch sortOrder {
        case .nameAscending:
            return model.albums.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .nameDescending:
            return model.albums.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .recentlyAdded:
            // `Album` does not carry `DateCreated` on the paginated shape, so
            // preserve the server's load order (which is `SortName` asc by
            // default). Acts as a no-op fallback rather than a misleading
            // "newest first" promise.
            return model.albums
        case .recentlyPlayed:
            return model.albums.sorted { lhs, rhs in
                let lhsDate = lhs.userData?.lastPlayedAt ?? ""
                let rhsDate = rhs.userData?.lastPlayedAt ?? ""
                if lhsDate == rhsDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
        case .mostPlayed:
            return model.albums.sorted { lhs, rhs in
                let lhsCount = lhs.userData?.playCount ?? 0
                let rhsCount = rhs.userData?.playCount ?? 0
                if lhsCount == rhsCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsCount > rhsCount
            }
        case .longest:
            return model.albums.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks > rhs.runtimeTicks
            }
        case .shortest:
            return model.albums.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks < rhs.runtimeTicks
            }
        case .yearAscending:
            return model.albums.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? Int32.max
                let rhsYear = rhs.year ?? Int32.max
                if lhsYear == rhsYear {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsYear < rhsYear
            }
        case .yearDescending:
            return model.albums.sorted { lhs, rhs in
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
            return model.artists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .recentlyPlayed:
            return model.artists.sorted { lhs, rhs in
                let lhsDate = lhs.userData?.lastPlayedAt ?? ""
                let rhsDate = rhs.userData?.lastPlayedAt ?? ""
                if lhsDate == rhsDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
        case .mostPlayed:
            return model.artists.sorted { lhs, rhs in
                let lhsCount = lhs.userData?.playCount ?? 0
                let rhsCount = rhs.userData?.playCount ?? 0
                if lhsCount == rhsCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsCount > rhsCount
            }
        case .recentlyAdded:
            // No per-item date on the artist payload — keep server order.
            return model.artists
        case .nameAscending, .longest, .shortest, .yearAscending, .yearDescending:
            // Year and runtime aren't carried for artists; treat as alpha asc.
            return model.artists.sorted { lhs, rhs in
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
            return model.tracks.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .nameDescending:
            return model.tracks.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .recentlyAdded:
            return model.tracks
        case .recentlyPlayed:
            return model.tracks.sorted { lhs, rhs in
                let lhsDate = lhs.userData?.lastPlayedAt ?? ""
                let rhsDate = rhs.userData?.lastPlayedAt ?? ""
                if lhsDate == rhsDate {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
        case .mostPlayed:
            return model.tracks.sorted { lhs, rhs in
                if lhs.playCount == rhs.playCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.playCount > rhs.playCount
            }
        case .longest:
            return model.tracks.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks > rhs.runtimeTicks
            }
        case .shortest:
            return model.tracks.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks < rhs.runtimeTicks
            }
        case .yearAscending:
            return model.tracks.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? Int32.max
                let rhsYear = rhs.year ?? Int32.max
                if lhsYear == rhsYear {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsYear < rhsYear
            }
        case .yearDescending:
            return model.tracks.sorted { lhs, rhs in
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
            return model.playlists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
        case .longest:
            return model.playlists.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks > rhs.runtimeTicks
            }
        case .shortest:
            return model.playlists.sorted { lhs, rhs in
                if lhs.runtimeTicks == rhs.runtimeTicks {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.runtimeTicks < rhs.runtimeTicks
            }
        case .recentlyAdded:
            return model.playlists
        case .nameAscending, .recentlyPlayed, .mostPlayed, .yearAscending, .yearDescending:
            return model.playlists.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
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
enum LibrarySortOrder: Hashable, CaseIterable {
    case nameAscending
    case nameDescending
    case recentlyAdded
    case recentlyPlayed
    case mostPlayed
    case longest
    case shortest
    case yearAscending
    case yearDescending

    /// Label shown in the menu, matching the spec's labels exactly.
    var label: String {
        switch self {
        case .nameAscending: return "A–Z"
        case .nameDescending: return "Z–A"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .longest: return "Longest"
        case .shortest: return "Shortest"
        case .yearAscending: return "Year ↑"
        case .yearDescending: return "Year ↓"
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
