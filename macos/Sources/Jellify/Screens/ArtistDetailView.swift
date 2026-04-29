import SwiftUI
@preconcurrency import JellifyCore

/// Full-surface Artist detail screen. Landed as part of BATCH-04 — closes
/// #58, #60, #227, #228, #231, #232.
///
/// Layout (top-to-bottom):
/// 1. **Hero band** (360pt) — blurred backdrop art, 200pt circular portrait,
///    eyebrow "ARTIST", 72pt italic-black title, genre line, stats strip.
/// 2. **Transport row** — 54pt Play All, Shuffle, Follow (heart), Artist
///    Radio, Instant Mix. Mirrors the album detail transport for consistency.
/// 3. **Top Songs** — built on `TopTrackRow` from PR #512 (#229). The rank /
///    artwork / play-count UI is already tuned there; we just render the
///    section around it.
/// 4. **Discography** — split by release type (Albums, Singles & EPs,
///    Compilations, Live, Appears On). Because the core doesn't surface
///    `AlbumType` yet, we lean on a name/track-count heuristic; sections
///    with zero matches collapse silently.
/// 5. **Similar Artists** — stubbed row (data dependency tracked below).
/// 6. **About / bio** — expandable overview block (data dependency tracked
///    below).
///
/// Data stubs that remain TODO pending core work:
/// - `artist_overview` / `artist_details` FFI (#231) → the About block falls
///   back to the artist's genres + a "No bio yet" line.
/// - `AlbumType` on the `Album` record (#60) → discography grouping uses
///   a name/track-count heuristic.
/// - Listener stats (plays last 30d, followers) (#227) → the hero's stats
///   strip uses albums + songs + genre as the best-available triad.
///
/// All stubs are deliberate: the rule for this screen is "use what the core
/// exposes today and make the gaps visible but not broken", not "fabricate
/// numbers".
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let artistID: String

    @State private var topTracks: [Track] = []
    @State private var isLoadingTopTracks = true
    @State private var artistAlbums: [Album] = []
    @State private var fetchedArtist: Artist?
    @State private var isBioExpanded = false
    @State private var similarArtistsState: [Artist] = []

    /// Resolve the artist: cached library page first, then whichever
    /// record the `.task` block fetched on demand. Missing (server
    /// unreachable or truly deleted) falls through to the gentle
    /// "Artist not found" placeholder below.
    private var artist: Artist? {
        model.artists.first { $0.id == artistID } ?? fetchedArtist
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                transportBar
                topSongsSection
                discographySection
                similarArtistsSection
                aboutSection
                footer
            }
        }
        .background(Theme.bg)
        .task(id: artistID) {
            isLoadingTopTracks = true
            if model.artists.first(where: { $0.id == artistID }) == nil {
                fetchedArtist = await model.resolveArtist(id: artistID)
            }
            // Server-scoped fetch via `AlbumArtistIds`. The prior
            // `model.albums.filter { ... }` only looked at the cached
            // first page of 100 library-wide albums, so Discography
            // rendered empty for most artists on a large library (#60).
            artistAlbums = await model.loadArtistAlbums(artistId: artistID)
            topTracks = await model.loadArtistTopTracks(artistId: artistID)
            isLoadingTopTracks = false
            similarArtistsState = await model.loadSimilarArtists(artistId: artistID)
        }
    }

    // MARK: - Hero (#58, #227)

    /// 360pt hero band. Layout per `06-screen-specs.md §4`: blurred full-width
    /// backdrop at 0.35 opacity, 200pt circular portrait on the left, type
    /// block on the right, stats strip pinned at the bottom. When the artist
    /// has no image we fall back to a deterministic gradient placeholder and
    /// `person.circle.fill` so the band doesn't read as broken.
    @ViewBuilder
    private var hero: some View {
        if let artist = artist {
            ZStack(alignment: .bottomLeading) {
                backdrop(for: artist)
                heroContent(for: artist)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .clipped()
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .contextMenu { ArtistContextMenu(artist: artist) }
        } else {
            HStack {
                Text("Artist not found")
                    .font(Theme.font(18, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
        }
    }

    /// Full-width blurred backdrop. Uses the same portrait as the hero
    /// circle but at 1600pt, 0.35 opacity, and 40pt blur — which softens
    /// JPEG artifacts and keeps the type block readable on light subjects.
    /// When there's no primary image we fall back to the deterministic
    /// gradient palette used for `person.circle.fill` fallbacks elsewhere.
    @ViewBuilder
    private func backdrop(for artist: Artist) -> some View {
        let url = model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 1600)
        ZStack {
            // Base layer — solid bg so transitions don't flash white.
            Theme.bg
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .opacity(0.35)
                            .blur(radius: 40)
                    case .failure, .empty:
                        backdropPlaceholder(seed: artist.name)
                    @unknown default:
                        backdropPlaceholder(seed: artist.name)
                    }
                }
            } else {
                backdropPlaceholder(seed: artist.name)
            }
            // Bottom gradient fade — keeps the hero title readable over any
            // image, and hands off to `Theme.bg` for the following sections.
            LinearGradient(
                colors: [.clear, Theme.bg.opacity(0.85), Theme.bg],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    @ViewBuilder
    private func backdropPlaceholder(seed: String) -> some View {
        let palette = Artwork.palette(for: seed)
        LinearGradient(
            colors: [palette.0.opacity(0.5), palette.1.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The hero's foreground: 200pt circular portrait + type block. The type
    /// block is right-aligned to the portrait and bottom-anchored so the
    /// stats strip sits on the gradient's fade-to-bg boundary.
    @ViewBuilder
    private func heroContent(for artist: Artist) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            heroPortrait(for: artist)
            heroTypeBlock(for: artist)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private func heroPortrait(for artist: Artist) -> some View {
        if let url = model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 480) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    portraitFallback(seed: artist.name)
                @unknown default:
                    portraitFallback(seed: artist.name)
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)
        } else {
            portraitFallback(seed: artist.name)
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)
        }
    }

    /// Gradient circle with `person.circle.fill` for artists with no portrait.
    /// Matches the hero palette so the hero doesn't read as broken when the
    /// server has no primary image for the artist.
    @ViewBuilder
    private func portraitFallback(seed: String) -> some View {
        let palette = Artwork.palette(for: seed)
        ZStack {
            LinearGradient(
                colors: [palette.0, palette.1],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "person.circle.fill")
                .font(.system(size: 100, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private func heroTypeBlock(for artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ARTIST")
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .tracking(3)
            Text(artist.name)
                .font(Theme.font(72, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .tracking(-2)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
            if !artist.genres.isEmpty {
                Text(artist.genres.joined(separator: ", "))
                    .font(Theme.font(15, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            heroStatsStrip(for: artist)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stats strip in the hero. Albums count is live; tracks / monthly
    /// listeners / followers are surfaced only when the core exposes them.
    /// Followers + monthly listeners are a #227 follow-up — the Jellyfin
    /// server doesn't report them today, so we render whichever of (albums,
    /// tracks, genre) we have.
    @ViewBuilder
    private func heroStatsStrip(for artist: Artist) -> some View {
        HStack(spacing: 28) {
            stat(value: "\(artistAlbums.count)", label: "Albums")
            if artist.songCount > 0 {
                stat(value: "\(artist.songCount)", label: "Tracks")
            }
            // TODO(core-#227): surface "plays last 30d" / "monthly listeners"
            // / "followers" once the core exposes those counters. Today they
            // aren't in the `Artist` record, so we stop at the genre pill.
            if !artist.genres.isEmpty {
                stat(value: artist.genres.first ?? "—", label: "Genre")
            }
        }
    }

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

    // MARK: - Transport (#228)

    /// Play All / Shuffle / Follow / Radio / Mix row. Matches the album
    /// detail transport so the two detail screens share a transport mental
    /// model. Most actions delegate to stubs on `AppModel` pending core
    /// work — the UI is live, the wiring lights up when each FFI lands.
    @ViewBuilder
    private var transportBar: some View {
        if let artist = artist {
            HStack(spacing: 14) {
                Button {
                    // Play All delegates to `playAll` on AppModel. That path
                    // falls back to "play the top 5" today (see #156 / #465)
                    // because the artist-tracks FFI isn't wired yet — so for
                    // the primary CTA we use the top-tracks list when Play
                    // All would no-op, which matches user expectation.
                    if topTracks.isEmpty {
                        model.playAll(artist: artist)
                    } else {
                        model.play(tracks: topTracks, startIndex: 0)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.accent))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
                }
                .buttonStyle(.plain)
                .help("Play all tracks")
                .accessibilityLabel("Play all tracks by \(artist.name)")

                if model.supportsArtistPlayShuffle {
                    transportSecondary(
                        icon: "shuffle",
                        help: "Shuffle all"
                    ) { model.shuffle(artist: artist) }
                }

                // Favorite — heart flips to filled/outlined based on server state.
                let isFav = model.isFavorite(id: artist.id)
                transportSecondary(
                    icon: isFav ? "heart.fill" : "heart",
                    help: isFav ? "Unfavorite" : "Favorite"
                ) { model.toggleFavorite(artist: artist) }

                transportSecondary(
                    icon: "dot.radiowaves.left.and.right",
                    help: "Start artist radio"
                ) { model.startArtistRadio(artist: artist) }

                // Instant Mix from the artist — same stub as the above radio
                // today, but they're separate affordances per the brief so
                // when #144 lands we can split them (radio = artist-seeded
                // station; mix = polymorphic Instant Mix).
                transportSecondary(
                    icon: "waveform.path.ecg",
                    help: "Start instant mix"
                ) { model.startArtistRadio(artist: artist) }

                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
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

    // MARK: - Top Songs (#229; PR #512)

    /// Calls through to `TopTrackRow` from PR #512 — we're the new layout
    /// shell, not a reimplementation of the top-tracks row UI.
    @ViewBuilder
    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(eyebrow: "MOST PLAYED", title: "Top Songs")
            VStack(alignment: .leading, spacing: 2) {
                if isLoadingTopTracks {
                    ProgressView()
                        .tint(Theme.ink2)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                } else if topTracks.isEmpty {
                    emptySection(
                        icon: "music.note.list",
                        message: "No play history yet for this artist."
                    )
                } else {
                    ForEach(Array(topTracks.enumerated()), id: \.element.id) { idx, track in
                        TopTrackRow(track: track, rank: idx + 1, queue: topTracks)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }

    // MARK: - Discography (#60)

    /// Discography grouped by the best-available release type. Jellyfin's
    /// `Album.AlbumType` isn't surfaced in the core `Album` record today
    /// (see TODO(core-#60) below), so we classify each album by:
    ///
    /// - **Live** — name contains "Live at", "Live in", or "(Live)".
    /// - **Compilations** — name contains "Compilation", "Greatest Hits",
    ///   "Anthology", "Collection", or "Best of".
    /// - **Singles & EPs** — `trackCount <= 6` (covers the single+B-side and
    ///   standard 4-6 track EP formats).
    /// - **Albums** — everything else.
    ///
    /// "Appears On" would be albums where the artist is credited at the
    /// track level but not as the album-artist. We don't have that join in
    /// the core yet, so the section is surfaced only when we can build it.
    /// Tracked in TODO(core-#60) along with real `AlbumType` support.
    ///
    /// Empty sections collapse silently. Each section sorts by year
    /// descending and renders a horizontal carousel of 160pt album tiles.
    @ViewBuilder
    private var discographySection: some View {
        let groups = discographyGroups()
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                sectionHeader(eyebrow: "DISCOGRAPHY", title: "Releases")
                    .padding(.bottom, -12)
                ForEach(groups, id: \.title) { group in
                    discographyGroup(group)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
        }
    }

    @ViewBuilder
    private func discographyGroup(_ group: DiscographyGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(Theme.font(18, weight: .bold))
                .foregroundStyle(Theme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(group.albums, id: \.id) { album in
                        ArtistDiscographyTile(album: album)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Build the grouped discography. Groups are returned in display order;
    /// empty groups are dropped so the section doesn't render placeholder
    /// headings.
    ///
    /// TODO(core-#60): swap the name/track-count heuristic for a real
    /// `AlbumType` field once the core exposes it from Jellyfin's
    /// `Album.AlbumType` (MusicBrainz plugin populates this; otherwise we
    /// keep the heuristic as a reasonable fallback).
    /// TODO(core-#60): add an "Appears On" group once the core can tell us
    /// which albums credit this artist only at the track level. Needs either
    /// an `album_artist_id` vs `track_artist_ids` split on the `Album` record
    /// or a dedicated `artist_appearances` query.
    private func discographyGroups() -> [DiscographyGroup] {
        var singles: [Album] = []
        var compilations: [Album] = []
        var live: [Album] = []
        var albums: [Album] = []

        for album in artistAlbums {
            let classification = classify(album)
            switch classification {
            case .live: live.append(album)
            case .compilation: compilations.append(album)
            case .singleOrEP: singles.append(album)
            case .album: albums.append(album)
            }
        }

        let sortByYearDesc: (Album, Album) -> Bool = { lhs, rhs in
            (lhs.year ?? 0) > (rhs.year ?? 0)
        }

        let all: [DiscographyGroup] = [
            DiscographyGroup(title: "Albums", albums: albums.sorted(by: sortByYearDesc)),
            DiscographyGroup(title: "Singles & EPs", albums: singles.sorted(by: sortByYearDesc)),
            DiscographyGroup(title: "Compilations", albums: compilations.sorted(by: sortByYearDesc)),
            DiscographyGroup(title: "Live", albums: live.sorted(by: sortByYearDesc)),
        ]
        return all.filter { !$0.albums.isEmpty }
    }

    private enum AlbumClassification {
        case album
        case singleOrEP
        case compilation
        case live
    }

    /// Heuristic classifier. See `discographyGroups` doc for why we're
    /// name-matching today. Tests (if we grow them) should cover:
    /// "Live at ...", "Greatest Hits", 2-track single, 4-track EP, and a
    /// standard 10-track LP.
    private func classify(_ album: Album) -> AlbumClassification {
        let name = album.name.lowercased()
        if name.contains("live at")
            || name.contains("live in")
            || name.contains("(live)")
            || name.hasSuffix(" live")
        {
            return .live
        }
        if name.contains("greatest hits")
            || name.contains("compilation")
            || name.contains("anthology")
            || name.contains("best of")
            || name.contains("collection")
        {
            return .compilation
        }
        if album.trackCount > 0, album.trackCount <= 6 {
            return .singleOrEP
        }
        return .album
    }

    private struct DiscographyGroup {
        let title: String
        let albums: [Album]
    }

    // MARK: - Similar Artists (#232)

    /// Horizontal carousel of 140pt circular artist tiles, mirroring
    /// `ArtistRadioTile`'s shape but with the real-artist nav action.
    /// Hidden when the server returns no similar artists so the section
    /// doesn't read as a bug. Data comes from `similarArtistsState`.
    @ViewBuilder
    private var similarArtistsSection: some View {
        let similar = similarArtists
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(eyebrow: "YOU MIGHT ALSO LIKE", title: "Similar Artists")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(similar, id: \.id) { similarArtist in
                            SimilarArtistTile(artist: similarArtist)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
        }
    }

    /// Similar artists list. Backed by `model.loadSimilarArtists` (which
    /// calls `core.similar_artists` via Jellyfin's `/Artists/{id}/Similar`).
    /// Populated by the `.task(id:)` block; collapses silently when empty.
    /// See #146.
    private var similarArtists: [Artist] {
        similarArtistsState
    }

    // MARK: - About / bio (#231)

    /// Expandable biography block. Jellyfin exposes an artist `Overview`
    /// field via `GET /Items/{id}?Fields=Overview`, but the core doesn't
    /// project it into the `Artist` record today (see TODO below). Until
    /// that lands we show a graceful fallback that leans on genres, which
    /// we do have — the section stays useful even in the stub state.
    @ViewBuilder
    private var aboutSection: some View {
        if let artist = artist {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(eyebrow: "ABOUT", title: "About \(artist.name)")
                aboutBody(for: artist)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
        }
    }

    /// Three-line clamp with a "Read more" reveal. When there is no bio
    /// text we render a lightweight placeholder that surfaces the genres
    /// and the count fields, so the section isn't dead real estate.
    @ViewBuilder
    private func aboutBody(for artist: Artist) -> some View {
        let overview = artistOverview(for: artist)
        if let overview = overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(overview)
                    .font(Theme.font(14, weight: .regular))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(isBioExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isBioExpanded.toggle() }
                } label: {
                    Text(isBioExpanded ? "Show less" : "Read more")
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                // Provider credit — only surfaced when we know the source.
                // Plugged in alongside the real overview feed (see TODO).
                Text("via Jellyfin")
                    .font(Theme.font(10, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .tracking(1)
            }
        } else {
            aboutFallback(for: artist)
        }
    }

    /// Placeholder rendered when the artist has no overview. Surfaces
    /// what we DO have (genres, catalog depth) so the section remains useful.
    @ViewBuilder
    private func aboutFallback(for artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !artist.genres.isEmpty {
                HStack(spacing: 8) {
                    ForEach(artist.genres, id: \.self) { genre in
                        Text(genre.uppercased())
                            .font(Theme.font(10, weight: .bold))
                            .foregroundStyle(Theme.ink2)
                            .tracking(1.5)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(Theme.surface)
                            )
                            .overlay(
                                Capsule().stroke(Theme.border, lineWidth: 1)
                            )
                    }
                }
            }
            Text(aboutFallbackText(for: artist))
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func aboutFallbackText(for artist: Artist) -> String {
        var parts: [String] = ["No bio yet for \(artist.name)."]
        if artistAlbums.count > 0 {
            let albumWord = artistAlbums.count == 1 ? "album" : "albums"
            parts.append("\(artistAlbums.count) \(albumWord) in your library.")
        }
        if artist.songCount > 0 {
            let trackWord = artist.songCount == 1 ? "track" : "tracks"
            parts.append("\(artist.songCount) \(trackWord) catalogued.")
        }
        return parts.joined(separator: " ")
    }

    /// Artist overview / biography. Returns `nil` until the core exposes
    /// the `Overview` field on the `Artist` record.
    ///
    /// TODO(core-#231): add `overview` to the `Artist` uniffi record (sourced
    /// from Jellyfin's `Item.Overview` with `Fields=Overview`), plus the
    /// related `born` / `origin` / `active_years` fields for the secondary
    /// line the design calls for. Until then this returns `nil` and the
    /// fallback block in `aboutBody` renders.
    private func artistOverview(for _: Artist) -> String? {
        // TODO(core-#231): return artist.overview once the field lands.
        nil
    }

    // MARK: - Section shell helpers

    @ViewBuilder
    private func sectionHeader(eyebrow: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.accent)
                .tracking(3)
            Text(title)
                .font(Theme.font(24, weight: .heavy))
                .foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder
    private func emptySection(icon: String, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink3)
            Text(message)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
            Spacer()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let artist = artist {
            Text("\(artist.name) · \(artistAlbums.count) \(artistAlbums.count == 1 ? "album" : "albums") in your library")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 32)
                .padding(.vertical, 32)
        }
    }
}

// MARK: - Discography tile

/// Compact 160pt square album tile used inside the artist discography
/// carousels. Keeps this view self-contained (the library's `AlbumCard` is
/// fixed at 180pt with a different subline shape) and tuned for dense,
/// year-first presentation.
private struct ArtistDiscographyTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    @State private var isHovering = false

    var body: some View {
        Button {
            model.navPath.append(AppModel.Route.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 400),
                        seed: album.name,
                        size: 160,
                        radius: 6
                    )
                    .frame(width: 160, height: 160)

                    Button { model.play(album: album) } label: {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 14))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.primary))
                            .shadow(color: Theme.primary.opacity(0.5), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
                    .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                    .accessibilityLabel("Play \(album.name)")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(Theme.font(12, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(yearLine)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
                .frame(width: 160, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { AlbumContextMenu(album: album) }
        .accessibilityLabel("\(album.name), \(yearLine)")
        .accessibilityHint("Opens album detail")
    }

    /// Year · track-count subline. Jellyfin's album records reliably carry
    /// a track count; year is best-effort (some albums ship without it), so
    /// we fall back to just the track count in that case.
    private var yearLine: String {
        let tracks = album.trackCount == 1 ? "1 track" : "\(album.trackCount) tracks"
        if let year = album.year, year > 0 {
            return "\(year) · \(tracks)"
        }
        return tracks
    }
}

// MARK: - Similar artist tile

/// 140pt circular artist tile used in the Similar Artists row. Tapping
/// navigates to the artist detail page for the similar artist. Mirrors the
/// visual shape of `ArtistRadioTile` but the action is "open detail", not
/// "start radio", and the subline is the genre rather than the word "Radio".
///
/// Wired as of #146 — `ArtistDetailView.similarArtistsState` is now populated
/// by `model.loadSimilarArtists(artistId:)` in the `.task(id:)` block.
private struct SimilarArtistTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artist: Artist
    var size: CGFloat = 140

    @State private var isHovering = false

    var body: some View {
        Button {
            model.navigate(to: .artist(artist.id))
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Artwork(
                        url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 400),
                        seed: artist.name,
                        size: size,
                        radius: size / 2
                    )
                    .frame(width: size, height: size)
                }
                .overlay(
                    Circle()
                        .stroke(
                            isHovering ? Theme.accent : Theme.border,
                            lineWidth: isHovering ? 2 : 1
                        )
                )
                .shadow(
                    color: isHovering ? Theme.accent.opacity(0.35) : .clear,
                    radius: 12
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)

                VStack(spacing: 2) {
                    Text(artist.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(artist.genres.first ?? "Artist")
                        .font(Theme.font(11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(0.5)
                        .lineLimit(1)
                }
                .frame(width: size)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { ArtistContextMenu(artist: artist) }
        .accessibilityLabel("\(artist.name), similar artist")
        .accessibilityHint("Opens artist detail")
    }
}
