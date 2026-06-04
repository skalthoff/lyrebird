import SwiftUI
@preconcurrency import LyrebirdCore

/// Full Now Playing view — takes over the detail column when the user
/// opens the "full player" from the `PlayerBar` artwork tap or via the
/// `⌘L` shortcut. Replaces the compact `NowPlayingSheet` used for
/// a quick glance at credits.
///
/// Layout mirrors `design/project/src/panels.jsx`: large album art on the
/// left (~50% width, square with a soft shadow), a segmented picker on
/// the right that toggles between **Queue**, **Lyrics**, **About**, and
/// **Credits**. The screen is a `View`, not a modal, so it slots into
/// `MainShell`'s `mainContent` switch alongside the other top-level
/// surfaces.
///
/// Closes: #89 (full player), #91 (lyrics inline), #272 (queue drawer),
/// #273 (lyrics drawer), #278 (about block), #287 (LRC parser),
/// #288 (auto-scroll).
///
/// The queue inspector (#272) is embedded via `QueueInspector`.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Contrast-adaptive accent for the favorite heart, the "NOW PLAYING"
    // section label, and the empty-state primary button. Lifts to `accentHot`
    // under Increase Contrast so accent text / the prominent button fill clear
    // 4.5:1 (#888).
    @Environment(\.accessibleTheme) private var a11yTheme

    /// Active right-pane tab. Reset to `.queue` when the view appears so
    /// opening the full player always lands on "what's next" rather than
    /// the tab the user was last on — a prior-tab memory would surprise
    /// people returning to Now Playing days later.
    @State private var tab: Tab = .queue
    @State private var resolvedAlbum: Album?

    /// Artwork-derived ambient wash behind the hero (#271). `nil` until the
    /// current cover is sampled (or when sampling fails / there's no art), in
    /// which case `AmbientWash` falls back to the theme gradient. Memoized in
    /// `AppModel`, so re-opening the player on the same album is a cache hit.
    @State private var ambientPalette: AmbientPalette?

    enum Tab: String, CaseIterable, Identifiable {
        case queue = "Queue"
        case lyrics = "Lyrics"
        case about = "About"
        case credits = "Credits"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let track = model.status.currentTrack {
                content(for: track)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Immersive background behind the whole player.
        //
        // Two layers compose here (#271 + #21):
        //   1. `AmbientWash` — opaque `Theme.bg` base + the artwork-derived
        //      palette gradient. This is the fallback surface and is always
        //      present.
        //   2. `NowPlayingBackdrop` — the large, heavily-blurred, dimmed
        //      current cover, layered *over* the wash but *under* the content.
        //      It renders nothing under Reduce Transparency or when there's no
        //      art, so the wash beneath shows through unchanged. Its single dim
        //      scrim is the only darkening over the cover, so the two layers
        //      never double-darken.
        .background {
            ZStack {
                AmbientWash(palette: ambientPalette)
                NowPlayingBackdrop(
                    url: backdropArtworkURL,
                    seed: model.status.currentTrack?.name ?? ""
                )
            }
        }
        // Re-fetch the People array + lyrics on open and on track change.
        // The polling loop in AppModel already handles mid-session
        // transitions; this keeps the open-from-cold path honest too.
        .task(id: model.status.currentTrack?.id) {
            await model.fetchCurrentTrackDetails()
            await model.fetchCurrentTrackLyrics()
        }
        // Sample the ambient palette off the current cover. Keyed on the same
        // identity the hero artwork uses (`albumId ?? id`) so a track change
        // within the same album doesn't re-sample, and so the sample reuses
        // the cover Nuke already decoded for the hero. The work is memoized in
        // AppModel and runs off the main actor, so this never beach-balls.
        .task(id: ambientArtworkKey) {
            guard let track = model.status.currentTrack else {
                ambientPalette = nil
                return
            }
            ambientPalette = await model.ambientPalette(
                forItemId: track.albumId ?? track.id,
                imageTag: track.imageTag
            )
        }
        // Honor a one-shot tab request (#91): the inline lyrics snippet in
        // the Queue Inspector taps `openLyrics()`, which sets
        // `requestedNowPlayingTab`. Consume it here so the view lands on the
        // Lyrics tab, then clear it so a later plain open still defaults to
        // Queue.
        .onAppear { consumeRequestedTab() }
        // Also react while already on-screen: the inline lyrics snippet in
        // the embedded Queue tab can call `openLyrics()` without re-pushing
        // the route, so `.onAppear` wouldn't fire. Watch the request so an
        // in-place tap still switches to the Lyrics tab.
        .onChange(of: model.requestedNowPlayingTab) { _, _ in consumeRequestedTab() }
    }

    /// Apply and clear a one-shot `requestedNowPlayingTab` (#91).
    private func consumeRequestedTab() {
        if let requested = model.requestedNowPlayingTab,
           let resolved = Tab(rawValue: requested) {
            tab = resolved
        }
        model.requestedNowPlayingTab = nil
    }

    /// Stable identity for the ambient-palette `.task` — the album id when the
    /// current track belongs to one, else the track id, mirroring the hero
    /// artwork's own `albumId ?? id` keying. `nil` when nothing is playing so
    /// the task clears the wash. Re-keying only when this string changes means
    /// skipping from track to track inside one album won't re-sample.
    private var ambientArtworkKey: String? {
        guard let track = model.status.currentTrack else { return nil }
        return track.albumId ?? track.id
    }

    /// Size-hinted URL for the blurred-artwork backdrop (#21). Resolves the
    /// same cover the hero shows (`albumId ?? id` identity, matching
    /// `ambientArtworkKey`) so the backdrop reuses the cover Nuke already
    /// decoded — a 1024px hint gives the heavy blur enough source detail
    /// without re-fetching a higher resolution than the screen can use.
    /// `imageURL` is memoized in `AppModel`, so reading this each body pass is
    /// a dictionary hit, not a per-render FFI crossing (gap pattern #2).
    /// `nil` when nothing is playing or the track has no art, in which case
    /// `NowPlayingBackdrop` stays transparent and the ambient wash shows.
    private var backdropArtworkURL: URL? {
        guard let track = model.status.currentTrack else { return nil }
        return model.imageURL(
            for: track.albumId ?? track.id,
            tag: track.imageTag,
            maxWidth: 1024
        )
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(for track: Track) -> some View {
        GeometryReader { geom in
            let isCompact = geom.size.width < 820
            HStack(alignment: .top, spacing: 0) {
                heroPane(for: track, width: isCompact ? nil : geom.size.width * 0.5)
                detailPane(for: track)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Left pane — large artwork + primary metadata. Sized at ~50% of
    /// the container at wide widths, so the art never dwarfs the detail
    /// column on a 13" MBP. Below ~820pt the hero collapses to its
    /// natural width so the right pane retains at least a usable column.
    @ViewBuilder
    private func heroPane(for track: Track, width: CGFloat?) -> some View {
        let artSide = heroArtSide(containerWidth: width)
        VStack(alignment: .leading, spacing: 22) {
            closeButton
            Spacer(minLength: 0)
            Artwork(
                url: model.imageURL(
                    for: track.albumId ?? track.id,
                    tag: track.imageTag,
                    maxWidth: UInt32(max(320, artSide * 2))
                ),
                seed: track.name,
                size: artSide,
                radius: 14,
                decorative: false
            )
            .accessibilityLabel(nowPlayingArtworkLabel(for: track))
            .frame(width: artSide, height: artSide)
            // Trailing alignment so the disc slides out past the art's right
            // edge rather than behind its center; the disc's own `+80pt`
            // x-offset pushes it clear.
            .background(alignment: .trailing) {
                VinylDisc(
                    artSide: artSide,
                    isPlaying: model.status.state == .playing
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(track.name)
                    .font(Theme.font(26, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: {
                    if let artistId = track.artistId {
                        model.navPath.append(AppModel.Route.artist(artistId))
                    }
                }) {
                    Text(track.artistName)
                        .font(Theme.font(15, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(track.artistId == nil)
                .accessibilityHint(track.artistId == nil ? "" : "Open artist page")

                if let album = track.albumName, !album.isEmpty {
                    Button(action: {
                        if let albumId = track.albumId {
                            model.navPath.append(AppModel.Route.album(albumId))
                        }
                    }) {
                        Text(album)
                            .font(Theme.font(12, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(track.albumId == nil)
                    .accessibilityHint(track.albumId == nil ? "" : "Open album page")
                }

                let isFav = model.isFavorite(track: track)
                Button {
                    model.toggleFavorite(track: track)
                } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isFav ? a11yTheme.accent : Theme.ink2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .help(isFav ? "Unfavorite" : "Favorite")
                .accessibilityLabel(isFav ? "Unfavorite" : "Favorite")
            }
            factTagline(for: track)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: width, alignment: .topLeading)
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
    }

    /// Compute a side length for the hero artwork that never exceeds
    /// half the pane height (keeps metadata visible) and caps out at
    /// 520pt so the art doesn't swell past a visually pleasing size on
    /// ultrawide displays.
    private func heroArtSide(containerWidth: CGFloat?) -> CGFloat {
        let byWidth = containerWidth.map { max(240, $0 - 72) } ?? 320
        return min(520, byWidth)
    }

    /// VoiceOver label for the now-playing hero artwork. The hero is the
    /// dominant identity of the screen and isn't wrapped in a labelled
    /// control, so it's marked meaningful (`decorative: false`) and reads as
    /// the cover for the album when known, falling back to the track when the
    /// server ships no album name (singles). (#356)
    private func nowPlayingArtworkLabel(for track: Track) -> String {
        Self.nowPlayingArtworkLabel(trackName: track.name, albumName: track.albumName)
    }

    /// Pure label builder, split out so the fallback rule is unit-testable
    /// without booting a SwiftUI scene.
    static func nowPlayingArtworkLabel(trackName: String, albumName: String?) -> String {
        if let album = albumName, !album.isEmpty {
            return "Album artwork for \(album)"
        }
        return "Artwork for \(trackName)"
    }

    @ViewBuilder
    private func factTagline(for track: Track) -> some View {
        let facts = NowPlayingFacts.variants(
            playCount: track.playCount,
            container: track.container,
            lastPlayedAt: track.userData?.lastPlayedAt
        )
        if !facts.isEmpty {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let index = reduceMotion
                    ? 0
                    : NowPlayingFacts.index(at: context.date, count: facts.count)
                Text(facts[index])
                    .font(Theme.font(11, weight: .regular, italic: true))
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .id(index)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: index)
                    .accessibilityLabel(facts[index])
            }
            .padding(.top, 6)
        }
    }

    /// Right pane — segmented tab picker over a per-tab view.
    @ViewBuilder
    private func detailPane(for track: Track) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            paneHeader
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            tabBody(for: track)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Reduce Motion disables the tab transition; otherwise
                // let SwiftUI cross-fade to avoid a hard snap between
                // the richly-laid-out panels.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
        .background(
            Rectangle()
                .fill(Theme.bgAlt.opacity(0.35))
        )
    }

    @ViewBuilder
    private var paneHeader: some View {
        HStack {
            Text("NOW PLAYING")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(a11yTheme.accent)
                .tracking(3)
            Spacer()
        }
    }

    @ViewBuilder
    private func tabBody(for track: Track) -> some View {
        switch tab {
        case .queue:
            queuePanel
        case .lyrics:
            lyricsPanel
        case .about:
            aboutPanel(for: track)
        case .credits:
            creditsPanel
        }
    }

    // MARK: - Queue tab (#272)

    /// Queue panel — embeds the full `QueueInspector` component so the Now
    /// Playing view surfaces the same upcoming-tracks UI as the sidebar.
    /// `QueueInspector` pulls its data from `AppModel` via `@Environment`,
    /// which `NowPlayingView` already injects.
    @ViewBuilder
    private var queuePanel: some View {
        QueueInspector()
    }

    // MARK: - Lyrics tab (#91, #273)

    /// Lyrics drawer. Delegates all rendering to `LyricsView`, which
    /// handles the LRC parse + auto-scroll + reduce-motion fallback.
    /// While `currentLyrics` is nil (pre-fetch / between tracks) we
    /// show a minimal loading row; an empty array — the stub state
    /// until the core lyrics FFI lands — renders the view's empty
    /// state.
    @ViewBuilder
    private var lyricsPanel: some View {
        if let lines = model.currentLyrics {
            LyricsView(
                lines: lines,
                progress: { model.status.positionSeconds }
            )
        } else {
            VStack {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.ink3)
                Text("Loading lyrics…")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - About tab (#278)

    /// About block. Surfaces the subset of metadata we already have on
    /// the `Track` — album, artist, year, runtime — plus the album's
    /// track count via a library lookup. The artist's long-form biography
    /// lives on the artist item (`ArtistDetail.overview`) and is rendered on
    /// the Artist detail page's About section; surfacing the first paragraph
    /// here would need its own artist-detail fetch and is out of scope.
    @ViewBuilder
    private func aboutPanel(for track: Track) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                aboutSection(
                    label: "Artist",
                    value: track.artistName
                )

                if let album = track.albumName, !album.isEmpty {
                    aboutSection(label: "Album", value: album)
                }

                if let year = track.year {
                    aboutSection(label: "Year", value: String(year))
                }

                aboutSection(
                    label: "Runtime",
                    value: formatRuntime(track.durationSeconds)
                )

                if track.playCount > 0 {
                    aboutSection(
                        label: "Plays",
                        value: formatPlayCount(track.playCount)
                    )
                }

                if let bitrate = track.bitrate, bitrate > 0 {
                    aboutSection(
                        label: "Bitrate",
                        value: formatBitrate(bitrate)
                    )
                }

                if let album = resolvedAlbum {
                    if album.trackCount > 0 {
                        aboutSection(
                            label: "Tracks",
                            value: "\(album.trackCount) on \(album.name)"
                        )
                    }
                    if !album.genres.isEmpty {
                        aboutSection(
                            label: "Genres",
                            value: album.genres.joined(separator: ", ")
                        )
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .task(id: track.albumId) {
            guard let albumId = track.albumId else {
                resolvedAlbum = nil
                return
            }
            resolvedAlbum = await model.resolveAlbum(id: albumId)
        }
    }

    @ViewBuilder
    private func aboutSection(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            Text(value)
                .font(Theme.font(14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func formatRuntime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatPlayCount(_ count: UInt32) -> String {
        count == 1 ? "1 play" : "\(count) plays"
    }

    private func formatBitrate(_ bitrate: Int64) -> String {
        let kbps = Int(bitrate) / 1000
        return "\(kbps) kbps"
    }

    // MARK: - Credits tab (PR #508)

    /// Credits block — pulls the `People` array off `AppModel` (populated
    /// by `fetchCurrentTrackDetails`) and hands it straight to the
    /// existing `NowPlayingCredits` component so we coexist with the
    /// work from PR #508 rather than re-implementing it.
    @ViewBuilder
    private var creditsPanel: some View {
        ScrollView {
            NowPlayingCredits(
                credits: Credit.rows(from: model.currentTrackPeople)
            )
            .padding(.vertical, 8)
        }
    }

    // MARK: - Close / dismiss

    /// Back affordance that pops to the screen the user was on before
    /// they opened the full player. Falls back to the library when we
    /// never stashed a predecessor.
    @ViewBuilder
    private var closeButton: some View {
        Button(action: dismiss) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                Text("Close")
                    .font(Theme.font(11, weight: .semibold))
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Theme.surface)
            )
            .overlay(
                Capsule().stroke(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close Now Playing")
    }

    private func dismiss() {
        // NavigationStack handles popping the path; we only need to walk
        // back one entry. If the user reached this view from a non-stack
        // entry (legacy paths), fall back to the user's previous tab.
        if !model.navPath.isEmpty {
            model.navPath.removeLast()
        } else if let previous = model.previousScreen {
            model.selectTab(previous)
            model.previousScreen = nil
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text("Nothing playing")
                .font(Theme.font(16, weight: .bold))
                .foregroundStyle(Theme.ink2)
            Text("Start a track to see the full player.")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
            Button("Back to Library") {
                model.selectTab(.library)
                model.previousScreen = nil
            }
            .buttonStyle(.borderedProminent)
            .tint(a11yTheme.accent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
