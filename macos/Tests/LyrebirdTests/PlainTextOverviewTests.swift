import XCTest
@testable import Lyrebird

/// Unit coverage for `ArtistDetailView.plainTextOverview(_:)`, the hand-rolled
/// HTML→plain-text strip used by the Artist detail About section. The AppKit
/// `NSAttributedString` HTML importer is main-thread-only and slow, so the
/// biography text is sanitized by this pure static function instead — which
/// makes it cheap to test in isolation.
final class PlainTextOverviewTests: XCTestCase {
	/// Plain text with no markup and no entities is returned verbatim
	/// (aside from surrounding-whitespace trimming).
	func testPlainTextPassesThroughTrimmed() {
		let input = "  Radiohead formed in Abingdon in 1985.  "
		XCTAssertEqual(
			ArtistDetailView.plainTextOverview(input),
			"Radiohead formed in Abingdon in 1985.")
	}

	/// A single-paragraph wrapper is unwrapped to its bare text: the `<p>` and
	/// `</p>` tags collapse to newlines that trimming then removes.
	func testStripsParagraphWrapper() {
		XCTAssertEqual(
			ArtistDetailView.plainTextOverview("<p>Hello world</p>"),
			"Hello world")
	}

	/// No `<...>` markup leaks through, and block-level structure is preserved
	/// as single newlines (consecutive newlines are collapsed).
	func testStripsTagsWithoutLeavingMarkup() {
		let input = "<p>First line.</p><p>Second line.</p>"
		guard let result = ArtistDetailView.plainTextOverview(input) else {
			return XCTFail("expected non-nil plain text")
		}
		XCTAssertFalse(result.contains("<"), "no markup should remain: \(result)")
		XCTAssertFalse(result.contains(">"), "no markup should remain: \(result)")
		XCTAssertEqual(result, "First line.\nSecond line.")
	}

	/// `<br>` line-break tags become newlines.
	func testConvertsBreakTagsToNewlines() {
		XCTAssertEqual(
			ArtistDetailView.plainTextOverview("Line one<br>Line two"),
			"Line one\nLine two")
	}

	/// The handful of HTML entities Jellyfin actually emits are decoded back to
	/// their literal characters.
	func testDecodesCommonEntities() {
		let input = "Simon &amp; Garfunkel said &quot;hello&quot; &lt;here&gt; &#39;now&#39;"
		XCTAssertEqual(
			ArtistDetailView.plainTextOverview(input),
			"Simon & Garfunkel said \"hello\" <here> 'now'")
	}

	/// A `nil` overview yields `nil` — the signal the About section uses to hide
	/// itself entirely.
	func testNilInputReturnsNil() {
		XCTAssertNil(ArtistDetailView.plainTextOverview(nil))
	}

	/// An empty / whitespace-only / empty-markup overview reduces to `nil`.
	func testEmptyAndWhitespaceReturnNil() {
		XCTAssertNil(ArtistDetailView.plainTextOverview(""))
		XCTAssertNil(ArtistDetailView.plainTextOverview("   \n\t  "))
		XCTAssertNil(ArtistDetailView.plainTextOverview("<p></p><br>"))
	}

	/// The optional result can be safely unwrapped and substring-checked.
	func testContainsCheckOnUnwrappedResult() {
		let result = ArtistDetailView.plainTextOverview("<p>Born in 1980</p>")
		XCTAssertEqual(result, "Born in 1980")
		XCTAssertTrue(result?.contains("Born in 1980") ?? false)
	}
}
