import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Genre browsing/actions and the Decade / Mood "radio" stations. Backs
/// `GenreContextMenu` / `GenreDetailView` and the Discover/Home radio surface:
/// resolve a genre name to its Jellyfin UUID, browse / instant-mix / shuffle a
/// genre, load a genre's albums & tracks, pin a genre to Home, and assemble
/// shuffled Decade- and Mood-tagged stations via the raw `/Items` query.
///
/// The genre/radio stored state (`_genreIdsByName`, `_genresLoaded`,
/// `availableMoods`) stays on the main `AppModel` class — stored properties
/// can't live in an extension. Extensions of a `@MainActor` type inherit its
/// isolation, so every method here is main-actor-bound just like the rest of
/// the class.
extension AppModel {
    // MARK: - Genre actions
    //
    // Backing calls for `GenreContextMenu` + `GenreDetailView`. Genres
    // surface as bare strings on `Album` / `Artist` records, but the
    // genre-scoped FFIs (`tracksByGenre`, `itemsByGenre`, `instantMix`)
    // require a real Jellyfin UUID. `resolvedGenreId(forName:)` lazily
    // loads `/MusicGenres` once and caches the name→UUID map so the
    // three actions below can dispatch on the real id without each call
    // site re-fetching. See #823 Wave 2.

    /// Resolve a Swift-side display name to the real Jellyfin UUID via
    /// the lazy `/MusicGenres` cache. Returns `nil` when the name has no
    /// match (genre exists in Album/Artist metadata but not as its own
    /// `MusicGenre` item — possible for empty / freshly-tagged genres).
    /// The FFI call runs off the MainActor per CLAUDE.md gap pattern #2.
    private func resolvedGenreId(forName name: String) async -> String? {
        if !_genresLoaded {
            let pairs: [(String, String)]? = await Task.detached(priority: .userInitiated) { [core] in
                (try? core.genres(offset: 0, limit: 500))?.items.map { ($0.name, $0.id) }
            }.value
            guard let pairs else { return nil }
            _genreIdsByName = Dictionary(uniqueKeysWithValues: pairs)
            _genresLoaded = true
        }
        return _genreIdsByName[name]
    }

    /// Open the genre detail screen. Resolves the display name to a real
    /// Jellyfin UUID first so downstream FFIs in `GenreDetailView` get a
    /// UUID instead of the name string.
    func browseGenre(genre: Genre) {
        Task { @MainActor in
            guard let realId = await resolvedGenreId(forName: genre.name) else {
                errorMessage = "Genre '\(genre.name)' not found on server"
                return
            }
            // Push a Genre carrying the resolved UUID so downstream FFI
            // calls in GenreDetailView don't have to re-resolve.
            navigate(to: .genre(Genre(id: realId, name: genre.name)))
        }
    }

    /// Kick off an Instant Mix seeded by this genre. Fixes the prior
    /// UUID-mismatch bug where the genre *name* was passed to
    /// `core.instantMix(itemId:)` which expects a UUID.
    func startGenreRadio(genre: Genre) {
        Task { @MainActor in
            guard let realId = await resolvedGenreId(forName: genre.name) else {
                errorMessage = "Genre '\(genre.name)' not found on server"
                return
            }
            playInstantMix(seedId: realId, seedName: genre.name)
        }
    }

    /// Shuffle every track in this genre. Loads the first 500-track page
    /// via `core.tracksByGenre`, shuffles client-side, then plays.
    func shuffleGenre(genre: Genre) {
        Task { @MainActor in
            guard let realId = await resolvedGenreId(forName: genre.name) else {
                errorMessage = "Genre '\(genre.name)' not found on server"
                return
            }
            do {
                let page = try await Task.detached(priority: .userInitiated) { [core] in
                    try core.tracksByGenre(genreId: realId, offset: 0, limit: 500)
                }.value
                let tracks = page.items
                guard !tracks.isEmpty else { return }
                play(tracks: tracks.shuffled(), startIndex: 0)
            } catch {
                if handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = "Couldn't load tracks for \(genre.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Decade / Mood radio (#256)
    //
    // The Discover/Home "Radio" surface offers Genre, Decade, and Mood
    // stations (per `06-screen-specs.md` §9). Genre radio reuses
    // `startGenreRadio` (Instant Mix seeded by the genre). Decade and Mood
    // have no Instant-Mix seed item, so they assemble a shuffled station out
    // of a random page of audio tracks matching the decade's ten-year
    // `Years` window / the mood `Tag`, then play it like any other queue.
    // We go through the raw `/Items` query (the established
    // `buildItemsQuery` pattern) rather than a new core FFI because the
    // dimensions we need — `Years`, `Tags` — are just extra query params.

    /// The fixed mood set the spec calls for, each backed by a Jellyfin tag.
    /// `tag` is matched case-insensitively server-side; `label`/`symbol` drive
    /// the tile. Only moods whose tag actually returns tracks are surfaced
    /// (see `availableMoods`), so a library with no mood tags shows no row.
    struct Mood: Identifiable, Hashable, Sendable {
        let tag: String
        let label: String
        let symbol: String

        var id: String { tag }

        /// The five moods from `06-screen-specs.md` §9, in spec order.
        static let all: [Mood] = [
            Mood(tag: "chill", label: "Chill", symbol: "leaf"),
            Mood(tag: "focus", label: "Focus", symbol: "scope"),
            Mood(tag: "workout", label: "Workout", symbol: "figure.run"),
            Mood(tag: "sleep", label: "Sleep", symbol: "moon.stars"),
            Mood(tag: "party", label: "Party", symbol: "party.popper"),
        ]
    }

    /// Best-effort probe of which spec moods have any tagged tracks. Fires one
    /// tiny (`limit: 1`) `/Items` HEAD-style fetch per mood concurrently and
    /// keeps only the moods that came back non-empty. Idempotent and cheap;
    /// safe to call on Discover/Home appearance. Failures (auth/network) leave
    /// `availableMoods` unchanged rather than blanking an already-populated row.
    func probeAvailableMoods() async {
        guard session != nil else { return }
        let present = await withTaskGroup(of: Mood?.self) { group in
            for mood in Mood.all {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    let hit = await self.moodHasTracks(tag: mood.tag)
                    return hit ? mood : nil
                }
            }
            var found: [Mood] = []
            for await result in group {
                if let mood = result { found.append(mood) }
            }
            return found
        }
        guard !present.isEmpty else { return }
        // Re-order to the canonical spec order rather than completion order.
        availableMoods = Mood.all.filter { mood in present.contains(mood) }
    }

    /// Does the given mood tag have at least one audio track? One `limit: 1`
    /// `/Items` probe; returns false on auth/network/parse failure.
    private func moodHasTracks(tag: String) async -> Bool {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "Random",
            sortOrder: "Ascending",
            filters: nil,
            limit: 1,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil,
            tags: [tag]
        ) else { return false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return false
            }
            return !Self.parseTracksFromItems(data: data).isEmpty
        } catch {
            return false
        }
    }

    /// Start a Decade Radio station — a shuffled queue of audio tracks whose
    /// `ProductionYear` falls inside the decade's ten-year window. Replaces the
    /// queue and plays from the top. Surfaces `errorMessage` when the decade
    /// has no tracks (rather than silently no-op'ing).
    func startDecadeRadio(startingYear start: Int) {
        let years = Array(start...(start + 9))
        Task {
            let tracks = await fetchRadioTracks(years: years, tags: nil)
            guard !tracks.isEmpty else {
                errorMessage = "No tracks from the \(start)s in your library yet."
                return
            }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Start a Mood Radio station — a shuffled queue of audio tracks carrying
    /// the mood's Jellyfin tag. Replaces the queue and plays from the top.
    func startMoodRadio(mood: Mood) {
        Task {
            let tracks = await fetchRadioTracks(years: nil, tags: [mood.tag])
            guard !tracks.isEmpty else {
                errorMessage = "No \(mood.label) tracks in your library yet."
                return
            }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Fetch up to `limit` random audio tracks matching the given `Years`
    /// window and/or `Tags`, already server-shuffled (`SortBy=Random`). Backs
    /// the Decade and Mood radio stations. Returns `[]` on auth/network/parse
    /// failure (the callers turn an empty result into a user-facing message).
    private func fetchRadioTracks(years: [Int]?, tags: [String]?, limit: UInt32 = 100) async -> [Track] {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "Random",
            sortOrder: "Ascending",
            filters: nil,
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil,
            years: years,
            tags: tags
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseTracksFromItems(data: data)
        } catch {
            Log.net.error("fetchRadioTracks failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Internal: load a page of albums tagged with the given resolved
    /// genre UUID. Used by `GenreDetailView` for the albums shelf. The
    /// FFI call runs off the MainActor per CLAUDE.md gap pattern #2.
    func loadAlbums(forGenreId genreId: String, limit: UInt32 = 50) async -> [Album] {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.itemsByGenre(genreId: genreId, offset: 0, limit: limit)
            }.value
            return page.items
        } catch {
            if !handleAuthError(error) {
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
            }
            return []
        }
    }

    /// Internal: load a page of tracks tagged with the given resolved
    /// genre UUID. Used by `GenreDetailView` for the tracks shelf. The
    /// FFI call runs off the MainActor per CLAUDE.md gap pattern #2.
    func loadTracks(forGenreId genreId: String, limit: UInt32 = 50) async -> [Track] {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.tracksByGenre(genreId: genreId, offset: 0, limit: limit)
            }.value
            return page.items
        } catch {
            if !handleAuthError(error) {
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = LyrebirdErrorPresenter.message(for: error, context: .libraryLoad)
            }
            return []
        }
    }

    /// Pin a genre tile to the Home screen so the user can one-click-browse.
    /// Persists into `PinnedStationsStore` — the placeholder JSON-in-UserDefaults
    /// bridge that backs the Home pinned-stations row (#253). When a real pin
    /// FFI lands this body becomes a thin adapter; the signature stays.
    func pinGenreToHome(genre: Genre) {
        var stations = PinnedStationsStore.load()
        // Dedup: drop any existing entry with the same id so we don't double-pin.
        stations.removeAll { $0.id == genre.id }
        stations.insert(PinnedStation(type: .genre, id: genre.id, title: genre.name), at: 0)
        // Cap at 6 — matches the Home shelf layout in PinnedStationTile.
        if stations.count > 6 { stations = Array(stations.prefix(6)) }
        PinnedStationsStore.save(stations)
    }
}
