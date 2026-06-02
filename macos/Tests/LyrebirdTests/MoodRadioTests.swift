import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Mood / Decade radio model and the `/Items` query the
/// stations build.
///
/// The mood set is pure value logic sourced from `06-screen-specs.md` §9
/// ("chill, focus, workout, sleep, party"), and `availableMoods` must start
/// empty so the Mood radio row hides itself on a library that hasn't been
/// probed / has no mood tags.
///
/// The Decade / Mood stations also add two new dimensions to the shared
/// `/Items` query — a comma-joined `Years` window and a pipe-joined `Tags`
/// list — and parse their response through `parseTracksFromItems`. Both the
/// query-param assembly and the parse path are exercised here without a live
/// session via the `itemsQueryItems` / `parseTracksFromItemsForTesting` seams.
@MainActor
final class MoodRadioTests: XCTestCase {

	override class func setUp() {
		super.setUp()
		let dir = NSTemporaryDirectory() + "lyrebird-mood-\(UUID().uuidString)"
		setenv("XDG_DATA_HOME", dir, 1)
	}

	func testMoodSetMatchesSpecTagsInOrder() {
		XCTAssertEqual(
			AppModel.Mood.all.map(\.tag),
			["chill", "focus", "workout", "sleep", "party"],
			"the mood row carries the five spec moods, in spec order"
		)
	}

	func testEachMoodHasADistinctLabelAndSymbol() {
		let labels = AppModel.Mood.all.map(\.label)
		let symbols = AppModel.Mood.all.map(\.symbol)
		XCTAssertEqual(Set(labels).count, labels.count, "labels are distinct")
		XCTAssertEqual(Set(symbols).count, symbols.count, "tile glyphs are distinct")
		XCTAssertFalse(symbols.contains(where: \.isEmpty), "every mood carries a glyph")
	}

	func testAvailableMoodsStartsEmptySoTheRowHidesUntilProbed() throws {
		let model = try AppModel()
		XCTAssertTrue(
			model.availableMoods.isEmpty,
			"no moods are surfaced until probeAvailableMoods() confirms tagged tracks exist"
		)
	}

	// MARK: - /Items query params (Years / Tags)

	private func value(_ items: [URLQueryItem], _ name: String) -> String? {
		items.first { $0.name == name }?.value
	}

	func testDecadeStationEmitsCommaJoinedYearsWindow() {
		let items = AppModel.itemsQueryItems(
			includeItemTypes: "Audio",
			sortBy: "Random",
			sortOrder: "Ascending",
			filters: nil,
			limit: 100,
			extraFields: [],
			minDateLastSaved: nil,
			parentId: nil,
			years: Array(1990...1999),
			tags: nil
		)
		XCTAssertEqual(
			value(items, "Years"),
			"1990,1991,1992,1993,1994,1995,1996,1997,1998,1999",
			"a decade station must expand its ten-year window into a comma-joined Years param"
		)
		XCTAssertNil(value(items, "Tags"), "a pure decade station carries no Tags filter")
		XCTAssertEqual(value(items, "SortBy"), "Random", "stations are server-shuffled")
		XCTAssertEqual(value(items, "Limit"), "100")
	}

	func testMoodStationEmitsPipeJoinedTags() {
		let items = AppModel.itemsQueryItems(
			includeItemTypes: "Audio",
			sortBy: "Random",
			sortOrder: "Ascending",
			filters: nil,
			limit: 1,
			extraFields: [],
			minDateLastSaved: nil,
			parentId: nil,
			years: nil,
			tags: ["chill", "focus"]
		)
		XCTAssertEqual(
			value(items, "Tags"),
			"chill|focus",
			"Jellyfin's Tags filter is pipe-delimited (OR semantics)"
		)
		XCTAssertNil(value(items, "Years"), "a pure mood station carries no Years window")
	}

	func testEmptyYearsAndTagsAreOmittedNotEmitted() {
		let items = AppModel.itemsQueryItems(
			includeItemTypes: "Audio",
			sortBy: "Random",
			sortOrder: "Ascending",
			filters: nil,
			limit: 1,
			extraFields: [],
			minDateLastSaved: nil,
			parentId: nil,
			years: [],
			tags: []
		)
		XCTAssertNil(value(items, "Years"), "an empty year window must not emit a blank Years param")
		XCTAssertNil(value(items, "Tags"), "an empty tag list must not emit a blank Tags param")
	}

	// MARK: - Response parsing (post-URLSession half of fetchRadioTracks)

	func testParsesItemsEnvelopeIntoTracks() throws {
		let json = """
		{
		  "Items": [
		    { "Id": "a1", "Name": "Track One", "Album": "LP", "ProductionYear": 1994 },
		    { "Id": "a2", "Name": "Track Two", "AlbumArtist": "Someone" }
		  ],
		  "TotalRecordCount": 2
		}
		""".data(using: .utf8)!

		let tracks = AppModel.parseTracksFromItemsForTesting(data: json)
		XCTAssertEqual(tracks.map(\.id), ["a1", "a2"], "both well-formed tracks parse out of the envelope")
		XCTAssertEqual(tracks.first?.year, 1994, "ProductionYear flows into the typed Track")
	}

	func testDropsBlankAndMalformedEntries() throws {
		let json = """
		{
		  "Items": [
		    { "Id": "", "Name": "No Id" },
		    { "Id": "ok", "Name": "" },
		    { "Name": "Missing Id" },
		    { "Id": "good", "Name": "Real Track" }
		  ]
		}
		""".data(using: .utf8)!

		let tracks = AppModel.parseTracksFromItemsForTesting(data: json)
		XCTAssertEqual(
			tracks.map(\.id), ["good"],
			"entries without a usable Id/Name are dropped so blank rows never enter the shuffle queue"
		)
	}

	func testEmptyOrGarbageResponseParsesToNoTracks() throws {
		XCTAssertTrue(
			AppModel.parseTracksFromItemsForTesting(data: Data("not json".utf8)).isEmpty,
			"a non-JSON body yields an empty station rather than crashing"
		)
		XCTAssertTrue(
			AppModel.parseTracksFromItemsForTesting(data: Data(#"{"Items":[]}"#.utf8)).isEmpty,
			"an empty Items array yields an empty station (callers turn this into a user-facing message)"
		)
	}
}
