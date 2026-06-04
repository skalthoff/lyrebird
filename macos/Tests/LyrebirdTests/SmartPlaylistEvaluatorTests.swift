import XCTest
@testable import Lyrebird
import LyrebirdCore

/// Coverage for `SmartPlaylistEvaluator` — the pure, deterministic filter at
/// the heart of smart playlists (#77 / #238). Every field × operator path,
/// both match modes, the album→track genre projection, relative-date
/// (`.inLast`) windows against an injected clock, unparseable-value safety,
/// result ordering, and the concrete `Track`/`Album` FFI entry point all
/// pin here. No network, no clock except the one passed in.
final class SmartPlaylistEvaluatorTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a `TrackFacts` fixture with sensible defaults so each test only
    /// states the attributes it cares about.
    private func facts(
        id: String = "t",
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        genres: [String] = [],
        year: Int? = nil,
        playCount: Int = 0,
        isFavorite: Bool = false,
        dateAdded: Date? = nil
    ) -> TrackFacts {
        TrackFacts(
            id: id, title: title, artist: artist, album: album,
            genres: genres, year: year, playCount: playCount,
            isFavorite: isFavorite, dateAdded: dateAdded
        )
    }

    private func playlist(
        _ mode: SmartPlaylistMatchMode = .all,
        _ rules: [SmartPlaylistRule]
    ) -> SmartPlaylist {
        SmartPlaylist(name: "Test", matchMode: mode, rules: rules)
    }

    private func rule(_ f: SmartPlaylistField, _ o: SmartPlaylistOperator, _ v: String) -> SmartPlaylistRule {
        SmartPlaylistRule(field: f, op: o, value: v)
    }

    // MARK: - Empty rule set

    /// A rule-less playlist matches every track (iTunes parity), preserving
    /// input order.
    func testEmptyRulesMatchEverything() {
        let tracks = [facts(id: "a"), facts(id: "b"), facts(id: "c")]
        let result = SmartPlaylistEvaluator.evaluate(playlist(.all, []), over: tracks)
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Text operators

    func testTextIsMatchesExactCaseInsensitive() {
        let r = rule(.artist, .is, "radiohead")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(artist: "Radiohead"), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(artist: "Radio"), rule: r))
    }

    func testTextIsIsDiacriticInsensitive() {
        let r = rule(.artist, .is, "bjork")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(artist: "Björk"), rule: r))
    }

    func testTextIsNot() {
        let r = rule(.artist, .isNot, "Radiohead")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(artist: "Radiohead"), rule: r))
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(artist: "Muse"), rule: r))
    }

    func testTextContains() {
        let r = rule(.album, .contains, "hits")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(album: "Greatest Hits"), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(album: "Debut"), rule: r))
    }

    /// `contains` with an empty needle never matches (it would otherwise be
    /// trivially true and silently widen a playlist).
    func testTextContainsEmptyNeedleNeverMatches() {
        let r = rule(.album, .contains, "   ")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(album: "Anything"), rule: r))
    }

    /// Surrounding whitespace in the rule value is trimmed before comparison.
    func testTextIsTrimsWhitespace() {
        let r = rule(.artist, .is, "  Radiohead  ")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(artist: "Radiohead"), rule: r))
    }

    /// Ordering / recency operators are out of domain for text and must
    /// no-match rather than widen the set.
    func testTextWithNumericOperatorNeverMatches() {
        let r = rule(.artist, .greaterThan, "M")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(artist: "Zelda"), rule: r))
    }

    // MARK: - Genre (multi-valued, via album)

    /// Genre is multi-valued: the rule holds if *any* of the track's genres
    /// satisfies it.
    func testGenreContainsMatchesAnyGenre() {
        let r = rule(.genre, .contains, "rock")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(genres: ["Jazz", "Indie Rock"]), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(genres: ["Jazz", "Blues"]), rule: r))
    }

    func testGenreIsMatchesOneOfSeveral() {
        let r = rule(.genre, .is, "Electronic")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(genres: ["Pop", "Electronic"]), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(genres: ["Pop"]), rule: r))
    }

    /// A track with no genres can't satisfy a genre rule.
    func testGenreRuleWithNoGenresNeverMatches() {
        let r = rule(.genre, .contains, "Rock")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(genres: []), rule: r))
    }

    /// Some Jellyfin libraries return a track's genres as a single
    /// semicolon-joined element ("Pop;Folk Pop;Rock") rather than a split
    /// array. The evaluator splits on `;` so an exact `is` rule still matches
    /// a constituent genre — not just `contains`. Pins the real-server shape
    /// observed during the #77 work.
    func testGenreSemicolonJoinedSplitsForExactMatch() {
        let joined = facts(genres: ["Pop;Folk Pop;Pop Rock;Rock;Soul"])
        XCTAssertTrue(SmartPlaylistEvaluator.matches(joined, rule: rule(.genre, .is, "Rock")))
        XCTAssertTrue(SmartPlaylistEvaluator.matches(joined, rule: rule(.genre, .is, "Folk Pop")))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(joined, rule: rule(.genre, .is, "Jazz")))
    }

    // MARK: - Number operators (year / playCount)

    func testYearGreaterThan() {
        let r = rule(.year, .greaterThan, "2000")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(year: 2010), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 1999), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 2000), rule: r), "strict >")
    }

    func testYearLessThanAndIs() {
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(year: 1980), rule: rule(.year, .lessThan, "1990")))
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(year: 1990), rule: rule(.year, .is, "1990")))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 1991), rule: rule(.year, .is, "1990")))
    }

    /// A nil year (track has no release year) never satisfies a year rule.
    func testYearNilNeverMatches() {
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: nil), rule: rule(.year, .greaterThan, "0")))
    }

    func testPlayCountGreaterThan() {
        let r = rule(.playCount, .greaterThan, "5")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(playCount: 10), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(playCount: 5), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(playCount: 0), rule: r))
    }

    func testPlayCountIsNot() {
        let r = rule(.playCount, .isNot, "0")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(playCount: 3), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(playCount: 0), rule: r))
    }

    /// An unparseable numeric value (e.g. "abc") makes the rule
    /// unsatisfiable rather than crashing or matching everything.
    func testNumberUnparseableValueNeverMatches() {
        let r = rule(.year, .greaterThan, "nineteen")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 2020), rule: r))
    }

    // MARK: - Boolean operator (isFavorite)

    func testIsFavoriteIsTrue() {
        let r = rule(.isFavorite, .is, "true")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(isFavorite: true), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(isFavorite: false), rule: r))
    }

    func testIsFavoriteIsFalse() {
        let r = rule(.isFavorite, .is, "false")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(isFavorite: false), rule: r))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(isFavorite: true), rule: r))
    }

    /// Boolean parsing accepts common synonyms a hand-edited file might use.
    func testBooleanSynonyms() {
        XCTAssertEqual(SmartPlaylistEvaluator.parseBool("yes"), true)
        XCTAssertEqual(SmartPlaylistEvaluator.parseBool("NO"), false)
        XCTAssertEqual(SmartPlaylistEvaluator.parseBool("1"), true)
        XCTAssertEqual(SmartPlaylistEvaluator.parseBool("0"), false)
        XCTAssertNil(SmartPlaylistEvaluator.parseBool("maybe"))
    }

    // MARK: - Date operators (relative, injected clock)

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testDateInLastWindow() {
        let now = date("2026-06-04T12:00:00Z")
        let r = rule(.dateAdded, .inLast, "30")
        // 10 days ago — inside the 30-day window.
        XCTAssertTrue(SmartPlaylistEvaluator.matches(
            facts(dateAdded: date("2026-05-25T12:00:00Z")), rule: r, now: now))
        // 60 days ago — outside.
        XCTAssertFalse(SmartPlaylistEvaluator.matches(
            facts(dateAdded: date("2026-04-05T12:00:00Z")), rule: r, now: now))
    }

    /// A track with no date (never played) can't be "in the last N days".
    func testDateInLastWithNilDateNeverMatches() {
        let now = date("2026-06-04T12:00:00Z")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(
            facts(dateAdded: nil), rule: rule(.dateAdded, .inLast, "30"), now: now))
    }

    /// A non-positive / unparseable day count never matches.
    func testDateInLastZeroDaysNeverMatches() {
        let now = date("2026-06-04T12:00:00Z")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(
            facts(dateAdded: date("2026-06-04T11:00:00Z")), rule: rule(.dateAdded, .inLast, "0"), now: now))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(
            facts(dateAdded: date("2026-06-04T11:00:00Z")), rule: rule(.dateAdded, .inLast, "abc"), now: now))
    }

    /// `lessThan` on a date means "older than N days ago".
    func testDateLessThanIsOlderThan() {
        let now = date("2026-06-04T12:00:00Z")
        let r = rule(.dateAdded, .lessThan, "30") // older than 30 days ago
        XCTAssertTrue(SmartPlaylistEvaluator.matches(
            facts(dateAdded: date("2026-01-01T00:00:00Z")), rule: r, now: now))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(
            facts(dateAdded: date("2026-06-01T00:00:00Z")), rule: r, now: now))
    }

    // MARK: - Match modes

    func testMatchAllRequiresEveryRule() {
        let p = playlist(.all, [
            rule(.year, .greaterThan, "1989"),
            rule(.year, .lessThan, "2000"),
        ])
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(year: 1995), playlist: p))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 2005), playlist: p), "fails upper bound")
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 1980), playlist: p), "fails lower bound")
    }

    func testMatchAnyRequiresOneRule() {
        let p = playlist(.any, [
            rule(.artist, .is, "Radiohead"),
            rule(.isFavorite, .is, "true"),
        ])
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(artist: "Radiohead", isFavorite: false), playlist: p))
        XCTAssertTrue(SmartPlaylistEvaluator.matches(facts(artist: "Muse", isFavorite: true), playlist: p))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(artist: "Muse", isFavorite: false), playlist: p))
    }

    // MARK: - Whole-set evaluation + ordering

    /// `evaluate` filters the set and preserves input order.
    func testEvaluatePreservesOrder() {
        let tracks = [
            facts(id: "1", artist: "Muse", isFavorite: true),
            facts(id: "2", artist: "Radiohead", isFavorite: false),
            facts(id: "3", artist: "Muse", isFavorite: false),
            facts(id: "4", artist: "Muse", isFavorite: true),
        ]
        let p = playlist(.all, [rule(.artist, .is, "Muse"), rule(.isFavorite, .is, "true")])
        let result = SmartPlaylistEvaluator.evaluate(p, over: tracks)
        XCTAssertEqual(result.map(\.id), ["1", "4"])
    }

    // MARK: - Concrete Track/Album FFI path

    private func makeTrack(
        id: String,
        name: String = "Song",
        albumId: String? = nil,
        albumName: String? = nil,
        artistName: String = "Artist",
        year: Int32? = nil,
        isFavorite: Bool = false,
        playCount: UInt32 = 0,
        userData: UserItemData? = nil
    ) -> Track {
        Track(
            id: id, name: name, albumId: albumId, albumName: albumName,
            artistName: artistName, artistId: nil, indexNumber: nil,
            discNumber: nil, year: year, runtimeTicks: 0,
            isFavorite: isFavorite, playCount: playCount, container: nil,
            bitrate: nil, imageTag: nil, playlistItemId: nil, userData: userData
        )
    }

    private func makeAlbum(id: String, genres: [String]) -> Album {
        Album(
            id: id, name: "Album", artistName: "Artist", artistId: nil,
            year: nil, trackCount: 0, runtimeTicks: 0, genres: genres,
            imageTag: nil, userData: nil
        )
    }

    /// The `Track`/`Album` entry point projects album genres onto the album's
    /// tracks and filters them. A genre rule matches a track whose *album*
    /// carries the genre, even though `Track` itself has no genres.
    func testEvaluateOverTracksProjectsAlbumGenres() {
        let albums = [
            makeAlbum(id: "alb-rock", genres: ["Rock"]),
            makeAlbum(id: "alb-jazz", genres: ["Jazz"]),
        ]
        let tracks = [
            makeTrack(id: "t1", albumId: "alb-rock"),
            makeTrack(id: "t2", albumId: "alb-jazz"),
            makeTrack(id: "t3", albumId: "alb-rock"),
            makeTrack(id: "t4", albumId: nil), // no album → no genres
        ]
        let p = playlist(.all, [rule(.genre, .is, "Rock")])
        let result = SmartPlaylistEvaluator.evaluate(p, tracks: tracks, albums: albums)
        XCTAssertEqual(result.map(\.id), ["t1", "t3"])
    }

    /// `matchCount` agrees with the materialized filter count and avoids
    /// building the array.
    func testMatchCountAgreesWithEvaluate() {
        let albums = [makeAlbum(id: "alb", genres: ["Pop"])]
        let tracks = [
            makeTrack(id: "t1", albumId: "alb", isFavorite: true),
            makeTrack(id: "t2", albumId: "alb", isFavorite: false),
            makeTrack(id: "t3", albumId: "alb", isFavorite: true),
        ]
        let p = playlist(.all, [rule(.isFavorite, .is, "true")])
        let filtered = SmartPlaylistEvaluator.evaluate(p, tracks: tracks, albums: albums)
        let count = SmartPlaylistEvaluator.matchCount(p, tracks: tracks, albums: albums)
        XCTAssertEqual(count, filtered.count)
        XCTAssertEqual(count, 2)
    }

    /// `TrackFacts(track:)` prefers the richer `UserData` projection over the
    /// convenience mirror for play count + favorite.
    func testTrackAdapterPrefersUserData() {
        let ud = UserItemData(
            isFavorite: true, played: true, playCount: 42,
            playbackPositionTicks: 0, lastPlayedAt: nil, likes: nil, rating: nil
        )
        // Mirror fields deliberately disagree with UserData to prove which wins.
        let track = makeTrack(id: "t", isFavorite: false, playCount: 1, userData: ud)
        let f = TrackFacts(track: track)
        XCTAssertEqual(f.playCount, 42)
        XCTAssertTrue(f.isFavorite)
    }

    /// `TrackFacts(track:)` falls back to the convenience mirror when there's
    /// no `UserData` (snapshot fetched without `Fields=UserData`).
    func testTrackAdapterFallsBackToMirror() {
        let track = makeTrack(id: "t", isFavorite: true, playCount: 7, userData: nil)
        let f = TrackFacts(track: track)
        XCTAssertEqual(f.playCount, 7)
        XCTAssertTrue(f.isFavorite)
        XCTAssertNil(f.dateAdded, "no UserData → no date")
    }

    /// "Date Added" is sourced from `UserData.lastPlayedAt` (the only
    /// per-track date the snapshot exposes) and parsed from Jellyfin's
    /// fractional-seconds ISO form.
    func testTrackAdapterParsesLastPlayedDate() {
        let ud = UserItemData(
            isFavorite: false, played: true, playCount: 1,
            playbackPositionTicks: 0,
            lastPlayedAt: "2026-05-01T08:30:00.0000000Z",
            likes: nil, rating: nil
        )
        let track = makeTrack(id: "t", userData: ud)
        let f = TrackFacts(track: track)
        XCTAssertNotNil(f.dateAdded)
        // Within the last 60 days of a June-2026 "now".
        let now = date("2026-06-04T12:00:00Z")
        XCTAssertTrue(SmartPlaylistEvaluator.matches(f, rule: rule(.dateAdded, .inLast, "60"), now: now))
    }

    // MARK: - Parsing helpers

    /// Numeric parsing is POSIX so a comma never reads as a decimal point.
    func testParseNumberIsPosix() {
        XCTAssertEqual(SmartPlaylistEvaluator.parseNumber("1999"), 1999)
        XCTAssertEqual(SmartPlaylistEvaluator.parseNumber("  42  "), 42)
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber(""))
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber("twelve"))
    }

    /// Non-finite values (`inf` / `nan`, which `Double.init` *does* accept)
    /// are rejected. `Double("inf")` would otherwise make a date rule's day
    /// count infinite (`threshold = now - inf*86400` is a `-inf` Date that
    /// matches or excludes every track) and `nan` poisons numeric
    /// comparisons; a finite check degrades both to "no value" (a visible
    /// empty result) instead of a silently-wrong filter.
    func testParseNumberRejectsNonFinite() {
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber("inf"))
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber("Infinity"))
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber("-inf"))
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber("nan"))
        XCTAssertNil(SmartPlaylistEvaluator.parseNumber("NaN"))
    }

    /// A date rule with an "inf" day count must not match every track. Before
    /// the finite guard, `parseNumber("inf")` → `.infinity`, which passed the
    /// `days > 0` check and produced a `-inf` threshold so `.inLast` matched
    /// everything (and `.lessThan` excluded everything). Now it's unparseable
    /// → no-match.
    func testDateRuleWithInfiniteDaysNeverMatches() {
        let now = date("2026-06-04T12:00:00Z")
        let recent = facts(dateAdded: date("2026-06-03T12:00:00Z"))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(recent, rule: rule(.dateAdded, .inLast, "inf"), now: now))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(recent, rule: rule(.dateAdded, .lessThan, "inf"), now: now))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(recent, rule: rule(.dateAdded, .greaterThan, "inf"), now: now))
    }

    /// A numeric rule with a NaN value never matches (NaN comparisons are all
    /// false), and the finite guard makes that explicit rather than relying on
    /// IEEE comparison semantics.
    func testNumberRuleWithNaNNeverMatches() {
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 2020), rule: rule(.year, .greaterThan, "nan")))
        XCTAssertFalse(SmartPlaylistEvaluator.matches(facts(year: 2020), rule: rule(.year, .is, "nan")))
    }

    // MARK: - Prebuilt-index overloads (perf hot path)

    /// The `genresByAlbumId:` overload of `evaluate` produces the same result
    /// as the `albums:` overload — it just reuses a prebuilt index instead of
    /// rebuilding it per call, so a per-render re-evaluation skips the
    /// O(albums) allocation.
    func testEvaluateWithPrebuiltIndexMatchesAlbumsOverload() {
        let albums = [
            makeAlbum(id: "alb-rock", genres: ["Rock"]),
            makeAlbum(id: "alb-jazz", genres: ["Jazz"]),
        ]
        let tracks = [
            makeTrack(id: "t1", albumId: "alb-rock"),
            makeTrack(id: "t2", albumId: "alb-jazz"),
            makeTrack(id: "t3", albumId: "alb-rock"),
        ]
        let p = playlist(.all, [rule(.genre, .is, "Rock")])
        let index = SmartPlaylistEvaluator.albumGenreIndex(albums)

        let viaAlbums = SmartPlaylistEvaluator.evaluate(p, tracks: tracks, albums: albums)
        let viaIndex = SmartPlaylistEvaluator.evaluate(p, tracks: tracks, genresByAlbumId: index)
        XCTAssertEqual(viaAlbums.map(\.id), viaIndex.map(\.id))
        XCTAssertEqual(viaIndex.map(\.id), ["t1", "t3"])
    }

    /// `matchCount`'s prebuilt-index overload agrees with both the `albums:`
    /// overload and the materialized filter.
    func testMatchCountWithPrebuiltIndexMatchesAlbumsOverload() {
        let albums = [makeAlbum(id: "alb", genres: ["Pop"])]
        let tracks = [
            makeTrack(id: "t1", albumId: "alb", isFavorite: true),
            makeTrack(id: "t2", albumId: "alb", isFavorite: false),
            makeTrack(id: "t3", albumId: "alb", isFavorite: true),
        ]
        let p = playlist(.all, [rule(.isFavorite, .is, "true")])
        let index = SmartPlaylistEvaluator.albumGenreIndex(albums)

        let viaAlbums = SmartPlaylistEvaluator.matchCount(p, tracks: tracks, albums: albums)
        let viaIndex = SmartPlaylistEvaluator.matchCount(p, tracks: tracks, genresByAlbumId: index)
        XCTAssertEqual(viaAlbums, viaIndex)
        XCTAssertEqual(viaIndex, 2)
    }

    /// An empty prebuilt index means no track gets album genres — a genre
    /// rule then matches nothing, proving the projection truly comes from the
    /// passed-in index (not some hidden rebuild).
    func testEvaluateWithEmptyIndexProjectsNoGenres() {
        let tracks = [makeTrack(id: "t1", albumId: "alb-rock")]
        let p = playlist(.all, [rule(.genre, .is, "Rock")])
        let result = SmartPlaylistEvaluator.evaluate(p, tracks: tracks, genresByAlbumId: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testParseDateAcceptsBothISOForms() {
        XCTAssertNotNil(SmartPlaylistEvaluator.parseDate("2026-05-01T08:30:00.0000000Z"))
        XCTAssertNotNil(SmartPlaylistEvaluator.parseDate("2026-05-01T08:30:00Z"))
        XCTAssertNil(SmartPlaylistEvaluator.parseDate("not a date"))
    }

    /// The album-genre index skips genre-less albums and keys the rest by id.
    func testAlbumGenreIndex() {
        let albums = [
            makeAlbum(id: "a", genres: ["Rock", "Indie"]),
            makeAlbum(id: "b", genres: []),
        ]
        let index = SmartPlaylistEvaluator.albumGenreIndex(albums)
        XCTAssertEqual(index["a"], ["Rock", "Indie"])
        XCTAssertNil(index["b"])
    }
}
