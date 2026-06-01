import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the Keyboard Shortcuts help-window catalog: the glyph
/// renderer (the riskiest piece — named `KeyEquivalent` statics are backed by
/// opaque scalars) and the catalog's internal integrity.
final class AppShortcutsTests: XCTestCase {
	// MARK: - Glyph rendering

	func testModifierGlyphsRenderInHIGOrder() {
		XCTAssertEqual(KeyboardGlyphs.modifierGlyphs(.command), "⌘")
		XCTAssertEqual(KeyboardGlyphs.modifierGlyphs([.command, .shift]), "⇧⌘")
		XCTAssertEqual(KeyboardGlyphs.modifierGlyphs([.command, .option]), "⌥⌘")
		// Control → Option → Shift → Command regardless of set literal order.
		XCTAssertEqual(
			KeyboardGlyphs.modifierGlyphs([.command, .option, .control]),
			"⌃⌥⌘"
		)
	}

	func testCharacterKeyUppercases() {
		XCTAssertEqual(KeyboardGlyphs.render(key: "n", modifiers: .command), "⌘N")
		XCTAssertEqual(KeyboardGlyphs.render(key: "1", modifiers: .command), "⌘1")
		XCTAssertEqual(KeyboardGlyphs.render(key: ".", modifiers: .command), "⌘.")
	}

	func testNamedKeysRenderAsSymbolGlyphs() {
		XCTAssertEqual(KeyboardGlyphs.keyGlyph(.rightArrow), "→")
		XCTAssertEqual(KeyboardGlyphs.keyGlyph(.leftArrow), "←")
		XCTAssertEqual(KeyboardGlyphs.keyGlyph(.upArrow), "↑")
		XCTAssertEqual(KeyboardGlyphs.keyGlyph(.downArrow), "↓")
		XCTAssertEqual(KeyboardGlyphs.keyGlyph(.space), "␣")
	}

	func testCompoundChordRendering() {
		// ⌘⇧→ (Seek Forward) and ⌃⌥⌘← (Tile Left) are the most complex chords.
		XCTAssertEqual(
			KeyboardGlyphs.render(key: .rightArrow, modifiers: [.command, .shift]),
			"⇧⌘→"
		)
		XCTAssertEqual(
			KeyboardGlyphs.render(key: .leftArrow, modifiers: [.control, .option, .command]),
			"⌃⌥⌘←"
		)
	}

	// MARK: - Catalog integrity

	func testCatalogIDsAreUnique() {
		let ids = AppShortcuts.all.map(\.id)
		XCTAssertEqual(ids.count, Set(ids).count, "duplicate shortcut id in catalog")
	}

	func testEverySectionHasAtLeastOneShortcut() {
		for section in AppShortcuts.Section.allCases {
			XCTAssertFalse(
				AppShortcuts.all.filter { $0.section == section }.isEmpty,
				"section \(section) has no shortcuts"
			)
		}
	}

	func testEveryShortcutRendersNonEmptyGlyphs() {
		for shortcut in AppShortcuts.all {
			XCTAssertFalse(shortcut.glyphs.isEmpty, "empty glyphs for \(shortcut.id)")
		}
	}

	// MARK: - Search matching

	func testSearchMatchesByGlyph() {
		// Searching the chord text narrows to chords containing it. "⌥" only
		// appears on the Mini Player (⌘⌥P) and the two Tile commands (⌃⌥⌘←/→).
		let optionRows = AppShortcuts.all.filter { $0.matches("⌥") }
		XCTAssertEqual(Set(optionRows.map(\.id)),
		               ["view.mini_player", "window.tile_left", "window.tile_right"])
	}

	func testSearchMatchesByName() {
		// "volume" appears in both the raw keys (menu.playback.volume_*) and the
		// localized names ("Volume Up/Down"), so this holds whether or not the
		// test bundle has the string table loaded. It must surface exactly the
		// two volume rows.
		let rows = AppShortcuts.all.filter { $0.matches("volume") }
		XCTAssertEqual(Set(rows.map(\.id)),
		               ["playback.volume_up", "playback.volume_down"])
	}
}
