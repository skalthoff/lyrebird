import SwiftUI

/// A keyboard chord — a single key plus its modifier set — modelled as a plain,
/// `Codable`, `Equatable` value so it can be persisted, diffed, and compared for
/// conflicts.
///
/// SwiftUI's own `KeyboardShortcut` / `KeyEquivalent` / `EventModifiers` are
/// deliberately *not* `Codable` or `Equatable`, which makes them useless as a
/// persistence or conflict-detection currency. `KeyChord` stores the chord as:
///
/// - `keyCharacter` — the `Character` backing the `KeyEquivalent` (the same
///   opaque scalar `KeyboardGlyphs` already switches on: a literal letter, or
///   one of the NSEvent function-key scalars for the arrows / space / etc.).
/// - `modifierFlags` — the raw `EventModifiers.RawValue` bitset.
///
/// Both are trivially `Codable`. Conversions back to the SwiftUI types are
/// lossless, so a stored chord round-trips to an identical `.keyboardShortcut`.
struct KeyChord: Codable, Equatable, Hashable {
	/// The chord's key, stored as the `Character` that backs `KeyEquivalent`.
	let keyCharacter: Character
	/// Raw `EventModifiers` bitset (`.command`, `.shift`, …).
	let modifierRawValue: Int

	init(key: KeyEquivalent, modifiers: EventModifiers) {
		self.keyCharacter = key.character
		self.modifierRawValue = modifiers.rawValue
	}

	init(keyCharacter: Character, modifiers: EventModifiers) {
		self.keyCharacter = keyCharacter
		self.modifierRawValue = modifiers.rawValue
	}

	/// The chord's modifier set, reconstructed from the stored bitset.
	var modifiers: EventModifiers { EventModifiers(rawValue: modifierRawValue) }

	/// The chord's key as a SwiftUI `KeyEquivalent`.
	var keyEquivalent: KeyEquivalent { KeyEquivalent(keyCharacter) }

	/// A live SwiftUI `KeyboardShortcut` for binding into menus / views.
	var keyboardShortcut: KeyboardShortcut {
		KeyboardShortcut(keyEquivalent, modifiers: modifiers)
	}

	/// Human-facing glyph rendering (⌃⌥⇧⌘ + key glyph), reusing the catalog's
	/// shared renderer so the editor and the help window draw chords
	/// identically.
	var glyphs: String {
		KeyboardGlyphs.render(key: keyEquivalent, modifiers: modifiers)
	}

	// MARK: - Codable
	//
	// `Character` isn't directly `Codable`; encode it as its `String` form and
	// decode the first scalar back. A chord's key is always exactly one
	// character, so the round-trip is lossless.

	private enum CodingKeys: String, CodingKey {
		case key
		case modifiers
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let keyString = try container.decode(String.self, forKey: .key)
		guard let first = keyString.first else {
			throw DecodingError.dataCorruptedError(
				forKey: .key,
				in: container,
				debugDescription: "Empty key string in persisted KeyChord"
			)
		}
		self.keyCharacter = first
		self.modifierRawValue = try container.decode(Int.self, forKey: .modifiers)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(String(keyCharacter), forKey: .key)
		try container.encode(modifierRawValue, forKey: .modifiers)
	}
}

extension KeyChord {
	/// Builds a `KeyChord` from a captured `NSEvent.keyDown`, or `nil` when the
	/// event can't be expressed as a usable chord.
	///
	/// Recording rules (matching what AppKit can actually fire as a menu key
	/// equivalent, and what users expect from a shortcut recorder):
	///
	/// - Only `.command` / `.option` / `.control` / `.shift` survive; the
	///   `.numericPad` / `.function` / caps-lock flags are stripped.
	/// - A bare key with no modifiers is rejected (it would shadow plain typing)
	///   *unless* it is a function-style key (arrows, etc.) — but to keep the
	///   scaffold safe we require at least one of ⌘/⌃/⌥ for letter/number keys.
	/// - The key character is normalised to the `KeyEquivalent`-backing scalar:
	///   `charactersIgnoringModifiers` lower-cased for ordinary keys, or the
	///   NSEvent function-key scalar for the arrow / special keys.
	static func from(event: NSEvent) -> KeyChord? {
		guard event.type == .keyDown else { return nil }

		// Map AppKit's modifier flags onto SwiftUI's EventModifiers, keeping
		// only the four chord-relevant modifiers.
		var mods: EventModifiers = []
		let flags = event.modifierFlags
		if flags.contains(.command) { mods.insert(.command) }
		if flags.contains(.option) { mods.insert(.option) }
		if flags.contains(.control) { mods.insert(.control) }
		if flags.contains(.shift) { mods.insert(.shift) }

		guard let character = keyCharacter(for: event) else { return nil }

		// Require a "real" command modifier for plain character keys so a
		// recorded shortcut can't swallow ordinary typing. Function-style keys
		// (arrows / page / etc.) are allowed with just ⌘/⌃/⌥ too — but a bare,
		// unmodified key is always rejected.
		let hasCommandModifier =
			mods.contains(.command) || mods.contains(.control) || mods.contains(.option)
		guard hasCommandModifier else { return nil }

		return KeyChord(keyCharacter: character, modifiers: mods)
	}

	/// Extract the `KeyEquivalent`-backing `Character` from a key-down event.
	///
	/// For the special keys SwiftUI names (`.leftArrow`, `.space`, …) we map the
	/// AppKit key code onto the same function-key scalar `KeyboardGlyphs`
	/// switches on, so a recorded arrow renders as "←" and round-trips to
	/// `.leftArrow`. Everything else uses `charactersIgnoringModifiers`
	/// lower-cased (AppKit draws ⌘N, not ⌘n, but the *equivalent* is the
	/// lowercase letter).
	private static func keyCharacter(for event: NSEvent) -> Character? {
		// Special keys by AppKit key code → KeyEquivalent-backing scalar.
		switch Int(event.keyCode) {
		case 123: return "\u{F702}"   // left arrow
		case 124: return "\u{F703}"   // right arrow
		case 126: return "\u{F700}"   // up arrow
		case 125: return "\u{F701}"   // down arrow
		case 49: return " "           // space
		case 53: return "\u{1B}"      // escape
		case 36, 76: return "\r"      // return / keypad enter
		case 48: return "\t"          // tab
		case 51: return "\u{8}"       // delete (backspace)
		case 117: return "\u{7F}"     // forward delete
		default: break
		}

		guard let raw = event.charactersIgnoringModifiers, let first = raw.first else {
			return nil
		}
		// A printable, non-whitespace character. Lower-case so "N" and "n" map
		// to the same equivalent (matching how `AppShortcuts` stores letters).
		guard first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else {
			return nil
		}
		return Character(first.lowercased())
	}
}
