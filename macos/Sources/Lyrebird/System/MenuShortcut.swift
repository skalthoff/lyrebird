import SwiftUI

extension View {
	/// Bind a menu item's key-equivalent to the chord the user has assigned to
	/// `actionId`, falling back to the catalog default when no override exists.
	///
	/// This is what makes the Keyboard pane (#120 / #265) non-cosmetic: the
	/// menus in `LyrebirdCommands` resolve every shortcut through here, so a
	/// remap in the editor re-binds the actual `NSMenuItem` key-equivalent. The
	/// `default:` argument is the literal chord the catalog ships, used both as
	/// the fallback and as a safety net for any id missing from `AppShortcuts`.
	///
	/// SwiftUI re-evaluates the commands body when the observed `AppModel`'s
	/// `shortcutOverrides` changes, so the menu re-binds live without a relaunch.
	func appShortcut(
		_ actionId: String,
		model: AppModel,
		default fallback: KeyboardShortcut
	) -> some View {
		keyboardShortcut(model.resolvedShortcut(for: actionId) ?? fallback)
	}
}
