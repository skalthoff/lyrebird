import SwiftUI

/// Keyboard Shortcuts help window.
///
/// A searchable, two-column map of every keyboard shortcut the app exposes:
/// the action name on the left, the chord rendered with proper macOS symbol
/// glyphs (⌃⌥⇧⌘ + key) on the right. Apple Music has no such screen; Doppler
/// does, and this matches that bar.
///
/// Data comes from `AppShortcuts.all` — the same catalog the menu bar mirrors —
/// so the help window and the menus never advertise different chords. Search
/// matches the resolved localized name and the glyph string, and sections with
/// no surviving rows drop out of the list entirely.
struct KeyboardShortcutsView: View {
	/// Live search text. The effective query is the trimmed, lowercased form.
	@State private var query: String = ""

	@FocusState private var searchFocused: Bool

	/// Trimmed + lowercased query used for matching. Empty means "show all".
	private var needle: String {
		query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	/// Sections (in catalog order) that still have at least one matching row,
	/// paired with their surviving rows. Resolving each row's localized name
	/// once here keeps the per-row body cheap and lets search match the
	/// *translated* name, not the `menu.*` key.
	private var visibleSections: [(section: AppShortcuts.Section, rows: [AppShortcuts.Shortcut])] {
		let n = needle
		return AppShortcuts.Section.allCases.compactMap { section in
			let rows = AppShortcuts.all
				.filter { $0.section == section }
				.filter { n.isEmpty || $0.matches(n) }
			return rows.isEmpty ? nil : (section, rows)
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			searchHeader

			Divider()
				.overlay(Theme.border)

			if visibleSections.isEmpty {
				emptyState
			} else {
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 24) {
						ForEach(visibleSections, id: \.section.id) { entry in
							sectionView(entry.section, rows: entry.rows)
						}
					}
					.padding(20)
				}
			}
		}
		.frame(minWidth: 420, minHeight: 360)
		.background(Theme.bg)
		// Color scheme is applied by the scene (honouring the Appearance pane);
		// the view paints from the dark-purple `Theme` palette regardless.
		.onAppear { searchFocused = true }
	}

	// MARK: - Header

	private var searchHeader: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(Theme.ink3)
			TextField("shortcuts.search.placeholder", text: $query)
				.textFieldStyle(.plain)
				.font(.system(size: 14))
				.foregroundStyle(Theme.ink)
				.focused($searchFocused)
				.accessibilityLabel(Text("shortcuts.search.accessibility"))
			if !query.isEmpty {
				Button {
					query = ""
					searchFocused = true
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(Theme.ink3)
				}
				.buttonStyle(.plain)
				.accessibilityLabel(Text("shortcuts.search.clear"))
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	// MARK: - Sections

	private func sectionView(_ section: AppShortcuts.Section, rows: [AppShortcuts.Shortcut]) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(section.titleKey)
				.font(.system(size: 11, weight: .semibold))
				.textCase(.uppercase)
				.kerning(0.6)
				.foregroundStyle(Theme.ink3)

			VStack(spacing: 0) {
				ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
					shortcutRow(row)
					if index < rows.count - 1 {
						Divider().overlay(Theme.border.opacity(0.6))
					}
				}
			}
			.background(Theme.surface)
			.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.strokeBorder(Theme.border, lineWidth: 1)
			)
		}
	}

	private func shortcutRow(_ row: AppShortcuts.Shortcut) -> some View {
		HStack(spacing: 12) {
			Text(row.nameKey)
				.font(.system(size: 13))
				.foregroundStyle(Theme.ink)
			Spacer(minLength: 16)
			KeyChord(glyphs: row.glyphs)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.contentShape(Rectangle())
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(row.localizedName))
		.accessibilityValue(Text(row.glyphs))
	}

	// MARK: - Empty state

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 28))
				.foregroundStyle(Theme.ink3)
			Text("shortcuts.search.no_results")
				.font(.system(size: 13))
				.foregroundStyle(Theme.ink3)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// A run of macOS modifier/key glyphs rendered as a single rounded "key cap"
/// chip — e.g. `⌘⇧→`. Monospaced digits keep the glyph baseline steady, and the
/// subtle bordered fill reads as a physical key the way Apple's own
/// key-equivalent rendering does.
private struct KeyChord: View {
	let glyphs: String

	var body: some View {
		Text(glyphs)
			.font(.system(size: 13, weight: .medium, design: .rounded))
			.monospacedDigit()
			.foregroundStyle(Theme.ink)
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(Theme.surface2)
			.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.strokeBorder(Theme.borderStrong, lineWidth: 1)
			)
			.accessibilityLabel(Text(glyphs))
	}
}
