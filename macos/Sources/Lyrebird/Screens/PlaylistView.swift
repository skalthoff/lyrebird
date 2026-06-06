import SwiftUI
@preconcurrency import LyrebirdCore

/// Playlist detail screen. The hero follows the Album detail layout but
/// swaps the single-image artwork slot for a 2×2 collage drawn from the
/// first four tracks' album art, and puts the title + description under
/// click-to-edit inline editors. See #234.
///
/// Fuller affordances (favorite toggle, drag-reordering, member-albums
/// shelf, custom cover drop-zone, virtualized long-playlist scroll) are
/// tracked as follow-ups. For now this view lands:
///   - the 2×2 collage hero (falls back to the playlist's own primary
///     image, and finally a gradient placeholder, when track art is thin);
///   - the click-to-edit title (uses `model.renamePlaylist`, which
///     persists to the server via `core.renamePlaylist` — optimistic
///     update with rollback + `errorMessage` on failure);
///   - the click-to-edit description, backed by
///     `model.playlistDescriptions` since the core's `Playlist` record
///     doesn't yet expose `Overview` — see #130;
///   - a minimal ordered tracks list using `TrackRow`, wired to play
///     through `model.play(tracks:startIndex:)`.
struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistID: String

    @State private var tracks: [Track] = []
    @State private var isLoadingTracks = true
    @State private var fetchedPlaylist: Playlist?

    /// Editor draft state for the title. `nil` means the title is being
    /// displayed; non-nil means the user has tapped it and a `TextField` is
    /// taking focus. On commit (Enter) or blur we call back into the model
    /// and clear the draft.
    @State private var titleDraft: String? = nil
    @FocusState private var titleFocused: Bool

    /// Tracks which row currently has keyboard focus so Alt+Up / Alt+Down
    /// reorder can move without requiring multi-select. `nil` = no row focused.
    @FocusState private var keyboardFocusedIndex: Int?

    /// Scoped (⌘F) search query that filters the playlist's track list
    /// in-place. Cleared on navigation away and on playlist change.
    @State private var scopedQuery: String = ""
    @FocusState private var scopedSearchFocused: Bool

    /// `tracks` filtered by `scopedQuery` (case/diacritic-insensitive over
    /// title + artist + album). Empty query shows the full list. Pairs each
    /// match with its original index so playback / reorder keep operating on
    /// the true playlist position.
    private var filteredTracks: [(index: Int, track: Track)] {
        Self.filterTracks(tracks, query: scopedQuery)
    }

    /// Pure filtering predicate behind `filteredTracks`, factored out so it
    /// can be unit-tested without instantiating the view. Each match keeps its
    /// **original** index so playback / reorder operate on the true playlist
    /// position even while filtered. Trims the query; an empty/whitespace-only
    /// query returns every track paired with its index. Matches
    /// case/diacritic-insensitively over track title + artist + album name.
    static func filterTracks(_ tracks: [Track], query: String) -> [(index: Int, track: Track)] {
        let indexed = tracks.enumerated().map { (index: $0.offset, track: $0.element) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return indexed }
        return indexed.filter { entry in
            entry.track.name.localizedCaseInsensitiveContains(q)
                || entry.track.artistName.localizedCaseInsensitiveContains(q)
                || (entry.track.albumName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Resolve the playlist: cached library page first, then whichever
    /// record the `.task` block fetched on demand. Nil means the id can't
    /// be resolved (deleted upstream, not a real Playlist, server errored).
    private var playlist: Playlist? {
        model.playlist(id: playlistID) ?? fetchedPlaylist
    }

    private var description: String {
        playlist.flatMap { model.playlistDescriptions[$0.id] } ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                transportBar
                trackList
                footer
            }
        }
        .background(Theme.bg)
        .task(id: playlistID) {
            // Cache miss (deep link past the first page of library playlists,
            // or the pre-#654 "Playlists collection folder id" regression
            // the core now defends against): ask `resolvePlaylist` to
            // fetch + validate the record so the hero can render.
            if model.playlist(id: playlistID) == nil {
                fetchedPlaylist = await model.resolvePlaylist(id: playlistID)
            }
            guard let playlist = playlist else {
                // Unknown / deleted / non-playlist id — refuse to load
                // tracks so the "Playlist not found" hero renders alone.
                isLoadingTracks = false
                return
            }
            scopedQuery = ""
            isLoadingTracks = true
            tracks = await model.loadPlaylistTracks(playlist: playlist)
            isLoadingTracks = false
        }
        // ⌘F → AppModel.requestFind() addresses a focus request to a specific
        // route. Only pull focus when the request targets *this* playlist so a
        // page stacked under us in the back-stack never steals focus.
        .onChange(of: model.scopedSearchFocusRequest) { _, _ in
            if model.consumeScopedSearchFocus(for: .playlist(playlistID)) {
                scopedSearchFocused = true
            }
        }
        // Keep the local `tracks` snapshot in sync with the shared
        // `playlistTracks` cache so drag-reorder (BATCH-06b, #73) reflects
        // immediately after `AppModel.moveTrackInPlaylist` mutates the
        // cache. Without this the optimistic reorder only shows up after
        // the next navigation away and back.
        .onChange(of: model.playlistTracks[playlistID]) { _, newValue in
            if let newValue = newValue { tracks = newValue }
        }
        // Clear the title draft when the user navigates away (#602).
        // SwiftUI may reuse the view struct across back-forward navigations
        // (especially with `NavigationStack`), so a stale `titleDraft` from a
        // prior session would appear pre-filled on the next visit. Resetting
        // on disappear ensures the next open starts with the committed value.
        .onDisappear {
            titleDraft = nil
            // Clear scoped filter on navigation away so it never persists
            // into the next page.
            scopedQuery = ""
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let playlist = playlist {
            HStack(alignment: .top, spacing: 36) {
                PlaylistCollage(
                    tracks: tracks,
                    fallbackURL: model.imageURL(for: playlist.id, tag: playlist.imageTag, maxWidth: 480),
                    seed: playlist.name
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("PLAYLIST")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .tracking(3)

                    editableTitle(playlist: playlist)

                    editableDescription(playlist: playlist)

                    HStack(spacing: 28) {
                        stat(value: "\(playlist.trackCount)", label: "Tracks")
                        stat(value: formatMinutes(playlist.runtimeTicks), label: "Minutes")
                    }
                    .padding(.top, 14)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .contextMenu { PlaylistContextMenu(playlist: playlist) }
        } else {
            HStack {
                Text("Playlist not found")
                    .font(Theme.font(18, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 60)
        }
    }

    // MARK: - Click-to-edit title

    @ViewBuilder
    private func editableTitle(playlist: Playlist) -> some View {
        if let draft = titleDraft {
            TextField(
                "Playlist name",
                text: Binding(
                    get: { draft },
                    set: { titleDraft = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(Theme.font(72, weight: .black, italic: true))
            .foregroundStyle(Theme.ink)
            .tracking(-2)
            .focused($titleFocused)
            .onSubmit { commitTitle(playlist: playlist) }
            .onChange(of: titleFocused) { _, focused in
                // Blur → commit. Matches the inline-edit pattern in the
                // spec ("autosaves on blur").
                if !focused { commitTitle(playlist: playlist) }
            }
            .accessibilityLabel("Edit playlist name")
        } else {
            Text(playlist.name)
                .font(Theme.font(72, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .tracking(-2)
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture {
                    titleDraft = playlist.name
                    // Defer focus request by a tick so the TextField has
                    // had time to mount.
                    DispatchQueue.main.async { titleFocused = true }
                }
                .accessibilityLabel(playlist.name)
                .accessibilityHint("Tap to rename")
        }
    }

    private func commitTitle(playlist: Playlist) {
        guard let draft = titleDraft else { return }
        model.renamePlaylist(playlist, newName: draft)
        titleDraft = nil
    }

    // MARK: - Read-only description
    // Editing is hidden until the server-side update_playlist FFI lands (#130).
    // The description renders as plain Text; when empty, nothing is shown
    // (consistent with how empty bios and subtitles are handled elsewhere).

    @ViewBuilder
    private func editableDescription(playlist: Playlist) -> some View {
        if !description.isEmpty {
            Text(description)
                .font(Theme.font(14, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(4)
                .accessibilityLabel(description)
        }
    }

    // MARK: - Stat cell

    @ViewBuilder
    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.font(22, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
        }
    }

    // MARK: - Transport bar

    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 14) {
            Button {
                if !tracks.isEmpty { model.play(tracks: tracks, startIndex: 0) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play playlist")
            .disabled(tracks.isEmpty)

            Button {
                if !tracks.isEmpty {
                    model.play(tracks: tracks.shuffled(), startIndex: 0)
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle playlist")
            .disabled(tracks.isEmpty)

            if let playlist = playlist {
                let isFav = model.isFavorite(playlist: playlist)
                Button { model.toggleFavorite(playlist: playlist) } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundStyle(isFav ? Theme.accent : Theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFav ? "Unfavorite playlist" : "Favorite playlist")
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Track list

    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isLoadingTracks && !tracks.isEmpty {
                // Scoped ⌘F filter, distinct from global search.
                HStack {
                    Spacer()
                    ScopedSearchBar(
                        query: $scopedQuery,
                        isFocused: $scopedSearchFocused,
                        placeholder: "Filter tracks"
                    )
                }
                .padding(.bottom, 8)
            }
            if isLoadingTracks {
                ProgressView().tint(Theme.ink2).padding(.vertical, 40).frame(maxWidth: .infinity)
            } else if tracks.isEmpty {
                Text("No tracks in this playlist")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if filteredTracks.isEmpty {
                Text("No tracks match \u{201C}\(scopedQuery)\u{201D}")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(filteredTracks, id: \.track.id) { entry in
                    let idx = entry.index
                    let track = entry.track
                    // Playlists ignore `indexNumber` (that's the track's
                    // position on its own album) — the playlist order is
                    // implicit in the array order, so number rows by array
                    // index instead.
                    TrackRow(
                        track: track,
                        number: idx + 1,
                        onPlay: { model.play(tracks: tracks, startIndex: idx) },
                        tracks: tracks,
                        index: idx,
                        playlistScope: playlist
                    )
                    // BATCH-06b (#73 / #235): drag-to-reorder. The modifier
                    // lives in `PlaylistReorderHandle.swift` and routes drops
                    // through `AppModel.moveTrackInPlaylist`. Uses the
                    // playlist id from the resolved view model so a deep
                    // link that arrives before the playlist cache is primed
                    // still wires up cleanly (the modifier is a no-op if
                    // `playlistTracks[id]` is empty).
                    .playlistReorderable(
                        playlistId: playlistID,
                        trackId: track.id,
                        index: idx
                    )
                    // Keyboard reorder (#73): make the row focusable so Tab
                    // cycles through the list, then handle Alt+Up / Alt+Down.
                    .focusable(true)
                    .focused($keyboardFocusedIndex, equals: idx)
                    .onKeyPress(.upArrow, phases: .down) { event in
                        guard event.modifiers.contains(.option) else { return .ignored }
                        guard idx > 0 else { return .ignored }
                        model.moveTrackInPlaylist(playlistId: playlistID, from: idx, to: idx - 1)
                        keyboardFocusedIndex = idx - 1
                        return .handled
                    }
                    .onKeyPress(.downArrow, phases: .down) { event in
                        guard event.modifiers.contains(.option) else { return .ignored }
                        guard idx < tracks.count - 1 else { return .ignored }
                        model.moveTrackInPlaylist(playlistId: playlistID, from: idx, to: idx + 2)
                        keyboardFocusedIndex = idx + 1
                        return .handled
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let playlist = playlist {
            Text("\(CountStrings.label(Int(playlist.trackCount), .tracks)) · \(formatMinutes(playlist.runtimeTicks)) min runtime")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
        }
    }

    /// Render a tick-count runtime as a human playlist duration.
    ///
    /// `ticks == 0` → "0" (falls back to zero rather than rendering a hero
    /// stat that reads as "no runtime data"; callers gate the surrounding
    /// stat line on `playlist != nil`).
    /// `< 60 min` → "42" (bare minute count — matches the stat's "MINUTES"
    /// label beneath).
    /// `≥ 60 min` → "5h 42m" (hours segment so a 5h42m playlist doesn't
    /// read as "342" minutes and tell the user it's roughly six hours by
    /// forcing them to do long division).
    private func formatMinutes(_ ticks: UInt64) -> String {
        guard ticks > 0 else { return "0" }
        let totalSeconds = Int(Double(ticks) / 10_000_000.0)
        let totalMinutes = totalSeconds / 60
        guard totalMinutes >= 60 else { return "\(totalMinutes)" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m"
    }
}

/// 2×2 collage of the first four playlist tracks' album art, filling the
/// same 240×240 slot as `Artwork` on the Album hero. Falls back to the
/// playlist's own primary image (if the server has one) and then to a
/// deterministic gradient placeholder when no track art is resolvable.
/// See #234.
private struct PlaylistCollage: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    let fallbackURL: URL?
    let seed: String

    private let slotSize: CGFloat = 240
    private let gap: CGFloat = 2

    var body: some View {
        let quads = quadrantTracks()
        // If no tracks have resolvable art, fall back to the single-image
        // treatment so the slot is never a featureless gradient for
        // playlists that already carry a server-side cover.
        if quads.allSatisfy({ artURL(for: $0) == nil }) {
            // Hero cover for the playlist — the collage path below labels its
            // container "Playlist artwork"; mirror that here so the
            // single-image fallback reads identically to VoiceOver. (#356)
            Artwork(url: fallbackURL, seed: seed, size: slotSize, radius: 6, decorative: false)
                .accessibilityLabel("Playlist artwork")
        } else {
            let cell = (slotSize - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    quadrant(quads[0], size: cell)
                    quadrant(quads[1], size: cell)
                }
                HStack(spacing: gap) {
                    quadrant(quads[2], size: cell)
                    quadrant(quads[3], size: cell)
                }
            }
            .frame(width: slotSize, height: slotSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            .accessibilityLabel("Playlist artwork")
        }
    }

    /// Pick four distinct album-art sources from the first tracks. If the
    /// playlist has fewer than four distinct albums we pad by repeating
    /// the last available track so the grid still reads as a collage.
    private func quadrantTracks() -> [Track?] {
        // Deduplicate by `albumId` so we don't show four copies of the same
        // album cover for a playlist that opens with a run from one album.
        var seenAlbumIDs = Set<String>()
        var distinct: [Track] = []
        for track in tracks {
            let key = track.albumId ?? track.id
            if seenAlbumIDs.insert(key).inserted {
                distinct.append(track)
                if distinct.count == 4 { break }
            }
        }
        var result: [Track?] = [nil, nil, nil, nil]
        for (i, t) in distinct.enumerated() { result[i] = t }
        // Pad gaps by reusing the last filled quadrant so the collage reads
        // as intentional when there are < 4 distinct album covers.
        if let filler = distinct.last {
            for i in distinct.count..<4 { result[i] = filler }
        }
        return result
    }

    private func artURL(for track: Track?) -> URL? {
        guard let track = track else { return nil }
        // Prefer the album's primary image (matches the album grid). Fall
        // back to the track-level image if the album id is missing.
        if let albumID = track.albumId {
            return model.imageURL(for: albumID, tag: track.imageTag, maxWidth: 240)
        }
        return model.imageURL(for: track.id, tag: track.imageTag, maxWidth: 240)
    }

    @ViewBuilder
    private func quadrant(_ track: Track?, size: CGFloat) -> some View {
        let url = artURL(for: track)
        let quadSeed = track?.albumName ?? track?.name ?? seed
        Artwork(url: url, seed: quadSeed, size: size, radius: 0)
    }
}
