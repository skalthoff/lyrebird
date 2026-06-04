import Foundation
@preconcurrency import LyrebirdCore

/// The flattened, comparison-ready view of a single track that
/// `SmartPlaylistEvaluator` tests rules against. Decoupling the rule logic
/// from the `Track` FFI struct keeps the evaluator unit-testable with tiny
/// hand-built fixtures (no UniFFI buffer round-trips) and gives the
/// last-played-date semantics a single documented seam.
///
/// All text comparisons the evaluator performs are case- and
/// diacritic-insensitive; the raw values are stored verbatim here and the
/// folding happens at compare time so the same `TrackFacts` works for any
/// operator.
struct TrackFacts: Hashable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Genres that apply to this track. `Track` carries none, so the
    /// evaluator fills these from the album the track belongs to (see
    /// `SmartPlaylistEvaluator`). Empty when the album genres are unknown.
    /// Stored verbatim; the evaluator splits any semicolon-joined element
    /// at compare time so both array and "Pop;Rock" server shapes work.
    var genres: [String]
    var year: Int?
    var playCount: Int
    var isFavorite: Bool
    /// Best per-track date the snapshot exposes: Jellyfin's `Track`
    /// projection carries `UserData.lastPlayedAt`, not `DateCreated`, so the
    /// date field tests **last-played** and is surfaced to the user as "Last
    /// Played" (see `SmartPlaylistField.displayName`). `nil` when the track
    /// has no user data / has never been played, in which case `.inLast` /
    /// date comparisons never match (a never-played track has no last-played
    /// date to fall inside any window). The case raw value is still
    /// `dateAdded` — a stable persisted storage key that predates the
    /// honest label and must not be renamed (see `SmartPlaylistField`).
    var dateAdded: Date?

    init(
        id: String,
        title: String,
        artist: String,
        album: String,
        genres: [String] = [],
        year: Int? = nil,
        playCount: Int = 0,
        isFavorite: Bool = false,
        dateAdded: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genres = genres
        self.year = year
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.dateAdded = dateAdded
    }
}

extension TrackFacts {
    /// Adapt a `Track` from the library snapshot. `genres` is supplied by the
    /// caller because `Track` itself carries none — the evaluator looks the
    /// track's album up in an `[albumId: [genre]]` map it builds once from
    /// `AppModel.albums`. `now` is injected so the (rare) call sites that
    /// need a deterministic clock can pass one; production passes the real
    /// `Date()`.
    init(track: Track, genres: [String] = []) {
        self.id = track.id
        self.title = track.name
        self.artist = track.artistName
        self.album = track.albumName ?? ""
        self.genres = genres
        self.year = track.year.map(Int.init)
        // Prefer the richer UserData projection; fall back to the convenience
        // mirror so a snapshot fetched without `Fields=UserData` still reads.
        self.playCount = Int(track.userData?.playCount ?? track.playCount)
        self.isFavorite = track.userData?.isFavorite ?? track.isFavorite
        // The single documented last-played-date seam. The field is labelled
        // "Last Played" because Jellyfin's `Track` projection exposes only
        // `lastPlayedAt`, not `DateCreated`; if core ever surfaces a real
        // per-track creation date, add it to the `Track` FFI model and a new
        // `SmartPlaylistField.dateAdded`-style case rather than overloading
        // this one (the label would otherwise lie again).
        self.dateAdded = track.userData?.lastPlayedAt.flatMap(SmartPlaylistEvaluator.parseDate)
    }
}

/// Pure, deterministic filter that turns a `SmartPlaylist` into the set of
/// tracks (from an in-memory snapshot) that satisfy its rules. No network,
/// no `UserDefaults`, no clock except the one injected into date rules —
/// so the whole thing is straightforwardly unit-tested.
///
/// Evaluation is order-preserving: the returned tracks keep their input
/// order (the snapshot's order), so a smart playlist plays in the same
/// sequence the library presents.
enum SmartPlaylistEvaluator {

    // MARK: - Public entry points

    /// Filter `tracks` (already adapted to `TrackFacts`) by `playlist`.
    /// `now` anchors relative-date rules (`.inLast`); defaults to the real
    /// current time.
    static func evaluate(
        _ playlist: SmartPlaylist,
        over tracks: [TrackFacts],
        now: Date = Date()
    ) -> [TrackFacts] {
        // A rule-less playlist matches everything (iTunes parity).
        guard !playlist.rules.isEmpty else { return tracks }
        return tracks.filter { matches($0, playlist: playlist, now: now) }
    }

    /// Convenience over the FFI `Track` type: builds the per-track genre
    /// lookup from `albums`, adapts each track, and filters. This is the
    /// entry point `AppModel` / the detail view call with the live snapshot.
    ///
    /// On a large library (the canonical real server holds ~20,060 albums)
    /// building `albumGenreIndex(albums)` is an O(albums) allocation. When a
    /// call site re-evaluates repeatedly against the *same* albums snapshot
    /// (a SwiftUI body that renders per keystroke / per visible row), build
    /// the index once with `albumGenreIndex(_:)` and call the
    /// `genresByAlbumId:` overload below so the index is reused rather than
    /// rebuilt on every pass.
    static func evaluate(
        _ playlist: SmartPlaylist,
        tracks: [Track],
        albums: [Album],
        now: Date = Date()
    ) -> [Track] {
        evaluate(playlist, tracks: tracks, genresByAlbumId: albumGenreIndex(albums), now: now)
    }

    /// As `evaluate(_:tracks:albums:now:)` but takes a *prebuilt*
    /// `[albumId: [genre]]` index instead of rebuilding it from `albums` on
    /// every call. Hot-path entry point: the detail/builder views build the
    /// index once per albums-snapshot and pass it in so a per-render
    /// re-evaluation is a single O(tracks) pass with no per-call O(albums)
    /// dictionary allocation.
    static func evaluate(
        _ playlist: SmartPlaylist,
        tracks: [Track],
        genresByAlbumId: [String: [String]],
        now: Date = Date()
    ) -> [Track] {
        guard !playlist.rules.isEmpty else { return tracks }
        return tracks.filter { track in
            matches(facts(for: track, genresByAlbumId: genresByAlbumId), playlist: playlist, now: now)
        }
    }

    /// The count of matching tracks — used for the builder's live "N songs"
    /// readout without materializing the filtered array at every call site.
    /// Builds the genre index from `albums`; prefer the `genresByAlbumId:`
    /// overload from a per-interaction path so the index isn't rebuilt on
    /// every keystroke.
    static func matchCount(
        _ playlist: SmartPlaylist,
        tracks: [Track],
        albums: [Album],
        now: Date = Date()
    ) -> Int {
        matchCount(playlist, tracks: tracks, genresByAlbumId: albumGenreIndex(albums), now: now)
    }

    /// As `matchCount(_:tracks:albums:now:)` but takes a prebuilt genre
    /// index. See `evaluate(_:tracks:genresByAlbumId:now:)`.
    static func matchCount(
        _ playlist: SmartPlaylist,
        tracks: [Track],
        genresByAlbumId: [String: [String]],
        now: Date = Date()
    ) -> Int {
        guard !playlist.rules.isEmpty else { return tracks.count }
        return tracks.reduce(into: 0) { count, track in
            if matches(facts(for: track, genresByAlbumId: genresByAlbumId), playlist: playlist, now: now) {
                count += 1
            }
        }
    }

    /// Adapt a `Track` to `TrackFacts`, projecting its album's genres via the
    /// prebuilt index. Shared by the filter + count paths so the projection
    /// rule lives in one place.
    private static func facts(for track: Track, genresByAlbumId: [String: [String]]) -> TrackFacts {
        let genres = track.albumId.flatMap { genresByAlbumId[$0] } ?? []
        return TrackFacts(track: track, genres: genres)
    }

    // MARK: - Matching

    /// Whether `facts` satisfies `playlist` under its match mode. `.all`
    /// requires every rule (vacuously true for no rules, but the public
    /// entry points short-circuit empty rule sets); `.any` requires at
    /// least one.
    static func matches(_ facts: TrackFacts, playlist: SmartPlaylist, now: Date = Date()) -> Bool {
        switch playlist.matchMode {
        case .all:
            return playlist.rules.allSatisfy { matches(facts, rule: $0, now: now) }
        case .any:
            return playlist.rules.contains { matches(facts, rule: $0, now: now) }
        }
    }

    /// Whether a single `rule` holds for `facts`. A rule whose value can't be
    /// parsed for its field kind (e.g. `year is "abc"`) never matches — an
    /// unparseable rule is treated as unsatisfiable rather than crashing or
    /// matching everything.
    static func matches(_ facts: TrackFacts, rule: SmartPlaylistRule, now: Date = Date()) -> Bool {
        switch rule.field {
        case .genre:
            // Genre is multi-valued: the rule holds if *any* of the track's
            // genres satisfies it. Some Jellyfin libraries store a track's
            // genres as a single semicolon-joined element
            // ("Pop;Folk Pop;Rock") rather than a split array, so split on
            // `;` first — otherwise a `genre is "Pop"` rule would miss those
            // items (only `contains` would catch them). See the real-server
            // probe in the #77 work.
            let atomicGenres = facts.genres.flatMap { $0.split(separator: ";").map(String.init) }
            return atomicGenres.contains { textMatch($0, rule: rule) }
        case .artist:
            return textMatch(facts.artist, rule: rule)
        case .album:
            return textMatch(facts.album, rule: rule)
        case .year:
            guard let year = facts.year else { return false }
            return numberMatch(Double(year), rule: rule)
        case .playCount:
            return numberMatch(Double(facts.playCount), rule: rule)
        case .isFavorite:
            return booleanMatch(facts.isFavorite, rule: rule)
        case .dateAdded:
            return dateMatch(facts.dateAdded, rule: rule, now: now)
        }
    }

    // MARK: - Per-kind comparisons

    private static func textMatch(_ lhs: String, rule: SmartPlaylistRule) -> Bool {
        let a = fold(lhs)
        let b = fold(rule.value)
        switch rule.op {
        case .is: return a == b
        case .isNot: return a != b
        case .contains: return !b.isEmpty && a.contains(b)
        // Ordering / recency operators don't apply to text; treat as no-match
        // rather than letting an out-of-domain pairing match everything.
        case .greaterThan, .lessThan, .inLast: return false
        }
    }

    private static func numberMatch(_ lhs: Double, rule: SmartPlaylistRule) -> Bool {
        guard let rhs = parseNumber(rule.value) else { return false }
        switch rule.op {
        case .is: return lhs == rhs
        case .isNot: return lhs != rhs
        case .greaterThan: return lhs > rhs
        case .lessThan: return lhs < rhs
        case .contains, .inLast: return false
        }
    }

    private static func booleanMatch(_ lhs: Bool, rule: SmartPlaylistRule) -> Bool {
        guard let rhs = parseBool(rule.value) else { return false }
        switch rule.op {
        case .is: return lhs == rhs
        // Only `is` is offered for booleans; anything else is out of domain.
        case .isNot: return lhs != rhs
        case .contains, .greaterThan, .lessThan, .inLast: return false
        }
    }

    /// Date rules all express their value as a **day count** (the builder's
    /// date editor is a "N days" stepper). The threshold is `N` days before
    /// `now`:
    /// - `.inLast`  → item is within the window `[now - N, now]` (recent).
    /// - `.greaterThan` → item is *more recent* than the threshold (newer
    ///   than N days ago) — i.e. equivalent to `.inLast` minus the upper
    ///   bound, useful when paired with another rule.
    /// - `.lessThan` → item is *older* than the threshold (before N days
    ///   ago).
    private static func dateMatch(_ lhs: Date?, rule: SmartPlaylistRule, now: Date) -> Bool {
        guard let lhs, let days = parseNumber(rule.value), days > 0 else { return false }
        let threshold = now.addingTimeInterval(-days * 86_400)
        switch rule.op {
        case .inLast: return lhs >= threshold && lhs <= now
        case .greaterThan: return lhs > threshold
        case .lessThan: return lhs < threshold
        case .is, .isNot, .contains: return false
        }
    }

    // MARK: - Album genre index

    /// Build an `[albumId: [genre]]` lookup once per evaluation so each
    /// track's genre check is an O(1) dictionary hit rather than a linear
    /// album scan. Albums with no genres are simply absent.
    static func albumGenreIndex(_ albums: [Album]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        index.reserveCapacity(albums.count)
        for album in albums where !album.genres.isEmpty {
            index[album.id] = album.genres
        }
        return index
    }

    // MARK: - Parsing helpers

    /// Case- and diacritic-insensitive fold for text comparisons, trimmed of
    /// surrounding whitespace so a stray trailing space in a rule value
    /// doesn't defeat an otherwise-exact match.
    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Parse a numeric rule value with the POSIX locale so "1,5" never reads
    /// as fifteen on a comma-decimal system. Returns `nil` for blank /
    /// non-numeric input.
    ///
    /// Non-finite values are rejected. `Double("inf")` / `Double("nan")`
    /// parse successfully but make a date rule's day count `±inf`/`NaN`
    /// (`threshold = now - inf*86400` is a `-inf` Date that matches or
    /// excludes *every* track) and a numeric `is`/`<`/`>` comparison
    /// silently degenerate — so a finite check keeps a hand-typed "inf" /
    /// "nan" from forming a silently-broken filter rather than an empty
    /// (no-match) one the user can at least see is wrong.
    static func parseNumber(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Parse a boolean rule value. Accepts the JSON-ish `true`/`false` the
    /// builder writes plus a couple of common synonyms so a hand-edited file
    /// is forgiving.
    static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Parse an ISO-8601 date string as returned by Jellyfin's `UserData`
    /// (`lastPlayedAt`). Tries fractional-seconds first (Jellyfin emits
    /// `2024-01-02T03:04:05.0000000Z`), then the plain form. Returns `nil`
    /// for unparseable input so a malformed server date degrades to
    /// "no date" rather than crashing the filter.
    static func parseDate(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
