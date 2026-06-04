import SwiftUI
@preconcurrency import LyrebirdCore

/// Detail screen for a saved **smart playlist** (#77 / #238).
///
/// A smart playlist has no server-side track list — it's the *live* result
/// of running its rules over the in-memory library snapshot
/// (`model.tracks`). So this view never fetches: it evaluates
/// `SmartPlaylistEvaluator` over the snapshot the app already holds and
/// renders the matches with the same `TrackRow` density the regular
/// playlist screen uses. Re-evaluation is automatic — the result is derived
/// from `model.tracks` / `model.albums`, so as the library snapshot grows
/// (pagination) or favorites change, the list recomputes on the next render.
///
/// The hero mirrors `PlaylistView`'s transport bar (Play / Shuffle) plus an
/// "Edit Rules" affordance that opens the builder sheet, and a rule summary
/// line so the user can see at a glance what the playlist matches.
struct SmartPlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID

    /// Drives the builder sheet. Set to the playlist being edited when the
    /// user taps "Edit Rules"; `nil` when closed.
    @State private var editing: SmartPlaylist?

    /// Scoped (⌘F-style) filter over the evaluated result, matching
    /// `PlaylistView`. Local only; not persisted.
    @State private var scopedQuery: String = ""
    @FocusState private var scopedSearchFocused: Bool

    private var playlist: SmartPlaylist? {
        model.smartPlaylists.playlist(id: playlistID)
    }

    /// The live evaluated track set. Pure function of the playlist's rules
    /// and the current snapshot — recomputed each render (cheap: a single
    /// linear pass with an O(1) genre lookup).
    private var matchedTracks: [Track] {
        guard let playlist else { return [] }
        return SmartPlaylistEvaluator.evaluate(
            playlist,
            tracks: model.tracks,
            albums: model.albums
        )
    }

    /// `matchedTracks` filtered by the scoped query, paired with the index
    /// into `matchedTracks` so playback starts from the right row.
    private var filteredTracks: [(index: Int, track: Track)] {
        PlaylistView.filterTracks(matchedTracks, query: scopedQuery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let playlist {
                    hero(playlist)
                    transportBar
                    trackList
                } else {
                    notFound
                }
            }
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .sheet(item: $editing) { draft in
            SmartPlaylistBuilderView(playlist: draft) { saved in
                model.smartPlaylists.save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .onChange(of: model.scopedSearchFocusRequest) { _, _ in
            if model.consumeScopedSearchFocus(for: .smartPlaylist(playlistID)) {
                scopedSearchFocused = true
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ playlist: SmartPlaylist) -> some View {
        HStack(alignment: .top, spacing: 24) {
            // Gradient artwork tile with the smart-playlist glyph, so the
            // detail page reads as "rule-driven" rather than a normal
            // playlist with missing art.
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Theme.primary, Theme.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 200, height: 200)
                .overlay(
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                )
                .shadow(color: Theme.primary.opacity(0.3), radius: 18, y: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("SMART PLAYLIST")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(2)

                Text(playlist.name)
                    .font(Theme.font(34, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)

                // Plain-English summary of the rules so the user sees what
                // this playlist matches without opening the builder.
                Text(SmartPlaylistDetailView.ruleSummary(playlist))
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SmartPlaylistDetailView.countSummary(matchedTracks.count))
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }

    // MARK: - Transport bar

    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 14) {
            Button {
                let t = matchedTracks
                if !t.isEmpty { model.play(tracks: t, startIndex: 0) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play smart playlist")
            .disabled(matchedTracks.isEmpty)

            Button {
                let t = matchedTracks
                if !t.isEmpty { model.play(tracks: t.shuffled(), startIndex: 0) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle smart playlist")
            .disabled(matchedTracks.isEmpty)

            Button {
                editing = playlist
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Edit Rules")
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit smart playlist rules")

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
            if !matchedTracks.isEmpty {
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

            if matchedTracks.isEmpty {
                emptyResult
            } else if filteredTracks.isEmpty {
                Text("No tracks match \u{201C}\(scopedQuery)\u{201D}")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(filteredTracks, id: \.track.id) { entry in
                    let idx = entry.index
                    TrackRow(
                        track: entry.track,
                        number: idx + 1,
                        onPlay: { model.play(tracks: matchedTracks, startIndex: idx) },
                        tracks: matchedTracks,
                        index: idx
                    )
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
    }

    // MARK: - Empty / not-found states

    @ViewBuilder
    private var emptyResult: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.ink3)
            Text("No tracks match these rules")
                .font(Theme.font(14, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Text("Loaded \(model.tracks.count) tracks so far. Try loosening the rules, or open the Library so more tracks are in memory.")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Edit Rules") { editing = playlist }
                .buttonStyle(.plain)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.top, 4)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var notFound: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 34))
                .foregroundStyle(Theme.ink3)
            Text("Smart playlist not found")
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pure summary helpers (unit-tested)

    /// One-line plain-English description of a playlist's rules, e.g.
    /// "Matches all of: Artist is Radiohead, Year greater than 2000". An
    /// empty rule set reads as "Matches every track". Pure so it's tested
    /// without a view.
    static func ruleSummary(_ playlist: SmartPlaylist) -> String {
        guard !playlist.rules.isEmpty else { return "Matches every track." }
        let clauses = playlist.rules.map { rule -> String in
            "\(rule.field.displayName) \(rule.op.displayName) \(rule.value)"
        }
        return "Matches \(playlist.matchMode.displayName) of: " + clauses.joined(separator: ", ")
    }

    /// Pluralized "N song(s)" readout. Pure.
    static func countSummary(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }
}
