import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the keyboard-shortcut customization model (#120 / #265): the
/// `KeyChord` value type's Codable round-trip + glyph rendering, and the
/// `AppModel` override map's resolution, conflict detection, and
/// set/reset/reset-all persistence contract.
///
/// `AppModel` is `@MainActor` and constructing it boots a live `LyrebirdCore`,
/// so the model-touching tests run main-actor isolated against a throwaway data
/// dir (via `XDG_DATA_HOME`) and scrub the persisted key around each test to
/// stay hermetic — the same pattern as `AutoplayWhenQueueEndsTests`. The pure
/// `KeyChord` tests need neither.
@MainActor
final class KeyboardShortcutCustomizationTests: XCTestCase {

	/// Persisted override-map key, pinned to `AppModel.shortcutOverridesKey`.
	private let key = "shortcuts.overrides"

	override class func setUp() {
		super.setUp()
		let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
		setenv("XDG_DATA_HOME", dir, 1)
	}

	override func setUp() {
		super.setUp()
		UserDefaults.standard.removeObject(forKey: key)
	}

	override func tearDown() {
		UserDefaults.standard.removeObject(forKey: key)
		super.tearDown()
	}

	// MARK: - KeyChord value type (pure)

	func testKeyChordRoundTripsThroughCodable() throws {
		let chord = KeyChord(key: "k", modifiers: [.command, .shift])
		let json = AppModel.encodeShortcutOverrides(["nav.command_palette": chord])
		let decoded = AppModel.decodeShortcutOverrides(json)

		XCTAssertEqual(decoded["nav.command_palette"], chord)
		XCTAssertEqual(decoded["nav.command_palette"]?.keyCharacter, "k")
		XCTAssertEqual(decoded["nav.command_palette"]?.modifiers, [.command, .shift])
	}

	func testKeyChordRoundTripsNamedKeyScalar() throws {
		// Arrow keys are backed by an NSEvent function-key scalar; the round-trip
		// must preserve it so a remapped arrow still renders + binds correctly.
		let chord = KeyChord(key: .rightArrow, modifiers: .command)
		let json = AppModel.encodeShortcutOverrides(["playback.next": chord])
		let decoded = AppModel.decodeShortcutOverrides(json)

		XCTAssertEqual(decoded["playback.next"], chord)
		XCTAssertEqual(decoded["playback.next"]?.glyphs, "⌘→")
	}

	func testKeyChordGlyphsMatchCatalogRenderer() {
		XCTAssertEqual(KeyChord(key: "n", modifiers: .command).glyphs, "⌘N")
		XCTAssertEqual(
			KeyChord(key: .leftArrow, modifiers: [.control, .option, .command]).glyphs,
			"⌃⌥⌘←"
		)
	}

	func testDecodeMalformedOverridesYieldsEmptyMap() {
		XCTAssertTrue(AppModel.decodeShortcutOverrides("not json").isEmpty)
		XCTAssertTrue(AppModel.decodeShortcutOverrides("").isEmpty)
		// A stale shape (array instead of dict) must not wedge the editor.
		XCTAssertTrue(AppModel.decodeShortcutOverrides("[\"x\"]").isEmpty)
	}

	// MARK: - Non-editable actions

	/// Bare-Space Play/Pause is bound by an `NSEvent` monitor, not a menu
	/// key-equivalent, so the editor must not offer it for remapping — but it
	/// stays in the catalog (the help window advertises ⎵). This pins the
	/// exclusion so a future catalog edit can't silently surface an un-bindable
	/// row.
	func testPlayPauseStaysInCatalogButIsNotEditable() {
		XCTAssertTrue(
			AppShortcuts.all.contains { $0.id == "playback.play_pause" },
			"play/pause must remain in the help-window catalog"
		)
		XCTAssertTrue(
			PreferencesKeyboard.nonEditableActionIds.contains("playback.play_pause"),
			"play/pause must be excluded from the remap editor"
		)
	}

	// MARK: - Resolution

	func testResolvedChordFallsBackToCatalogDefault() throws {
		let model = try AppModel()
		// nav.home ships as ⌘1 in the catalog.
		let resolved = model.resolvedChord(for: "nav.home")
		XCTAssertEqual(resolved, KeyChord(key: "1", modifiers: .command))
		XCTAssertFalse(model.isShortcutCustomized("nav.home"))
	}

	func testResolvedChordReturnsNilForUnknownAction() throws {
		let model = try AppModel()
		XCTAssertNil(model.resolvedChord(for: "does.not.exist"))
		XCTAssertNil(model.resolvedShortcut(for: "does.not.exist"))
	}

	func testOverrideShadowsDefault() throws {
		let model = try AppModel()
		let newChord = KeyChord(key: "h", modifiers: [.command, .shift])
		let conflicts = model.setShortcut(newChord, for: "nav.home")

		XCTAssertTrue(conflicts.isEmpty, "⌘⇧H is unused, so no conflict")
		XCTAssertEqual(model.resolvedChord(for: "nav.home"), newChord)
		XCTAssertTrue(model.isShortcutCustomized("nav.home"))
	}

	// MARK: - Conflict detection (pure)

	func testConflictDetectedAgainstAnotherActionsDefault() throws {
		let model = try AppModel()
		// nav.library ships as ⌘2. Trying to give nav.home ⌘2 must clash.
		let clashing = KeyChord(key: "2", modifiers: .command)
		let conflicts = model.conflictingActionIds(for: clashing, excluding: "nav.home")

		XCTAssertEqual(conflicts, ["nav.library"])
		XCTAssertTrue(model.wouldConflict(clashing, for: "nav.home"))
	}

	func testSetShortcutRefusesConflictAndLeavesMapUnchanged() throws {
		let model = try AppModel()
		let clashing = KeyChord(key: "2", modifiers: .command)  // nav.library's chord
		let conflicts = model.setShortcut(clashing, for: "nav.home")

		XCTAssertEqual(conflicts, ["nav.library"], "the clash is reported back")
		XCTAssertFalse(model.isShortcutCustomized("nav.home"), "nothing was written")
		XCTAssertEqual(
			model.resolvedChord(for: "nav.home"),
			KeyChord(key: "1", modifiers: .command),
			"nav.home still resolves to its default"
		)
	}

	func testChordEqualToItsOwnDefaultIsNotAConflict() throws {
		let model = try AppModel()
		// Re-assigning nav.home its own default chord must succeed (and clear any
		// override), not self-conflict.
		let ownDefault = KeyChord(key: "1", modifiers: .command)
		let conflicts = model.setShortcut(ownDefault, for: "nav.home")
		XCTAssertTrue(conflicts.isEmpty)
	}

	// MARK: - Reset semantics

	func testSettingDefaultChordClearsOverride() throws {
		let model = try AppModel()
		// Customize, then set back to the catalog default — the override should
		// drop out entirely so `isShortcutCustomized` stays honest.
		model.setShortcut(KeyChord(key: "h", modifiers: [.command, .shift]), for: "nav.home")
		XCTAssertTrue(model.isShortcutCustomized("nav.home"))

		model.setShortcut(KeyChord(key: "1", modifiers: .command), for: "nav.home")
		XCTAssertFalse(
			model.isShortcutCustomized("nav.home"),
			"re-setting the default must clear the override, not store a redundant one"
		)
	}

	func testResetShortcutRestoresDefault() throws {
		let model = try AppModel()
		model.setShortcut(KeyChord(key: "j", modifiers: .command), for: "nav.search")
		XCTAssertTrue(model.isShortcutCustomized("nav.search"))

		model.resetShortcut(for: "nav.search")
		XCTAssertFalse(model.isShortcutCustomized("nav.search"))
		XCTAssertEqual(
			model.resolvedChord(for: "nav.search"),
			KeyChord(key: "3", modifiers: .command)
		)
	}

	func testResetAllClearsEveryOverride() throws {
		let model = try AppModel()
		model.setShortcut(KeyChord(key: "h", modifiers: [.command, .shift]), for: "nav.home")
		model.setShortcut(KeyChord(key: "j", modifiers: [.command, .shift]), for: "nav.search")
		XCTAssertEqual(model.shortcutOverrides.count, 2)

		model.resetAllShortcuts()
		XCTAssertTrue(model.shortcutOverrides.isEmpty)
	}

	// MARK: - Persistence round-trip

	func testOverridePersistsAcrossModelConstruction() throws {
		let first = try AppModel()
		let chord = KeyChord(key: "h", modifiers: [.command, .shift])
		first.setShortcut(chord, for: "nav.home")

		// A freshly-constructed model reads the persisted map from UserDefaults.
		let second = try AppModel()
		XCTAssertEqual(second.resolvedChord(for: "nav.home"), chord)
		XCTAssertTrue(second.isShortcutCustomized("nav.home"))
	}

	func testResetPersistsRemoval() throws {
		let first = try AppModel()
		first.setShortcut(KeyChord(key: "h", modifiers: [.command, .shift]), for: "nav.home")
		first.resetShortcut(for: "nav.home")

		let second = try AppModel()
		XCTAssertFalse(
			second.isShortcutCustomized("nav.home"),
			"a reset must persist as a removal, not leave the stale override on disk"
		)
	}
}
