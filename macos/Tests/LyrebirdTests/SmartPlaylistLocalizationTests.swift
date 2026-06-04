import XCTest
@testable import Lyrebird

/// Localization coverage for the smart-playlist views (#77 / #238 re-audit).
///
/// The three smart-playlist screens (detail, builder) were shipped with
/// hard-coded English literals while the rest of the app routes through the
/// String Catalog. This pins two things:
///
/// 1. **Pure summary structure.** `SmartPlaylistDetailView.ruleSummary` is a
///    pure helper; it now builds from localized format strings. In the unit
///    test binary the `.xcstrings` catalog is stripped (SwiftPM copies
///    resources only into the `.app`), so `String(localized:)` returns the raw
///    key — which is precisely what lets us assert the *structure* (which key,
///    which interpolation order) deterministically here, with the rendered
///    English copy verified by the catalog-sync test below + the running app.
///
/// 2. **Catalog sync.** Same `#filePath`-relative loader idiom as
///    `CountStringsTests`: every `smart_playlist.*` key the code references is
///    read off disk and asserted present, so a typo'd key (which would
///    silently render as the raw key in the UI) fails the build instead.
final class SmartPlaylistLocalizationTests: XCTestCase {

    // MARK: - ruleSummary structure

    /// An empty rule set resolves to the dedicated "matches every track" key.
    func testRuleSummaryEmptyUsesMatchesAllTracksKey() {
        let p = SmartPlaylist(name: "All", matchMode: .all, rules: [])
        XCTAssertEqual(SmartPlaylistDetailView.ruleSummary(p), "smart_playlist.rules.matches_all_tracks")
    }

    /// A non-empty rule set is built from the localized "matches %@ of: %@"
    /// frame. In the test bundle (catalog stripped) `String(localized:)`
    /// returns the raw key with the interpolated arguments appended, so we can
    /// pin that the match mode and the joined clauses are both threaded in.
    func testRuleSummaryNonEmptyThreadsModeAndClauses() {
        let p = SmartPlaylist(
            name: "Test",
            matchMode: .all,
            rules: [
                SmartPlaylistRule(field: .artist, op: .is, value: "Radiohead"),
                SmartPlaylistRule(field: .year, op: .greaterThan, value: "2000"),
            ]
        )
        let summary = SmartPlaylistDetailView.ruleSummary(p)
        // The frame key is present…
        XCTAssertTrue(
            summary.contains("smart_playlist.rules.matches"),
            "rule summary should be built from the localized frame key"
        )
        // …the match mode label is threaded in (its own localized key)…
        XCTAssertTrue(summary.contains(SmartPlaylistMatchMode.all.displayName))
        // …and each clause's raw value appears (values aren't localized).
        XCTAssertTrue(summary.contains("Radiohead"))
        XCTAssertTrue(summary.contains("2000"))
    }

    /// The clause separator is itself a catalog key (so locales that don't
    /// join with ", " can override it) — joining two clauses must place that
    /// separator between them.
    func testRuleSummaryJoinsClausesWithLocalizedSeparator() {
        let p = SmartPlaylist(
            name: "Test",
            matchMode: .any,
            rules: [
                SmartPlaylistRule(field: .artist, op: .is, value: "A"),
                SmartPlaylistRule(field: .album, op: .is, value: "B"),
            ]
        )
        let summary = SmartPlaylistDetailView.ruleSummary(p)
        let separator = String(localized: "smart_playlist.rules.clause_separator", bundle: .main)
        XCTAssertTrue(
            summary.contains(separator),
            "joined clauses should be separated by the localized clause separator"
        )
    }

    // MARK: - Field / operator / mode displayName routing

    /// `.dateAdded` is surfaced to the user as "Last Played" — the honest
    /// label for a field sourced from `UserData.lastPlayedAt` (Jellyfin's
    /// `Track` projection has no `DateCreated`). The catalog key encodes that.
    func testDateFieldDisplayNameRoutesToLastPlayedKey() {
        XCTAssertEqual(SmartPlaylistField.dateAdded.displayName, "smart_playlist.field.last_played")
    }

    /// Every field's `displayName` routes through a `smart_playlist.field.*`
    /// catalog key (raw key returned in the stripped test bundle).
    func testEveryFieldDisplayNameRoutesThroughCatalog() {
        for field in SmartPlaylistField.allCases {
            XCTAssertTrue(
                field.displayName.hasPrefix("smart_playlist.field."),
                "\(field) displayName should route through the catalog, got \(field.displayName)"
            )
        }
    }

    /// Every operator's `displayName` routes through a `smart_playlist.op.*`
    /// key, and every match mode through `smart_playlist.match_mode.*`.
    func testOperatorAndModeDisplayNamesRouteThroughCatalog() {
        for op in SmartPlaylistOperator.allCases {
            XCTAssertTrue(
                op.displayName.hasPrefix("smart_playlist.op."),
                "\(op) displayName should route through the catalog, got \(op.displayName)"
            )
        }
        for mode in SmartPlaylistMatchMode.allCases {
            XCTAssertTrue(
                mode.displayName.hasPrefix("smart_playlist.match_mode."),
                "\(mode) displayName should route through the catalog, got \(mode.displayName)"
            )
        }
    }

    // MARK: - Catalog sync

    /// Every `smart_playlist.*` key the views and model reference exists in the
    /// catalog with an English localization. A missing key would silently
    /// render as the raw key string in the UI; this turns that into a test
    /// failure. The list mirrors the literals routed through the catalog in
    /// `SmartPlaylistDetailView`, `SmartPlaylistBuilderView`, and
    /// `SmartPlaylist` (field/op/mode displayNames).
    func testAllReferencedKeysExistInCatalog() throws {
        let catalog = try loadCatalog()
        let keys = [
            // Detail view
            "smart_playlist.badge",
            "smart_playlist.edit_rules",
            "smart_playlist.a11y.play",
            "smart_playlist.a11y.shuffle",
            "smart_playlist.a11y.edit_rules",
            "smart_playlist.filter_placeholder",
            "smart_playlist.no_filter_match %@",
            "smart_playlist.empty.title",
            "smart_playlist.empty.detail %lld",
            "smart_playlist.not_found",
            "smart_playlist.rules.matches_all_tracks",
            "smart_playlist.rules.matches %@ %@",
            "smart_playlist.rules.clause_separator",
            // Builder view
            "smart_playlist.builder.title",
            "smart_playlist.builder.name_label",
            "smart_playlist.builder.name_placeholder",
            "smart_playlist.builder.a11y.name",
            "smart_playlist.builder.match_prefix",
            "smart_playlist.builder.match_suffix",
            "smart_playlist.builder.a11y.match_mode",
            "smart_playlist.builder.add_rule",
            "smart_playlist.builder.a11y.add_rule",
            "smart_playlist.builder.a11y.field",
            "smart_playlist.builder.a11y.operator",
            "smart_playlist.builder.a11y.remove_rule",
            "smart_playlist.builder.value_placeholder",
            "smart_playlist.builder.a11y.value",
            "smart_playlist.builder.a11y.value_days",
            "smart_playlist.builder.bool_yes",
            "smart_playlist.builder.bool_no",
            "smart_playlist.builder.days_suffix",
            "smart_playlist.builder.counting",
            "smart_playlist.builder.match_count %lld",
            "smart_playlist.builder.cancel",
            "smart_playlist.builder.save",
            "smart_playlist.builder.a11y.save",
            "smart_playlist.builder.default_name",
            // Field labels
            "smart_playlist.field.genre",
            "smart_playlist.field.artist",
            "smart_playlist.field.album",
            "smart_playlist.field.year",
            "smart_playlist.field.play_count",
            "smart_playlist.field.favorite",
            "smart_playlist.field.last_played",
            // Operator labels
            "smart_playlist.op.is",
            "smart_playlist.op.is_not",
            "smart_playlist.op.contains",
            "smart_playlist.op.greater_than",
            "smart_playlist.op.less_than",
            "smart_playlist.op.in_last",
            // Match mode labels
            "smart_playlist.match_mode.all",
            "smart_playlist.match_mode.any",
        ]
        for key in keys {
            guard let entry = catalog[key] as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any],
                  locs["en"] != nil else {
                XCTFail("Catalog key \(key) is missing or has no `en` localization")
                continue
            }
        }
    }

    /// The plural-aware footer count key carries `one`/`other` English
    /// variations that both keep the `%lld` placeholder.
    func testMatchCountKeyHasPluralVariations() throws {
        let catalog = try loadCatalog()
        let key = "smart_playlist.builder.match_count %lld"
        guard let entry = catalog[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let en = locs["en"] as? [String: Any],
              let variations = en["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else {
            return XCTFail("\(key) is missing its en plural variations")
        }
        let one = stringUnitValue(plural["one"])
        let other = stringUnitValue(plural["other"])
        XCTAssertEqual(one?.contains("%lld"), true, "`one` variation lost its %lld placeholder")
        XCTAssertEqual(other?.contains("%lld"), true, "`other` variation lost its %lld placeholder")
    }

    // MARK: - Catalog loading helpers (mirrors CountStringsTests)

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

    private func stringUnitValue(_ variation: Any?) -> String? {
        (variation as? [String: Any])?["stringUnit"]
            .flatMap { ($0 as? [String: Any])?["value"] as? String }
    }
}
