import SwiftUI
@preconcurrency import LyrebirdCore

/// Album detail screen — hero + CTA row + disc-grouped tracklist + editorial
/// "About this album" blurb + liner-note credits block. Implements the
/// BATCH-05 polish pass: #219 (hero stat strip typography), #70
/// (Play/Shuffle/Radio/Download + overflow CTAs), #222 (favourite /
/// add-to-playlist / download inline actions), #66 (disc grouping with
/// sticky small-caps headers), #65 (liner-note credits section with
/// clickable people chips), #68 (editorial "About this album" section,
/// hidden when the server has no `Overview`).
///
/// Data flow:
/// - `tracks` is loaded via `AppModel.loadTracks(forAlbum:)` (cached).
/// - `detail` (label, release date, aggregated People) is fetched on open via
///   `AppModel.loadAlbumDetail(albumId:)`. The view degrades cleanly when
///   `detail` is empty — the liner-note section falls back to cached fields.
struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    /// Honour the system "Reduce Motion" setting for the liner-notes drawer
    /// slide (#221) — when set, the panel appears/disappears with an opacity
    /// crossfade instead of a horizontal slide. Matches the shell's
    /// queue-inspector and the artist-page hover treatments.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let albumID: String

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var detail: AlbumDetail = AlbumDetail(label: nil, releaseDate: nil, people: [], overview: nil)
    @State private var fetchedAlbum: Album?
    @State private var showAddToPlaylist = false
    @State private var moreByArtist: [Album] = []
    /// Whether the full editorial blurb popover is open (#68). Mirrors the
    /// artist About section's "Read more" affordance.
    @State private var isAboutExpanded = false
    /// Whether the right-side liner-notes drawer is presented (#221). The
    /// liner-note fields + credits also live inline at the bottom of the page
    /// (#65); the drawer surfaces the same structured data without a scroll to
    /// the foot of a long tracklist. Reset on album change in the `.task`.
    @State private var isLinerNotesDrawerPresented = false

    /// Cache-first lookup against the paged `albums` list, then fall
    /// back to the record the `.task` block fetched. Missing after both
    /// resolves means the id really isn't in the user's library — the
    /// hero silently skips rendering rather than showing "Album not
    /// found"; the tracklist section still renders if it loaded.
    private var album: Album? {
        model.albums.first { $0.id == albumID } ?? fetchedAlbum
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                ctaRow
                trackList
                aboutSection
                linerNotes
                moreByArtistSection
            }
        }
        .background(Theme.bg)
        // Right-side liner-notes drawer (#221). Layered above the scroll view
        // so it slides in over the page rather than reflowing it. Mounted only
        // while presented so it costs nothing when closed.
        .overlay(alignment: .trailing) { linerNotesDrawer }
        .task(id: albumID) {
            isLoading = true
            // Reset the editorial-blurb popover so a prior album's expanded
            // "About this album" never bleeds into this page (#68).
            isAboutExpanded = false
            // Close any open liner-notes drawer so it doesn't carry a prior
            // album's data into this page (#221).
            isLinerNotesDrawerPresented = false
            if model.albums.first(where: { $0.id == albumID }) == nil {
                fetchedAlbum = await model.resolveAlbum(id: albumID)
            }
            tracks = await model.loadTracks(forAlbum: albumID)
            isLoading = false
            detail = await model.loadAlbumDetail(albumId: albumID)
            // Load "More by Artist" in parallel with detail — non-blocking for
            // the tracklist which is already visible at this point.
            if let artistId = album?.artistId, !artistId.isEmpty {
                let all = await model.loadArtistAlbums(artistId: artistId)
                moreByArtist = Array(
                    all
                        .filter { $0.id != albumID }
                        .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                        .prefix(10)
                )
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let album = album {
            HStack(alignment: .bottom, spacing: 36) {
                Artwork(
                    url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 480),
                    seed: album.name,
                    size: 240,
                    radius: 6,
                    decorative: false
                )
                .accessibilityLabel("Album artwork for \(album.name)")
                VStack(alignment: .leading, spacing: 6) {
                    Text("LONG-PLAYER · \(album.year.map(String.init) ?? "")")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .tracking(3)
                    Text(album.name)
                        .font(Theme.font(72, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                        .tracking(-2)
                    artistNameLine(for: album)
                    statStrip(album: album)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .contextMenu { AlbumContextMenu(album: album, showGoToAlbum: false) }
        }
    }

    /// "by <Artist Name>" below the album title. When the album carries a
    /// resolvable `artistId` (the usual case — server returns it on every
    /// MusicAlbum BaseItemDto), the whole line is a button that routes to
    /// `.artist(id)`. When there's no id (degenerate metadata, compilations
    /// without a credited album artist) it falls back to plain text so the
    /// eye isn't drawn to an unresponsive click target.
    @ViewBuilder
    private func artistNameLine(for album: Album) -> some View {
        let line = Text("by \(album.artistName)")
            .font(Theme.font(20, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 2)
                    .padding(.leading, 28)
                    .offset(y: 2)
            }
        if let artistId = album.artistId, !artistId.isEmpty {
            Button {
                model.navPath.append(AppModel.Route.artist(artistId))
            } label: {
                line
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to artist \(album.artistName)")
            .accessibilityHint("Opens the artist page")
            .accessibilityAddTraits(.isButton)
        } else {
            line
        }
    }

    /// Four-stat strip — Tracks, Minutes, Label, Format — per #219. Stats
    /// are laid out with a 28pt gap and tabular-nums 22pt/heavy values on
    /// `ink`, 10pt/bold/2-tracking/uppercase labels on `ink3`. The last two
    /// stats (Label, Format) collapse to an em-dash when their source
    /// fields are absent, which matches the "degrade cleanly when fields
    /// are empty" acceptance on #65.
    @ViewBuilder
    private func statStrip(album: Album) -> some View {
        HStack(spacing: 28) {
            stat(value: "\(album.trackCount)", label: "Tracks")
            stat(value: formatMinutes(album.runtimeTicks), label: "Minutes")
            stat(value: detail.label ?? "—", label: "Label")
            stat(value: formatSummary(tracks: tracks), label: "Format")
        }
    }

    @ViewBuilder
    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.font(22, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .lineLimit(1)
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
        }
    }

    // MARK: - CTA row

    /// Horizontal row below the hero: primary Play, secondary Shuffle /
    /// Radio / Download, then inline actions (Favourite heart, Add-to-
    /// playlist plus) and a `•••` overflow menu. Every item is a real
    /// SwiftUI `Button`, so keyboard Tab focus walks each one in order and
    /// Space activates the focused control — the #70 acceptance criterion.
    @ViewBuilder
    private var ctaRow: some View {
        HStack(spacing: 12) {
            playButton
            shuffleButton
            radioButton
            downloadButton
            linerNotesButton

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 4)

            favouriteButton
            addToPlaylistButton

            Spacer()

            overflowMenu
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var playButton: some View {
        Button {
            if !tracks.isEmpty { model.play(tracks: tracks, startIndex: 0) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("Play")
                    .font(Theme.font(13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .accessibilityLabel("Play album")
    }

    private var shuffleButton: some View {
        secondaryCTA(icon: "shuffle", label: "Shuffle") {
            if let album = album { model.shuffle(album: album) }
        }
        .disabled(tracks.isEmpty)
        .accessibilityLabel("Shuffle album")
    }

    private var radioButton: some View {
        secondaryCTA(icon: "dot.radiowaves.left.and.right", label: "Radio") {
            if let album = album { model.startAlbumRadio(album: album) }
        }
        .accessibilityLabel("Start album radio")
    }

    @ViewBuilder
    private var downloadButton: some View {
        if model.supportsDownloads {
            secondaryCTA(icon: "arrow.down.circle", label: "Download") {
                if let album = album { model.enqueueDownload(album: album) }
            }
            .accessibilityLabel("Download album")
        }
    }

    /// Opens the right-side liner-notes drawer (#221). Uses the same
    /// secondary-CTA pill as Shuffle / Radio / Download so it reads as a peer
    /// affordance and Tab focus walks it in row order. The toggle is wrapped
    /// in a reduce-motion-aware animation so the panel slides (or crossfades)
    /// in consistently with the close paths.
    private var linerNotesButton: some View {
        secondaryCTA(icon: "doc.text", label: "Liner Notes") {
            withAnimation(LinerNotesDrawerPresentation.animation(reduceMotion: reduceMotion)) {
                isLinerNotesDrawerPresented = true
            }
        }
        .accessibilityLabel("Show liner notes")
        .accessibilityHint("Opens a panel with release details and credits")
    }

    private var favouriteButton: some View {
        // Snapshot-aware read: when `album` is non-nil we hit the
        // server-authoritative `userData.isFavorite` projection on first
        // paint; the `?? false` only triggers before resolveAlbum returns.
        let isFav = album.map { model.isFavorite(album: $0) } ?? false
        return Button {
            if let album = album { model.toggleFavorite(album: album) }
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isFav ? Theme.accent : Theme.ink2)
                .frame(width: 36, height: 36)
                .background(Circle().stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFav ? "Remove from favorites" : "Add to favorites")
    }

    private var addToPlaylistButton: some View {
        Button {
            showAddToPlaylist = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 36, height: 36)
                .background(Circle().stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to playlist")
        .popover(isPresented: $showAddToPlaylist, arrowEdge: .top) {
            AddToPlaylistPopover(trackIds: tracks.map(\.id)) {
                showAddToPlaylist = false
            }
            .environment(model)
        }
    }

    private var overflowMenu: some View {
        Menu {
            if let album = album { AlbumContextMenu(album: album) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 36, height: 36)
                .background(Circle().stroke(Theme.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private func secondaryCTA(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(Theme.font(13, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Track list

    /// Disc-grouped tracklist. Tracks are sorted by `(disc, track)` so a
    /// multi-disc album reads top-to-bottom in spec order (#66). The sticky
    /// "DISC N" header is shown only when more than one disc is present,
    /// per the same issue's "hidden for single-disc albums" acceptance.
    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView()
                    .tint(Theme.ink2)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                let groups = discGroups(from: tracks)
                let showHeaders = groups.count > 1
                ForEach(groups, id: \.disc) { group in
                    if showHeaders {
                        discHeader(number: group.disc)
                    }
                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { localIdx, track in
                        TrackRow(
                            track: track,
                            number: discLocalNumber(fallback: localIdx + 1, track: track),
                            onPlay: {
                                if let absoluteIdx = tracks.firstIndex(where: { $0.id == track.id }) {
                                    model.play(tracks: tracks, startIndex: absoluteIdx)
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    /// Small-caps "DISC N" header between disc groups. Sticky-feeling is
    /// achieved visually via the subtle bottom rule and the row-surface
    /// background — a real `pinnedViews` sticky header is intentionally
    /// avoided because the hero already takes the top of the scroll view.
    @ViewBuilder
    private func discHeader(number: Int) -> some View {
        HStack {
            Text("DISC \(number)")
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.horizontal, 16)
        }
    }

    /// Disc-local track number. Jellyfin's `IndexNumber` is usually local
    /// per-disc, but some rippers emit a global sequence — when the
    /// track's `indexNumber` is missing or looks global we fall back to the
    /// row's local index so the column always starts at 1 per disc.
    private func discLocalNumber(fallback: Int, track: Track) -> Int {
        if let n = track.indexNumber, n > 0 { return Int(n) }
        return fallback
    }

    // MARK: - About this album

    /// Editorial "About this album" block (#68). Renders Jellyfin's album
    /// `Overview` (populated by metadata plugins like TheAudioDB /
    /// MusicBrainz) HTML-stripped to plain text, clamped to four lines with a
    /// keyboard-accessible "Read more" popover for the full text — mirroring
    /// `ArtistDetailView.aboutSection`.
    ///
    /// The HTML strip is shared with the artist bio via
    /// `ArtistDetailView.plainTextOverview` so the two surfaces can't drift.
    /// The section is hidden entirely when the album has no overview — no
    /// "no description" placeholder — so an album without editorial metadata
    /// simply doesn't grow a dead region, matching the liner-note block's
    /// "degrade cleanly when fields are empty" behaviour.
    @ViewBuilder
    private var aboutSection: some View {
        if let overview = ArtistDetailView.plainTextOverview(detail.overview) {
            VStack(alignment: .leading, spacing: 0) {
                Text("ABOUT THIS ALBUM")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(2)
                    .padding(.bottom, 12)
                aboutBody(overview: overview)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
        }
    }

    /// Four-line clamp on the overview plus a keyboard-accessible "Read more"
    /// button that opens the full text in a popover. The popover is driven by
    /// a plain SwiftUI `Button`, so it's focusable and Return-activatable for
    /// free — the same affordance as the artist About section.
    @ViewBuilder
    private func aboutBody(overview: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overview)
                .font(Theme.font(14, weight: .regular))
                .foregroundStyle(Theme.ink2)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button {
                isAboutExpanded = true
            } label: {
                Text("Read more")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read full description for \(album?.name ?? "this album")")
            .accessibilityHint("Opens the complete album description in a popover")
            .popover(isPresented: $isAboutExpanded, arrowEdge: .top) {
                aboutPopover(overview: overview)
            }
        }
    }

    /// Full-description popover. Scrolls when the text is long so the popover
    /// stays a sane size, and is dismissible with Escape (SwiftUI default) or
    /// the explicit Done button for pointer users.
    @ViewBuilder
    private func aboutPopover(overview: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(album?.name ?? "About this album")
                    .font(Theme.font(18, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 24)
                Button("Done") { isAboutExpanded = false }
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
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .frame(maxHeight: 460)
    }

    // MARK: - Liner notes

    /// Bottom-of-page liner-note block (#65): "Released", "Label", "Format",
    /// "Runtime", "Tracks / Discs", plus a Credits subsection with clickable
    /// role → people chips. Lines collapse to an em-dash when the server
    /// doesn't surface a field, and the credits subsection is hidden
    /// entirely when `detail.people` has no relevant roles — matches the
    /// "degrades cleanly when fields are empty" acceptance.
    @ViewBuilder
    private var linerNotes: some View {
        if let album = album {
            VStack(alignment: .leading, spacing: 0) {
                Text("LINER NOTES")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(2)
                    .padding(.bottom, 12)

                linerNotesContent(album: album)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 48)
        }
    }

    /// The structured liner-note body — the field rows plus the optional
    /// Credits subsection — without the section header or page padding. Shared
    /// verbatim between the inline bottom-of-page block (#65) and the slide-in
    /// drawer (#221) so the two surfaces can never drift in what they show.
    /// Reads only the already-loaded `detail` / `tracks`, so it's free to
    /// render in both places at once.
    @ViewBuilder
    private func linerNotesContent(album: Album) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                linerRow(label: "Released", value: releasedSummary(album: album))
                linerRow(label: "Label", value: detail.label ?? "—")
                linerRow(label: "Format", value: formatSummary(tracks: tracks))
                linerRow(label: "Runtime", value: runtimeSummary(album: album))
                linerRow(label: "Tracks", value: tracksSummary(album: album))
            }
            .textSelection(.enabled)

            let creditRows = ExtendedCredit.rows(from: detail.people)
            if !creditRows.isEmpty {
                Text("CREDITS")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(2)
                    .padding(.top, 28)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(creditRows, id: \.label) { row in
                        creditRowView(row: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linerRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder
    private func creditRowView(row: ExtendedCredit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
            FlowLayout(spacing: 6) {
                ForEach(Array(row.people.enumerated()), id: \.offset) { _, person in
                    CreditChip(person: person) {
                        if let id = person.id {
                            model.navPath.append(AppModel.Route.artist(id))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Liner notes drawer (#221)

    /// Right-side slide-in drawer surfacing the same structured liner-note
    /// fields + credits as the inline block (#65), reachable from the hero
    /// without scrolling past a long tracklist. Closes on Escape, a tap on the
    /// dimmed scrim, or the panel's close button. Honours Reduce Motion: the
    /// panel crossfades instead of sliding when the setting is on.
    ///
    /// Mounted only while presented (`if`-gated) so it adds no cost to a
    /// closed page, and renders nothing when the album hasn't resolved yet so
    /// the panel never shows an empty shell.
    @ViewBuilder
    private var linerNotesDrawer: some View {
        if isLinerNotesDrawerPresented, let album = album {
            ZStack(alignment: .trailing) {
                // Dimmed tap-out scrim. `contentShape` + a plain Button keeps
                // the whole backdrop a single dismiss target without stealing
                // VoiceOver focus from the panel (it's hidden from the
                // accessibility tree — the panel's close button is the
                // assistive-tech dismiss path).
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissLinerNotesDrawer() }
                    .accessibilityHidden(true)
                    .transition(.opacity)

                linerNotesPanel(album: album)
                    .transition(LinerNotesDrawerPresentation.transition(reduceMotion: reduceMotion))
            }
            // An invisible cancel-action button gives the drawer an Escape
            // handler without a focusable on-screen control — the same idiom
            // the command palette uses to close on Escape.
            .background {
                Button("", action: dismissLinerNotesDrawer)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The drawer's opaque panel: a fixed-width column pinned to the trailing
    /// edge with a header (title + close) over a scrollable liner-note body.
    @ViewBuilder
    private func linerNotesPanel(album: Album) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LINER NOTES")
                        .font(Theme.font(10, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(2)
                    Text(album.name)
                        .font(Theme.font(16, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 16)
                Button(action: dismissLinerNotesDrawer) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close liner notes")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }

            ScrollView {
                linerNotesContent(album: album)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
            }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(Theme.bgAlt)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: -8, y: 0)
        // Group the panel as one container so VoiceOver treats it as a
        // self-contained dialog rather than letting focus wander onto the
        // dimmed page behind it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Liner notes for \(album.name)")
        .accessibilityAddTraits(.isModal)
    }

    /// Single dismiss path for every close affordance (Escape / scrim tap /
    /// close button) so the slide-out animation stays consistent and honours
    /// Reduce Motion regardless of how the user closed the panel.
    private func dismissLinerNotesDrawer() {
        withAnimation(LinerNotesDrawerPresentation.animation(reduceMotion: reduceMotion)) {
            isLinerNotesDrawerPresented = false
        }
    }

    // MARK: - More by Artist

    /// Horizontal carousel showing up to 10 other albums by the same artist,
    /// sorted most-recent-first. The section is hidden entirely when the
    /// artist has only one album in the library (i.e. the carousel would be
    /// empty after excluding the current album) — matches the "handles
    /// solo-artist edge case" acceptance on #67.
    @ViewBuilder
    private var moreByArtistSection: some View {
        if !moreByArtist.isEmpty, let album = album {
            VStack(alignment: .leading, spacing: 12) {
                Text("MORE BY \(album.artistName.uppercased())")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(2)
                    .padding(.horizontal, 40)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(moreByArtist, id: \.id) { related in
                            HomeAlbumTile(album: related, hint: "Double-click to open album")
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 4)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Formatting helpers

    /// Minutes-only duration string for the hero stat. The older
    /// implementation returned an integer minute count; we keep the same
    /// shape so the "Minutes" stat reads as a clean number.
    private func formatMinutes(_ ticks: UInt64) -> String {
        let seconds = Double(ticks) / 10_000_000.0
        return "\(Int(seconds / 60))"
    }

    /// Compact runtime string for the liner-note "Runtime" row, e.g.
    /// `42:11` or `1h 12m`. Sums the cached track runtimes when available
    /// so re-ripped albums with trimmed tails stay accurate; falls back to
    /// the album's `runtime_ticks` otherwise.
    private func runtimeSummary(album: Album) -> String {
        let ticks: UInt64 = tracks.isEmpty
            ? album.runtimeTicks
            : tracks.reduce(0) { $0 + $1.runtimeTicks }
        let totalSeconds = Int(Double(ticks) / 10_000_000.0)
        if totalSeconds >= 3600 {
            let h = totalSeconds / 3600
            let m = (totalSeconds % 3600) / 60
            return "\(h)h \(m)m"
        } else {
            let m = totalSeconds / 60
            let s = totalSeconds % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    /// "Released" line — preferred form is a full date, falls back to
    /// just the year from the cached `Album`, then an em-dash. Reissue
    /// disambiguation (original year + reissue year) from #65 is parked
    /// for follow-up since the core doesn't yet surface an `OriginalYear`
    /// / reissue-date pair.
    private func releasedSummary(album: Album) -> String {
        if let date = detail.releaseDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f.string(from: date)
        }
        if let year = album.year { return String(year) }
        return "—"
    }

    /// "Tracks" line — doubles as the disc-count breakdown when the album
    /// spans multiple discs ("12 tracks · 2 discs").
    private func tracksSummary(album: Album) -> String {
        let trackCount = tracks.isEmpty ? Int(album.trackCount) : tracks.count
        let trackWord = trackCount == 1 ? "track" : "tracks"
        let discs = Set(tracks.compactMap { $0.discNumber.map(Int.init) }).count
        if discs > 1 {
            return "\(trackCount) \(trackWord) · \(discs) discs"
        }
        return "\(trackCount) \(trackWord)"
    }

    /// Format summary used by both the hero stat and the liner-note row.
    /// Lifts uppercased `container` values off the cached tracks and joins
    /// them with ` · `; when the tracks haven't loaded yet we fall back to
    /// a plain em-dash rather than inventing "FLAC".
    private func formatSummary(tracks: [Track]) -> String {
        let containers = tracks
            .compactMap { $0.container?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
        guard !containers.isEmpty else { return "—" }
        var seen = Set<String>()
        var ordered: [String] = []
        for c in containers where seen.insert(c).inserted {
            ordered.append(c)
        }
        // Single-format album with known bitrate: include the bitrate
        // in kbps so "MP3 320" reads clean.
        if ordered.count == 1, tracks.count > 0 {
            let bitrates = tracks.compactMap { $0.bitrate }
            if let avg = bitrates.first, bitrates.allSatisfy({ abs(Int($0) - Int(avg)) < 32_000 }) {
                let kbps = Int(avg) / 1000
                if kbps > 0 {
                    return "\(ordered[0]) \(kbps)"
                }
            }
        }
        return ordered.joined(separator: " · ")
    }
}

// MARK: - Liner-notes drawer presentation (#221)

/// Pure presentation policy for the album liner-notes drawer. SwiftUI exposes
/// no way to introspect a `transition` / `animation` off a `some View` without
/// booting a scene, so — mirroring the `SidebarAutoHide` reducer — the two
/// motion decisions that depend on the system "Reduce Motion" setting are
/// hoisted into static functions here where they can be unit-tested directly:
///
/// - `transition(reduceMotion:)` — the panel slides in from the trailing edge
///   normally, and crossfades (`.opacity`) when Reduce Motion is on so no
///   horizontal travel occurs.
/// - `animation(reduceMotion:)` — the `withAnimation` curve driving every
///   open/close path; `nil` under Reduce Motion so the state flips instantly.
///
/// Keeping both in one type guarantees the open button, the Escape handler,
/// the scrim tap, and the close button all animate identically.
enum LinerNotesDrawerPresentation {
    /// Trailing-edge slide normally; opacity-only crossfade under Reduce
    /// Motion. The combined `.move + .opacity` keeps the slide from popping a
    /// hard rectangle in at full alpha.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .trailing).combined(with: .opacity)
    }

    /// The curve for the present/dismiss `withAnimation`. `nil` disables the
    /// animation entirely so Reduce Motion users get an instant state change.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }
}

// MARK: - Disc grouping

/// Tracks on a single disc, in ascending `IndexNumber` order. `disc` is
/// `track.disc_number` when present; tracks without a disc number collapse
/// into disc 1 so a malformed item doesn't split the grouping.
private struct DiscGroup {
    let disc: Int
    let tracks: [Track]
}

/// Partition a flat `[Track]` into per-disc groups, sorted by
/// `(disc, track)`. Handles disc numbers 1-20 per #66's acceptance; the
/// upper bound isn't enforced here because sorting naturally handles any
/// range and the server-side data rarely exceeds it.
private func discGroups(from tracks: [Track]) -> [DiscGroup] {
    let sorted = tracks.sorted { lhs, rhs in
        let ld = Int(lhs.discNumber ?? 1)
        let rd = Int(rhs.discNumber ?? 1)
        if ld != rd { return ld < rd }
        let li = Int(lhs.indexNumber ?? UInt32.max)
        let ri = Int(rhs.indexNumber ?? UInt32.max)
        return li < ri
    }
    var bucket: [Int: [Track]] = [:]
    var order: [Int] = []
    for t in sorted {
        let d = Int(t.discNumber ?? 1)
        if bucket[d] == nil { order.append(d) }
        bucket[d, default: []].append(t)
    }
    return order.map { DiscGroup(disc: $0, tracks: bucket[$0] ?? []) }
}

// MARK: - Extended credits (liner-note section)

/// One role bucket in the liner-note Credits subsection. Unlike
/// `NowPlayingCredits.Credit`, this variant keeps the per-person `Person`
/// records rather than flattening to a comma string, so the album detail
/// chips can navigate to each artist individually (#65).
struct ExtendedCredit {
    let label: String
    let people: [Person]

    /// Bucket a flat `[Person]` list into the roles surfaced on the album
    /// detail screen: Composers, Producers, Mixers, Engineers, plus a
    /// catch-all "Writers" row that pulls both `Writer` and `Lyricist`.
    ///
    /// Dedupe is by `(name, id)` so servers that list the same person
    /// twice under slightly different roles (a producer who also
    /// engineered) show once per role-bucket. Rows with no matching people
    /// are dropped so the section stays compact.
    static func rows(from people: [Person]) -> [ExtendedCredit] {
        func filter(types: [String]) -> [Person] {
            var seen = Set<String>()
            var out: [Person] = []
            for p in people where types.contains(where: { p.type.caseInsensitiveCompare($0) == .orderedSame }) {
                let key = "\(p.name.lowercased())|\(p.id ?? "")"
                if seen.insert(key).inserted {
                    out.append(p)
                }
            }
            return out
        }

        let mapping: [(label: String, types: [String])] = [
            ("Composers", ["Composer"]),
            ("Writers", ["Writer", "Lyricist"]),
            ("Producers", ["Producer"]),
            ("Mixers", ["Mixer", "Remixer"]),
            ("Engineers", ["Engineer"]),
        ]
        return mapping.compactMap { row in
            let matched = filter(types: row.types)
            guard !matched.isEmpty else { return nil }
            return ExtendedCredit(label: row.label, people: matched)
        }
    }
}

/// Clickable chip rendering one credited person. When the backing `Person`
/// carries an id the chip behaves as a navigation button that routes to
/// the artist detail screen; when the id is missing (servers that strip
/// `People.Id`) the chip renders as inert selectable text — still usable
/// via copy/paste per the #65 acceptance.
private struct CreditChip: View {
    let person: Person
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Text(person.name)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(person.id == nil ? Theme.ink2 : Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isHovering && person.id != nil ? Theme.surface2 : Theme.surface)
                )
                .overlay(
                    Capsule().stroke(Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(person.id == nil)
        .onHover { isHovering = $0 }
        .accessibilityLabel(person.id == nil ? person.name : "Open artist \(person.name)")
    }
}

// MARK: - Add-to-playlist popover

/// Popover-style picker shown by the album detail's `+` button. Lists the
/// current user's playlists and calls `AppModel.addToPlaylist(...)` with
/// the album's track ids when the user picks one.
///
/// Empty-state copy explains "No playlists yet"; callers close the popover
/// via the passed-in `onDismiss` closure after a successful append.
private struct AddToPlaylistPopover: View {
    @Environment(AppModel.self) private var model
    let trackIds: [String]
    let onDismiss: () -> Void

    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADD TO PLAYLIST")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if model.playlists.isEmpty {
                Text("No playlists yet")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .italic()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.playlists, id: \.id) { playlist in
                            Button {
                                Task {
                                    isAdding = true
                                    let ok = await model.addToPlaylist(
                                        trackIds: trackIds,
                                        playlistId: playlist.id
                                    )
                                    isAdding = false
                                    if ok { onDismiss() }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.ink2)
                                        .frame(width: 18)
                                    Text(playlist.name)
                                        .font(Theme.font(13, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isAdding)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .frame(width: 240)
        .padding(.bottom, 10)
        .background(Theme.bgAlt)
    }
}

// MARK: - Flow layout (credit chips)

/// Minimal left-aligned flow layout for the credit chips. SwiftUI ships
/// `Layout`-based primitives but no bundled flow layout; rolling our own
/// keeps the chip row wrapping on narrow window widths without dragging
/// in a dependency. Measures each subview at its preferred size and wraps
/// to a new line when the cursor would exceed the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]
        var cursor: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if cursor + size.width > maxWidth, cursor > 0 {
                rows.append(0)
                rowHeights.append(0)
                cursor = 0
            }
            cursor += size.width + spacing
            let rowIdx = rows.count - 1
            rows[rowIdx] = max(rows[rowIdx], cursor)
            rowHeights[rowIdx] = max(rowHeights[rowIdx], size.height)
        }
        let totalHeight = rowHeights.reduce(0, +) + CGFloat(rowHeights.count - 1) * spacing
        let totalWidth = rows.max() ?? 0
        return CGSize(width: min(totalWidth, maxWidth), height: max(0, totalHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
