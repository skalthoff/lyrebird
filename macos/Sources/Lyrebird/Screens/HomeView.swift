import SwiftUI
@preconcurrency import LyrebirdCore

/// The Home screen. Per the design brief, Home is a "content river": a
/// greeting block, a 3-column quick-tiles row, and a stack of carousels
/// (Recently Played, Artists You Love, Jump Back In, Your Playlists,
/// Recently Added). See `research/06-screen-specs.md`.
///
/// Shipped content blocks: greeting header (#204), quick-tiles row (#205),
/// Recently Played tiles (#206), Pinned Stations row (#253), Artist Radio
/// row (#254), Jump Back In (#51), Recently Played track rows (#52),
/// Quick Picks (#53), Recently Added (#54), and Favorites (#55). The
/// section stack is deliberately "dumb" — each section reads its own slice
/// off `AppModel` and hides itself when empty, so a new shelf lands with
/// zero coordination from the rest of the view.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutDirection) private var layoutDirection

    /// Locally-persisted list of pinned stations (#253). JSON-encoded into
    /// `@AppStorage` via `PinnedStationsStore` — placeholder until the real
    /// pin infrastructure ships. See `PinnedStationTile.swift`.
    @AppStorage(PinnedStationsStore.defaultsKey) private var pinnedStationsData: Data = Data()

    /// User-chosen section order + hidden set (#56). Two CSV strings the
    /// `CustomizeHomeSheet` edits and `HomeSectionLayout` sorts the shelf stack
    /// by; an empty value is the shipped default order with every shelf shown.
    @AppStorage(HomeLayoutDefaults.sectionOrderKey) private var sectionOrderRaw = ""
    @AppStorage(HomeLayoutDefaults.sectionHiddenKey) private var sectionHiddenRaw = ""

    /// Drives the "Customize Home" sheet.
    @State private var isCustomizing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                // quickTilesRow — hidden for v1.0: uses albums.prefix(3) as a
                // placeholder for "top tracks of the day"; random albums are
                // not meaningful here. Re-enable once the ranked data sources
                // land (#206, #209).
                //
                // Section stack order + visibility is user-customizable (#56):
                // render the catalog through `HomeSectionLayout`, skipping hidden
                // shelves. Each shelf still hides itself when its own data is
                // empty, so this governs order + explicit show/hide only.
                ForEach(visibleSections, id: \.self) { section in
                    sectionView(for: section)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
        .sheet(isPresented: $isCustomizing) {
            CustomizeHomeSheet()
        }
        // Keep the Recently Played carousel fresh as tracks play (#794).
        // `loadHomeData()` only seeds the section on initial library load,
        // so without this hook a user who plays a few songs and returns to
        // Home sees stale entries from a prior session. `.task(id:)` fires
        // once when the view first appears and again on every transition
        // of `currentTrack?.id` (start of playback, skip-next, auto-advance),
        // which is exactly when the server's recently-played list grows.
        .task(id: model.status.currentTrack?.id) {
            await model.refreshRecentlyPlayed()
        }
    }

    // MARK: - Section customization (#56)

    /// The shelves to render, in the user's chosen order, with hidden ones
    /// removed. Reconciled against the live `HomeSection` catalog on every
    /// paint so a shelf added in a future build appears automatically. See
    /// `HomeSectionLayout`.
    private var visibleSections: [HomeSection] {
        HomeSectionLayout.visibleOrder(order: sectionOrderRaw, hidden: sectionHiddenRaw)
    }

    /// Map a catalog entry to its shelf view. Each case is the same shelf the
    /// body used to list inline; the shelves themselves still self-hide when
    /// their data slice is empty.
    @ViewBuilder
    private func sectionView(for section: HomeSection) -> some View {
        switch section {
        case .recentlyPlayed: recentlyPlayedSection
        case .artistsYouLove: artistsYouLoveSection
        case .recentlyDiscoveredArtists: recentlyDiscoveredArtistsSection
        case .jumpBackIn: jumpBackInSection
        case .recentTracks: recentlyPlayedTracksSection
        case .yourPlaylists: yourPlaylistsSection
        case .recentlyAdded: recentlyAddedSection
        case .rediscover: rediscoverSection
        case .quickPicks: quickPicksSection
        case .suggestions: suggestionsSection
        case .favorites: favoritesSection
        case .pinnedStations: pinnedStationsRow
        case .artistRadio: artistRadioRow
        }
    }

    /// Time-of-day aware greeting header with two pill CTAs (#204).
    ///
    /// Layout follows `research/06-screen-specs.md`:
    /// - Eyebrow "IN ROTATION" 12pt `ink2`, letter-spaced.
    /// - Italic 42pt black h1 greeting. Copy branches on the current hour
    ///   and, when a session exists, is personalised with the user's first
    ///   name ("good morning, jane").
    /// - 14pt `ink2` subtitle with the accent-coloured "instant mix" word.
    /// - Right-aligned CTAs: primary "Instant Mix" (ink fill) + ghost
    ///   "Shuffle All" (border-only). On narrow windows the header stacks
    ///   vertically so the CTAs never clip.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                greetingBlock
                Spacer(minLength: 16)
                headerCTAs
                    .padding(.top, 22)
            }
            VStack(alignment: .leading, spacing: 18) {
                greetingBlock
                headerCTAs
            }
        }
    }

    /// Left-hand block: eyebrow, greeting, subtitle. Pulled out of `header`
    /// so the stacked + side-by-side layouts in `ViewThatFits` can share it.
    @ViewBuilder
    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN ROTATION")
                .font(Theme.font(12, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(1.2)
            Text(greetingText)
                .font(Theme.font(42, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            subtitleLine
        }
    }

    /// Subtitle rendered as three Text pieces so the middle "instant mix"
    /// word can be styled in accent italic — per the `06-screen-specs.md`
    /// "inline accent italicized link" pattern. Concatenating `Text` values
    /// preserves each run's styling while keeping the whole line wrappable.
    private var subtitleLine: some View {
        (
            Text("Pick up where you left off, or start an ")
                + Text("instant mix")
                    .font(Theme.font(14, weight: .semibold, italic: true))
                    .foregroundColor(Theme.accent)
                + Text(" seeded from your library.")
        )
        .font(Theme.font(14, weight: .medium))
        .foregroundStyle(Theme.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Pick up where you left off, or start an instant mix seeded from your library.")
    }

    /// Right-hand action cluster: primary "Instant Mix" + ghost "Shuffle All".
    /// Shuffle All dims + disables while the library hasn't loaded; Instant
    /// Mix always remains tappable since it routes through a stub landing pad
    /// regardless of library state (see `AppModel.startInstantMix`).
    @ViewBuilder
    private var headerCTAs: some View {
        HStack(spacing: 10) {
            Button {
                model.startInstantMix()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                    Text("Instant Mix")
                        .font(Theme.font(13, weight: .bold))
                }
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.ink))
                .shadow(color: Theme.ink.opacity(0.18), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start Instant Mix")
            .accessibilityHint("Generates a personalised mix seeded from your library")

            Button {
                model.shuffleLibrary()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .bold))
                    Text("Shuffle All")
                        .font(Theme.font(13, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule().stroke(Theme.borderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(model.albums.isEmpty)
            .opacity(model.albums.isEmpty ? 0.5 : 1)
            .accessibilityLabel("Shuffle your entire library")

            // "Customize Home" entry point (#56). Compact icon-only ghost
            // button so it sits beside the two primary CTAs without competing
            // with them; opens the reorder / show-hide sheet.
            Button {
                isCustomizing = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 13)
                    .background(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Customize Home — reorder, show, or hide sections")
            .accessibilityLabel("Customize Home")
        }
    }

    /// Produces the time-branched greeting per `06-screen-specs.md`:
    /// `<5h → "still up?"`, `<12 → "good morning"`, `<18 → "good afternoon"`,
    /// else `"good evening"`. Appends the first name when a session is in
    /// place, so logged-out previews still render nicely.
    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        switch hour {
        case 0..<5: base = "still up?"
        case 5..<12: base = "good morning"
        case 12..<18: base = "good afternoon"
        default: base = "good evening"
        }
        guard let first = firstName(from: model.session?.user.name), !first.isEmpty else {
            return base
        }
        // "still up?" keeps its terminal punctuation — tucking a name in
        // after the question mark reads awkwardly, so skip personalisation.
        if base.hasSuffix("?") { return base }
        return "\(base), \(first.lowercased())"
    }

    /// Split the Jellyfin display name on whitespace and return the first
    /// non-empty segment. Returns `nil` for empty / whitespace-only input so
    /// `greetingText` can fall back to the un-personalised copy.
    private func firstName(from displayName: String?) -> String? {
        guard let displayName else { return nil }
        let first = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }

    /// 3-column quick tiles row. Per the brief the content should rank
    /// `recently_played` / `most_played` with a fallback to pinned playlists;
    /// none of those FFI paths exist yet (see #206 for recently_played,
    /// #209 for user_playlists). Until they land we use the first three
    /// albums in the library as a best-effort stand-in.
    private var quickTilesRow: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            alignment: .leading,
            spacing: 10
        ) {
            // TODO: #206 / #209 — replace `albums.prefix(3)` with the top 3 of
            // `core.recently_played(last_7d)` or `core.most_played(last_7d)`
            // (whichever yields more distinct items), falling back to the
            // first 3 pinned playlists.
            ForEach(Array(tileAlbums.enumerated()), id: \.element.id) { _, album in
                HomeQuickTile(
                    title: album.name,
                    subtitle: album.artistName,
                    artworkURL: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 96),
                    seed: album.name,
                    action: { model.navPath.append(AppModel.Route.album(album.id)) },
                    onPlay: { model.play(album: album) }
                )
            }
            // Pad out to exactly three slots so the row layout stays stable
            // before the library has finished loading.
            ForEach(0..<placeholderCount, id: \.self) { _ in
                HomeQuickTilePlaceholder()
            }
        }
    }

    /// Horizontal row of circular "<Artist> Radio" tiles. Source of artists
    /// is picked by `radioArtists`, which today falls back to the first few
    /// library artists — the favorites/top-listened signals (#133, #229)
    /// aren't wired yet, and this view swaps to them seamlessly once they are.
    @ViewBuilder
    private var artistRadioRow: some View {
        if !radioArtists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 14, weight: .bold))
                    Text("Artist Radio")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Tap to start a radio station")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(radioArtists, id: \.id) { artist in
                            ArtistRadioTile(artist: artist)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Pinned Stations row (#253). A user-curated shelf of station "presets".
    /// Today the only pin source is the genre Pin button / context menu
    /// (`AppModel.pinGenreToHome`), which persists into `PinnedStationsStore`;
    /// this row is its reader, so a pinned genre shows up here one click away.
    /// Like every other Home shelf it hides itself when empty (no pins yet)
    /// rather than render a permanent empty band — the user pins from a genre
    /// page, so there is no in-row "add" affordance to show.
    @ViewBuilder
    private var pinnedStationsRow: some View {
        if !pinnedStations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(Theme.primary)
                        .font(.system(size: 14, weight: .bold))
                        .rotationEffect(.degrees(-15))
                    Text("Pinned Stations")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Your radio presets — always one click away")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(pinnedStations) { station in
                            PinnedStationTile(
                                station: station,
                                subtitle: pinnedStationSubtitle(for: station),
                                action: { handleStationTap(station) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Decoded view over `pinnedStationsData`. The `@AppStorage` backing is a
    /// single `Data` blob (JSON), decoded every render — the lists are tiny
    /// and this avoids a separate observable object just for placeholder data.
    private var pinnedStations: [PinnedStation] {
        guard !pinnedStationsData.isEmpty else { return [] }
        return (try? JSONDecoder().decode([PinnedStation].self, from: pinnedStationsData)) ?? []
    }

    /// Placeholder subtitle — we don't yet have a real "track count / updated"
    /// signal for user-curated stations. Once the pin model exposes those
    /// fields we swap this for the live string; the tile already accepts any
    /// string. See `06-screen-specs.md §9`.
    private func pinnedStationSubtitle(for station: PinnedStation) -> String {
        // TODO: #253 follow-up — replace with live "N tracks · updated X" once
        // the pin model carries those fields.
        switch station.type {
        case .artist: return "Artist radio · updated today"
        case .playlist: return "Playlist · always fresh"
        case .mood: return "Mood station · updated today"
        case .genre: return "Genre station · updated today"
        case .mix: return "Auto mix · updated today"
        }
    }

    /// Handler for a tapped pinned station. Dispatches on `station.type` to
    /// the same destinations the rest of the app uses for each kind, so a
    /// pinned tile behaves exactly like opening that subject elsewhere.
    private func handleStationTap(_ station: PinnedStation) {
        switch station.type {
        case .genre:
            // The pinned station's id IS the genre display name (Wave 1
            // stored it that way because the Swift Genre struct's id == name).
            // Construct a name-only Genre and let browseGenre resolve the
            // real Jellyfin UUID via the /MusicGenres cache before pushing.
            model.browseGenre(genre: Genre(name: station.title))
        case .playlist:
            // The id is a real Jellyfin playlist UUID — drill into it.
            model.navigate(to: .playlist(station.id))
        case .artist, .mood, .mix:
            // Start a radio seeded from the station's subject. Artist radio,
            // mood, and auto-mix all reduce to an Instant Mix off the stored
            // id (an artist UUID or a mood/mix seed).
            model.startStationRadio(seedId: station.id)
        }
    }

    /// The albums surfaced as quick tiles — capped at 3. Pulled from the
    /// currently-loaded library as a placeholder until the ranked data sources
    /// in the TODO above are wired.
    private var tileAlbums: [Album] {
        Array(model.albums.prefix(3))
    }

    /// Number of placeholder tiles needed to fill the 3-column grid while
    /// the library is still loading or empty.
    private var placeholderCount: Int {
        max(0, 3 - tileAlbums.count)
    }

    /// The "Recently Played" carousel (#206). Hidden when the backing data is
    /// still loading or empty so we don't punch a blank hole in the layout.
    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if !model.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Played")
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(model.recentlyPlayed, id: \.id) { track in
                            RecentlyPlayedTile(track: track)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// "Artists You Love" — a circle-card carousel of the artists the user
    /// has favorited (#207). Reuses `ArtistCard` (the same circular tile the
    /// Library Artists grid and Favorites screen render) over the
    /// favorites-driven `model.favoriteArtists` slice, so it never drifts
    /// from the Favorites screen's Artists section. Tapping a card pushes
    /// `Route.artist` via `ArtistCard`'s own button; "See All" jumps to the
    /// Favorites tab. Hidden when the user has no favorited artists so a
    /// fresh library doesn't render an empty shelf.
    ///
    /// `ArtistCard` stretches to `maxWidth: .infinity` (it's built for a
    /// grid cell), so each card is pinned to a fixed width here — otherwise
    /// the cards would collapse inside the horizontal `HStack`. The row is
    /// capped so it stays bounded for power users with hundreds of
    /// favorited artists.
    @ViewBuilder
    private var artistsYouLoveSection: some View {
        if !model.favoriteArtists.isEmpty {
            carouselSection(
                icon: "heart.circle.fill",
                iconColor: Theme.accentHot,
                title: "Artists You Love",
                subtitle: "The artists you've hearted",
                onSeeAll: { model.selectTab(.favorites) }
            ) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.favoriteArtists.prefix(artistsYouLoveLimit), id: \.id) { artist in
                        ArtistCard(artist: artist)
                            .frame(width: 150)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Cap on how many circles the "Artists You Love" row renders. Keeps the
    /// horizontal scroll bounded for users with a large favorites set; the
    /// "See All" button routes to the full Favorites screen for the rest.
    private var artistsYouLoveLimit: Int { 18 }

    /// "Recently Discovered Artists" — a circle-card carousel of the album
    /// artists whose catalogue most recently landed on the library (#252).
    /// Reads `model.recentlyDiscoveredArtists`, which the core sorts by
    /// `DateCreated` descending (newest arrivals first) via the
    /// `listRecentlyAddedArtists` FFI. Reuses `ArtistCard` — the same circular
    /// tile the Library Artists grid, Favorites screen, and "Artists You Love"
    /// row render — so the visual language stays consistent and tapping a card
    /// pushes `Route.artist` through `ArtistCard`'s own button. "See All"
    /// jumps to the Library tab's Artists list. Hidden when the slice is empty
    /// so a fresh or static library renders no shelf rather than a blank band.
    ///
    /// As with "Artists You Love", `ArtistCard` is built for a grid cell and
    /// stretches to `maxWidth: .infinity`, so each card is pinned to a fixed
    /// width here — otherwise the cards would collapse inside the horizontal
    /// `HStack`. The row is capped so it stays bounded.
    @ViewBuilder
    private var recentlyDiscoveredArtistsSection: some View {
        if !model.recentlyDiscoveredArtists.isEmpty {
            carouselSection(
                icon: "person.crop.circle.badge.plus",
                iconColor: Theme.primary,
                title: "Recently Discovered Artists",
                subtitle: "New names that just landed in your library",
                onSeeAll: {
                    model.libraryTab = .artists
                    model.selectTab(.library)
                }
            ) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.recentlyDiscoveredArtists.prefix(recentlyDiscoveredArtistsLimit), id: \.id) { artist in
                        ArtistCard(artist: artist)
                            .frame(width: 150)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Cap on how many circles the "Recently Discovered Artists" row renders.
    /// Keeps the horizontal scroll bounded; the "See All" button routes to the
    /// full Library Artists list for the rest.
    private var recentlyDiscoveredArtistsLimit: Int { 18 }

    /// Pick a short list of artists to surface as radio seeds. Prefer
    /// favorites → top-listened → library order. Favorites and top-listened
    /// aren't wired in the core yet (tracked in #133 and #229), so for now
    /// this falls through to the library's first few artists. Capped at 20
    /// so the horizontal row doesn't grow unbounded once the better signals
    /// are available.
    private var radioArtists: [Artist] {
        // TODO: #133 — surface favorites here once `list_favorite_artists`
        //   lands on the core.
        // TODO: #229 — surface top-listened artists once that endpoint is wired.
        let limit = 20
        return Array(model.artists.prefix(limit))
    }

    // MARK: - New carousels (#51 / #52 / #53 / #54 / #55)

    /// "Jump Back In" — last-played albums (#51). Up to 12 tiles, 180pt
    /// artwork. Hidden until data arrives so a brand-new user isn't left
    /// staring at an empty shelf.
    @ViewBuilder
    private var jumpBackInSection: some View {
        if !model.jumpBackIn.isEmpty {
            carouselSection(
                icon: "arrow.uturn.backward",
                iconColor: Theme.primary,
                title: "Jump Back In",
                subtitle: "Pick up where you left off",
                onSeeAll: { model.selectTab(.library) }
            ) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.jumpBackIn, id: \.id) { album in
                        HomeAlbumTile(album: album)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Track-level "Recent Tracks" (#52) — compact rows with a 48pt
    /// thumbnail. Distinct from the tile-based `recentlyPlayedSection` above:
    /// both read `model.recentlyPlayed`, so this variant carries a different
    /// title/subtitle to avoid two "Recently Played" headers stacked on one
    /// screen. It is denser and prioritises "tap to replay" over "browse art".
    /// Hidden when there's no history.
    ///
    /// Jellyfin tracks `DatePlayed` via its playback-reporting pipeline,
    /// which is always on for the stock server install. If a user has
    /// disabled the playback-report plugin their history will stay empty —
    /// we silently hide this shelf in that case (the Settings-side nudge
    /// is tracked alongside the broader Preferences work).
    @ViewBuilder
    private var recentlyPlayedTracksSection: some View {
        if !model.recentlyPlayed.isEmpty {
            carouselSection(
                icon: "clock.arrow.circlepath",
                iconColor: Theme.accent,
                title: "Recent Tracks",
                subtitle: "Jump back into a recent track",
                onSeeAll: nil
            ) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.recentlyPlayed.prefix(20), id: \.id) { track in
                        RecentlyPlayedTrackRow(track: track)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// "Your Playlists" — a carousel of the user's own playlists. Reads the
    /// already-loaded `model.playlists` slice so the shelf adds no extra
    /// round-trip and never drifts from the Library tab's Playlists chip.
    /// Hidden when there are no playlists so a fresh library doesn't render
    /// an empty shelf.
    @ViewBuilder
    private var yourPlaylistsSection: some View {
        if !model.playlists.isEmpty {
            carouselSection(
                icon: "music.note.list",
                iconColor: Theme.accent,
                title: "Your Playlists",
                subtitle: "Jump back into a playlist you've made",
                onSeeAll: {
                    model.libraryTab = .playlists
                    model.selectTab(.library)
                }
            ) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.playlists.prefix(8), id: \.id) { playlist in
                        PlaylistCard(playlist: playlist)
                            .frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// "Recently Added" — new arrivals in the library (#54). Backed by
    /// `/Users/{id}/Items/Latest`, so the list is sorted by `DateCreated`
    /// server-side. Items added within the last 7 days carry a "NEW"
    /// badge in the tile's top-leading corner.
    @ViewBuilder
    private var recentlyAddedSection: some View {
        if !model.recentlyAdded.isEmpty {
            carouselSection(
                icon: "sparkle",
                iconColor: Theme.primary,
                title: "Recently Added",
                subtitle: "Fresh arrivals in your library",
                onSeeAll: { model.selectTab(.library) }
            ) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.recentlyAdded, id: \.id) { album in
                        HomeAlbumTile(album: album) {
                            if let created = model.recentlyAddedDates[album.id],
                               isWithinLastWeek(created) {
                                NewBadge()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// "Rediscover" — albums the user has never played (#57). Backed by
    /// `model.rediscover`, an `/Items` query filtered to `IsUnplayed` and
    /// sorted `Random`, so the shelf surfaces a fresh handful from the
    /// unplayed corners of the library on each refresh. Hidden when empty
    /// (a fully-played library) so we don't punch a blank hole in the
    /// layout. Reuses `HomeAlbumTile`, the same tile the other album
    /// carousels render.
    @ViewBuilder
    private var rediscoverSection: some View {
        if !model.rediscover.isEmpty {
            carouselSection(
                icon: "binoculars.fill",
                iconColor: Theme.primary,
                title: "Rediscover",
                subtitle: "Albums in your library you haven't played yet",
                onSeeAll: { model.selectTab(.library) }
            ) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.rediscover, id: \.id) { album in
                        HomeAlbumTile(album: album)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// "Quick Picks" — heavy-rotation albums over the last 30 days (#53).
    /// Sorted server-side by `PlayCount` desc; each tile exposes a play
    /// count on hover so the user sees *why* it picked these. Hidden until
    /// the user has accumulated enough plays for the shelf to feel
    /// non-random.
    @ViewBuilder
    private var quickPicksSection: some View {
        if !model.quickPicks.isEmpty {
            carouselSection(
                icon: "flame.fill",
                iconColor: Theme.accent,
                title: "Quick Picks",
                subtitle: "Your heavy rotation — last 30 days",
                onSeeAll: nil
            ) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.quickPicks, id: \.id) { album in
                        HomeAlbumTile(album: album) {
                            if let plays = model.quickPicksPlayCounts[album.id], plays > 0 {
                                PlayCountBadge(plays: plays)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// "You might like" — server-curated discovery tracks (#145). Backed by
    /// `core.suggestions()` which calls Jellyfin's `/Items/Suggestions`
    /// endpoint. Hidden until data arrives so new users don't see an empty
    /// shelf. Rendered as compact track rows (same component as the
    /// Recently Played track list) — tap to play a single track instantly.
    @ViewBuilder
    private var suggestionsSection: some View {
        if !model.suggestions.isEmpty {
            carouselSection(
                icon: "wand.and.sparkles",
                iconColor: Theme.primary,
                title: "You Might Like",
                subtitle: "Picks the server thinks you'll love",
                onSeeAll: nil
            ) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.suggestions, id: \.id) { track in
                        RecentlyPlayedTrackRow(track: track)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// "Favorites" — shuffled random favorite albums, 12 visible (#55).
    /// The header carries a "Shuffle All Favorites" CTA that pulls every
    /// favorite track and starts playback shuffled. The row self-reshuffles
    /// on each cold launch / refresh so it feels alive.
    @ViewBuilder
    private var favoritesSection: some View {
        if model.favoriteAlbumsVisible.isEmpty {
            favoritesEmptyState
        } else {
            VStack(alignment: .leading, spacing: 12) {
                favoritesSectionHeader
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(model.favoriteAlbumsVisible, id: \.id) { album in
                            HomeAlbumTile(album: album)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Favorites header — title + subtitle on the left, a primary
    /// "Shuffle All Favorites" pill + ghost "Reshuffle row" on the right.
    /// Pulled out because it diverges from the simpler `carouselSection`
    /// scaffold (two CTAs instead of one "See All").
    private var favoritesSectionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Theme.accentHot)
                        .font(.system(size: 14, weight: .bold))
                    Text("Favorites")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("A handful of the albums you love")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 12)
                favoritesCTAs
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Theme.accentHot)
                        .font(.system(size: 14, weight: .bold))
                    Text("Favorites")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
                favoritesCTAs
            }
        }
    }

    /// Right-hand CTA cluster for the Favorites header — "Shuffle All
    /// Favorites" (primary accent pill) + "Reshuffle" (ghost) + "See All"
    /// link to the full FavoritesView (#23). Extracted so the narrow and
    /// wide layouts share one source of truth.
    private var favoritesCTAs: some View {
        HStack(spacing: 8) {
            Button("See All") {
                model.selectTab(.favorites)
            }
            .buttonStyle(.plain)
            .font(Theme.font(13, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .help("Open the full Favorites screen")
            .accessibilityLabel("See all favorites")
            Button {
                model.shuffleAllFavorites()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12, weight: .bold))
                    Text("Shuffle All Favorites")
                        .font(Theme.font(12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.accent))
                .shadow(color: Theme.accent.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .help("Play every favorite track, shuffled")
            .accessibilityLabel("Shuffle all favorites")

            Button {
                model.reshuffleFavoriteAlbumsVisible()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                    Text("Reshuffle")
                        .font(Theme.font(12, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Pick a different handful of favorites")
            .accessibilityLabel("Reshuffle the favorites row")
        }
    }

    /// Empty-state card shown when the user hasn't favorited any albums
    /// yet, giving the Home layout a "tap this to fill the shelf" affordance.
    private var favoritesEmptyState: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.surface2)
                    .frame(width: 56, height: 56)
                Image(systemName: "heart.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.accentHot)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("No favorites yet")
                    .font(Theme.font(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Tap the heart on any album or track to start building your favorites row.")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    /// Shared scaffold for the new carousels: icon + title + subtitle on
    /// the left, optional "See All" ghost button on the right, and a
    /// horizontally-scrolling content slot underneath. Keeps the five new
    /// shelves visually consistent without a heavy component.
    ///
    /// `onSeeAll == nil` drops the button — useful for shelves where the
    /// "full version" doesn't have a destination yet.
    @ViewBuilder
    private func carouselSection<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        onSeeAll: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 12)
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        HStack(spacing: 4) {
                            Text("See All")
                                .font(Theme.font(12, weight: .semibold))
                            Image(systemName: layoutDirection == .rightToLeft ? "chevron.left" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().stroke(Theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open \(title) in full")
                    .accessibilityLabel("See all \(title)")
                }
            }
            // Right-click (the Mac-native "long-press on a section header")
            // opens the same Customize Home sheet (#56). `contentShape` makes
            // the whole header row the hit target, not just the glyphs.
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    isCustomizing = true
                } label: {
                    Label("Customize Home…", systemImage: "slider.horizontal.3")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                content()
            }
        }
    }

    /// Returns `true` when the given date is within the last 7 days. Used
    /// by `recentlyAddedSection` to decide whether to stamp the NEW badge
    /// on a given tile.
    private func isWithinLastWeek(_ date: Date) -> Bool {
        let oneWeek: TimeInterval = 7 * 24 * 60 * 60
        return Date().timeIntervalSince(date) < oneWeek
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
}

/// An inert, dimmed version of `HomeQuickTile` used to keep the 3-column
/// grid visually balanced before the library has loaded. Intentionally not
/// interactive — once the real data sources for this row exist (#206 / #209)
/// we should prefer a skeleton shimmer, but that belongs in #212 (Home
/// empty + skeleton states).
private struct HomeQuickTilePlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.surface2)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.surface2)
                    .frame(height: 10)
                    .frame(maxWidth: 120, alignment: .leading)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.surface)
                    .frame(height: 8)
                    .frame(maxWidth: 80, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface.opacity(0.5))
        )
        .accessibilityHidden(true)
    }
}

// `RecentlyPlayedTile` lives in `Components/RecentlyPlayedTile.swift` so it
// can be reused from the Discover "For You" carousel (#249) without
// duplication.

/// "NEW" chip overlaid on `HomeAlbumTile` for items in the Recently Added
/// row that were created within the last 7 days (#54). Small, hot-accent,
/// top-leading — deliberately un-missable without crowding the artwork.
private struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(Theme.font(9, weight: .black))
            .foregroundStyle(.white)
            .tracking(1.2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentHot))
            .shadow(color: Theme.accentHot.opacity(0.5), radius: 4, y: 1)
            .accessibilityLabel("Newly added")
    }
}

/// Subtle "42 plays" chip rendered in the top-leading corner of a
/// `HomeAlbumTile` to explain why the Quick Picks row picked an album
/// (#53). Dimmer than `NewBadge` because it's informational, not a call
/// to action.
private struct PlayCountBadge: View {
    let plays: UInt32
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(playsLabel)
                .font(Theme.font(10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.55)))
        .accessibilityLabel(playsLabel)
    }

    private var playsLabel: String {
        CountStrings.label(Int(plays), .plays)
    }
}
