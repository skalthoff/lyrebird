import SwiftUI
@preconcurrency import JellifyCore

/// Dedicated Favorites surface. Users had no place to browse the items
/// they'd hearted from context menus and detail screens — the sidebar
/// "Favorites" row routed to the all-albums library tab as a stopgap.
/// This screen surfaces favorited Songs, Albums, and Artists in their
/// own sections, sourced via `IsFavorite` filters on `/Items` queries.
///
/// Playlist favorites are intentionally out of scope here: the user's
/// playlists already live in the sidebar and are reachable directly
/// from there, so a separate "favorited playlists" surface would be
/// redundant for v1.0. Adding it later is a small follow-up if usage
/// shows demand.
struct FavoritesView: View {
    @Environment(AppModel.self) private var model

    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                if isLoading && tracks.isEmpty && albums.isEmpty && artists.isEmpty {
                    loadingState
                } else if tracks.isEmpty && albums.isEmpty && artists.isEmpty {
                    emptyState
                } else {
                    if !tracks.isEmpty { songsSection }
                    if !albums.isEmpty { albumsSection }
                    if !artists.isEmpty { artistsSection }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .background(Theme.bg)
        .task(id: "\(model.session?.user.id ?? "")|\(model.favoriteChangeToken)") {
            await refresh()
        }
    }

    // MARK: - Header

    /// 80pt eyebrow / title block. Mirrors HomeView and LibraryView's
    /// hero rather than the smaller chip rows so the page feels like
    /// its own destination, not a filter applied elsewhere.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FAVORITES")
                .font(Theme.font(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Your Library")
                    .font(Theme.font(34, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !tracks.isEmpty {
                    Button {
                        model.play(tracks: tracks.shuffled(), startIndex: 0)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                            Text("Shuffle All")
                        }
                        .font(Theme.font(13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surface)
                        .foregroundStyle(Theme.ink)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle all favorite songs")
                }
            }
            countLine
        }
    }

    /// Subtitle that summarizes what the user is looking at. Renders the
    /// counts in a single line so the user sees scope at a glance.
    private var countLine: some View {
        let parts: [String] = [
            tracks.isEmpty ? nil : "\(tracks.count) song\(tracks.count == 1 ? "" : "s")",
            albums.isEmpty ? nil : "\(albums.count) album\(albums.count == 1 ? "" : "s")",
            artists.isEmpty ? nil : "\(artists.count) artist\(artists.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        return Text(parts.isEmpty ? " " : parts.joined(separator: " · "))
            .font(Theme.font(13, weight: .medium))
            .foregroundStyle(Theme.ink3)
    }

    // MARK: - Sections

    /// Songs section — vertical list. Tap plays the song against the
    /// full favorites track list so Up Next reflects the user's
    /// intent ("play from my favorites").
    @ViewBuilder
    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Songs", count: tracks.count)
            VStack(spacing: 0) {
                ForEach(Array(tracks.prefix(50).enumerated()), id: \.element.id) { idx, track in
                    TrackListRow(
                        track: track,
                        tracks: tracks,
                        index: idx
                    )
                }
            }
            .padding(.vertical, 4)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if tracks.count > 50 {
                Text("Showing 50 of \(tracks.count). The full list shuffles via Shuffle All.")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 4)
            }
        }
    }

    /// Albums section — adaptive grid mirroring LibraryView's tile size.
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Albums", count: albums.count)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 18)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(albums, id: \.id) { album in
                    AlbumCard(album: album)
                }
            }
        }
    }

    /// Artists section — circular tiles. Wraps every six tiles via the
    /// same adaptive grid the library uses; ArtistCard owns its own
    /// circular crop so we don't have to clip here.
    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Artists", count: artists.count)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 144, maximum: 200), spacing: 20)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(artists, id: \.id) { artist in
                    ArtistCard(artist: artist)
                }
            }
        }
    }

    // MARK: - States

    /// Skeleton-flavored loading state — same visual weight as the
    /// real content so the page doesn't reflow when sections fill in.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Loading your favorites…")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
    }

    /// Empty state when the user hasn't favorited anything yet. Points
    /// at the heart icons that drive the IsFavorite mutation so users
    /// know how to seed the view.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "heart")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.ink2)
                Text("No favorites yet")
                    .font(Theme.font(20, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
            Text("Tap the heart on a song, album, or artist and it shows up here.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Theme.font(20, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("\(count)")
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink3)
            Spacer()
        }
    }

    /// Pull all three lists in parallel. Each load is independent so a
    /// flaky endpoint on one type doesn't sink the others — same pattern
    /// as ArtistDetailView's parallel album/top-tracks/similar fetches.
    private func refresh() async {
        isLoading = true
        async let t = model.loadFavoriteTracks()
        async let a = model.loadFavoriteAlbums()
        async let r = model.loadFavoriteArtists()
        let (loadedTracks, loadedAlbums, loadedArtists) = await (t, a, r)
        tracks = loadedTracks
        albums = loadedAlbums
        artists = loadedArtists
        isLoading = false
    }
}
