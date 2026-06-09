import SwiftUI

/// Keyboard-shortcut customization (#120 / #265).
///
/// The app's menu key-equivalents are declared as plain data in `AppShortcuts`.
/// This extension layers a *user override* map on top: an `actionId -> KeyChord`
/// dictionary the Keyboard pane edits, persisted as JSON in `UserDefaults` via
/// the same `@Observable` → JSON bridge the command-palette recents (#308) and
/// the mini-player flag use, since `@Observable` can't reach `@AppStorage`.
///
/// The store is the single source of truth for "what chord does this action
/// have right now": `resolvedChord(for:)` returns the override if one exists,
/// else the catalog default. `LyrebirdCommands` resolves every menu shortcut
/// through it (via `model.resolvedShortcut(for:)`), so a remap in the editor
/// actually re-binds the live menu key-equivalent — this is not a cosmetic
/// scaffold.
///
/// ## Conflict detection
///
/// Two actions must not resolve to the same chord. `conflictingActionIds(...)`
/// is a pure function over the *effective* map (defaults merged with overrides),
/// so the editor can warn inline before committing and the model can refuse a
/// genuinely clashing assignment. Storing ids (not the chord structs) keeps the
/// store decoupled from the live roster: an id that no longer resolves is simply
/// skipped on rebuild and the persisted entry is harmless.
extension AppModel {
	/// UserDefaults key for the JSON-encoded `[actionId: KeyChord]` override map.
	static let shortcutOverridesKey = "shortcuts.overrides"

	// MARK: - Resolution

	/// The chord currently in effect for `actionId`: the user's override if one
	/// is set, otherwise the catalog default. Returns `nil` only for an unknown
	/// id (not in `AppShortcuts.all` and not overridden).
	func resolvedChord(for actionId: String) -> KeyChord? {
		if let override = shortcutOverrides[actionId] {
			return override
		}
		return AppShortcuts.all.first { $0.id == actionId }?.defaultChord
	}

	/// The live `KeyboardShortcut` for `actionId`, for binding into a menu /
	/// view. `nil` for an unknown id so the call site can fall through to no
	/// shortcut rather than guessing.
	func resolvedShortcut(for actionId: String) -> KeyboardShortcut? {
		resolvedChord(for: actionId)?.keyboardShortcut
	}

	/// Whether `actionId` currently differs from its catalog default.
	func isShortcutCustomized(_ actionId: String) -> Bool {
		shortcutOverrides[actionId] != nil
	}

	// MARK: - Conflict detection (pure)

	/// The effective chord map (catalog defaults with overrides applied) keyed
	/// by action id. The basis for conflict detection and for resolving the
	/// menus.
	var effectiveShortcutMap: [String: KeyChord] {
		var map: [String: KeyChord] = [:]
		for shortcut in AppShortcuts.all {
			map[shortcut.id] = shortcut.defaultChord
		}
		for (id, chord) in shortcutOverrides {
			map[id] = chord
		}
		return map
	}

	/// All action ids — other than `excluding` — whose effective chord equals
	/// `chord`. Empty means "no conflict". Used by the editor to warn before a
	/// remap and to highlight clashing rows.
	///
	/// Pure over `effectiveShortcutMap`, so it's trivially unit-testable and
	/// free of side effects.
	func conflictingActionIds(for chord: KeyChord, excluding actionId: String) -> [String] {
		effectiveShortcutMap
			.filter { $0.key != actionId && $0.value == chord }
			.map(\.key)
			.sorted()
	}

	/// Convenience: does assigning `chord` to `actionId` collide with any other
	/// action's effective chord?
	func wouldConflict(_ chord: KeyChord, for actionId: String) -> Bool {
		!conflictingActionIds(for: chord, excluding: actionId).isEmpty
	}

	// MARK: - Mutations

	/// Assign `chord` to `actionId`, persisting the override. When the chord
	/// equals the catalog default the override is *cleared* instead (so the map
	/// only ever holds genuine customizations and `isShortcutCustomized`
	/// stays honest).
	///
	/// Returns the conflicting action ids if the assignment would clash; in that
	/// case nothing is written. The editor surfaces the clash and lets the user
	/// pick a different chord rather than silently overwriting.
	@discardableResult
	func setShortcut(_ chord: KeyChord, for actionId: String) -> [String] {
		let conflicts = conflictingActionIds(for: chord, excluding: actionId)
		guard conflicts.isEmpty else { return conflicts }

		var next = shortcutOverrides
		if let def = AppShortcuts.all.first(where: { $0.id == actionId })?.defaultChord,
		   def == chord {
			next.removeValue(forKey: actionId)
		} else {
			next[actionId] = chord
		}
		shortcutOverrides = next
		persistShortcutOverrides(next)
		return []
	}

	/// Reset a single action back to its catalog default by dropping its
	/// override. A no-op when the action isn't customized.
	func resetShortcut(for actionId: String) {
		guard shortcutOverrides[actionId] != nil else { return }
		var next = shortcutOverrides
		next.removeValue(forKey: actionId)
		shortcutOverrides = next
		persistShortcutOverrides(next)
	}

	/// Reset *every* action back to its catalog default by clearing the whole
	/// override map.
	func resetAllShortcuts() {
		guard !shortcutOverrides.isEmpty else { return }
		shortcutOverrides = [:]
		persistShortcutOverrides([:])
	}

	// MARK: - Persistence bridge

	private func persistShortcutOverrides(_ map: [String: KeyChord]) {
		UserDefaults.standard.set(
			AppModel.encodeShortcutOverrides(map),
			forKey: AppModel.shortcutOverridesKey
		)
	}

	/// Decode the persisted JSON `[actionId: KeyChord]` map. Returns `[:]` on
	/// malformed data so a stale shape from a prior build can't wedge the
	/// editor — the same defensive decode as `decodePaletteActionIds`.
	static func decodeShortcutOverrides(_ json: String) -> [String: KeyChord] {
		guard let data = json.data(using: .utf8),
		      let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data)
		else { return [:] }
		return decoded
	}

	/// Encode the override map back to the JSON string persisted in
	/// `UserDefaults`. Returns `"{}"` on failure so a write never stores a
	/// half-baked value.
	static func encodeShortcutOverrides(_ map: [String: KeyChord]) -> String {
		guard let data = try? JSONEncoder().encode(map),
		      let s = String(data: data, encoding: .utf8)
		else { return "{}" }
		return s
	}
}
