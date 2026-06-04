import XCTest
@testable import Lyrebird

/// Coverage for the album editorial "About this album" data path (#68):
/// `AppModel.parseAlbumDetail(from:)` lifting Jellyfin's album `Overview`
/// field out of the `fetch_item` JSON, plus the hide-when-empty contract the
/// `AlbumDetailView.aboutSection` guard relies on.
///
/// `parseAlbumDetail` is a pure static function over a JSON string, so it can
/// be exercised without a live core. The shape used here mirrors what the
/// real server returns for a `MusicAlbum` with `Fields=...,Overview` (verified
/// against music.skalthoff.com): a root-level `"Overview"` string with `\n`
/// paragraph breaks.
///
/// `parseAlbumDetail` is `@MainActor`-isolated (it lives on the `@MainActor`
/// `AppModel`), so the suite is annotated `@MainActor` to call it
/// synchronously — matching the other AppModel-static test suites.
@MainActor
final class AlbumOverviewTests: XCTestCase {
	/// A populated `Overview` is carried through onto `AlbumDetail.overview`
	/// verbatim (the HTML strip happens later, in the view).
	func testParsesOverviewFromJSON() {
		let json = """
		{"Name":"÷","Overview":"Third studio album by Ed Sheeran.","Studios":[],"People":[]}
		"""
		let detail = AppModel.parseAlbumDetail(from: json)
		XCTAssertEqual(detail.overview, "Third studio album by Ed Sheeran.")
	}

	/// Multi-paragraph overviews (Jellyfin uses literal `\n` between
	/// paragraphs) survive the parse intact so the view can clamp / expand
	/// them.
	func testPreservesMultiParagraphOverview() {
		let json = """
		{"Name":"Batman Forever","Overview":"Soundtrack to the 1995 film.\\n\\nOnly five songs feature in the movie."}
		"""
		let detail = AppModel.parseAlbumDetail(from: json)
		XCTAssertEqual(
			detail.overview,
			"Soundtrack to the 1995 film.\n\nOnly five songs feature in the movie.")
	}

	/// A missing `Overview` key yields `nil` — the signal the About section
	/// uses to hide itself. The rest of the detail still parses.
	func testMissingOverviewIsNil() {
		let json = """
		{"Name":"Some Album","Studios":[{"Name":"Asylum"}],"PremiereDate":"2017-03-03T00:00:00.0000000Z"}
		"""
		let detail = AppModel.parseAlbumDetail(from: json)
		XCTAssertNil(detail.overview)
		// Sibling fields are unaffected by the new parse branch.
		XCTAssertEqual(detail.label, "Asylum")
	}

	/// An empty-string `Overview` collapses to `nil` so the section never
	/// renders an empty shell.
	func testEmptyOverviewIsNil() {
		let json = #"{"Name":"X","Overview":""}"#
		XCTAssertNil(AppModel.parseAlbumDetail(from: json).overview)
	}

	/// A whitespace-only `Overview` (spaces / tabs / newlines) likewise
	/// collapses to `nil`.
	func testWhitespaceOnlyOverviewIsNil() {
		let json = #"{"Name":"X","Overview":"  \n\t  "}"#
		XCTAssertNil(AppModel.parseAlbumDetail(from: json).overview)
	}

	/// A non-string `Overview` (defensive: a server quirk emitting a number /
	/// null) is treated as absent rather than crashing the parse.
	func testNonStringOverviewIsNil() {
		let json = #"{"Name":"X","Overview":42}"#
		XCTAssertNil(AppModel.parseAlbumDetail(from: json).overview)
	}

	/// Malformed JSON degrades to an all-`nil` detail, including `overview` —
	/// the parser never throws.
	func testGarbageJSONYieldsNilOverview() {
		let detail = AppModel.parseAlbumDetail(from: "not json at all")
		XCTAssertNil(detail.overview)
		XCTAssertNil(detail.label)
		XCTAssertTrue(detail.people.isEmpty)
	}

	// MARK: - Hide-when-empty contract

	/// The `aboutSection` renders iff `plainTextOverview(detail.overview)` is
	/// non-nil. These cases pin that end-to-end decision: a real overview
	/// shows, every empty variant hides. The HTML strip is shared with the
	/// artist bio, so HTML-only overviews ("<p></p>") collapse to nil and the
	/// album section hides exactly like the artist one.
	func testAboutSectionVisibilityFollowsPlainTextOverview() {
		// Present → visible.
		let present = AppModel.parseAlbumDetail(
			from: #"{"Overview":"<p>A landmark record.</p>"}"#)
		XCTAssertEqual(
			ArtistDetailView.plainTextOverview(present.overview),
			"A landmark record.")

		// Absent → hidden.
		let absent = AppModel.parseAlbumDetail(from: #"{"Name":"X"}"#)
		XCTAssertNil(ArtistDetailView.plainTextOverview(absent.overview))

		// HTML that strips to nothing → hidden.
		let htmlOnly = AppModel.parseAlbumDetail(
			from: #"{"Overview":"<p></p><br>"}"#)
		XCTAssertNil(ArtistDetailView.plainTextOverview(htmlOnly.overview))
	}
}
