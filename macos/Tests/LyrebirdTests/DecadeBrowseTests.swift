import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Discover "Browse by Decade" deep-link.
///
/// Two contracts: the static `Decade` ramp and its label formatting are pure
/// value logic, and `AppModel.browseDecade(_:)` must stash a one-shot
/// `[start, start+9]` year window, force the Albums chip, switch to the Library,
/// and surrender that window exactly once via `consumePendingLibraryYearRange()`.
///
/// Same isolation contract as `DiscoverSongRadioRouteTests`: `AppModel` is
/// `@MainActor` and boots a live core pointed at a throwaway data dir.
@MainActor
final class DecadeBrowseTests: XCTestCase {

	override class func setUp() {
		super.setUp()
		let dir = NSTemporaryDirectory() + "lyrebird-decade-\(UUID().uuidString)"
		setenv("XDG_DATA_HOME", dir, 1)
	}

	func testDecadeRampCoversSixtiesThroughTwenties() {
		XCTAssertEqual(
			Decade.all.map(\.startYear),
			[1960, 1970, 1980, 1990, 2000, 2010, 2020],
			"the row renders the fixed '60s→'20s ramp, oldest first"
		)
	}

	func testShortLabelUsesTwoDigitApostropheForm() {
		XCTAssertEqual(Decade(startYear: 1980).shortLabel, "'80s")
		XCTAssertEqual(Decade(startYear: 2000).shortLabel, "'00s")
		XCTAssertEqual(Decade(startYear: 2020).shortLabel, "'20s")
	}

	func testBrowseDecadeStashesInclusiveTenYearWindowAndRoutesToLibrary() throws {
		let model = try AppModel()
		model.libraryTab = .artists

		model.browseDecade(startingYear: 1990)

		XCTAssertEqual(
			model.pendingLibraryYearRange,
			1990...1999,
			"a decade tile must stash the inclusive [start, start+9] window"
		)
		XCTAssertEqual(
			model.libraryTab, .albums,
			"the decade filter keys on album years, so the Albums chip is forced"
		)
		XCTAssertEqual(model.screen, .library, "tapping a decade routes to the Library")
		XCTAssertTrue(model.navPath.isEmpty, "the drill stack is reset on tab switch")
	}

	func testConsumePendingYearRangeIsOneShot() throws {
		let model = try AppModel()

		model.browseDecade(startingYear: 2010)

		XCTAssertEqual(
			model.consumePendingLibraryYearRange(),
			2010...2019,
			"the first consume hands back the pending window"
		)
		XCTAssertNil(
			model.consumePendingLibraryYearRange(),
			"the window is cleared after one read so a later Library visit isn't re-filtered"
		)
		XCTAssertNil(model.pendingLibraryYearRange)
	}
}
