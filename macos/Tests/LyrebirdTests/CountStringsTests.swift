import XCTest

@testable import Lyrebird

/// Coverage for `CountStrings` — the inflected-count helper added in #350.
///
/// Two layers, mirroring `LyrebirdErrorPresenterTests`:
///
/// 1. **Pure logic.** `pluralCategory(for:)` (the English singular/plural rule)
///    and `Noun.key` (catalog routing) are exercised directly. These don't
///    touch the `.xcstrings` catalog, which SwiftPM strips from the test
///    binary, so they're the authoritative coverage for the selection rule.
///
/// 2. **Catalog sync.** The catalog *can't* be looked up via
///    `String(localized:)` here (no resource in the test bundle), but it can be
///    read off disk as a file. The `#filePath`-relative loader (same idiom as
///    `ArtworkAccessibilityTests`) parses `Localizable.xcstrings` and pins that
///    every key the helper emits actually exists with `one`/`other` English
///    plural variations whose singular form is "<n> <noun>" and plural is
///    "<n> <noun>s". This is what catches a typo'd key or a catalog entry
///    deleted out from under the helper — a `String(localized:)` miss would
///    silently render the raw key in the UI.
final class CountStringsTests: XCTestCase {

    // MARK: - Plural rule (English)

    /// Exactly 1 is `one`; everything else — including 0 and negatives — is
    /// `other`. This is the CLDR English rule the catalog's `en` variations
    /// encode, and the bug #350 fixes (a hand-rolled `count == 1 ?` at every
    /// call site, occasionally wrong on the 0 case).
    func testPluralCategoryOneVsOther() {
        XCTAssertEqual(CountStrings.pluralCategory(for: 1), .one)

        for n in [0, 2, 3, 11, 21, 100, 1_000_000] {
            XCTAssertEqual(
                CountStrings.pluralCategory(for: n), .other,
                "count \(n) should select the plural (.other) category in English"
            )
        }
    }

    /// Zero takes the plural form ("0 albums"), not the singular — a place the
    /// old `count == 1 ? "1 X" : "\(count) Xs"` ternaries happened to get right
    /// but which a naive `count <= 1` would break.
    func testZeroIsPlural() {
        XCTAssertEqual(CountStrings.pluralCategory(for: 0), .other)
    }

    /// Negatives are defensive — counts shouldn't go below zero, but if one
    /// does it must not crash or land in `one`.
    func testNegativeIsPlural() {
        XCTAssertEqual(CountStrings.pluralCategory(for: -1), .other)
        XCTAssertEqual(CountStrings.pluralCategory(for: -5), .other)
    }

    // MARK: - Key routing

    /// Each noun maps to its documented `count.<noun> %lld` catalog key, and
    /// `key(_:)` is a faithful pass-through to `Noun.key`.
    func testNounKeys() {
        XCTAssertEqual(CountStrings.Noun.albums.key, "count.albums %lld")
        XCTAssertEqual(CountStrings.Noun.artists.key, "count.artists %lld")
        XCTAssertEqual(CountStrings.Noun.items.key, "count.items %lld")
        XCTAssertEqual(CountStrings.Noun.playlists.key, "count.playlists %lld")
        XCTAssertEqual(CountStrings.Noun.plays.key, "count.plays %lld")
        XCTAssertEqual(CountStrings.Noun.results.key, "count.results %lld")
        XCTAssertEqual(CountStrings.Noun.selected.key, "count.selected %lld")
        XCTAssertEqual(CountStrings.Noun.songs.key, "count.songs %lld")
        XCTAssertEqual(CountStrings.Noun.tracks.key, "count.tracks %lld")

        for noun in CountStrings.Noun.allCases {
            XCTAssertEqual(CountStrings.key(noun), noun.key)
        }
    }

    /// Every noun's key carries the `%lld` placeholder (so the catalog can run
    /// plural selection on the count) and the keys are mutually distinct.
    func testKeysAreWellFormedAndDistinct() {
        var seen = Set<String>()
        for noun in CountStrings.Noun.allCases {
            let key = noun.key
            XCTAssertTrue(
                key.hasSuffix(" %lld"),
                "\(key) must end with the ` %lld` count placeholder"
            )
            XCTAssertTrue(
                key.hasPrefix("count."),
                "\(key) must live under the `count.` namespace"
            )
            XCTAssertTrue(seen.insert(key).inserted, "duplicate key \(key)")
        }
        // Nine nouns, nine distinct keys.
        XCTAssertEqual(seen.count, CountStrings.Noun.allCases.count)
        XCTAssertEqual(seen.count, 9)
    }

    // MARK: - Catalog sync

    /// Every helper key resolves to a catalog entry carrying English `one` and
    /// `other` plural variations, and the variation values inflect correctly
    /// ("%lld album" singular vs "%lld albums" plural). The `selected` noun is
    /// the one exception — "selected" doesn't inflect — so its two variations
    /// match.
    func testEveryKeyExistsInCatalogWithInflectedVariations() throws {
        let catalog = try loadCatalog()

        for noun in CountStrings.Noun.allCases {
            let key = noun.key
            guard let entry = catalog[key] as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any],
                  let en = locs["en"] as? [String: Any],
                  let variations = en["variations"] as? [String: Any],
                  let plural = variations["plural"] as? [String: Any] else {
                XCTFail("Catalog key \(key) is missing or has no en plural variations")
                continue
            }

            let one = stringUnitValue(plural["one"])
            let other = stringUnitValue(plural["other"])
            XCTAssertNotNil(one, "\(key) is missing its `one` variation")
            XCTAssertNotNil(other, "\(key) is missing its `other` variation")

            // The count placeholder must survive into both variations.
            XCTAssertEqual(one?.contains("%lld"), true, "\(key) `one` lost its %lld placeholder")
            XCTAssertEqual(other?.contains("%lld"), true, "\(key) `other` lost its %lld placeholder")

            if noun == .selected {
                // "selected" is invariant in English.
                XCTAssertEqual(one, other, "count.selected should not inflect")
            } else {
                // Singular is a strict prefix of the plural (English -s rule),
                // and they must differ so "1 album" != "2 albums".
                XCTAssertNotEqual(one, other, "\(key) singular and plural must differ")
                if let one, let other {
                    XCTAssertTrue(
                        other.hasPrefix(one),
                        "\(key): plural \"\(other)\" should extend singular \"\(one)\""
                    )
                    XCTAssertEqual(
                        other, one + "s",
                        "\(key): English plural should be the singular plus 's'"
                    )
                }
            }
        }
    }

    /// The catalog must not regress the pre-existing `sidebar.server.connected`
    /// plural key while the new `count.*` block is added next to it — a guard
    /// that the surgical insertion didn't disturb its neighbour.
    func testPreExistingPluralKeyStillPresent() throws {
        let catalog = try loadCatalog()
        let entry = catalog["sidebar.server.connected %lld"] as? [String: Any]
        XCTAssertNotNil(entry, "the pre-existing connected-count plural key disappeared")
    }

    // MARK: - Catalog loading helpers

    /// The `strings` dictionary of `Localizable.xcstrings`, read off disk
    /// relative to this test file (the catalog isn't bundled into the test
    /// binary — SwiftPM copies resources only into the `.app`).
    private func loadCatalog(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let target = here
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: target)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let strings = json?["strings"] as? [String: Any] else {
            XCTFail("Could not parse strings table from \(target.path)", file: file, line: line)
            return [:]
        }
        return strings
    }

    /// Pulls `<variation>.stringUnit.value` out of a decoded plural variation.
    private func stringUnitValue(_ variation: Any?) -> String? {
        (variation as? [String: Any])?["stringUnit"]
            .flatMap { ($0 as? [String: Any])?["value"] as? String }
    }
}
