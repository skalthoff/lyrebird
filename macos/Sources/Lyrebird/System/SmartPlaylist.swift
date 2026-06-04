import Foundation
@preconcurrency import LyrebirdCore

/// Client-side **smart playlists** (#77 / #238).
///
/// Jellyfin's SDK has no native smart-playlist concept, so this is a
/// purely local feature: a `SmartPlaylist` is a `name` + a match mode
/// (`.all` / `.any`) + an ordered list of `Rule`s. The companion
/// `SmartPlaylistEvaluator` filters the in-memory library snapshot
/// (`AppModel.tracks`) against those rules. Nothing here touches the
/// network — there is no server round-trip, by design (the issue scopes
/// that out).
///
/// Everything in this file is a pure value type with deterministic
/// behaviour so the rule model + evaluator can be unit-tested without a
/// SwiftUI scene, a live server, or `UserDefaults`. The persistence
/// layer (`SmartPlaylistStore`) and the builder / detail UI live in
/// separate files; this one is the contract they all share.
///
/// ## Field ↔ snapshot mapping
/// The fields the rule builder offers map onto the `Track` projection the
/// app already loads (see `TrackFacts.init(track:)`):
///
/// | Field         | Source on `Track`                                  |
/// |---------------|----------------------------------------------------|
/// | `.genre`      | `Track` carries no genres; sourced from the album  |
/// |               | snapshot via the evaluator's `genresForAlbum`      |
/// |               | lookup (album genres apply to their tracks).       |
/// | `.artist`     | `artistName`                                       |
/// | `.album`      | `albumName`                                        |
/// | `.year`       | `year`                                             |
/// | `.playCount`  | `userData?.playCount ?? playCount`                 |
/// | `.isFavorite` | `userData?.isFavorite ?? isFavorite`               |
/// | `.dateAdded`  | `userData?.lastPlayedAt` (ISO-8601). Jellyfin's    |
/// |               | per-track projection exposes *last played*, not    |
/// |               | `DateCreated`; the desktop client treats "Date     |
/// |               | added" as last activity until core surfaces a real |
/// |               | creation date. The seam is the single `dateAdded`  |
/// |               | assignment in `TrackFacts.init`.                   |

// MARK: - Field

/// The track attribute a `Rule` tests. Raw values are stable storage keys
/// (persisted in JSON), so renaming a case is a breaking change — add new
/// cases, never repurpose old strings.
enum SmartPlaylistField: String, Codable, CaseIterable, Hashable, Sendable {
    case genre
    case artist
    case album
    case year
    case playCount
    case isFavorite
    case dateAdded

    /// The natural value kind this field compares against. Drives which
    /// operators are offered and how the value editor renders.
    var valueKind: SmartPlaylistValueKind {
        switch self {
        case .genre, .artist, .album: return .text
        case .year, .playCount: return .number
        case .isFavorite: return .boolean
        case .dateAdded: return .date
        }
    }

    /// Short, human-facing label. Not localized through the String Catalog
    /// yet (the catalog work is #560); kept as plain English so the builder
    /// is legible until that lands.
    var displayName: String {
        switch self {
        case .genre: return "Genre"
        case .artist: return "Artist"
        case .album: return "Album"
        case .year: return "Year"
        case .playCount: return "Play Count"
        case .isFavorite: return "Favorite"
        case .dateAdded: return "Date Added"
        }
    }
}

/// The kind of value a field compares against — determines which operators
/// are legal and how the UI renders the value editor.
enum SmartPlaylistValueKind: Hashable, Sendable {
    case text
    case number
    case boolean
    case date
}

// MARK: - Operator

/// The comparison a `Rule` applies between a field and its value. Raw
/// values are stable storage keys; see `SmartPlaylistField`.
enum SmartPlaylistOperator: String, Codable, CaseIterable, Hashable, Sendable {
    case `is`
    case isNot
    case contains
    case greaterThan
    case lessThan
    /// "in the last N days" — only meaningful for `.date` fields. The rule's
    /// `value` carries the day count as a base-10 integer string.
    case inLast

    var displayName: String {
        switch self {
        case .is: return "is"
        case .isNot: return "is not"
        case .contains: return "contains"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .inLast: return "in the last (days)"
        }
    }

    /// The operators that make sense for a given value kind. The builder
    /// uses this to populate the operator picker and to repair a rule whose
    /// operator no longer fits after the user changes its field.
    static func applicable(to kind: SmartPlaylistValueKind) -> [SmartPlaylistOperator] {
        switch kind {
        case .text: return [.is, .isNot, .contains]
        case .number: return [.is, .isNot, .greaterThan, .lessThan]
        case .boolean: return [.is]
        case .date: return [.inLast, .greaterThan, .lessThan]
        }
    }
}

// MARK: - Match mode

/// Whether a track must satisfy every rule (`.all`, logical AND) or at
/// least one (`.any`, logical OR). Mirrors iTunes / Marvis "Match all / any
/// of the following rules".
enum SmartPlaylistMatchMode: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case any

    var displayName: String {
        switch self {
        case .all: return "all"
        case .any: return "any"
        }
    }
}

// MARK: - Rule

/// A single `field op value` clause. `value` is always stored as a string
/// and parsed lazily by the evaluator according to the field's value kind,
/// which keeps the model trivially `Codable` and lets the builder bind a
/// plain `TextField` regardless of the underlying type.
///
/// `id` exists only so SwiftUI's `ForEach` has a stable identity for row
/// add / remove animations; it is intentionally excluded from `==` and
/// from the persisted-equality notion the tests care about (two rules with
/// the same field/op/value are semantically identical even if their ids
/// differ). It is still encoded so an edit session round-trips without
/// reshuffling row identity.
struct SmartPlaylistRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var field: SmartPlaylistField
    var op: SmartPlaylistOperator
    var value: String

    init(id: UUID = UUID(), field: SmartPlaylistField, op: SmartPlaylistOperator, value: String) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    /// Semantic equality ignores `id` so a reordered / re-instantiated rule
    /// with identical contents compares equal. Used by the store's
    /// change-detection and by tests asserting on logical content.
    static func == (lhs: SmartPlaylistRule, rhs: SmartPlaylistRule) -> Bool {
        lhs.field == rhs.field && lhs.op == rhs.op && lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(field)
        hasher.combine(op)
        hasher.combine(value)
    }

    /// A fresh rule seeded with sensible defaults for a field — used when
    /// the builder adds a row or the user switches a rule's field and its
    /// operator no longer applies.
    static func defaultRule(for field: SmartPlaylistField = .artist) -> SmartPlaylistRule {
        let op = SmartPlaylistOperator.applicable(to: field.valueKind).first ?? .is
        let value: String
        switch field.valueKind {
        case .text: value = ""
        case .number: value = "0"
        case .boolean: value = "true"
        case .date: value = "30"
        }
        return SmartPlaylistRule(field: field, op: op, value: value)
    }

    /// Return a copy whose operator is guaranteed legal for the (possibly
    /// just-changed) field. If the current operator already applies it is
    /// kept; otherwise it snaps to the first applicable operator and the
    /// value is reset to that field-kind's default. Pure — the builder calls
    /// this whenever the user changes a row's field so an impossible
    /// `field`/`op` pairing (e.g. `isFavorite greaterThan`) can't persist.
    func repaired() -> SmartPlaylistRule {
        let legal = SmartPlaylistOperator.applicable(to: field.valueKind)
        guard !legal.contains(op) else { return self }
        var fixed = SmartPlaylistRule.defaultRule(for: field)
        fixed.id = id
        return fixed
    }
}

// MARK: - SmartPlaylist

/// A saved smart playlist: a name, a match mode, and the rules. `id` is the
/// stable storage key (used by the sidebar selection + the routing). An
/// empty `rules` array is legal and matches *every* track (an "all of my
/// music" playlist), matching iTunes' behaviour for a rule-less smart
/// playlist.
struct SmartPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var matchMode: SmartPlaylistMatchMode
    var rules: [SmartPlaylistRule]

    init(
        id: UUID = UUID(),
        name: String,
        matchMode: SmartPlaylistMatchMode = .all,
        rules: [SmartPlaylistRule] = []
    ) {
        self.id = id
        self.name = name
        self.matchMode = matchMode
        self.rules = rules
    }

    /// A blank playlist seeded with one default rule, used by "New Smart
    /// Playlist…". Starting with one row means the builder never opens on an
    /// empty (and therefore match-everything) state the user didn't ask for.
    static func newDraft(name: String = "New Smart Playlist") -> SmartPlaylist {
        SmartPlaylist(name: name, matchMode: .all, rules: [.defaultRule()])
    }
}
