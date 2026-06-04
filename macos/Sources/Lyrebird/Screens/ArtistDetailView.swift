import os
import SwiftUI
@preconcurrency import LyrebirdCore

/// Full-surface Artist detail screen. Landed as part of BATCH-04 — closes
/// #58, #60, #227, #228, #231, #232.
///
/// Layout (top-to-bottom):
/// 1. **Hero band** (360pt) — blurred backdrop art, 200pt circular portrait,
///    eyebrow "ARTIST", 72pt italic-black title, genre line, stats strip.
/// 2. **Transport row** — 54pt Play, Shuffle, Follow / Following pill,
///    Artist Radio. Mirrors the album detail transport for
///    consistency. Following an artist favorites the artist entity on the
///    server (Jellyfin has no separate follow primitive) so it can seed a
///    future "New from artists you follow" home section.
/// 3. **Top Songs** — built on `TopTrackRow` from PR #512 (#229). The rank /
///    artwork / play-count UI is already tuned there; we just render the
///    section around it.
/// 4. **Discography** — split by release type (Albums, Singles & EPs,
///    Compilations, Live, Appears On). Because the core doesn't surface
///    `AlbumType` yet, we lean on a name/track-count heuristic; sections
///    with zero matches collapse silently.
/// 5. **Similar Artists** — stubbed row (data dependency tracked below).
/// 6. **About / bio** — biography from the artist `Overview`, HTML-stripped,
///    clamped to 4 lines with a keyboard-accessible "Read more" popover.
///    Hidden entirely when the artist has no overview.
///
/// Data stubs that remain TODO pending core work:
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
    /// Playlists whose track list features this artist. Populated by
    /// the `.task(id:)` block; the rail collapses silently when empty.
    @State private var featuringPlaylists: [Playlist] = []
    /// Plain-text biography, HTML-stripped from `ArtistDetail.overview`.
    /// `nil` until the detail fetch resolves; empty/whitespace-only overviews
    /// collapse to `nil` so the About section hides entirely.
    @State private var bioOverview: String?

    /// Pre-resolved discography artwork URLs, keyed by album id. Populated
    /// off the main thread in the `.task` block (see `model.resolveImageURLs`)
    /// so the eager discography `HStack` hands each tile a ready URL instead of
    /// taking the Rust `Inner` mutex on the MainActor inside every tile body
    /// (gap pattern #2). A missing key means "not resolved yet"; the tile
    /// shows its gradient placeholder until the warm pass lands.
    @State private var discographyArtwork: [String: URL] = [:]

    /// Scoped (⌘F) search query that filters the Top Songs list in-place.
    /// Cleared on navigation away and on artist change so it never bleeds
    /// across pages.
    @State private var scopedQuery: String = ""
    @FocusState private var scopedSearchFocused: Bool

    /// Top Songs filtered by `scopedQuery` (case/diacritic-insensitive over
    /// title + album name). Empty query shows the full list.
    private var filteredTopTracks: [Track] {
        Self.filterTopTracks(topTracks, query: scopedQuery)
    }

    /// Pure filtering predicate behind `filteredTopTracks`, factored out so it
    /// can be unit-tested without instantiating the view. Trims the query;
    /// an empty/whitespace-only query returns the list unchanged. Matches
    /// case/diacritic-insensitively over track title + album name.
    static func filterTopTracks(_ tracks: [Track], query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tracks }
        return tracks.filter { track in
            track.name.localizedCaseInsensitiveContains(q)
                || (track.albumName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Help-tooltip text for the primary play button. The button plays the
    /// loaded Top Songs when there is play history, and only falls back to the
    /// full catalog when there is none — so the label must reflect which of the
    /// two it will actually do, rather than always promising "all tracks".
    /// Factored out (with `primaryPlayAccessibilityLabel`) so the label/behavior
    /// contract is unit-testable without instantiating the view.
    static func primaryPlayHelp(hasTopTracks: Bool) -> String {
        hasTopTracks ? "Play top songs" : "Play all tracks"
    }

    /// VoiceOver label for the primary play button. Mirrors `primaryPlayHelp`
    /// but names the artist, matching the resting album-detail transport voice.
    static func primaryPlayAccessibilityLabel(hasTopTracks: Bool, artistName: String) -> String {
        hasTopTracks
            ? "Play top songs by \(artistName)"
            : "Play all tracks by \(artistName)"
    }

    /// Resolve the artist: cached library page first, then whichever
    /// record the `.task` block fetched on demand. Missing (server
    /// unreachable or truly deleted) falls through to the gentle
    /// "Artist not found" placeholder below.
    private var artist: Artist? {
        model.artists.first { $0.id == artistID } ?? fetchedArtist
    }

    var body: some View {
        // Resolve the artist exactly once per render. `artist` is an O(n) scan
        // over `model.artists` (potentially thousands of entries), and `body`
        // invalidates on every keystroke in the scoped filter — so resolving
        // it per sub-view would run the scan five-plus times per keystroke.
        // One `let` here, threaded into each section, collapses that to one
        // scan per render.
        let artist = self.artist
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(artist)
                transportBar(artist)
                topSongsSection
                discographySection
                featuringPlaylistsSection(artist)
                similarArtistsSection
                aboutSection(artist)
                footer(artist)
            }
        }
        .background(Theme.bg)
        // ⌘F → AppModel.requestFind() addresses a focus request to a specific
        // route. Only pull focus when the request targets *this* artist so a
        // page stacked under us in the back-stack never steals focus.
        .onChange(of: model.scopedSearchFocusRequest) { _, _ in
            if model.consumeScopedSearchFocus(for: .artist(artistID)) {
                scopedSearchFocused = true
            }
        }
        // Clear the scoped query on navigation away so it never persists into
        // the next page.
        .onDisappear { scopedQuery = "" }
        .task(id: artistID) {
            Log.app.info("ArtistDetailView.task fire artist=\(artistID, privacy: .public)")
            // Reset per-artist state so a prior artist's bio / expanded popover
            // never bleeds into this page while the new fetch is in flight.
            bioOverview = nil
            isBioExpanded = false
            scopedQuery = ""
            featuringPlaylists = []
            discographyArtwork = [:]
            isLoadingTopTracks = true
            if model.artists.first(where: { $0.id == artistID }) == nil {
                fetchedArtist = await model.resolveArtist(id: artistID)
            }
            // Server-scoped fetch via `AlbumArtistIds`. The prior
            // `model.albums.filter { ... }` only looked at the cached
            // first page of 100 library-wide albums, so Discography
            // rendered empty for most artists on a large library.
            artistAlbums = await model.loadArtistAlbums(artistId: artistID)
            // Warm the discography artwork URLs off the main thread before the
            // eager tiles render, so the per-tile `imageURL` calls are pure
            // cache hits instead of ~200 serialized mutex-guarded FFI calls on
            // the MainActor (gap pattern #2). Each tile gets a pre-resolved URL.
            let resolved = await model.resolveImageURLs(
                for: artistAlbums.map { (id: $0.id, tag: $0.imageTag) },
                maxWidth: 400
            )
            discographyArtwork = resolved.reduce(into: [:]) { acc, pair in
                if let url = pair.value { acc[pair.key] = url }
            }
            topTracks = await model.loadArtistTopTracks(artistId: artistID)
            isLoadingTopTracks = false
            similarArtistsState = await model.loadSimilarArtists(artistId: artistID)
            featuringPlaylists = await model.loadPlaylistsFeaturingArtist(artistId: artistID)
            // Biography is independent of the lists above so a missing or slow
            // detail fetch never blocks the rest of the page. The server
            // overview may carry HTML, so it is stripped to plain text before
            // storing; whitespace-only collapses to nil so the section hides.
            if let detail = await model.artistDetail(artistId: artistID) {
                bioOverview = Self.plainTextOverview(detail.overview)
            }
            Log.app.info("ArtistDetailView.task done artist=\(artistID, privacy: .public) albums=\(artistAlbums.count, privacy: .public) topTracks=\(topTracks.count, privacy: .public) similar=\(similarArtistsState.count, privacy: .public) bio=\(bioOverview != nil, privacy: .public)")
        }
    }

    // MARK: - Hero (#58, #227)

    /// 360pt hero band. Layout per `06-screen-specs.md §4`: blurred full-width
    /// backdrop at 0.35 opacity, 200pt circular portrait on the left, type
    /// block on the right, stats strip pinned at the bottom. When the artist
    /// has no image we fall back to a deterministic gradient placeholder and
    /// `person.circle.fill` so the band doesn't read as broken.
    @ViewBuilder
    private func hero(_ artist: Artist?) -> some View {
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

    /// Play / Shuffle / Follow / Radio row. Matches the album detail transport
    /// so the two detail screens share a transport mental model. Most actions
    /// delegate to stubs on `AppModel` pending core work — the UI is live, the
    /// wiring lights up when each FFI lands.
    @ViewBuilder
    private func transportBar(_ artist: Artist?) -> some View {
        if let artist = artist {
            HStack(spacing: 14) {
                Button {
                    // Primary CTA. With play history we play the loaded Top
                    // Songs; the rank/queue UI is already built around that
                    // list. Only when there's no play history do we fall
                    // through to `playAll(artist:)` (the full catalog). The
                    // button is labeled to match this — "Play top songs" — so
                    // it doesn't promise a full-catalog play it rarely does.
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
                .help(Self.primaryPlayHelp(hasTopTracks: !topTracks.isEmpty))
                .accessibilityLabel(
                    Self.primaryPlayAccessibilityLabel(
                        hasTopTracks: !topTracks.isEmpty,
                        artistName: artist.name
                    )
                )

                if model.supportsArtistPlayShuffle {
                    transportSecondary(
                        icon: "shuffle",
                        help: "Shuffle all"
                    ) { model.shuffle(artist: artist) }
                }

                followButton(for: artist)

                // Artist radio = Instant Mix seeded by this artist. The core
                // exposes a single polymorphic `instantMix` primitive, so a
                // separate "Instant Mix" button would call the exact same path
                // — one button, one honest affordance, rather than two
                // identically-behaving controls under different labels.
                transportSecondary(
                    icon: "dot.radiowaves.left.and.right",
                    help: "Start artist radio"
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

    /// Labeled Follow / Following pill. The filled accent state reads
    /// "Following" so it's legible at a glance the way Apple Music / Spotify
    /// follow buttons are; the resting state is an outlined "Follow".
    @ViewBuilder
    private func followButton(for artist: Artist) -> some View {
        let following = model.isFollowing(artist: artist)
        Button {
            model.toggleFollow(artist: artist)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: following ? "person.fill.checkmark" : "person.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                Text(following ? "Following" : "Follow")
                    .font(Theme.font(13, weight: .semibold))
            }
            .foregroundStyle(following ? .white : Theme.ink2)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                Capsule().fill(following ? Theme.accent : Theme.surface)
            )
            .overlay(
                Capsule().stroke(following ? Color.clear : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(following ? "Unfollow \(artist.name)" : "Follow \(artist.name)")
        .accessibilityLabel(following ? "Following \(artist.name)" : "Follow \(artist.name)")
        .accessibilityAddTraits(following ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Top Songs (#229; PR #512)

    /// Calls through to `TopTrackRow` from PR #512 — we're the new layout
    /// shell, not a reimplementation of the top-tracks row UI.
    @ViewBuilder
    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                sectionHeader(eyebrow: "MOST PLAYED", title: "Top Songs")
                Spacer()
                // Scoped ⌘F filter. Only meaningful once there's a list
                // to narrow, so it appears with the loaded Top Songs.
                if !topTracks.isEmpty {
                    ScopedSearchBar(
                        query: $scopedQuery,
                        isFocused: $scopedSearchFocused,
                        placeholder: "Filter songs"
                    )
                }
            }
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
                } else if filteredTopTracks.isEmpty {
                    emptySection(
                        icon: "magnifyingglass",
                        message: "No songs match \u{201C}\(scopedQuery)\u{201D}."
                    )
                } else {
                    // rc9: drop the `Array(topTracks.enumerated())` wrapper.
                    // The wrapped sequence allocates fresh `(Int, Track)`
                    // tuples each render and `id: \.element.id` was the only
                    // identity hint SwiftUI had; the indirection appears to
                    // confuse macOS 26.4's layout-cache invalidation. Direct
                    // `ForEach(filteredTopTracks, id: \.id)` gives SwiftUI a
                    // stable identity rooted in the persistent `Track.id`.
                    // Rank + queue stay rooted in the full `topTracks` list so
                    // the rank badge and play-queue match the unfiltered order.
                    ForEach(filteredTopTracks, id: \.id) { track in
                        let rank = (topTracks.firstIndex(where: { $0.id == track.id }) ?? 0) + 1
                        TopTrackRow(track: track, rank: rank, queue: topTracks)
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
                // rc9: regular `HStack` instead of `LazyHStack`. macOS 26.4 +
                // Apple Silicon SwiftUI 7.4.27 has a use-after-free in
                // `_ArrayBuffer._consumeAndCreateNew` when a `LazyHStack`
                // inside a `ScrollView(.horizontal)` reuses children across
                // navigation — confirmed by two consecutive crashes
                // (rc7 OOM + rc8 SIGSEGV) both inside `HVStack.updateCache`
                // during ArtistDetailView render. Each discography group
                // here holds at most ~50 tiles (loadArtistAlbums limit / 4
                // groups), so the eager `HStack` is plenty cheap and avoids
                // the lazy-recycle buffer churn that triggers the UAF.
                HStack(alignment: .top, spacing: 16) {
                    ForEach(group.albums, id: \.id) { album in
                        // Hand the tile its artwork URL pre-resolved off the
                        // main thread (see `.task` → `resolveImageURLs`) so the
                        // eager HStack never calls the sync `imageURL` FFI on
                        // the MainActor inside a tile body. `nil` until the warm
                        // pass lands; the tile shows its placeholder meanwhile.
                        ArtistDiscographyTile(
                            album: album,
                            artworkURL: discographyArtwork[album.id]
                        )
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

    // MARK: - Playlists featuring artist

    /// Horizontal carousel of playlists whose track list features this
    /// artist. Mirrors the discography carousel's shape with 160pt playlist
    /// tiles. Hidden entirely when the artist appears in no playlists so the
    /// section never reads as a broken empty shelf. Data comes from
    /// `featuringPlaylists`, populated by the `.task(id:)` block.
    @ViewBuilder
    private func featuringPlaylistsSection(_ artist: Artist?) -> some View {
        if !featuringPlaylists.isEmpty, let artist = artist {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(eyebrow: "APPEARS ON", title: "Featuring \(artist.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    // Eager `HStack` (not `LazyHStack`) for the same macOS 26.4
                    // recycle-UAF reason documented in `discographyGroup`. The
                    // rail is capped at six tiles, so eager rendering is free.
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(featuringPlaylists, id: \.id) { playlist in
                            FeaturingPlaylistTile(playlist: playlist)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
        }
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
                    // rc9: regular `HStack` instead of `LazyHStack`. See the
                    // matching note in `discographyGroup` — same UAF surface,
                    // same fix. `loadSimilarArtists(limit: 12)` caps the row
                    // at twelve tiles, so eager rendering is essentially free.
                    HStack(alignment: .top, spacing: 18) {
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

    // MARK: - About / bio

    /// Biography block. The bio text comes from Jellyfin's artist `Overview`
    /// field (`GET /Items/{id}?Fields=Overview`, populated by metadata
    /// plugins), fetched via `model.artistDetail` and HTML-stripped into
    /// `bioOverview` by the `.task` block.
    ///
    /// The section is hidden entirely when the overview is empty — no
    /// "no bio yet" placeholder — so an artist with no metadata simply
    /// doesn't grow a dead About region. Genres already surface in the hero
    /// and catalog depth in the footer, so nothing useful is lost.
    @ViewBuilder
    private func aboutSection(_ artist: Artist?) -> some View {
        if let artist = artist, let overview = bioOverview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(eyebrow: "ABOUT", title: "About \(artist.name)")
                aboutBody(overview: overview, artistName: artist.name)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
        }
    }

    /// Four-line clamp on the overview with a keyboard-accessible "Read more"
    /// button that opens the full text in a popover. The popover is driven by
    /// a plain SwiftUI `Button` → focusable and Return-activatable for free,
    /// satisfying the "Read more is keyboard accessible" criterion.
    @ViewBuilder
    private func aboutBody(overview: String, artistName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overview)
                .font(Theme.font(14, weight: .regular))
                .foregroundStyle(Theme.ink2)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isBioExpanded = true
            } label: {
                Text("Read more")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read full biography for \(artistName)")
            .accessibilityHint("Opens the complete biography in a popover")
            .popover(isPresented: $isBioExpanded, arrowEdge: .top) {
                bioPopover(overview: overview, artistName: artistName)
            }
        }
    }

    /// Full-biography popover. Scrolls when the text is long so the popover
    /// stays a sane size, and is dismissible with Escape (SwiftUI default) or
    /// the explicit Done button for pointer users.
    @ViewBuilder
    private func bioPopover(overview: String, artistName: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(artistName)
                    .font(Theme.font(18, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 24)
                Button("Done") { isBioExpanded = false }
                    .buttonStyle(.plain)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(overview)
                    .font(Theme.font(14, weight: .regular))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 420)
        .frame(maxHeight: 460)
    }

    /// Reduce a Jellyfin `Overview` to plain text for display. Returns `nil`
    /// for `nil`, empty, or whitespace-only input so the caller can hide the
    /// section.
    ///
    /// A lightweight strip is used rather than an
    /// `NSAttributedString(data:options:)` HTML parse: the latter is
    /// main-thread-only, spins up a WebKit-backed parser per call, and is far
    /// too heavy for a single bio string. Block-level tags become newlines so
    /// paragraph breaks survive; all other tags are dropped; named and numeric
    /// (decimal / hex) character references are decoded.
    static func plainTextOverview(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        var text = raw
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>"] {
            text = text.replacingOccurrences(
                of: tag,
                with: "\n",
                options: .caseInsensitive
            )
        }
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        text = Self.decodingHTMLEntities(text)
        let collapsed = text.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decode the named and numeric HTML character references that Jellyfin
    /// metadata plugins emit. Named entities cover the common five plus the
    /// quote/apostrophe/nbsp variants; numeric references (`&#160;`, `&#x2013;`)
    /// are decoded generically so en/em dashes and non-breaking spaces from
    /// TheAudioDB / MusicBrainz bios render as their characters rather than raw.
    private static func decodingHTMLEntities(_ input: String) -> String {
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": "\u{00A0}",
        ]
        var text = input
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        guard text.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
        else { return text }

        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard let full = Range(match.range, in: text),
                  let hexFlag = Range(match.range(at: 1), in: text),
                  let digits = Range(match.range(at: 2), in: text)
            else { continue }
            let radix = text[hexFlag].isEmpty ? 10 : 16
            guard let code = UInt32(text[digits], radix: radix),
                  let scalar = Unicode.Scalar(code)
            else { continue }
            text.replaceSubrange(full, with: String(scalar))
        }
        return text
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
    private func footer(_ artist: Artist?) -> some View {
        if let artist = artist {
            Text("\(artist.name) · \(CountStrings.label(artistAlbums.count, .albums)) in your library")
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
    /// Artwork URL resolved off the main thread by the parent's `.task` block.
    /// `nil` while the warm pass is in flight — `Artwork` then renders its
    /// deterministic gradient placeholder, never a sync FFI from this body.
    let artworkURL: URL?
    @State private var isHovering = false

    var body: some View {
        Button {
            model.navPath.append(AppModel.Route.album(album.id))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: artworkURL,
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
        let tracks = CountStrings.label(Int(album.trackCount), .tracks)
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

// MARK: - Featuring-playlist tile

/// Compact 160pt square playlist tile used in the "Featuring <artist>" rail
/// on the Artist detail screen. Mirrors `ArtistDiscographyTile`'s shape
/// so the two artist-page carousels read consistently; tapping opens the
/// playlist detail, the hover play button plays the playlist, and the subline
/// is the track count.
private struct FeaturingPlaylistTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playlist: Playlist
    @State private var isHovering = false

    var body: some View {
        Button {
            model.navPath.append(AppModel.Route.playlist(playlist.id))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: playlist.id, tag: playlist.imageTag, maxWidth: 400),
                        seed: playlist.name,
                        size: 160,
                        radius: 6
                    )
                    .frame(width: 160, height: 160)

                    Button { model.play(playlist: playlist) } label: {
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
                    .accessibilityLabel("Play \(playlist.name)")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(Theme.font(12, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
                .frame(width: 160, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        .accessibilityLabel("\(playlist.name), \(subtitle)")
        .accessibilityHint("Opens playlist detail")
    }

    /// "42 tracks" / "1 track" / "Empty" — matches `PlaylistCard`'s subline.
    private var subtitle: String {
        switch playlist.trackCount {
        case 0: return "Empty"
        default: return CountStrings.label(Int(playlist.trackCount), .tracks)
        }
    }
}
