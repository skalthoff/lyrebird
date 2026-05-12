import SwiftUI
@preconcurrency import LyrebirdCore

/// Instant-results dropdown anchored to a search field. Renders typed
/// sections (Top Result hero, Artists, Albums, Tracks, Playlists, Genres)
/// while the user is still typing, with a 250ms debounce on the fetch.
///
/// Issues #85 (instant dropdown), #241 (debounced fetch), #243 (Top
/// Result hero card).
///
/// Wiring model:
///   - `query` — two-way binding to the field's text. Keystrokes drive
///     `AppModel.runInstantSearch` through `onChange`, which handles
///     cancellation of in-flight work.
///   - `isPresented` — external "show me" flag. The dropdown flips itself
///     off when `query` goes empty so the caller doesn't have to.
///   - `onPickItem` — routing callback. The dropdown surfaces a
///     heterogeneous `SearchItem` so the caller can decide whether a
///     pick means "navigate" (artist / album / playlist / genre) or
///     "play" (track). Keeps the component agnostic about the host's
///     navigation stack.
///
/// Presentation: attached via `.popover` for now. BATCH-01 is responsible
/// for wiring this to the toolbar's search field — until then the
/// dropdown is presentation-ready but unattached. Using `.popover` (vs.
/// a hand-rolled `overlay`) leverages AppKit's existing anchor, focus-
/// handoff, and dismissal-on-outside-click behaviour.
struct SearchInstantDropdown: View {
    @Environment(AppModel.self) private var model

    @Binding var query: String
    @Binding var isPresented: Bool
    let onPickItem: (SearchItem) -> Void

    var body: some View {
        Group {
            if query.isEmpty {
                // Empty field: render nothing. The caller's binding drives
                // whether the popover is visible at all, but we also guard
                // here so a stray "show" with no query doesn't flash an
                // empty sheet.
                EmptyView()
            } else {
                content
            }
        }
        .onChange(of: query) { _, newValue in
            // Each keystroke debounces inside the model — the task there
            // cancels the previous one. An empty field short-circuits to
            // `.empty` in the model, so the dropdown clears instantly.
            if newValue.isEmpty {
                isPresented = false
            } else {
                isPresented = true
            }
            model.runInstantSearch(query: newValue)
        }
        .onDisappear {
            // Cancel any in-flight debounced fetch when the dropdown goes
            // away — the caller may have dismissed by submitting the
            // full search, in which case the leftover instant results
            // would overwrite the empty `.empty` state mid-navigation.
            model.searchTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        let results = model.instantSearchResults
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let top = results.topResult {
                    Self.sectionHeader("Top Result")
                    TopResultHero(item: top, onPick: onPickItem)
                }

                if !results.artists.isEmpty {
                    Self.sectionHeader("Artists")
                    ArtistsRow(artists: Array(results.artists.prefix(6)), onPick: onPickItem)
                }

                if !results.albums.isEmpty {
                    Self.sectionHeader("Albums")
                    AlbumsGrid(albums: Array(results.albums.prefix(10)), onPick: onPickItem)
                }

                if !results.tracks.isEmpty {
                    Self.sectionHeader("Tracks")
                    TracksList(tracks: Array(results.tracks.prefix(8)), onPick: onPickItem)
                }

                if !results.playlists.isEmpty {
                    Self.sectionHeader("Playlists")
                    PlaylistsGrid(
                        playlists: Array(results.playlists.prefix(10)),
                        onPick: onPickItem
                    )
                }

                if !results.genres.isEmpty {
                    Self.sectionHeader("Genres")
                    GenresRow(genres: Array(results.genres.prefix(8)), onPick: onPickItem)
                }

                if results.isEmpty {
                    // Instant-search yielded nothing yet — either the
                    // debounce hasn't fired or the query truly has no
                    // matches. Either way a bare line beats a spinner +
                    // skeleton flicker on every keystroke.
                    Text("No matches yet")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.bgAlt)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 200, idealHeight: 420, maxHeight: 520)
    }

    // MARK: - Section header

    @ViewBuilder
    static func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.font(11, weight: .bold))
            .foregroundStyle(Theme.ink2)
            .tracking(1.5)
            .padding(.top, 4)
    }
}

// MARK: - Top Result hero

/// Large hero card for the "Top Result" section. Mirrors Spotify /
/// Apple Music's omnibox: oversized artwork, type label, and a prominent
/// accent-tinted play button that lifts slightly on hover. Spec #243.
private struct TopResultHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: SearchItem
    let onPick: (SearchItem) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                Text(item.typeLabel.uppercased())
                    .font(Theme.font(10, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                    .tracking(1.5)
                Text(item.title)
                    .font(Theme.font(22, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            playButton
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovering ? Theme.surface2 : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovering ? Theme.borderStrong : Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onPick(item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top result: \(item.typeLabel) \(item.title)")
    }

    private var artwork: some View {
        Artwork(
            url: artworkURL,
            seed: item.title,
            size: 88,
            radius: item.isArtist ? 44 : 8,
            targetPixelSize: CGSize(width: 264, height: 264)
        )
        .frame(width: 88, height: 88)
        // Artist hero uses a circular mask to match the ArtistCard
        // shape convention used elsewhere.
        .clipShape(
            item.isArtist
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: 8))
        )
    }

    private var playButton: some View {
        Button(action: { onPick(item) }) {
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.accent))
                .shadow(color: Theme.accent.opacity(0.45), radius: 12, y: 4)
                .scaleEffect(isHovering ? 1.04 : 1.0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(item.title)")
    }

    private var artworkURL: URL? {
        switch item {
        case .artist(let a): return model.imageURL(for: a.id, tag: a.imageTag, maxWidth: 400)
        case .album(let a): return model.imageURL(for: a.id, tag: a.imageTag, maxWidth: 400)
        case .track(let t): return model.imageURL(for: t.albumId ?? t.id, tag: t.imageTag, maxWidth: 400)
        case .playlist(let p): return model.imageURL(for: p.id, tag: p.imageTag, maxWidth: 400)
        case .genre: return nil
        }
    }

    private var subtitle: String? {
        switch item {
        case .artist(let a):
            if a.albumCount > 0 {
                return a.albumCount == 1 ? "1 album" : "\(a.albumCount) albums"
            }
            return a.genres.first
        case .album(let a):
            if let year = a.year, year > 0 {
                return "\(a.artistName) \u{00B7} \(year)"
            }
            return a.artistName
        case .track(let t):
            if let album = t.albumName, !album.isEmpty {
                return "\(t.artistName) \u{00B7} \(album)"
            }
            return t.artistName
        case .playlist(let p):
            switch p.trackCount {
            case 0: return "Empty"
            case 1: return "1 track"
            default: return "\(p.trackCount) tracks"
            }
        case .genre:
            return nil
        }
    }
}

// MARK: - Artists row (6 circles)

private struct ArtistsRow: View {
    let artists: [Artist]
    let onPick: (SearchItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(artists, id: \.id) { artist in
                    ArtistCircleTile(artist: artist, onPick: onPick)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct ArtistCircleTile: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    let onPick: (SearchItem) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            Artwork(
                url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 200),
                seed: artist.name,
                size: 68,
                radius: 34,
                targetPixelSize: CGSize(width: 204, height: 204)
            )
            .frame(width: 68, height: 68)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(
                    isHovering ? Theme.accent : Color.clear,
                    lineWidth: 2
                )
            )
            Text(artist.name)
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(isHovering ? Theme.accent : Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: 80)
        }
        .frame(width: 80)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onPick(.artist(artist)) }
        // Custom tap-gesture control needs an explicit focusable + button
        // trait so the VoiceOver rotor can reach it. See #588.
        .focusable(true)
        .accessibilityLabel("Artist \(artist.name)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Albums grid (5 cols)

private struct AlbumsGrid: View {
    let albums: [Album]
    let onPick: (SearchItem) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 5
    )

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(albums, id: \.id) { album in
                AlbumMiniTile(album: album, onPick: onPick)
            }
        }
    }
}

private struct AlbumMiniTile: View {
    @Environment(AppModel.self) private var model
    let album: Album
    let onPick: (SearchItem) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(
                url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 300),
                seed: album.name,
                size: 88,
                radius: 6,
                targetPixelSize: CGSize(width: 264, height: 264)
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHovering ? Theme.accent : Color.clear, lineWidth: 2)
            )
            Text(album.name)
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(isHovering ? Theme.accent : Theme.ink)
                .lineLimit(1)
            Text(album.artistName)
                .font(Theme.font(10, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onPick(.album(album)) }
        // Custom tap-gesture control — expose as a focusable button so the
        // VoiceOver rotor can reach search result album tiles. See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Album \(album.name) by \(album.artistName)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Tracks list

private struct TracksList: View {
    let tracks: [Track]
    let onPick: (SearchItem) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(tracks, id: \.id) { track in
                TrackDropdownRow(track: track, onPick: onPick)
            }
        }
    }
}

private struct TrackDropdownRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let onPick: (SearchItem) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(
                url: model.imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: 120),
                seed: track.name,
                size: 34,
                radius: 4,
                targetPixelSize: CGSize(width: 102, height: 102)
            )
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(isHovering ? Theme.accent : Theme.ink)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(Theme.font(10, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer()
            Text(track.durationFormatted)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Theme.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onPick(.track(track)) }
        // Custom tap-gesture row — expose as focusable button so the
        // VoiceOver rotor can reach search result track rows. See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Track \(track.name) by \(track.artistName)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Playlists grid (5 cols)

private struct PlaylistsGrid: View {
    let playlists: [Playlist]
    let onPick: (SearchItem) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 5
    )

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(playlists, id: \.id) { playlist in
                PlaylistMiniTile(playlist: playlist, onPick: onPick)
            }
        }
    }
}

private struct PlaylistMiniTile: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let onPick: (SearchItem) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(
                url: model.imageURL(for: playlist.id, tag: playlist.imageTag, maxWidth: 300),
                seed: playlist.name,
                size: 88,
                radius: 6,
                targetPixelSize: CGSize(width: 264, height: 264)
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHovering ? Theme.accent : Color.clear, lineWidth: 2)
            )
            Text(playlist.name)
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(isHovering ? Theme.accent : Theme.ink)
                .lineLimit(1)
            Text(countLabel)
                .font(Theme.font(10, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onPick(.playlist(playlist)) }
        // Custom tap-gesture control — expose as focusable button so the
        // VoiceOver rotor can reach search result playlist tiles. See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playlist \(playlist.name)")
        .accessibilityAddTraits(.isButton)
    }

    private var countLabel: String {
        switch playlist.trackCount {
        case 0: return "Empty"
        case 1: return "1 track"
        default: return "\(playlist.trackCount) tracks"
        }
    }
}

// MARK: - Genres row (horizontal tiles)

private struct GenresRow: View {
    let genres: [Genre]
    let onPick: (SearchItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(genres, id: \.id) { genre in
                    GenreTile(genre: genre, onPick: onPick)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct GenreTile: View {
    let genre: Genre
    let onPick: (SearchItem) -> Void

    @State private var isHovering = false

    var body: some View {
        Text(genre.name)
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(isHovering ? .white : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Theme.accent : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture { onPick(.genre(genre)) }
            // Custom tap-gesture genre chip — expose as focusable button for
            // VoiceOver rotor traversal. See #588.
            .focusable(true)
            .accessibilityLabel("Genre \(genre.name)")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Type helpers

private extension SearchItem {
    /// True when this item should render with a circular artwork mask —
    /// matches the rest of the app's "artists are circles, everything
    /// else is square" convention.
    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}
