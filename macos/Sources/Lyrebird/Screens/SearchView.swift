import SwiftUI
@preconcurrency import LyrebirdCore

/// Full search page. The committed surface the user lands on after pressing
/// Return in the toolbar, or after choosing "See all results" on the
/// instant dropdown (#85). Distinct from any inline search chrome — this
/// view owns the field at the top of the page, the scope chip row below
/// it, and the sectioned / recents / empty-state body.
///
/// Closes (together in one PR):
///
///   * #86  — full results page with per-section rendering.
///   * #242 — scope chips (All / Artists / Albums / Tracks / Playlists / Genres)
///   * #244 — sections layout, up to ~20 per category with "Load more".
///   * #245 — zero-results illustrative state with two helper suggestions.
///   * #246 — recent searches list with per-row clear + "Clear history".
///
/// Intentionally does NOT touch the instant dropdown (BATCH-09a / PR #535)
/// or the command palette (BATCH-09c / PR #536) — those are separate
/// surfaces that share `core.search` but run their own state paths.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFieldFocused: Bool

    /// Debounce handle for the "as the user types, refresh the page"
    /// path. Cancelled on each keystroke so the last keystroke wins.
    @State private var searchDebounce: Task<Void, Never>?

    /// Handle for the in-flight `runFullSearch` network call. Cancelled
    /// whenever a newer query starts so a slow response from an older
    /// request can never overwrite fresher results (#566).
    @State private var searchTask: Task<Void, Never>?

    /// Per-scope reveal caps — each scope section shows `initialRevealCount`
    /// rows by default, and the "Load more" button bumps by `revealStep`
    /// until either the local bucket is exhausted or the server signals
    /// there are no more results. Keyed by `SearchScope.storageKey`.
    @State private var revealedCounts: [String: Int] = [:]

    /// Recent searches persisted as JSON (`@AppStorage` doesn't support
    /// `[String]` directly). The page reads + mutates through the
    /// `AppModel.addRecentSearch` / `removeRecentSearch` / `clearRecentSearches`
    /// helpers so the encode / decode + cap-to-10 logic stays in one place.
    /// See #246.
    @AppStorage("recentSearches") private var recentSearchesJSON: String = "[]"

    // MARK: - Tuning

    /// Number of rows every section reveals before the "Load more" button
    /// bumps the cap. Matches #244's "show 10, reveal +10".
    private let initialRevealCount = 10

    /// Increment applied when the user taps "Load more" for a scope.
    private let revealStep = 10

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                scopeRow
                resultsBody
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        // #585: Route space-bar keypresses to the search TextField even
        // while the global Play/Pause ⎵ shortcut is active.
        .spaceKeyGuardForTextField()
        // Best-effort populate of the "Browse by Genre" tiles (#247) so the
        // empty-search landing has something to browse even if the user
        // reaches Search before the post-login bootstrap got to it. Cheap
        // (one cached /MusicGenres page) and idempotent.
        .task {
            if model.browseGenres.isEmpty {
                await model.refreshBrowseGenres()
            }
        }
        .onAppear {
            if model.requestSearchFocus {
                searchFieldFocused = true
                model.requestSearchFocus = false
            }
        }
        .onChange(of: model.requestSearchFocus) { _, newValue in
            if newValue {
                searchFieldFocused = true
                model.requestSearchFocus = false
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SEARCH")
                .font(Theme.font(12, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(2)
            searchField
        }
    }

    /// Page-level search field. Distinct from any toolbar-based field so
    /// this screen is a fully self-contained surface — a user can land
    /// here from the sidebar or ⌘F with no prior state and still drive
    /// everything from here.
    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.ink2)
                .font(.system(size: 18))
            TextField("Search your library", text: $model.searchPageQuery)
                .textFieldStyle(.plain)
                .font(Theme.font(18, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($searchFieldFocused)
                .onSubmit {
                    commitQuery(model.searchPageQuery)
                }
                .onExitCommand {
                    if !model.searchPageQuery.isEmpty {
                        clearQuery()
                    }
                }
                .onChange(of: model.searchPageQuery) { _, newValue in
                    scheduleDebouncedSearch(newValue)
                }
            if !model.searchPageQuery.isEmpty {
                Button(action: clearQuery) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.ink2)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Scope chips (#242)

    /// Horizontal chip row under the search field. Selecting a chip
    /// narrows the page to that section; `All` shows every populated
    /// bucket. Rendering goes through the shared `Chip` primitive so the
    /// look matches Library's own chip row.
    @ViewBuilder
    private var scopeRow: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            ForEach(visibleScopes, id: \.self) { scope in
                Chip(
                    label: scope.label,
                    isActive: model.activeSearchScope == scope,
                    onTap: {
                        model.activeSearchScope = scope
                        // Reset reveal caps when switching scopes so a
                        // previously-expanded tab doesn't carry a tall
                        // revealed count into the new view.
                        revealedCounts = [:]
                    }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search scope")
    }

    // MARK: - Body

    /// The body is a three-way switch: empty-query → recents, non-empty
    /// with nothing to show → illustrative zero-results (#245), otherwise
    /// the sectioned results layout (#244).
    @ViewBuilder
    private var resultsBody: some View {
        let trimmed = model.searchPageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            recentSearches
        } else if model.isLoadingFullSearch && model.searchPageResults.isEmpty {
            loadingIndicator
        } else if allBucketsEmpty {
            ZeroResultsState(query: trimmed) { suggestion in
                commitQuery(suggestion)
            }
        } else {
            sectionedResults
        }
    }

    /// True when every scope bucket is empty — drives the #245 zero-results
    /// panel. Uses the bucketed dictionary rather than a raw combined
    /// array because `runFullSearch` always writes every key (even if
    /// empty) so this collapses to a single check per render.
    private var allBucketsEmpty: Bool {
        let all = model.searchPageResults.values.reduce(0) { $0 + $1.count }
        return all == 0
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(Theme.ink2)
                .scaleEffect(0.9)
            Spacer()
        }
        .padding(.vertical, 48)
    }

    // MARK: - Recent searches (#246) + Suggested (#87)

    /// Empty-query panel: a "Recent searches" list capped at 10 items
    /// with per-row clear × and a footer "Clear history" button, followed
    /// by the "Suggested" exploration panel (lightly-played artists, genre
    /// tiles, and decade tiles). Persisted in `UserDefaults` as JSON.
    @ViewBuilder
    private var recentSearches: some View {
        let items = AppModel.decodeRecentSearches(recentSearchesJSON)
        VStack(alignment: .leading, spacing: 28) {
            recentSearchesList(items)
            SuggestedSearchesSection { term in
                model.searchPageQuery = term
                commitQuery(term)
            }
            BrowseByGenreSection()
        }
    }

    /// The recent-searches list proper, split out so the empty-query body can
    /// compose it above the "Browse by Genre" tiles (#247).
    @ViewBuilder
    private func recentSearchesList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent searches")
                .font(Theme.font(18, weight: .bold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 12)

            if items.isEmpty {
                Text("Start typing to search your library. Your recent searches will show up here.")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 2) {
                    ForEach(items, id: \.self) { term in
                        RecentSearchRow(
                            term: term,
                            onTap: {
                                model.searchPageQuery = term
                                commitQuery(term)
                            },
                            onClear: {
                                AppModel.removeRecentSearch(term, from: &recentSearchesJSON)
                            }
                        )
                    }
                }

                Button(action: {
                    AppModel.clearRecentSearches(&recentSearchesJSON)
                }) {
                    Text("Clear history")
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .accessibilityLabel("Clear search history")
            }
        }
    }

    // MARK: - Sectioned results (#244)

    /// Renders the per-scope sections. Which sections render is governed
    /// by `activeSearchScope`: `.all` shows every populated bucket in the
    /// canonical order; any other scope renders just that one (or its
    /// zero-state if the bucket came back empty for the query).
    @ViewBuilder
    private var sectionedResults: some View {
        VStack(alignment: .leading, spacing: 28) {
            let scopes = model.activeSearchScope == .all
                ? composedScopes
                : [model.activeSearchScope]
            ForEach(scopes, id: \.self) { scope in
                SectionView(
                    scope: scope,
                    items: bucket(for: scope),
                    revealed: revealedCount(for: scope),
                    canLoadMore: canLoadMore(for: scope),
                    isLoading: model.isLoadingFullSearch,
                    onLoadMore: { handleLoadMore(for: scope) }
                )
            }
        }
    }

    /// The ordered scopes the `.all` view composes. Genres and playlists
    /// are each gated by a capability flag so the page never renders a
    /// section that can only say "no … matched this query": genres via
    /// `supportsGenreActions`, playlists via `supportsPlaylistSearch`
    /// (the core search backend doesn't return playlists yet).
    private var composedScopes: [SearchScope] {
        var scopes: [SearchScope] = [.artists, .albums, .tracks]
        if model.supportsPlaylistSearch { scopes.append(.playlists) }
        if model.supportsGenreActions { scopes.append(.genres) }
        return scopes
    }

    /// Scope chips to render in the chip row. Drops `.genres` when the
    /// genre actions feature is hidden, and `.playlists` until the core
    /// search backend returns playlists (`supportsPlaylistSearch`), so
    /// users can't navigate to a scope that is either all-stub (genres)
    /// or permanently empty (playlists).
    private var visibleScopes: [SearchScope] {
        SearchScope.allCases.filter { scope in
            switch scope {
            case .genres: return model.supportsGenreActions
            case .playlists: return model.supportsPlaylistSearch
            default: return true
            }
        }
    }

    private func bucket(for scope: SearchScope) -> [SearchItem] {
        model.searchPageResults[scope.storageKey] ?? []
    }

    /// How many rows to render inside a given scope section. Defaults to
    /// `initialRevealCount` until the user clicks "Load more".
    private func revealedCount(for scope: SearchScope) -> Int {
        revealedCounts[scope.storageKey] ?? initialRevealCount
    }

    /// "Load more" is visible when there's another row to reveal in the
    /// local bucket, OR — for server-paged scopes only — when the local
    /// bucket is exhausted but the server still has more results for the
    /// overall query. Derived / not-yet-paged scopes (genres, playlists)
    /// never consult the server signal, so their button disappears the
    /// moment the whole bucket is on screen instead of staying perpetual.
    private func canLoadMore(for scope: SearchScope) -> Bool {
        let revealed = revealedCount(for: scope)
        if revealed < bucket(for: scope).count { return true }
        // Locally exhausted — only server-paged scopes can fetch more.
        return scope.isServerPaged && model.searchPageHasMore
    }

    /// Bump the reveal count for this scope by `revealStep`, and — for a
    /// server-paged scope whose buffered bucket is fully revealed — kick
    /// off a follow-up page fetch. The reveal grows straight to
    /// `bucketSize` (no artificial sub-page cap) so every locally-loaded
    /// row is reachable; the page size already bounds how much arrives at
    /// once. When a server fetch is started the reveal window is nudged
    /// one step past the current bucket end so freshly-fetched rows land
    /// inside the visible window without forcing a second click.
    private func handleLoadMore(for scope: SearchScope) {
        let key = scope.storageKey
        let current = revealedCount(for: scope)
        let bucketSize = bucket(for: scope).count
        let serverHasMore = scope.isServerPaged && model.searchPageHasMore

        if current < bucketSize {
            // Still rows buffered locally — reveal the next chunk, clamped
            // to what the bucket actually holds.
            revealedCounts[key] = min(current + revealStep, bucketSize)
        } else if serverHasMore {
            // Bucket fully revealed and the server has more: spill the
            // window past the current end so the incoming page is visible
            // on arrival, then fetch it.
            revealedCounts[key] = current + revealStep
            Task { await model.loadMoreFullSearch() }
        }
    }

    // MARK: - Actions

    /// Commit a query — kicks off the full search and saves the term into
    /// the recent-searches list. Shared by the field's Return, a recent
    /// row tap, and the zero-results helper suggestions.
    private func commitQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Cancel any pending debounce so the committed search isn't chased
        // ~300ms later by a duplicate that would also cancel this request
        // mid-flight. `clearQuery` cancels both; mirror that here.
        searchDebounce?.cancel()
        searchTask?.cancel()
        AppModel.addRecentSearch(trimmed, into: &recentSearchesJSON)
        revealedCounts = [:]
        let scope = model.activeSearchScope
        searchTask = Task { await model.runFullSearch(query: trimmed, scope: scope) }
    }

    /// Schedule a debounced "live" search so typing into the field
    /// eventually refreshes the page without requiring a Return press.
    /// 300ms matches the rhythm the instant dropdown uses (250ms) plus
    /// a small buffer for the heavier full-page fetch.
    private func scheduleDebouncedSearch(_ query: String) {
        searchDebounce?.cancel()
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty field → clear the page immediately and don't schedule
        // anything. The recents panel will take over.
        guard !trimmed.isEmpty else {
            revealedCounts = [:]
            let scope = model.activeSearchScope
            searchTask = Task { await model.runFullSearch(query: "", scope: scope) }
            return
        }
        let scope = model.activeSearchScope
        searchDebounce = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            // Cancel any prior request that may still be in flight before
            // issuing the new one; the debounce sleep alone doesn't guarantee
            // the previous network call has finished.
            searchTask?.cancel()
            revealedCounts = [:]
            searchTask = Task { await model.runFullSearch(query: trimmed, scope: scope) }
        }
    }

    /// Reset the page to a blank state — used by the field's × button
    /// and by Esc.
    private func clearQuery() {
        searchDebounce?.cancel()
        searchTask?.cancel()
        model.searchPageQuery = ""
        revealedCounts = [:]
        searchFieldFocused = true
        let scope = model.activeSearchScope
        searchTask = Task { await model.runFullSearch(query: "", scope: scope) }
    }
}

// MARK: - Section rendering

/// A single scope section: heading, the rendered rows, and the "Load
/// more" affordance when there's more to reveal. Broken out so the
/// parent view stays a concise composition and so each scope gets its
/// own consistent frame.
private struct SectionView: View {
    let scope: SearchScope
    let items: [SearchItem]
    let revealed: Int
    let canLoadMore: Bool
    let isLoading: Bool
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(scope.sectionHeader)
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                if !items.isEmpty {
                    Text(countLabel)
                        .font(Theme.font(11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(1.2)
                }
                Spacer()
            }

            if items.isEmpty {
                Text("No \(scope.label.lowercased()) matched this query.")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 4)
            } else {
                content
                if canLoadMore {
                    loadMoreButton
                }
            }
        }
    }

    private var countLabel: String {
        "\(items.count)"
    }

    /// Render the visible slice of the bucket in the shape that matches
    /// the scope — track rows, album grid, artist grid, playlist grid,
    /// or a simple text list for genres.
    @ViewBuilder
    private var content: some View {
        let visible = Array(items.prefix(revealed))
        switch scope {
        case .tracks:
            trackRows(visible)
        case .albums:
            albumGrid(visible)
        case .artists:
            artistGrid(visible)
        case .playlists:
            playlistGrid(visible)
        case .genres:
            genreRows(visible)
        case .all:
            // `.all` never renders a single mixed bucket — the parent
            // composes per-scope sections in order. If we somehow land
            // here, fall back to a flat list so nothing crashes.
            VStack(spacing: 2) {
                ForEach(visible, id: \.id) { item in
                    Text(item.title)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    @ViewBuilder
    private func trackRows(_ items: [SearchItem]) -> some View {
        let tracks = items.compactMap { item -> Track? in
            if case .track(let t) = item { return t } else { return nil }
        }
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                SearchPageTrackRow(track: track, number: idx + 1, queue: tracks)
            }
        }
    }

    @ViewBuilder
    private func albumGrid(_ items: [SearchItem]) -> some View {
        let albums = items.compactMap { item -> Album? in
            if case .album(let a) = item { return a } else { return nil }
        }
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(albums, id: \.id) { album in
                AlbumCard(album: album)
            }
        }
    }

    @ViewBuilder
    private func artistGrid(_ items: [SearchItem]) -> some View {
        let artists = items.compactMap { item -> Artist? in
            if case .artist(let a) = item { return a } else { return nil }
        }
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(artists, id: \.id) { artist in
                ArtistCard(artist: artist)
            }
        }
    }

    @ViewBuilder
    private func playlistGrid(_ items: [SearchItem]) -> some View {
        let playlists = items.compactMap { item -> Playlist? in
            if case .playlist(let p) = item { return p } else { return nil }
        }
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(playlists, id: \.id) { playlist in
                PlaylistCard(playlist: playlist)
            }
        }
    }

    @ViewBuilder
    private func genreRows(_ items: [SearchItem]) -> some View {
        let names = items.compactMap { item -> String? in
            if case .genre(let g) = item { return g.name } else { return nil }
        }
        VStack(spacing: 2) {
            ForEach(names, id: \.self) { name in
                GenreResultRow(name: name)
            }
        }
    }

    /// "Load more" button shown when there's another chunk to reveal or
    /// the server has more rows buffered past what's been loaded so far.
    @ViewBuilder
    private var loadMoreButton: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .tint(Theme.ink2)
                    .scaleEffect(0.8)
                    .padding(.vertical, 10)
            } else {
                Button(action: onLoadMore) {
                    Text("Load more")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.borderStrong, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Load more \(scope.label.lowercased())")
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Suggested searches (#87)

/// The "Suggested" section shown beneath "Recent Searches" when the search
/// field is empty. Surfaces up to 5 lightly-played (never or rarely played)
/// artists so the user can discover neglected corners of their library — the
/// artists rotate daily via a seeded shuffle in `AppModel.suggestedSearchArtists`.
///
/// Hidden entirely when the artist library hasn't loaded yet (empty model), so
/// a cold-launch first paint is never cluttered with placeholder rows.
///
/// Each row taps into the parent's `onSelect` closure which prefills the
/// search field and commits the query — the same flow as a recent-search tap.
private struct SuggestedSearchesSection: View {
    @Environment(AppModel.self) private var model
    /// Called with the artist name when the user taps a suggestion row.
    let onSelect: (String) -> Void

    var body: some View {
        let artists = model.suggestedSearchArtists
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("Suggested")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
                .padding(.top, 4)

                VStack(spacing: 2) {
                    ForEach(artists, id: \.id) { artist in
                        SuggestedArtistRow(artist: artist) {
                            onSelect(artist.name)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggested searches")
        }
    }
}

/// One row in the "Suggested" section. Renders the artist name with a
/// "sparkle" icon in place of the recents clock, and a chevron to hint that
/// tapping runs a search. Hovering highlights the row like a recent-search row.
private struct SuggestedArtistRow: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Small circular artwork fallback — matches the Home Artists
            // carousel aesthetic at a compact size.
            Artwork(
                url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 60),
                seed: artist.name,
                size: 32,
                radius: 16,
                targetPixelSize: CGSize(width: 96, height: 96)
            )
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(artistSubtitle)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "arrow.up.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .opacity(isHovering ? 1 : 0.4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Theme.rowHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search for \(artist.name)")
        .accessibilityHint("Never played — \(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
        .accessibilityAddTraits(.isButton)
    }

    /// Short descriptor shown below the artist name. Prefers "Never played"
    /// when play count is 0 or missing; falls back to a "N album(s)" count
    /// for artists in the played fallback pool.
    private var artistSubtitle: String {
        let playCount = artist.userData?.playCount ?? 0
        if playCount == 0 {
            let n = artist.albumCount
            return "Never played · \(n) album\(n == 1 ? "" : "s")"
        }
        return "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")"
    }
}

// MARK: - Row primitives

/// Recent search row — reveals an × on hover so the user can remove a
/// single term without clearing the whole history. Tapping the row
/// re-runs the query. See #246.
private struct RecentSearchRow: View {
    let term: String
    let onTap: () -> Void
    let onClear: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 20)
            Text(term)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.5)
            .help("Remove from recent searches")
            .accessibilityLabel("Remove \(term) from recent searches")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Theme.rowHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Activate to search for \(term)")
    }
}

/// Thin wrapper around `TrackRow` that knows which queue to hand to the
/// player when the row is activated. Every row in the Tracks section
/// shares the same `queue` array so clicking row 5 plays from index 4 of
/// the visible list — behaviour that matches Library and Playlist pages.
private struct SearchPageTrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let number: Int
    let queue: [Track]

    var body: some View {
        // Resolve this row's position in the shared queue once; reuse it for
        // both tap-to-play and arrow-key focus navigation. A track absent
        // from `queue` (shouldn't happen — every Tracks-section row is built
        // from it) falls back to a one-track queue and disables nav.
        let queueIndex = queue.firstIndex(where: { $0.id == track.id })
        TrackRow(
            track: track,
            number: number,
            onPlay: {
                guard let idx = queueIndex else {
                    model.play(tracks: [track], startIndex: 0)
                    return
                }
                model.play(tracks: queue, startIndex: idx)
            },
            tracks: queueIndex == nil ? [] : queue,
            index: queueIndex ?? 0
        )
    }
}

/// Simple row for a genre result. Rendered as a clickable chip-row-ish
/// surface; routes through `AppModel.browseGenre`, which resolves the
/// genre name to its Jellyfin UUID via `core.genres` and navigates to
/// `GenreDetailView` (backed by `core.itemsByGenre` / `core.tracksByGenre`,
/// shipped in #823). The context menu exposes the full genre actions so
/// pin / radio / shuffle work from here.
private struct GenreResultRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var isHovering = false

    var body: some View {
        if model.supportsGenreActions {
            Button(action: { model.browseGenre(genre: Genre(name: name)) }) {
                HStack(spacing: 12) {
                    Image(systemName: "guitars")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 24)
                    Text(name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .opacity(isHovering ? 1 : 0.4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Theme.rowHover : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .contextMenu { GenreContextMenu(genre: Genre(name: name)) }
            .accessibilityLabel("Browse genre \(name)")
        }
    }
}

// MARK: - Zero results (#245)

/// Illustrative zero-results state shown when a committed query returns
/// no rows across any scope. In addition to the illustration + headline,
/// it surfaces a helper suggestion the user can click — bouncing them
/// to a simplified query (artist name only). See #245 for the planned
/// "wider metadata search" follow-up.
private struct ZeroResultsState: View {
    let query: String
    /// Invoked when the user taps a suggestion — lets the parent commit
    /// the suggested query without threading another callback through.
    let onUseSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: 20) {
            illustration

            VStack(spacing: 8) {
                Text("No results for \u{201C}\(query)\u{201D}")
                    .font(Theme.font(22, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Try a different spelling, or narrow your query.")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                suggestionRow(
                    label: "Try: artist name only",
                    symbol: "person.fill",
                    action: {
                        // First token is usually the artist — strip the
                        // rest so "Radiohead kid a live" becomes
                        // "Radiohead" when the user takes the hint.
                        let firstToken = query
                            .split(separator: " ")
                            .first
                            .map(String.init)
                            ?? query
                        onUseSuggestion(firstToken)
                    }
                )
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No results for \(query). Try a different spelling, or narrow your query.")
    }

    /// Decorative glyph — uses the same `surface2` pill + `border` stroke
    /// treatment as the shared `EmptyStateView` so the Search no-results
    /// page feels like a sibling of the other empty states in the app.
    private var illustration: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(Theme.ink2)
            .frame(width: 112, height: 112)
            .background(Circle().fill(Theme.surface2))
            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func suggestionRow(
        label: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 18)
                Text(label)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minWidth: 260)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
