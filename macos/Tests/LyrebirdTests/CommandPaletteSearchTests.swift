import XCTest

@testable import Lyrebird

/// Coverage for the command-palette action matcher
/// (`CommandPalette.actionMatches`).
///
/// The matcher replaced a `hasPrefix`-only filter that returned zero actions
/// for common substring queries — typing "preferences", "shuffle", "queue",
/// "favorites", or "library" matched nothing because every shipped action
/// title starts with a different word ("Open Preferences", "Toggle Shuffle",
/// "Clear Queue", "Go to Favorites", "Go to Library"). These tests pin the
/// substring + token-prefix contract so that regression can't return.
final class CommandPaletteSearchTests: XCTestCase {

	/// The exact queries called out in the audit: each is a substring of a
	/// shipped action title that the old prefix-only matcher dropped.
	func testSubstringQueriesThatPrefixMatchingMissed() {
		XCTAssertTrue(CommandPalette.actionMatches("Open Preferences", query: "preferences"))
		XCTAssertTrue(CommandPalette.actionMatches("Toggle Shuffle", query: "shuffle"))
		XCTAssertTrue(CommandPalette.actionMatches("Clear Queue", query: "queue"))
		XCTAssertTrue(CommandPalette.actionMatches("Go to Favorites", query: "favorites"))
		XCTAssertTrue(CommandPalette.actionMatches("Go to Library", query: "library"))
	}

	/// Matching is case-insensitive on both sides.
	func testCaseInsensitive() {
		XCTAssertTrue(CommandPalette.actionMatches("Toggle Shuffle", query: "SHUFFLE"))
		XCTAssertTrue(CommandPalette.actionMatches("Clear Queue", query: "Queue"))
	}

	/// A leading-edge prefix of the whole title still matches (the old
	/// behaviour stays valid — we widened, not replaced, the match).
	func testWholeTitlePrefixStillMatches() {
		XCTAssertTrue(CommandPalette.actionMatches("Play Next", query: "play"))
		XCTAssertTrue(CommandPalette.actionMatches("Play Next", query: "play n"))
	}

	/// A prefix of a non-leading word matches via the token-prefix pass even
	/// when it isn't a contiguous substring of the leading word.
	func testTokenPrefixMatches() {
		XCTAssertTrue(CommandPalette.actionMatches("Go to Favorites", query: "fav"))
		XCTAssertTrue(CommandPalette.actionMatches("Add to Queue", query: "que"))
	}

	/// Mid-word substrings match (contains is the primary pass).
	func testInteriorSubstringMatches() {
		XCTAssertTrue(CommandPalette.actionMatches("Toggle Shuffle", query: "ggle"))
	}

	/// A query that appears in no title (and is no token prefix) does not match.
	func testNonMatchReturnsFalse() {
		XCTAssertFalse(CommandPalette.actionMatches("Clear Queue", query: "xyz"))
		XCTAssertFalse(CommandPalette.actionMatches("Go to Home", query: "library"))
	}

	/// Whitespace-only / empty queries are treated as "match" (the caller
	/// routes the empty-query case to the pinned/recent ordering, but the
	/// matcher itself must not spuriously reject a blank needle).
	func testEmptyAndWhitespaceQueryMatches() {
		XCTAssertTrue(CommandPalette.actionMatches("Anything", query: ""))
		XCTAssertTrue(CommandPalette.actionMatches("Anything", query: "   "))
	}

	/// Leading/trailing whitespace around a real query is trimmed before
	/// matching so a stray space doesn't drop an otherwise-valid hit.
	func testQueryIsTrimmed() {
		XCTAssertTrue(CommandPalette.actionMatches("Clear Queue", query: "  queue  "))
	}
}
