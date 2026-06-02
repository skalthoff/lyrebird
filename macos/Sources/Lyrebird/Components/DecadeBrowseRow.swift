import SwiftUI

/// Discover "Browse by Decade" row.
///
/// A horizontal strip of gradient tiles — '60s, '70s, '80s, '90s, '00s, '10s,
/// '20s — each carrying a huge italic decade label over a deterministic
/// per-decade wash. Tapping a tile deep-links to the Library pre-filtered to
/// that decade's ten-year release-year window via `AppModel.browseDecade`.
///
/// The decade set is static (the catalogue's actual year coverage isn't known
/// until the whole library is paged in, and the spec calls for the fixed
/// '60s→'20s ramp), so the row always renders. A decade with no matching
/// albums simply lands on an empty filtered Library, which the existing
/// empty-grid affordance already covers.
struct DecadeBrowseRow: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: "calendar")
					.foregroundStyle(Theme.primary)
					.font(.system(size: 14, weight: .bold))
				Text("Browse by Decade")
					.font(Theme.font(18, weight: .bold))
					.foregroundStyle(Theme.ink)
				Text("Jump into a ten-year slice of your library")
					.font(Theme.font(12, weight: .medium))
					.foregroundStyle(Theme.ink3)
			}
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 14) {
					ForEach(Decade.all) { decade in
						DecadeTile(decade: decade) {
							model.browseDecade(startingYear: decade.startYear)
						}
					}
				}
				.padding(.vertical, 4)
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Browse by Decade")
	}
}

/// A single decade in the browse row. `startYear` is the inclusive lower bound
/// of the ten-year window the Library filters to; `shortLabel` is the apostrophe
/// form ("'80s") used on the tile face.
struct Decade: Identifiable, Hashable {
	let startYear: Int

	var id: Int { startYear }

	/// Two-digit apostrophe label — `1980 → "'80s"`, `2000 → "'00s"`.
	var shortLabel: String {
		let twoDigit = String(format: "%02d", startYear % 100)
		return "'\(twoDigit)s"
	}

	/// VoiceOver-friendly spelled-out form — "the 1980s".
	var spokenLabel: String { "the \(startYear)s" }

	/// The fixed '60s→'20s ramp the Discover row renders, oldest first.
	static let all: [Decade] = stride(from: 1960, through: 2020, by: 10).map(Decade.init)
}

/// One gradient decade tile. 150×120, continuous-corner card with a
/// deterministic per-decade wash and an oversized italic label bottom-leading —
/// the "default artwork gradient + huge italic decade text" the spec asks for.
/// Mirrors the hover/scale/shadow vocabulary of `GenreExploreTile` so the
/// Discover surface reads as one family.
private struct DecadeTile: View {
	let decade: Decade
	let onOpen: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var isHovering = false

	var body: some View {
		Button(action: onOpen) {
			ZStack(alignment: .bottomLeading) {
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.fill(gradient)
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.stroke(.white.opacity(isHovering ? 0.35 : 0.12), lineWidth: 1)
				Text(decade.shortLabel)
					.font(Theme.font(40, weight: .black, italic: true))
					.foregroundStyle(.white)
					.shadow(color: .black.opacity(0.45), radius: 4, y: 1)
					.padding(14)
			}
			.frame(width: 150, height: 120)
			.scaleEffect(reduceMotion ? 1 : (isHovering ? 1.03 : 1))
			.shadow(
				color: seedColor.opacity(isHovering ? 0.45 : 0.25),
				radius: isHovering ? 14 : 8,
				y: isHovering ? 8 : 4
			)
			.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
			.contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.help("Browse \(decade.spokenLabel)")
		.accessibilityLabel("Browse \(decade.spokenLabel)")
		.accessibilityHint("Filters the Library to albums from \(decade.spokenLabel)")
		.accessibilityAddTraits(.isButton)
	}

	/// Base hue spread evenly across the seven decades so the row reads as a
	/// rainbow ramp rather than a wall of one color. Derived from the decade's
	/// ordinal (0 for the '60s … 6 for the '20s) so the same decade always
	/// lands on the same hue across launches.
	private var hue: Double {
		let ordinal = Double((decade.startYear - 1960) / 10)
		return (ordinal / 7.0)
	}

	private var seedColor: Color {
		Color(hue: hue, saturation: 0.55, brightness: 0.62)
	}

	/// Diagonal wash from the seed hue into a darker shade of itself so the
	/// white italic label stays legible at the bottom-left.
	private var gradient: LinearGradient {
		LinearGradient(
			colors: [
				Color(hue: hue, saturation: 0.62, brightness: 0.66),
				Color(hue: hue, saturation: 0.70, brightness: 0.34),
			],
			startPoint: .topLeading,
			endPoint: .bottomTrailing
		)
	}
}
