import XCTest
@testable import Lyrebird
import LyrebirdCore

/// Coverage for the pure `SmartPlaylist` rule model (#77 / #238): the
/// field/operator domain, default-rule seeding, the field→operator repair
/// that keeps an impossible pairing from forming, and `Codable`
/// round-tripping (the model is persisted as JSON, so its on-the-wire shape
/// is a contract).
final class SmartPlaylistModelTests: XCTestCase {

    // MARK: - Field / operator domain

    /// Each field advertises exactly one value kind, and that kind drives
    /// which operators are legal. Pin the mapping so a future field addition
    /// has to consciously slot itself in.
    func testFieldValueKinds() {
        XCTAssertEqual(SmartPlaylistField.genre.valueKind, .text)
        XCTAssertEqual(SmartPlaylistField.artist.valueKind, .text)
        XCTAssertEqual(SmartPlaylistField.album.valueKind, .text)
        XCTAssertEqual(SmartPlaylistField.year.valueKind, .number)
        XCTAssertEqual(SmartPlaylistField.playCount.valueKind, .number)
        XCTAssertEqual(SmartPlaylistField.isFavorite.valueKind, .boolean)
        XCTAssertEqual(SmartPlaylistField.dateAdded.valueKind, .date)
    }

    /// The operator sets are scoped to the value kind: text gets equality +
    /// contains; numbers get equality + ordering; booleans only `is`; dates
    /// get recency + ordering. `contains` must never be offered for a number.
    func testApplicableOperatorsPerKind() {
        XCTAssertEqual(SmartPlaylistOperator.applicable(to: .text), [.is, .isNot, .contains])
        XCTAssertEqual(SmartPlaylistOperator.applicable(to: .number), [.is, .isNot, .greaterThan, .lessThan])
        XCTAssertEqual(SmartPlaylistOperator.applicable(to: .boolean), [.is])
        XCTAssertEqual(SmartPlaylistOperator.applicable(to: .date), [.inLast, .greaterThan, .lessThan])
    }

    // MARK: - Default rule seeding

    /// A default rule for a field picks the first legal operator and a
    /// kind-appropriate value, so a freshly-added row is immediately valid.
    func testDefaultRuleSeedsLegalOperatorAndValue() {
        let text = SmartPlaylistRule.defaultRule(for: .artist)
        XCTAssertEqual(text.field, .artist)
        XCTAssertEqual(text.op, .is)
        XCTAssertEqual(text.value, "")

        let number = SmartPlaylistRule.defaultRule(for: .playCount)
        XCTAssertEqual(number.op, .is)
        XCTAssertEqual(number.value, "0")

        let boolean = SmartPlaylistRule.defaultRule(for: .isFavorite)
        XCTAssertEqual(boolean.op, .is)
        XCTAssertEqual(boolean.value, "true")

        let date = SmartPlaylistRule.defaultRule(for: .dateAdded)
        XCTAssertEqual(date.op, .inLast)
        XCTAssertEqual(date.value, "30")
    }

    // MARK: - Field→operator repair

    /// Changing a rule's field to one whose kind doesn't support the current
    /// operator snaps the operator (and value) to that field's default,
    /// preserving the row's identity. This is what stops "Favorite greater
    /// than 5" from ever forming in the builder.
    func testRepairFixesIncompatibleOperator() {
        // Start with a valid numeric rule, then flip the field to a boolean.
        var rule = SmartPlaylistRule(field: .playCount, op: .greaterThan, value: "5")
        let originalId = rule.id
        rule.field = .isFavorite // op `.greaterThan` is now illegal for boolean

        let repaired = rule.repaired()
        XCTAssertEqual(repaired.field, .isFavorite)
        XCTAssertEqual(repaired.op, .is, "boolean only supports `is`")
        XCTAssertEqual(repaired.value, "true")
        XCTAssertEqual(repaired.id, originalId, "repair preserves row identity")
    }

    /// Repair is a no-op when the operator already applies — it must not
    /// clobber a perfectly good rule's value.
    func testRepairLeavesValidRuleUntouched() {
        let rule = SmartPlaylistRule(field: .year, op: .greaterThan, value: "1999")
        XCTAssertEqual(rule.repaired(), rule)
        XCTAssertEqual(rule.repaired().value, "1999")
    }

    // MARK: - Semantic equality

    /// Two rules with identical field/op/value compare equal even if their
    /// `id`s differ — the model treats `id` as presentation-only identity.
    func testRuleEqualityIgnoresId() {
        let a = SmartPlaylistRule(id: UUID(), field: .artist, op: .is, value: "Bjork")
        let b = SmartPlaylistRule(id: UUID(), field: .artist, op: .is, value: "Bjork")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - Codable round-trip

    /// A playlist survives an encode → decode round trip with every field,
    /// operator, match mode, and rule contents intact. This is the persisted
    /// contract — a regression here silently drops a user's saved playlists.
    func testPlaylistCodableRoundTrip() throws {
        let original = SmartPlaylist(
            id: UUID(),
            name: "90s Favorites",
            matchMode: .any,
            rules: [
                SmartPlaylistRule(field: .year, op: .greaterThan, value: "1989"),
                SmartPlaylistRule(field: .year, op: .lessThan, value: "2000"),
                SmartPlaylistRule(field: .isFavorite, op: .is, value: "true"),
                SmartPlaylistRule(field: .genre, op: .contains, value: "Rock"),
                SmartPlaylistRule(field: .dateAdded, op: .inLast, value: "365"),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SmartPlaylist.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.matchMode, original.matchMode)
        XCTAssertEqual(decoded.rules, original.rules)
        // Rule ids round-trip too (encoded so an edit session keeps row
        // identity), not just the semantic content.
        XCTAssertEqual(decoded.rules.map(\.id), original.rules.map(\.id))
    }

    /// Enum raw values are stable storage keys; pin them so a rename can't
    /// silently invalidate every file on disk.
    func testEnumRawValuesAreStable() {
        XCTAssertEqual(SmartPlaylistField.playCount.rawValue, "playCount")
        XCTAssertEqual(SmartPlaylistField.isFavorite.rawValue, "isFavorite")
        XCTAssertEqual(SmartPlaylistField.dateAdded.rawValue, "dateAdded")
        XCTAssertEqual(SmartPlaylistOperator.greaterThan.rawValue, "greaterThan")
        XCTAssertEqual(SmartPlaylistOperator.inLast.rawValue, "inLast")
        XCTAssertEqual(SmartPlaylistMatchMode.all.rawValue, "all")
        XCTAssertEqual(SmartPlaylistMatchMode.any.rawValue, "any")
    }

    /// `newDraft` opens with exactly one default rule (so the builder never
    /// starts on an accidental match-everything state).
    func testNewDraftHasOneDefaultRule() {
        let draft = SmartPlaylist.newDraft()
        XCTAssertEqual(draft.rules.count, 1)
        XCTAssertEqual(draft.matchMode, .all)
        XCTAssertFalse(draft.name.isEmpty)
    }
}
