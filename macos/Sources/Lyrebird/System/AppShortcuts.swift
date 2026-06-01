import SwiftUI

/// Single source of truth for the app's keyboard-shortcut map.
///
/// The menu commands in `LyrebirdCommands` declare the *live*
/// `.keyboardShortcut(...)` bindings; this catalog mirrors them as plain data
/// so the Keyboard Shortcuts help window (`KeyboardShortcutsView`) and the menus
/// can never drift in *what they advertise*. Each entry pairs a localized name
/// key (the same `menu.*` key the menu item uses, so the help window reads
/// identically to the menu) with the `KeyEquivalent` + `EventModifiers` that
/// produce the shortcut, plus a precomputed glyph string for display.
///
/// Adding a new menu shortcut means adding a row here in the same change — the
/// help window then surfaces it automatically. Kept as a flat `[Shortcut]`
/// rather than a tree so search (which ignores section boundaries) is a trivial
/// filter and grouping is a `Dictionary(grouping:)`.
enum AppShortcuts {
	/// One row in the shortcut map.
	struct Shortcut: Identifiable {
		/// Stable identifier (also the dedupe / diff key).
		let id: String
		/// Raw localization key for the action name — the same `menu.*` key the
		/// menu item renders, so the help window and the menu read identically.
		/// Stored as a `String` (not `LocalizedStringKey`) so search can resolve
		/// it via `NSLocalizedString` without reflecting into the opaque
		/// `LocalizedStringKey` type.
		let nameKeyString: String
		/// SwiftUI-facing localized name, derived from `nameKeyString`.
		var nameKey: LocalizedStringKey { LocalizedStringKey(nameKeyString) }
		/// Resolved (translated) action name, used for search matching and as
		/// the row's accessibility label.
		var localizedName: String { NSLocalizedString(nameKeyString, comment: "") }
		let section: Section
		let key: KeyEquivalent
		let modifiers: EventModifiers

		/// Human-facing rendering of `modifiers` + `key` using the standard
		/// macOS symbol glyphs (⌃⌥⇧⌘ then the key glyph). Order matches the
		/// Apple HIG modifier-key ordering shown in menu key-equivalents.
		var glyphs: String {
			KeyboardGlyphs.render(key: key, modifiers: modifiers)
		}

		/// Whether this row matches a (pre-lowercased, non-empty) search needle.
		/// Matches against the resolved localized name plus the glyph string so
		/// a user can search by either the action ("volume") or the chord
		/// ("⌘→" / "cmd").
		func matches(_ needle: String) -> Bool {
			let hay = (localizedName + " " + glyphs).lowercased()
			return hay.contains(needle)
		}
	}

	/// Logical groups, ordered as they appear in the menu bar (File → View →
	/// Playback → Window). The `titleKey` reuses the menu-section vocabulary so
	/// the help window's section headers read like the menu bar.
	enum Section: Int, CaseIterable, Identifiable {
		case file
		case view
		case playback
		case window

		var id: Int { rawValue }

		var titleKey: LocalizedStringKey {
			switch self {
			case .file: return "shortcuts.section.file"
			case .view: return "shortcuts.section.view"
			case .playback: return "shortcuts.section.playback"
			case .window: return "shortcuts.section.window"
			}
		}
	}

	/// The full catalog. Mirrors every `.keyboardShortcut(...)` in
	/// `LyrebirdCommands` (File / View / Playback / Window). Disabled-by-default
	/// menu items (Show Sidebar, Show Queue) are intentionally omitted until
	/// their actions are wired — advertising a no-op shortcut would mislead.
	static let all: [Shortcut] = [
		// File
		Shortcut(id: "file.new_playlist", nameKeyString: "menu.file.new_playlist",
		         section: .file, key: "n", modifiers: .command),

		// View / navigation
		Shortcut(id: "nav.home", nameKeyString: "menu.nav.home",
		         section: .view, key: "1", modifiers: .command),
		Shortcut(id: "nav.library", nameKeyString: "menu.nav.library",
		         section: .view, key: "2", modifiers: .command),
		Shortcut(id: "nav.search", nameKeyString: "menu.nav.search",
		         section: .view, key: "3", modifiers: .command),
		Shortcut(id: "nav.find", nameKeyString: "menu.nav.find",
		         section: .view, key: "f", modifiers: .command),
		Shortcut(id: "nav.now_playing", nameKeyString: "menu.nav.now_playing",
		         section: .view, key: "l", modifiers: .command),
		Shortcut(id: "nav.command_palette", nameKeyString: "menu.nav.command_palette",
		         section: .view, key: "k", modifiers: .command),
		Shortcut(id: "view.mini_player", nameKeyString: "menu.view.mini_player",
		         section: .view, key: "p", modifiers: [.command, .option]),

		// Playback
		Shortcut(id: "playback.play_pause", nameKeyString: "shortcuts.playback.play_pause",
		         section: .playback, key: .space, modifiers: []),
		Shortcut(id: "playback.next", nameKeyString: "menu.playback.next",
		         section: .playback, key: .rightArrow, modifiers: .command),
		Shortcut(id: "playback.previous", nameKeyString: "menu.playback.previous",
		         section: .playback, key: .leftArrow, modifiers: .command),
		Shortcut(id: "playback.volume_up", nameKeyString: "menu.playback.volume_up",
		         section: .playback, key: .upArrow, modifiers: .command),
		Shortcut(id: "playback.volume_down", nameKeyString: "menu.playback.volume_down",
		         section: .playback, key: .downArrow, modifiers: .command),
		Shortcut(id: "playback.seek_forward", nameKeyString: "menu.playback.seek_forward",
		         section: .playback, key: .rightArrow, modifiers: [.command, .shift]),
		Shortcut(id: "playback.seek_back", nameKeyString: "menu.playback.seek_back",
		         section: .playback, key: .leftArrow, modifiers: [.command, .shift]),
		Shortcut(id: "playback.stop", nameKeyString: "menu.playback.stop",
		         section: .playback, key: ".", modifiers: .command),

		// Window
		Shortcut(id: "window.tile_left", nameKeyString: "menu.window.tile_left",
		         section: .window, key: .leftArrow, modifiers: [.control, .option, .command]),
		Shortcut(id: "window.tile_right", nameKeyString: "menu.window.tile_right",
		         section: .window, key: .rightArrow, modifiers: [.control, .option, .command]),
	]

	/// Scene identity for the Keyboard Shortcuts help `Window`. Centralised so
	/// the scene declaration and the `openWindow(id:)` call site agree.
	static let windowID = "shortcuts-help"
}

/// Renders a `KeyEquivalent` + `EventModifiers` pair as the macOS symbol
/// glyphs (⌃⌥⇧⌘ + key glyph). Pure, side-effect-free, and `static` so both the
/// catalog and any future caller can share one rendering of "what does this
/// chord look like".
enum KeyboardGlyphs {
	static func render(key: KeyEquivalent, modifiers: EventModifiers) -> String {
		modifierGlyphs(modifiers) + keyGlyph(key)
	}

	/// Modifier glyphs in HIG order: Control, Option, Shift, Command.
	static func modifierGlyphs(_ modifiers: EventModifiers) -> String {
		var out = ""
		if modifiers.contains(.control) { out += "⌃" }
		if modifiers.contains(.option) { out += "⌥" }
		if modifiers.contains(.shift) { out += "⇧" }
		if modifiers.contains(.command) { out += "⌘" }
		return out
	}

	/// Glyph for the bound key. `KeyEquivalent`'s named statics (`.space`,
	/// `.leftArrow`, …) are backed by specific `Character` scalars, so we switch
	/// on `key.character` rather than the (non-`Equatable`) `KeyEquivalent`
	/// itself. A plain character key uppercases — matching how AppKit draws menu
	/// key equivalents (⌘N, not ⌘n).
	static func keyGlyph(_ key: KeyEquivalent) -> String {
		// KeyEquivalent's named statics back their `.character` with the
		// NSEvent function-key scalars (U+F700–F703 for the arrows) or the
		// literal control scalars — verified empirically, since the type
		// exposes no case to switch on directly.
		switch key.character {
		case " ": return "␣"            // .space   (U+0020)
		case "\u{F702}": return "←"     // .leftArrow
		case "\u{F703}": return "→"     // .rightArrow
		case "\u{F700}": return "↑"     // .upArrow
		case "\u{F701}": return "↓"     // .downArrow
		case "\u{1B}": return "⎋"       // .escape  (U+001B)
		case "\r": return "↩"           // .return  (U+000D)
		case "\t": return "⇥"           // .tab     (U+0009)
		case "\u{8}", "\u{7F}": return "⌫" // .delete (U+0008)
		default: return String(key.character).uppercased()
		}
	}
}
