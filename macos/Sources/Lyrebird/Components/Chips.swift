import SwiftUI

/// Pill-style chip for filter/tab rows. A single chip renders its label in a
/// rounded capsule; the active state uses an `ink` (white) fill with `bg`
/// foreground for a high-contrast selected look, while idle chips sit on a
/// subtle `surface` background with `ink2` text.
///
/// The component is intentionally a presentational primitive — selection
/// state and callbacks are driven by the caller. Typography and padding
/// follow the design spec: 14pt/semibold label, 7pt vertical / 14pt
/// horizontal padding. See `06-screen-specs.md` (Issue 13 / #212).
struct Chip: View {
	let label: String
	let isActive: Bool
	var onTap: () -> Void

	var body: some View {
		Button(action: onTap) {
			Text(label)
				.font(Theme.font(14, weight: .semibold))
				.foregroundStyle(isActive ? Theme.bg : Theme.ink2)
				.padding(.vertical, 7)
				.padding(.horizontal, 14)
				.background(
					Capsule()
						.fill(isActive ? Theme.ink : Theme.surface)
				)
				.overlay(
					Capsule()
						.stroke(isActive ? Color.clear : Theme.border, lineWidth: 1)
				)
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isActive ? [.isSelected, .isButton] : [.isButton])
	}
}

/// Horizontal row of `Chip`s. The caller passes the options and a binding to
/// the active selection; the row handles rendering and dispatch. Generic over
/// any `Hashable` tag so it works equally well for library tabs, search
/// scopes, etc.
struct ChipRow<Tag: Hashable>: View {
	let options: [(label: String, tag: Tag)]
	@Binding var selection: Tag

	var body: some View {
		HStack(spacing: 8) {
			ForEach(options, id: \.tag) { option in
				Chip(
					label: option.label,
					isActive: option.tag == selection,
					onTap: { selection = option.tag }
				)
			}
		}
		.accessibilityElement(children: .contain)
	}
}

#Preview("Chip row") {
	struct Demo: View {
		@State private var selection: String = "Albums"
		var body: some View {
			VStack(alignment: .leading, spacing: 20) {
				ChipRow(
					options: [
						(label: "Tracks", tag: "Tracks"),
						(label: "Albums", tag: "Albums"),
						(label: "Artists", tag: "Artists"),
						(label: "Playlists", tag: "Playlists"),
						(label: "Downloaded", tag: "Downloaded"),
					],
					selection: $selection
				)
				Text("Active: \(selection)")
					.font(Theme.font(12, weight: .medium))
					.foregroundStyle(Theme.ink3)
			}
			.padding(24)
			.background(Theme.bg)
		}
	}
	return Demo().preferredColorScheme(.dark)
}
