import SwiftUI
@preconcurrency import LyrebirdCore

/// Compact single-line row used by the Library list view. Mirrors the
/// design's list density: small square artwork, title, secondary text, and
/// a trailing metadata slot. Renders an album, artist, or playlist depending
/// on which payload was used at construction time. Clicking opens the
/// relevant detail screen; hover reveals an inline play button.
///
/// Each backing value type (`Album`, `Artist`, `Playlist`) has its own
/// initializer so the call sites stay typed without a giant sum-type
/// argument. The body is one `switch self.payload` so the SwiftUI layout
/// doesn't fan out across separate view structs.
struct LibraryListRow: View {
    enum Payload {
        case album(Album)
        case artist(Artist)
        case playlist(Playlist)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let payload: Payload
    @State private var isHovering = false

    init(album: Album) {
        self.payload = .album(album)
    }

    init(artist: Artist) {
        self.payload = .artist(artist)
    }

    init(playlist: Playlist) {
        self.payload = .playlist(playlist)
    }

    var body: some View {
        Button(action: openDetail) {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(
                        url: artworkURL,
                        seed: artworkSeed,
                        size: 40,
                        radius: artworkRadius
                    )
                    if isHovering, showPlayHover {
                        Button(action: playPrimary) {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .font(.system(size: 11))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.primary))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(secondaryText)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer()

                if let trailing = trailingMeta {
                    Text(trailing)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }

                Text(countMeta)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Theme.rowHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
        .contextMenu { contextMenu }
        // VoiceOver hears "<primary>, <secondary>. Opens <kind> detail."
        // The hover play button only appears on cursor hover, so we route
        // the row's body tap (openDetail) as the single focusable target.
        // `.focusable` lets the rotor Tab through the list; `.combine`
        // collapses artwork + text into one element. See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        let subtitle = secondaryText.isEmpty ? "" : ", \(secondaryText)"
        return "\(primaryText)\(subtitle)"
    }

    private var accessibilityHint: String {
        switch payload {
        case .album: return "Opens album detail"
        case .artist: return "Opens artist detail"
        case .playlist: return "Opens playlist detail"
        }
    }

    // MARK: - Payload-driven properties

    private var artworkURL: URL? {
        switch payload {
        case .album(let album):
            return model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 120)
        case .artist(let artist):
            return model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 120)
        case .playlist(let playlist):
            return model.imageURL(for: playlist.id, tag: playlist.imageTag, maxWidth: 120)
        }
    }

    private var artworkSeed: String {
        switch payload {
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.name
        }
    }

    /// Albums and playlists use the shared 4pt radius; artists get a
    /// pill/circle so the list row reads consistently with the circular
    /// `ArtistRadioTile` used elsewhere.
    private var artworkRadius: CGFloat {
        switch payload {
        case .album, .playlist: return 4
        case .artist: return 20
        }
    }

    private var primaryText: String {
        switch payload {
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.name
        }
    }

    private var secondaryText: String {
        switch payload {
        case .album(let album):
            return album.artistName
        case .artist(let artist):
            if !artist.genres.isEmpty { return artist.genres.joined(separator: ", ") }
            return "Artist"
        case .playlist(let playlist):
            // Playlists have no "artist" analogue, so the subtitle carries
            // runtime duration instead. Falls back to an empty label for
            // zero-runtime playlists so the layout still lines up.
            return formattedDuration(runtimeTicks: playlist.runtimeTicks)
        }
    }

    /// Optional trailing metadata (e.g. release year for albums). Artists
    /// and playlists have no equivalent, so the slot stays empty.
    private var trailingMeta: String? {
        switch payload {
        case .album(let album):
            return album.year.map { String($0) }
        case .artist, .playlist:
            return nil
        }
    }

    private var countMeta: String {
        switch payload {
        case .album(let album):
            return album.trackCount == 1 ? "1 track" : "\(album.trackCount) tracks"
        case .artist(let artist):
            return artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums"
        case .playlist(let playlist):
            // Empty playlists get a compact "Empty" label rather than "0
            // tracks"; otherwise mirror the album column's format.
            switch playlist.trackCount {
            case 0: return "Empty"
            case 1: return "1 track"
            default: return "\(playlist.trackCount) tracks"
            }
        }
    }

    /// Compact duration label for the playlist subtitle. Ticks are in
    /// hundred-nanoseconds (standard Jellyfin unit). Shows `H:MM` past the
    /// hour mark, `Mm` otherwise ("4 min", "1h 32m"). Empty playlists
    /// (`runtimeTicks == 0`) render as an empty string so the row collapses
    /// to just the title line.
    private func formattedDuration(runtimeTicks: UInt64) -> String {
        guard runtimeTicks > 0 else { return "" }
        let totalSeconds = Int(runtimeTicks / 10_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        // Sub-minute playlists round up to "1 min" rather than "0 min", so a
        // 30-second single-track playlist still looks like content.
        return "\(max(minutes, 1)) min"
    }

    private func openDetail() {
        switch payload {
        case .album(let album):
            model.navPath.append(AppModel.Route.album(album.id))
        case .artist(let artist):
            model.navPath.append(AppModel.Route.artist(artist.id))
        case .playlist(let playlist):
            // Route through `goToPlaylist` so the playlist is seeded into
            // `model.playlists` before the screen flips. Without this seed,
            // `PlaylistView`'s cache lookup misses for any row the user
            // opens from a non-first-page list (search results, list
            // pagination beyond 100 items) and the hero renders "not found".
            model.goToPlaylist(playlist)
        }
    }

    private func playPrimary() {
        switch payload {
        case .album(let album):
            model.play(album: album)
        case .artist(let artist):
            model.playAll(artist: artist)
        case .playlist(let playlist):
            model.play(playlist: playlist)
        }
    }

    /// Hide the inline hover-play button when the row's primary action would
    /// hit a stub (artist rows depend on `supportsArtistPlayShuffle`).
    /// Album / Playlist rows always show it.
    private var showPlayHover: Bool {
        switch payload {
        case .album, .playlist: return true
        case .artist: return model.supportsArtistPlayShuffle
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch payload {
        case .album(let album):
            AlbumContextMenu(album: album)
        case .artist(let artist):
            ArtistContextMenu(artist: artist)
        case .playlist(let playlist):
            PlaylistContextMenu(playlist: playlist)
        }
    }
}
