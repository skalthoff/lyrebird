import SwiftUI

/// The Genre / Decade / Mood radio rows (`06-screen-specs.md` §9).
///
/// Three horizontal rows of 4–6 gradient tiles. Each tile *starts a radio
/// station* — it replaces the queue with a shuffled, station-style mix and
/// plays from the top — as opposed to the Discover "Browse by Decade" /
/// "Genres to Explore" rows, which deep-link into a filtered Library / genre
/// detail. The two families share the gradient-tile vocabulary on purpose so
/// the surfaces read as one design, but their *verbs* differ (radio vs.
/// browse).
///
/// - Genre radio is seeded off the library's largest genres
///   (`model.browseGenres`) via `startGenreRadio` (Instant Mix).
/// - Decade radio assembles a shuffled queue from the decade's ten-year
///   window via `startDecadeRadio`.
/// - Mood radio is sourced from Jellyfin *tags* and only shows moods that are
///   actually present in the library (`model.availableMoods`, populated by
///   `probeAvailableMoods()`), so a library with no mood tags renders no row.
///
/// Each row hides itself when its data source is empty, so a brand-new or
/// sparsely-tagged library never sees a blank band.
struct RadioStationRows: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(alignment: .leading, spacing: 28) {
			genreRadioRow
			decadeRadioRow
			moodRadioRow
		}
		// Populate the genre seed pool + probe which mood tags exist. Both are
		// cheap + idempotent (the genre fetch is one cached /MusicGenres page;
		// the mood probe is five limit:1 /Items HEADs) and only run when their
		// backing data is still empty, so re-appearing the surface is free.
		.task {
			if model.browseGenres.isEmpty {
				await model.refreshBrowseGenres()
			}
			if model.availableMoods.isEmpty {
				await model.probeAvailableMoods()
			}
		}
	}

	// MARK: - Genre radio

	@ViewBuilder
	private var genreRadioRow: some View {
		// Cap at 6 per the spec's "4–6 tiles" — browseGenres is the largest
		// genres, already ranked, so the top 6 are the most useful stations.
		let genres = Array(model.browseGenres.prefix(6))
		if !genres.isEmpty {
			RadioRow(
				icon: "guitars",
				iconColor: Theme.accent,
				title: "Genre Radio",
				subtitle: "Endless stations from your top genres"
			) {
				ForEach(genres, id: \.id) { genre in
					RadioStationTile(
						title: genre.name,
						seed: genre.name,
						symbol: "dot.radiowaves.left.and.right",
						accessibilityVerb: "Start \(genre.name) radio"
					) {
						model.startGenreRadio(genre: genre)
					}
				}
			}
		}
	}

	// MARK: - Decade radio

	private var decadeRadioRow: some View {
		// The decade ramp is static ('60s→'20s); we surface the most recent 6
		// so the row honors the "4–6 tiles" cap while leading with the decades
		// a music library is most likely to be dense in.
		let decades = Array(Decade.all.suffix(6).reversed())
		return RadioRow(
			icon: "calendar",
			iconColor: Theme.primary,
			title: "Decade Radio",
			subtitle: "A shuffled trip through a ten-year slice"
		) {
			ForEach(decades) { decade in
				RadioStationTile(
					title: decade.shortLabel,
					seed: "decade-\(decade.startYear)",
					symbol: "dot.radiowaves.left.and.right",
					titleFont: Theme.font(34, weight: .black, italic: true),
					accessibilityVerb: "Start \(decade.spokenLabel) radio"
				) {
					model.startDecadeRadio(startingYear: decade.startYear)
				}
			}
		}
	}

	// MARK: - Mood radio

	@ViewBuilder
	private var moodRadioRow: some View {
		if !model.availableMoods.isEmpty {
			RadioRow(
				icon: "sparkles",
				iconColor: Theme.teal,
				title: "Mood Radio",
				subtitle: "Stations for however you are feeling"
			) {
				ForEach(model.availableMoods) { mood in
					RadioStationTile(
						title: mood.label,
						seed: "mood-\(mood.tag)",
						symbol: mood.symbol,
						accessibilityVerb: "Start \(mood.label) radio"
					) {
						model.startMoodRadio(mood: mood)
					}
				}
			}
		}
	}
}

/// Shared chrome for a radio row: a labeled header + a horizontal scroller of
/// tiles. Uses an eager `HStack` inside the horizontal `ScrollView` (not
/// `LazyHStack`) to stay clear of the rc9 macOS 26.4 `LazyHStack` UAF noted in
/// CLAUDE.md.
private struct RadioRow<Content: View>: View {
	let icon: String
	let iconColor: Color
	let title: String
	let subtitle: String
	@ViewBuilder let content: () -> Content

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: icon)
					.foregroundStyle(iconColor)
					.font(.system(size: 14, weight: .bold))
				Text(title)
					.font(Theme.font(18, weight: .bold))
					.foregroundStyle(Theme.ink)
				Text(subtitle)
					.font(Theme.font(12, weight: .medium))
					.foregroundStyle(Theme.ink3)
			}
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 14) {
					content()
				}
				.padding(.vertical, 4)
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(title)
	}
}

/// One radio-station tile. A 150×120 continuous-corner gradient card (the same
/// vocabulary as `DecadeBrowseRow`/`GenresToExploreSection`) with a station
/// title and a radio glyph that brightens on hover so the tile reads as a
/// "press to start a station" affordance rather than a passive label.
private struct RadioStationTile: View {
	let title: String
	/// Deterministic color seed — the same seed always lands on the same hue
	/// across launches, so a given station keeps its color.
	let seed: String
	let symbol: String
	var titleFont: Font = Theme.font(20, weight: .bold)
	let accessibilityVerb: String
	let onStart: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var isHovering = false

	var body: some View {
		Button(action: onStart) {
			ZStack(alignment: .bottomLeading) {
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.fill(gradient)
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.stroke(.white.opacity(isHovering ? 0.35 : 0.12), lineWidth: 1)

				// Radio glyph, top-trailing — the "this is a station" cue.
				Image(systemName: symbol)
					.font(.system(size: 16, weight: .bold))
					.foregroundStyle(.white.opacity(isHovering ? 1 : 0.7))
					.shadow(color: .black.opacity(0.35), radius: 3, y: 1)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
					.padding(12)

				Text(title)
					.font(titleFont)
					.foregroundStyle(.white)
					.lineLimit(2)
					.multilineTextAlignment(.leading)
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
		.help(accessibilityVerb)
		.accessibilityLabel("\(title) Radio")
		.accessibilityHint(accessibilityVerb)
		.accessibilityAddTraits(.isButton)
	}

	/// Deterministic base hue via a small FNV-1a over the seed's scalars —
	/// matches `GenreExploreTile` so the surfaces share one palette logic.
	private var hue: Double {
		var hash: UInt32 = 2_166_136_261
		for scalar in seed.unicodeScalars {
			hash = (hash ^ scalar.value) &* 16_777_619
		}
		return Double(hash % 360) / 360.0
	}

	private var seedColor: Color {
		Color(hue: hue, saturation: 0.55, brightness: 0.62)
	}

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
