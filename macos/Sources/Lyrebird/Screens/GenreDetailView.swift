import SwiftUI
@preconcurrency import LyrebirdCore

/// Genre detail screen — pushed onto the navigation stack by
/// `AppModel.browseGenre(genre:)`. Mirrors the shape of `ArtistDetailView`:
/// a header band with the genre name, a transport row (Play / Shuffle /
/// Radio / Pin), an Albums shelf, and a Tracks shelf. The shelves render
/// eagerly (no `LazyHStack`) per CLAUDE.md's rc9 note about the macOS 26.4
/// UAF in `LazyHStack` inside a horizontal ScrollView.
///
/// The incoming `Genre` is constructed by `AppModel.browseGenre` and
/// carries the *resolved Jellyfin UUID* in `genre.id` (not the display
/// name — see #823 Wave 2), so this view passes `genre.id` directly to
/// `core.itemsByGenre` / `core.tracksByGenre`. Don't re-resolve here.
struct GenreDetailView: View {
    @Environment(AppModel.self) private var model
    let genre: Genre

    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var isLoadingAlbums = true
    @State private var isLoadingTracks = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                transportBar
                albumsSection
                tracksSection
            }
        }
        .background(Theme.bg)
        .task(id: genre.id) {
            isLoadingAlbums = true
            isLoadingTracks = true
            // Independent do/catch per CLAUDE.md gap pattern #4 — one
            // flaky endpoint shouldn't sink the other shelf. The two
            // helpers on AppModel already swallow errors into
            // `errorMessage`, so we just await each in turn.
            albums = await model.loadAlbums(forGenreId: genre.id, limit: 50)
            isLoadingAlbums = false
            tracks = await model.loadTracks(forGenreId: genre.id, limit: 50)
            isLoadingTracks = false
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GENRE")
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .tracking(3)
            Text(genre.name)
                .font(Theme.font(64, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .tracking(-2)
                .lineLimit(2)
            subtitleLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 12)
    }

    /// "N songs · M albums" subtitle — built from whichever counts the
    /// shelves loaded so far. Falls back to a quiet stat-less line while
    /// the page is still warming up.
    @ViewBuilder
    private var subtitleLine: some View {
        let songCount = tracks.count
        let albumCount = albums.count
        let parts: [String] = {
            var p: [String] = []
            if !isLoadingTracks { p.append(CountStrings.label(songCount, .songs)) }
            if !isLoadingAlbums { p.append(CountStrings.label(albumCount, .albums)) }
            return p
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
        } else {
            Text(" ")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
        }
    }

    // MARK: - Transport

    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 14) {
            // Primary CTA — Play. Plays the loaded track page in order
            // (no shuffle). Disabled while tracks are still loading.
            Button {
                guard !tracks.isEmpty else { return }
                model.play(tracks: tracks, startIndex: 0)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .help("Play \(genre.name)")
            .accessibilityLabel("Play all \(genre.name) tracks")

            transportSecondary(icon: "shuffle", help: "Shuffle \(genre.name)") {
                model.shuffleGenre(genre: genre)
            }

            transportSecondary(icon: "dot.radiowaves.left.and.right", help: "Start \(genre.name) radio") {
                model.startGenreRadio(genre: genre)
            }

            transportSecondary(icon: "pin", help: "Pin \(genre.name) to Home") {
                model.pinGenreToHome(genre: genre)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func transportSecondary(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.ink2)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Albums shelf

    @ViewBuilder
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(eyebrow: "ALBUMS", title: "Albums in \(genre.name)")
            if isLoadingAlbums {
                ProgressView()
                    .tint(Theme.ink2)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if albums.isEmpty {
                emptySection(icon: "square.stack", message: "No albums tagged with \(genre.name) yet.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    // Eager HStack per CLAUDE.md rc9 — LazyHStack inside a
                    // horizontal ScrollView triggers a UAF on macOS 26.4
                    // when the carousel reuses children across navigation.
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(albums, id: \.id) { album in
                            HomeAlbumTile(album: album)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 32)
                }
            }
        }
        .padding(.top, 24)
    }

    // MARK: - Tracks shelf

    @ViewBuilder
    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(eyebrow: "TRACKS", title: "Tracks in \(genre.name)")
            if isLoadingTracks {
                ProgressView()
                    .tint(Theme.ink2)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if tracks.isEmpty {
                emptySection(icon: "music.note.list", message: "No tracks tagged with \(genre.name) yet.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tracks, id: \.id) { track in
                        let index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
                        TrackListRow(track: track, tracks: tracks, index: index)
                    }
                }
                .padding(.horizontal, 32)
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 40)
    }

    // MARK: - Section helpers (mirror ArtistDetailView)

    @ViewBuilder
    private func sectionHeader(eyebrow: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow)
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
            Text(title)
                .font(Theme.font(22, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .tracking(-1)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func emptySection(icon: String, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.ink3)
            Text(message)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
    }
}
