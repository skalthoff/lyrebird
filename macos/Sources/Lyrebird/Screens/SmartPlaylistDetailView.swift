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
    /// and the current snapshot.
    ///
    /// SwiftUI does not memoize computed properties, so reading this once per
    /// visible row (as the old code did via `matchedTracks`) re-ran the whole
    /// O(albums + tracks) predicate N times per render. `body` instead
    /// evaluates **once** into a local and threads the result down to every
    /// subview, building the album→genre index a single time per render with
    /// the `genresByAlbumId:` evaluator overload rather than rebuilding it
    /// per access.
    private func evaluate(_ playlist: SmartPlaylist) -> [Track] {
        SmartPlaylistEvaluator.evaluate(
            playlist,
            tracks: model.tracks,
            genresByAlbumId: SmartPlaylistEvaluator.albumGenreIndex(model.albums)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let playlist {
                    // Evaluate once per render; pass the result to every
                    // subview so the predicate isn't re-run per row / per
                    // property access.
                    let matched = evaluate(playlist)
                    hero(playlist, matched: matched)
                    transportBar(playlist, matched: matched)
                    trackList(matched: matched)
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
    private func hero(_ playlist: SmartPlaylist, matched: [Track]) -> some View {
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
                Text("smart_playlist.badge")
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

                Text(CountStrings.label(matched.count, .songs))
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
    private func transportBar(_ playlist: SmartPlaylist, matched: [Track]) -> some View {
        HStack(spacing: 14) {
            Button {
                if !matched.isEmpty { model.play(tracks: matched, startIndex: 0) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("smart_playlist.a11y.play"))
            .disabled(matched.isEmpty)

            Button {
                if !matched.isEmpty { model.play(tracks: matched.shuffled(), startIndex: 0) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("smart_playlist.a11y.shuffle"))
            .disabled(matched.isEmpty)

            Button {
                editing = playlist
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("smart_playlist.edit_rules")
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("smart_playlist.a11y.edit_rules"))

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Track list

    @ViewBuilder
    private func trackList(matched: [Track]) -> some View {
        // Filter the (already-evaluated) set by the scoped query once, paired
        // with the index into `matched` so playback starts from the right row.
        let filtered = PlaylistView.filterTracks(matched, query: scopedQuery)
        VStack(alignment: .leading, spacing: 0) {
            if !matched.isEmpty {
                HStack {
                    Spacer()
                    ScopedSearchBar(
                        query: $scopedQuery,
                        isFocused: $scopedSearchFocused,
                        placeholder: String(localized: "smart_playlist.filter_placeholder")
                    )
                }
                .padding(.bottom, 8)
            }

            if matched.isEmpty {
                emptyResult
            } else if filtered.isEmpty {
                Text("smart_playlist.no_filter_match \(scopedQuery)")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(filtered, id: \.track.id) { entry in
                    let idx = entry.index
                    TrackRow(
                        track: entry.track,
                        number: idx + 1,
                        onPlay: { model.play(tracks: matched, startIndex: idx) },
                        tracks: matched,
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
            Text("smart_playlist.empty.title")
                .font(Theme.font(14, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Text("smart_playlist.empty.detail \(model.tracks.count)")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button { editing = playlist } label: {
                Text("smart_playlist.edit_rules")
            }
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
            Text("smart_playlist.not_found")
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pure summary helpers (unit-tested)

    /// One-line localized description of a playlist's rules, e.g. (en)
    /// "Matches all of: Artist is Radiohead, Year greater than 2000". An
    /// empty rule set reads as "Matches every track."
    ///
    /// Built from localized format strings rather than English-glued clauses:
    /// the empty case and the "Matches {mode} of: {clauses}" frame are catalog
    /// keys, the per-clause `field`/`op` labels are already localized via the
    /// model's `displayName`, and the clause separator is itself a catalog key
    /// so locales that don't list-join with ", " can override it. Pure (no
    /// view state) so it stays unit-testable; in the test bundle the catalog
    /// is stripped, so lookups return the raw keys — the *structure* is what's
    /// pinned there, the rendered copy is verified in the running app.
    static func ruleSummary(_ playlist: SmartPlaylist) -> String {
        guard !playlist.rules.isEmpty else {
            return String(localized: "smart_playlist.rules.matches_all_tracks", bundle: .main)
        }
        let separator = String(localized: "smart_playlist.rules.clause_separator", bundle: .main)
        let clauses = playlist.rules
            .map { rule in "\(rule.field.displayName) \(rule.op.displayName) \(rule.value)" }
            .joined(separator: separator)
        return String(
            localized: "smart_playlist.rules.matches \(playlist.matchMode.displayName) \(clauses)",
            bundle: .main
        )
    }
}
