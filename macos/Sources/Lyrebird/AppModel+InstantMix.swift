import Foundation
@preconcurrency import LyrebirdCore

/// Instant Mix and radio-station seeding. Backs the Discover "Instant Mix"
/// CTA, the Home "Pinned Stations" tiles, the seed-picker sheet (driven by
/// `isShowingInstantMixPicker` / `instantMixSeedLabel`), and the "Shuffle All"
/// library affordance. `core.instantMix` is polymorphic over any item id
/// (track / album / artist / genre / playlist), so every entry point funnels
/// through `playInstantMix`; the FFI hops run off the MainActor per the
/// sync-FFI gap pattern. Stored state for the picker lives on the main
/// `AppModel` class — stored properties can't live in an extension. Extensions
/// of a `@MainActor` type inherit its isolation, so every method here is
/// main-actor-bound just like the rest of the class.
extension AppModel {
    /// Kick off a library-seeded Instant Mix from the Discover screen's CTA.
    /// Seeds off the currently-playing track if there is one; otherwise a
    /// random recently-played track; otherwise a random album. Keeps the
    /// action productive regardless of state.
    func startInstantMix() {
        let seedId: String? = {
            if let current = status.currentTrack { return current.id }
            if let recent = recentlyPlayed.first { return recent.id }
            return albums.first?.id
        }()
        guard let seedId else {
            errorMessage = "Nothing to seed a mix from yet — play a track first."
            return
        }
        playInstantMix(seedId: seedId)
    }

    /// Start a radio station seeded from a pinned-station subject (#253). The
    /// Home "Pinned Stations" row routes artist / mood / mix tiles here; the
    /// stored id is a real Jellyfin item id (or a mood/mix seed), which
    /// `core.instantMix` accepts polymorphically. Genre and playlist tiles
    /// take their own routes (`browseGenre` / `navigate(to:.playlist)`).
    func startStationRadio(seedId: String) {
        playInstantMix(seedId: seedId)
    }

    /// Re-seed the Instant Mix with a different track than the current one.
    /// Picks a random track from `recentlyPlayed` excluding the currently-
    /// playing track, so "Generate new mix" actually sounds different. Falls
    /// back to `startInstantMix` when there is nothing else to pick from.
    func regenerateInstantMix() {
        let currentId = status.currentTrack?.id
        let candidates = recentlyPlayed.filter { $0.id != currentId }
        if let seed = candidates.randomElement() {
            playInstantMix(seedId: seed.id)
        } else {
            startInstantMix()
        }
    }

    /// Present the Instant Mix seed-picker sheet (#327). The sheet lets the
    /// user search for and pick any track / album / artist / genre to seed a
    /// fresh radio station, rather than relying on the implicit "currently
    /// playing" seed that `startInstantMix` uses. Mounted on `MainShell`
    /// driven by `isShowingInstantMixPicker`; wired to the View ▸ "New
    /// Instant Mix…" menu command.
    func presentInstantMixPicker() {
        isShowingInstantMixPicker = true
    }

    /// Generate an Instant Mix from an explicitly chosen seed (#327). The
    /// seed-picker sheet hands back a heterogeneous `SearchItem`; we dispatch
    /// on its case because the seed id semantics differ:
    ///
    /// - Tracks / albums / artists carry a real Jellyfin UUID, so they feed
    ///   `playInstantMix` directly.
    /// - Genres surfaced by search only carry the display name as their id
    ///   (`Genre.init(name:)`), so they route through `startGenreRadio`,
    ///   which resolves the name → real UUID before seeding. Playlists aren't
    ///   offered as a seed by the picker today, but fall through to the
    ///   direct path should the picker ever surface one.
    ///
    /// Records the seed's display name in `instantMixSeedLabel` so a re-open
    /// of the picker can offer a one-tap regenerate, then dismisses the sheet.
    func generateInstantMix(seed: SearchItem) {
        switch seed {
        case .track(let t):
            instantMixSeedLabel = t.name
            playInstantMix(seedId: t.id)
        case .album(let a):
            instantMixSeedLabel = a.name
            playInstantMix(seedId: a.id)
        case .artist(let a):
            instantMixSeedLabel = a.name
            playInstantMix(seedId: a.id)
        case .playlist(let p):
            instantMixSeedLabel = p.name
            playInstantMix(seedId: p.id)
        case .genre(let g):
            instantMixSeedLabel = g.name
            startGenreRadio(genre: g)
        }
        isShowingInstantMixPicker = false
    }

    /// Read-only search used by the Instant Mix seed picker (#327). Returns a
    /// raw `SearchResults` without touching any of the page-level search
    /// state (`searchResults`, `searchPageResults`, …) so opening the picker
    /// never disturbs the standalone Search screen the user may have set up.
    /// The FFI hop runs off the MainActor per CLAUDE.md gap pattern #2;
    /// errors collapse to `nil` because the picker treats "no matches" and
    /// "search failed" identically (an empty candidate list), and a flaky
    /// keystroke shouldn't raise an error banner mid-typing.
    func searchSeeds(query: String, limit: UInt32 = 20) async -> SearchResults? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { [core] in
            try? core.search(query: trimmed, offset: 0, limit: limit)
        }.value
    }

    /// Common driver for every "Start Radio" entry point. `core.instantMix`
    /// is polymorphic — any item id (track, album, artist, genre, playlist)
    /// works. Wraps the FFI hop in `Task.detached` so the main actor doesn't
    /// block on a network round-trip.
    func playInstantMix(seedId: String, limit: UInt32 = 50) {
        Task {
            do {
                let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                    try core.instantMix(itemId: seedId, limit: limit)
                }.value
                guard !tracks.isEmpty else { return }
                play(tracks: tracks, startIndex: 0)
            } catch {
                if handleAuthError(error) { return }
                if ServerReachability.shouldCount(error: error) {
                    serverReachability.noteFailure()
                }
                errorMessage = "Couldn't start radio: \(error.localizedDescription)"
            }
        }
    }

    /// Shuffle the entire library — loads tracks from a handful of random
    /// albums, interleaves them into one queue, shuffles, and plays.
    ///
    /// Powers the "Shuffle All" CTA on the Home greeting header (#204). The
    /// core doesn't expose a "list every track" primitive yet (see #465), so
    /// we draw from the albums already loaded on the Home screen and assemble
    /// a queue of up to ~200 tracks. Good enough as a "play my library"
    /// affordance until a server-side random-songs endpoint lands.
    func shuffleLibrary() {
        guard !albums.isEmpty else { return }
        Task {
            // Draw from a random sample of albums so repeat presses don't
            // always yield the same seed set. Cap the sample so we don't
            // fan-out hundreds of `albumTracks` calls in a single tap.
            let sampleSize = min(albums.count, 25)
            let sampled = Array(albums.shuffled().prefix(sampleSize))
            var collected: [Track] = []
            for album in sampled {
                let tracks = await loadTracks(forAlbum: album.id)
                collected.append(contentsOf: tracks)
                // Cap total queue length — mirrors other "play a lot" flows.
                if collected.count >= 200 { break }
            }
            guard !collected.isEmpty else { return }
            play(tracks: collected.shuffled(), startIndex: 0)
        }
    }
}
