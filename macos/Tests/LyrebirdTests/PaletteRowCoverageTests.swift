import XCTest

@testable import Lyrebird

/// Coverage for the command-palette row label/icon lookup tables.
///
/// `PaletteRow` labels and icons each action by id through two hand-maintained
/// static maps (`actionTitleById` / `actionSymbolById`), kept in sync with the
/// roster emitted by `AppModel.paletteActions`. A drift between the two renders
/// the raw id string and a generic bolt icon (the key-miss fallbacks) — exactly
/// the `nav.favorites` regression in #937. This gate fails if any registered
/// action id is missing from either map.
@MainActor
final class PaletteRowCoverageTests: XCTestCase {

	override class func setUp() {
		super.setUp()
		let dir = NSTemporaryDirectory() + "lyrebird-palette-\(UUID().uuidString)"
		setenv("XDG_DATA_HOME", dir, 1)
	}

	func testEveryPaletteActionHasATitleAndSymbolEntry() throws {
		let model = try AppModel()
		let actionIds = Set(model.paletteActions.map(\.id))

		let titleKeys = Set(PaletteRow.actionTitleById.keys)
		XCTAssertTrue(
			actionIds.isSubset(of: titleKeys),
			"actions missing from actionTitleById: \(actionIds.subtracting(titleKeys))"
		)

		let symbolKeys = Set(PaletteRow.actionSymbolById.keys)
		XCTAssertTrue(
			actionIds.isSubset(of: symbolKeys),
			"actions missing from actionSymbolById: \(actionIds.subtracting(symbolKeys))"
		)
	}
}
