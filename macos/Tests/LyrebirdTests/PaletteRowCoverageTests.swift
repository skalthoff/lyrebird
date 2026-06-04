import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the command-palette action model as the single source of
/// truth for row labels + icons.
///
/// `PaletteRow` used to label/icon each action through two hand-maintained
/// static maps that drifted from `AppModel.paletteActions`. Those maps are
/// gone: the row now renders `Text(action.title)` and
/// `Image(systemName: action.symbol)` straight off the model, and search
/// matches on the owned `action.searchTitle`. This gate fails if any
/// registered action ships an empty `symbol` or `searchTitle` (which would
/// render a blank icon or make the action unsearchable) or if `searchTitle`
/// drifts away from the displayed `title`.
@MainActor
final class PaletteRowCoverageTests: XCTestCase {

	override class func setUp() {
		super.setUp()
		let dir = NSTemporaryDirectory() + "lyrebird-palette-\(UUID().uuidString)"
		setenv("XDG_DATA_HOME", dir, 1)
	}

	/// Every action exposes a non-empty symbol + searchTitle. A blank symbol
	/// renders an empty icon column; a blank searchTitle makes the verb
	/// impossible to find by typing.
	func testEveryPaletteActionHasSymbolAndSearchTitle() throws {
		let model = try AppModel()
		for action in model.paletteActions {
			XCTAssertFalse(
				action.symbol.isEmpty,
				"action \(action.id) has an empty symbol"
			)
			XCTAssertFalse(
				action.searchTitle.isEmpty,
				"action \(action.id) has an empty searchTitle"
			)
		}
	}

	/// `searchTitle` must stay in lockstep with the displayed `title`. The two
	/// are separate fields (one plain `String`, one `LocalizedStringKey`)
	/// because `LocalizedStringKey` can't be read back as a string; this guard
	/// is the contract that they don't silently diverge. We compare against
	/// the `LocalizedStringKey` built from `searchTitle` — equal keys mean the
	/// search text matches the (unlocalized) display literal.
	func testSearchTitleMatchesDisplayTitle() throws {
		let model = try AppModel()
		for action in model.paletteActions {
			XCTAssertEqual(
				action.title,
				LocalizedStringKey(action.searchTitle),
				"action \(action.id): searchTitle '\(action.searchTitle)' drifted from its display title"
			)
		}
	}
}
