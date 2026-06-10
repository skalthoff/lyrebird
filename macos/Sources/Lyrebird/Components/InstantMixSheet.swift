import SwiftUI
@preconcurrency import LyrebirdCore

/// Seed-picker modal for Instant Mix (#327).
///
/// The Instant Mix *engine* was already wired end-to-end —
/// `AppModel.playInstantMix(seedId:)` feeds `core.instantMix(itemId:limit:)`,
/// and the Discover / Home CTAs (`startInstantMix`) seed it off whatever is
/// currently playing. What was missing was a way to *choose* the seed. This
/// sheet fills that gap: search the library, pick a track / album / artist /
/// genre, hit Generate, and the chosen seed is handed to `generateInstantMix`.
///
/// Presentation mirrors `TrackInfoSheet` / `NowPlayingSheet`: a fixed-width
/// `VStack` mounted via `.sheet` on `MainShell`, driven by the
/// `AppModel.isShowingInstantMixPicker` flag and summoned from the View ▸
/// "New Instant Mix…" menu command.
///
/// All the searchable / selectable logic lives in `InstantMixSeedPickerModel`
/// (below) so it can be unit-tested headlessly without booting the scene
/// graph — the view is a thin shell around it. See
/// `Tests/LyrebirdTests/InstantMixSeedPickerTests.swift`.
struct InstantMixSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The picker view-model. Built in `init` so the closures it needs
    /// (`search` / `onGenerate`) can capture the live `AppModel`. Held as
    /// `@State` so its `@Observable` mutations drive re-render.
    @State private var picker: InstantMixSeedPickerModel

    @FocusState private var searchFocused: Bool

    init(model: AppModel) {
        // `@State`'s wrappedValue initializer captures the model once; the
        // sheet is re-created per presentation so this never goes stale.
        _picker = State(wrappedValue: InstantMixSeedPickerModel(
            search: { [weak model] query in await model?.searchSeeds(query: query) },
            onGenerate: { [weak model] seed in model?.generateInstantMix(seed: seed) }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            categoryBar
            Divider().background(Theme.border)
            resultsBody
            footer
        }
        .frame(width: 460, height: 560)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("instant_mix.picker.title")
                    .font(Theme.font(16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                if let label = model.instantMixSeedLabel {
                    // One-tap regenerate hint — echoes the last seed so a
                    // re-open offers "again" without re-searching. Composed as
                    // a localized prefix + verbatim seed name so the user-data
                    // title isn't fed through the catalog. Mirrors the
                    // playlist-delete dialog's prefix + verbatim split.
                    (Text("instant_mix.picker.last_mix") + Text(verbatim: " \(label)"))
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("instant_mix.picker.close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.ink2)
                .font(.system(size: 15, weight: .medium))
            TextField("instant_mix.picker.search_placeholder", text: $picker.query)
                .textFieldStyle(.plain)
                .font(Theme.font(15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onChange(of: picker.query) { _, _ in picker.queryChanged() }
            if picker.isSearching {
                ProgressView()
                    .tint(Theme.ink2)
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .spaceKeyGuardForTextField()
    }

    // MARK: - Category chips

    private var categoryBar: some View {
        HStack(spacing: 6) {
            ForEach(InstantMixSeedPickerModel.SeedCategory.allCases, id: \.self) { cat in
                Button {
                    picker.category = cat
                } label: {
                    Text(cat.label)
                        .font(Theme.font(11, weight: .semibold))
                        .foregroundStyle(picker.category == cat ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(picker.category == cat ? Theme.surface2 : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(picker.category == cat ? Theme.borderStrong : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picker.category == cat ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsBody: some View {
        if picker.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyPrompt
        } else if picker.candidates.isEmpty {
            noMatches
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(picker.candidates, id: \.id) { item in
                        SeedRow(
                            item: item,
                            isSelected: picker.selectedSeed?.id == item.id,
                            onPick: { picker.select(item) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "dial.medium")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text("instant_mix.picker.empty_prompt")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var noMatches: some View {
        Text("instant_mix.picker.no_matches")
            .font(Theme.font(13, weight: .medium))
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let seed = picker.selectedSeed {
                // Localized "Seed:" prefix + verbatim title (user data).
                (Text("instant_mix.picker.selected") + Text(verbatim: " \(seed.title)"))
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { picker.generate() }) {
                Text("instant_mix.picker.generate")
                    .font(Theme.font(13, weight: .semibold))
                    .frame(width: 120, height: 32)
                    .foregroundStyle(picker.canGenerate ? Theme.bg : Theme.ink3)
                    .background(picker.canGenerate ? Theme.ink : Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(!picker.canGenerate)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("instant_mix.picker.generate")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

// MARK: - Seed row

/// One selectable seed candidate. A compact artwork + title/subtitle row,
/// plus a trailing checkmark when it's the chosen seed. Genres render with an
/// SF Symbol since they carry no artwork.
private struct SeedRow: View {
    @Environment(AppModel.self) private var model
    let item: SearchItem
    let isSelected: Bool
    let onPick: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(isSelected || isHovering ? Theme.accent : Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.typeLabel)
                        .font(Theme.font(9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.font(10, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.surface2 : (isHovering ? Theme.nativeHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onPick() }
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.typeLabel) \(item.title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .genre:
            // Genres carry no artwork — render a tinted glyph chip instead of
            // a seeded gradient so they read as a distinct seed kind.
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.surface2)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "guitars")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                )
        case .artist(let a):
            Artwork(
                url: model.imageURL(for: a.id, tag: a.imageTag, maxWidth: 120),
                seed: a.name,
                size: 34,
                radius: 17,
                targetPixelSize: CGSize(width: 102, height: 102)
            )
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        case .album(let a):
            Artwork(
                url: model.imageURL(for: a.id, tag: a.imageTag, maxWidth: 120),
                seed: a.name,
                size: 34,
                radius: 4,
                targetPixelSize: CGSize(width: 102, height: 102)
            )
            .frame(width: 34, height: 34)
        case .track(let t):
            Artwork(
                url: model.imageURL(for: t.albumId ?? t.id, tag: t.imageTag, maxWidth: 120),
                seed: t.name,
                size: 34,
                radius: 4,
                targetPixelSize: CGSize(width: 102, height: 102)
            )
            .frame(width: 34, height: 34)
        case .playlist(let p):
            Artwork(
                url: model.imageURL(for: p.id, tag: p.imageTag, maxWidth: 120),
                seed: p.name,
                size: 34,
                radius: 4,
                targetPixelSize: CGSize(width: 102, height: 102)
            )
            .frame(width: 34, height: 34)
        }
    }

    /// Secondary line — artist for tracks/albums, counts for artists. Genres
    /// get nothing (the type label alone is enough).
    private var subtitle: String? {
        switch item {
        case .track(let t):
            if let album = t.albumName, !album.isEmpty {
                return "\(t.artistName) \u{00B7} \(album)"
            }
            return t.artistName
        case .album(let a):
            return a.artistName
        case .artist(let a):
            return CountStrings.label(Int(a.albumCount), .albums)
        case .playlist(let p):
            return CountStrings.label(Int(p.trackCount), .tracks)
        case .genre:
            return nil
        }
    }
}

// MARK: - View-model

/// Headless, testable engine behind `InstantMixSheet` (#327).
///
/// Owns the search query, a debounced/cancellable fetch, the category filter,
/// the flattened candidate list, and the chosen seed. Deliberately holds no
/// reference to `AppModel`: the two side-effecting hooks it needs are injected
/// as closures (`search` for the FFI-backed lookup, `onGenerate` for handing
/// the chosen seed back), so the suite can drive it with deterministic data
/// and assert on `candidates` / `canGenerate` / generate-dispatch without any
/// network or scene graph.
@MainActor
@Observable
final class InstantMixSeedPickerModel {
    /// Seed-kind filter chip. `all` unions every kind; the rest scope the
    /// candidate list to a single seed type.
    enum SeedCategory: String, CaseIterable, Hashable, Sendable {
        case all, tracks, albums, artists, genres

        var label: LocalizedStringKey {
            switch self {
            case .all: return "instant_mix.picker.category.all"
            case .tracks: return "instant_mix.picker.category.tracks"
            case .albums: return "instant_mix.picker.category.albums"
            case .artists: return "instant_mix.picker.category.artists"
            case .genres: return "instant_mix.picker.category.genres"
            }
        }
    }

    /// Bound to the search field's text.
    var query: String = ""

    /// Active seed-kind filter. Re-filtering is pure (`candidates` recomputes
    /// off `lastResults`), so flipping a chip never re-hits the network.
    var category: SeedCategory = .all

    /// Spinner state for the search field.
    private(set) var isSearching: Bool = false

    /// Raw results from the most recent successful search, retained so a
    /// category change can re-bucket locally without a refetch. `nil` until
    /// the first search resolves (or after the query is cleared).
    private(set) var lastResults: SearchResults?

    /// The seed the user has chosen. `nil` disables Generate.
    private(set) var selectedSeed: SearchItem?

    /// Debounce interval before a keystroke triggers a fetch. Matches the
    /// instant-search dropdown's 250ms cadence.
    private let debounceNanos: UInt64

    private let search: (String) async -> SearchResults?
    private let onGenerate: (SearchItem) -> Void
    private var searchTask: Task<Void, Never>?

    init(
        debounceNanos: UInt64 = 250_000_000,
        search: @escaping (String) async -> SearchResults?,
        onGenerate: @escaping (SearchItem) -> Void
    ) {
        self.debounceNanos = debounceNanos
        self.search = search
        self.onGenerate = onGenerate
    }

    /// The flattened, filtered list of seed candidates the sheet renders.
    /// Derived purely from `lastResults` + `category` so the view never has
    /// to re-partition and tests can assert on it directly.
    var candidates: [SearchItem] {
        guard let results = lastResults else { return [] }
        return Self.seedCandidates(from: results, category: category)
    }

    /// Generate is actionable only once a seed is chosen.
    var canGenerate: Bool { selectedSeed != nil }

    /// Choose (or, if tapped again, keep) a seed. Selecting a row that's
    /// already selected is a no-op rather than a toggle-off — a picker should
    /// always leave *something* selected once the user has committed to one,
    /// so an accidental second tap doesn't silently disable Generate.
    func select(_ item: SearchItem) {
        selectedSeed = item
    }

    /// Hand the chosen seed back to the host (which performs the actual
    /// `instantMix` FFI) and tear down any in-flight search. No-op when
    /// nothing is selected, so a stray Return on an empty picker is harmless.
    func generate() {
        guard let seed = selectedSeed else { return }
        searchTask?.cancel()
        onGenerate(seed)
    }

    /// Debounced search driven by the field's `onChange`. Cancels any prior
    /// in-flight pass, clears state immediately on an empty query, and drops
    /// a selection that's no longer present in the fresh candidate set so the
    /// footer never claims a seed the list no longer shows.
    func queryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastResults = nil
            selectedSeed = nil
            isSearching = false
            searchTask = nil
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceNanos)
            } catch {
                return // cancelled by the next keystroke
            }
            if Task.isCancelled { return }
            let results = await self.search(trimmed)
            if Task.isCancelled { return }
            self.apply(results: results)
        }
    }

    /// Fold a fresh search response into state. Split out from `queryChanged`
    /// so tests can exercise the candidate/selection-pruning contract without
    /// waiting on the debounce timer.
    func apply(results: SearchResults?) {
        isSearching = false
        lastResults = results
        // Drop a stale selection if the new candidate set no longer contains
        // it (the user kept typing past the row they'd tapped).
        if let selected = selectedSeed,
           !Self.allCandidates(from: results).contains(where: { $0.id == selected.id }) {
            selectedSeed = nil
        }
    }

    // MARK: - Pure helpers (deterministic; unit-tested)

    /// Every seed candidate a response yields, unfiltered: artists, albums,
    /// tracks, then genres harvested from the album/artist `genres` arrays.
    /// Genres are reconstructed client-side (case-insensitive de-dupe,
    /// alpha-sorted) exactly like `AppModel.bucketSearchResults` because
    /// Jellyfin's combined search endpoint doesn't return genre items
    /// directly — the seed carries the display name, and
    /// `AppModel.generateInstantMix` resolves it to a UUID via
    /// `startGenreRadio`.
    nonisolated static func allCandidates(from results: SearchResults?) -> [SearchItem] {
        guard let results else { return [] }
        var items: [SearchItem] = []
        items.append(contentsOf: results.artists.map(SearchItem.artist))
        items.append(contentsOf: results.albums.map(SearchItem.album))
        items.append(contentsOf: results.tracks.map(SearchItem.track))
        items.append(contentsOf: genres(from: results).map(SearchItem.genre))
        return items
    }

    /// `allCandidates` narrowed to a single seed kind (or unchanged for `.all`).
    nonisolated static func seedCandidates(
        from results: SearchResults,
        category: SeedCategory
    ) -> [SearchItem] {
        let all = allCandidates(from: results)
        switch category {
        case .all:
            return all
        case .tracks:
            return all.filter { if case .track = $0 { return true }; return false }
        case .albums:
            return all.filter { if case .album = $0 { return true }; return false }
        case .artists:
            return all.filter { if case .artist = $0 { return true }; return false }
        case .genres:
            return all.filter { if case .genre = $0 { return true }; return false }
        }
    }

    /// Distinct genres harvested from a response's album + artist genre
    /// arrays, case-insensitively de-duped and alpha-sorted.
    nonisolated static func genres(from results: SearchResults) -> [Genre] {
        var seen = Set<String>()
        var out: [Genre] = []
        let raw = results.albums.flatMap(\.genres) + results.artists.flatMap(\.genres)
        for name in raw {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(Genre(name: trimmed))
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }
}
