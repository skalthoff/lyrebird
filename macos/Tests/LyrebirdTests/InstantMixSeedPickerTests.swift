import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Instant Mix seed-picker (#327).
///
/// The picker's logic lives in the headless `InstantMixSeedPickerModel` so it
/// can be exercised without booting the SwiftUI scene graph or hitting the
/// network — the model takes its two side-effecting hooks (`search`,
/// `onGenerate`) as injected closures, and these tests feed it deterministic
/// `SearchResults` fixtures and capture the generated seed.
///
/// What's pinned:
/// 1. `seedCandidates` flattens artists/albums/tracks and reconstructs genres
///    from the album/artist `genres` arrays (deduped, alpha-sorted), matching
///    `AppModel.bucketSearchResults`'s genre derivation.
/// 2. The category chip narrows the candidate list to a single seed kind.
/// 3. Selection drives `canGenerate`; re-tapping a row keeps the selection.
/// 4. A fresh search prunes a now-absent selection but keeps a still-present one.
/// 5. `generate()` hands exactly the chosen seed to the host, and is inert
///    when nothing is selected.
/// 6. An emptied query resets results + selection.
///
/// The `AppModel`-side wiring (`presentInstantMixPicker` flips the sheet flag;
/// `generateInstantMix` records the seed label and dismisses) is also pinned.
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore` against a
/// throwaway data dir via `XDG_DATA_HOME`, so the suite never touches the real
/// database — we drive the view-model directly rather than the live FFI search.
@MainActor
final class InstantMixSeedPickerTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-instant-mix-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Fixtures

    private func makeTrack(id: String, name: String, artist: String = "Artist") -> Track {
        Track(
            id: id, name: name, albumId: nil, albumName: nil, artistName: artist,
            artistId: nil, indexNumber: nil, discNumber: nil, year: nil,
            runtimeTicks: 0, isFavorite: false, playCount: 0, container: nil,
            bitrate: nil, imageTag: nil, playlistItemId: nil, userData: nil
        )
    }

    private func makeAlbum(id: String, name: String, genres: [String] = []) -> Album {
        Album(
            id: id, name: name, artistName: "Artist", artistId: nil, year: nil,
            trackCount: 0, runtimeTicks: 0, genres: genres, imageTag: nil, userData: nil
        )
    }

    private func makeArtist(id: String, name: String, genres: [String] = []) -> Artist {
        Artist(
            id: id, name: name, albumCount: 0, songCount: 0, genres: genres,
            imageTag: nil, userData: nil
        )
    }

    private func results(
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = []
    ) -> SearchResults {
        SearchResults(
            artists: artists,
            albums: albums,
            tracks: tracks,
            totalRecordCount: UInt32(artists.count + albums.count + tracks.count)
        )
    }

    /// A picker wired to a fixed result set, capturing whatever seed gets
    /// generated. The `generated` box lets a test assert the dispatch.
    private func makePicker(
        returning fixture: SearchResults?,
        generated: @escaping (SearchItem) -> Void = { _ in }
    ) -> InstantMixSeedPickerModel {
        InstantMixSeedPickerModel(
            search: { _ in fixture },
            onGenerate: generated
        )
    }

    // MARK: - Candidate flattening + genre derivation

    func testSeedCandidatesFlattensEveryKind() {
        let r = results(
            artists: [makeArtist(id: "ar1", name: "Radiohead")],
            albums: [makeAlbum(id: "al1", name: "OK Computer")],
            tracks: [makeTrack(id: "t1", name: "Karma Police")]
        )
        let all = InstantMixSeedPickerModel.seedCandidates(from: r, category: .all)

        // Order is artists, then albums, then tracks, then genres.
        XCTAssertEqual(all.count, 3)
        if case .artist(let a) = all[0] { XCTAssertEqual(a.id, "ar1") } else { XCTFail("expected artist first") }
        if case .album(let a) = all[1] { XCTAssertEqual(a.id, "al1") } else { XCTFail("expected album second") }
        if case .track(let t) = all[2] { XCTAssertEqual(t.id, "t1") } else { XCTFail("expected track third") }
    }

    func testGenresDerivedDedupedAndSorted() {
        // Genres come off album + artist metadata; "Rock" appears thrice
        // across two casings and two records and must collapse to one.
        let r = results(
            artists: [makeArtist(id: "ar1", name: "A", genres: ["rock", "Jazz"])],
            albums: [makeAlbum(id: "al1", name: "B", genres: ["Rock", "Ambient"])]
        )
        let genres = InstantMixSeedPickerModel.seedCandidates(from: r, category: .genres)
        let names = genres.compactMap { item -> String? in
            if case .genre(let g) = item { return g.name }
            return nil
        }
        // Albums are harvested before artists, so the first-seen casing of the
        // shared genre is the album's ("Rock"); the artist's lowercase "rock"
        // is the de-duped duplicate. The whole list is then alpha-sorted
        // (case-insensitively), so "Rock" sorts last of the three.
        XCTAssertEqual(names, ["Ambient", "Jazz", "Rock"])
    }

    func testEmptyResultsYieldNoCandidates() {
        XCTAssertTrue(InstantMixSeedPickerModel.allCandidates(from: nil).isEmpty)
        XCTAssertTrue(InstantMixSeedPickerModel.allCandidates(from: results()).isEmpty)
    }

    // MARK: - Category filter

    func testCategoryFilterNarrowsToSingleKind() {
        let r = results(
            artists: [makeArtist(id: "ar1", name: "A")],
            albums: [makeAlbum(id: "al1", name: "B", genres: ["Jazz"])],
            tracks: [makeTrack(id: "t1", name: "C"), makeTrack(id: "t2", name: "D")]
        )

        let tracksOnly = InstantMixSeedPickerModel.seedCandidates(from: r, category: .tracks)
        XCTAssertEqual(tracksOnly.count, 2)
        XCTAssertTrue(tracksOnly.allSatisfy { if case .track = $0 { return true }; return false })

        let albumsOnly = InstantMixSeedPickerModel.seedCandidates(from: r, category: .albums)
        XCTAssertEqual(albumsOnly.count, 1)

        let genresOnly = InstantMixSeedPickerModel.seedCandidates(from: r, category: .genres)
        XCTAssertEqual(genresOnly.count, 1)
        if case .genre(let g) = genresOnly[0] { XCTAssertEqual(g.name, "Jazz") } else { XCTFail() }
    }

    func testCandidatesReflectActiveCategory() {
        let r = results(
            artists: [makeArtist(id: "ar1", name: "A")],
            tracks: [makeTrack(id: "t1", name: "C")]
        )
        let picker = makePicker(returning: r)
        picker.apply(results: r)

        XCTAssertEqual(picker.candidates.count, 2, "All shows artist + track")
        picker.category = .artists
        XCTAssertEqual(picker.candidates.count, 1)
        if case .artist = picker.candidates[0] {} else { XCTFail("artists chip should leave only the artist") }
    }

    // MARK: - Selection + canGenerate

    func testCanGenerateRequiresSelection() {
        let r = results(tracks: [makeTrack(id: "t1", name: "Seed")])
        let picker = makePicker(returning: r)
        picker.apply(results: r)

        XCTAssertFalse(picker.canGenerate, "nothing selected yet")
        picker.select(picker.candidates[0])
        XCTAssertTrue(picker.canGenerate)
    }

    func testReSelectingSameSeedKeepsItSelected() {
        let r = results(tracks: [makeTrack(id: "t1", name: "Seed")])
        let picker = makePicker(returning: r)
        picker.apply(results: r)
        let seed = picker.candidates[0]

        picker.select(seed)
        picker.select(seed) // second tap must not toggle off
        XCTAssertTrue(picker.canGenerate)
        XCTAssertEqual(picker.selectedSeed?.id, seed.id)
    }

    // MARK: - Stale-selection pruning across searches

    func testApplyDropsSelectionThatVanishesFromNewResults() {
        let first = results(tracks: [makeTrack(id: "t1", name: "First")])
        let picker = makePicker(returning: first)
        picker.apply(results: first)
        picker.select(picker.candidates[0])
        XCTAssertTrue(picker.canGenerate)

        // New search no longer contains t1 — selection must clear so the
        // footer can't claim a seed the list no longer shows.
        let second = results(tracks: [makeTrack(id: "t2", name: "Second")])
        picker.apply(results: second)
        XCTAssertNil(picker.selectedSeed)
        XCTAssertFalse(picker.canGenerate)
    }

    func testApplyKeepsSelectionStillPresentInNewResults() {
        let first = results(tracks: [makeTrack(id: "t1", name: "Keep"), makeTrack(id: "t2", name: "Other")])
        let picker = makePicker(returning: first)
        picker.apply(results: first)
        // Select t1.
        let keep = picker.candidates.first { $0.id == "track:t1" }!
        picker.select(keep)

        // A refined search still contains t1 — selection survives.
        let second = results(tracks: [makeTrack(id: "t1", name: "Keep")])
        picker.apply(results: second)
        XCTAssertEqual(picker.selectedSeed?.id, "track:t1")
        XCTAssertTrue(picker.canGenerate)
    }

    // MARK: - generate() dispatch

    func testGenerateHandsSelectedSeedToHost() {
        var captured: SearchItem?
        let r = results(albums: [makeAlbum(id: "al1", name: "Seed Album")])
        let picker = makePicker(returning: r, generated: { captured = $0 })
        picker.apply(results: r)
        picker.select(picker.candidates[0])

        picker.generate()
        XCTAssertEqual(captured?.id, "album:al1", "the chosen album must be the seed handed back")
    }

    func testGenerateIsInertWithoutSelection() {
        var fired = false
        let picker = makePicker(returning: results(), generated: { _ in fired = true })
        picker.generate()
        XCTAssertFalse(fired, "Generate with no seed selected must not dispatch")
    }

    // MARK: - Query reset

    func testEmptyingQueryClearsResultsAndSelection() {
        let r = results(tracks: [makeTrack(id: "t1", name: "Seed")])
        let picker = makePicker(returning: r)
        picker.apply(results: r)
        picker.select(picker.candidates[0])

        // Emptying the field synchronously tears everything down (no debounce
        // wait needed because the empty-query branch short-circuits).
        picker.query = "   "
        picker.queryChanged()
        XCTAssertTrue(picker.candidates.isEmpty)
        XCTAssertNil(picker.selectedSeed)
        XCTAssertFalse(picker.canGenerate)
    }

    // MARK: - AppModel wiring

    func testPresentInstantMixPickerFlipsFlag() throws {
        let model = try AppModel()
        XCTAssertFalse(model.isShowingInstantMixPicker, "sheet starts hidden")
        model.presentInstantMixPicker()
        XCTAssertTrue(model.isShowingInstantMixPicker)
    }

    func testGenerateInstantMixRecordsSeedLabelAndDismisses() throws {
        let model = try AppModel()
        model.isShowingInstantMixPicker = true

        let album = Album(
            id: "al1", name: "Kind of Blue", artistName: "Miles Davis", artistId: nil,
            year: nil, trackCount: 0, runtimeTicks: 0, genres: [], imageTag: nil, userData: nil
        )
        model.generateInstantMix(seed: .album(album))

        XCTAssertEqual(model.instantMixSeedLabel, "Kind of Blue", "seed label echoes the chosen item for the regenerate hint")
        XCTAssertFalse(model.isShowingInstantMixPicker, "generating dismisses the picker")
    }
}
