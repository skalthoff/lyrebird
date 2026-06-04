import SwiftUI
@preconcurrency import LyrebirdCore

/// Audio container formats the filter offers. Matching is done against the
/// track's (lower/upper-mixed) `container` string, normalised to upper case.
/// `ALAC` is shipped by Jellyfin in an `m4a`/`mp4` container, so its match set
/// covers the common container spellings as well as the codec name itself.
enum TrackFormat: String, CaseIterable, Identifiable, Hashable {
	case flac = "FLAC"
	case alac = "ALAC"
	case mp3 = "MP3"

	var id: String { rawValue }

	var label: String { rawValue }

	/// Upper-cased container tokens that count as this format.
	private var containerTokens: Set<String> {
		switch self {
		case .flac: return ["FLAC"]
		case .alac: return ["ALAC", "M4A", "MP4"]
		case .mp3: return ["MP3", "MPEG"]
		}
	}

	/// Whether a track's `container` string matches this format.
	func matches(container raw: String?) -> Bool {
		guard let token = raw?.trimmingCharacters(in: .whitespaces).uppercased(),
			!token.isEmpty
		else { return false }
		return containerTokens.contains(token)
	}
}

/// Coarse duration buckets the filter offers. Bounds are in seconds; matching a
/// track means its runtime falls inside the half-open range.
enum DurationBucket: String, CaseIterable, Identifiable, Hashable {
	case short
	case medium
	case long

	var id: String { rawValue }

	var label: String {
		switch self {
		case .short: return "< 3m"
		case .medium: return "3–6m"
		case .long: return "> 6m"
		}
	}

	/// Whether a runtime in seconds falls in this bucket.
	func matches(seconds: Double) -> Bool {
		switch self {
		case .short: return seconds < 180
		case .medium: return seconds >= 180 && seconds <= 360
		case .long: return seconds > 360
		}
	}
}

/// Declarative, value-type description of the Library filter state. Lives on
/// `LibraryView` as `@State`; the popover edits a working copy and commits it
/// on "Apply". Filtering is applied client-side over the already-loaded
/// `model.X` arrays (the same paged-cache scope the sort already operates on),
/// so it composes with `LibrarySortOrder` without touching pagination
/// accounting.
struct LibraryFilter: Equatable {
	/// Selected genre names. Empty = no genre constraint.
	var genres: Set<String> = []
	/// Inclusive `[lower, upper]` release-year window, or `nil` for no bound.
	/// Stored separately from the slider's full range so a filter that spans
	/// the whole catalogue reads as "inactive".
	var yearRange: ClosedRange<Int>?
	var onlyDownloaded = false
	var onlyFavorited = false
	/// Selected formats. Empty = no format constraint.
	var formats: Set<TrackFormat> = []
	/// Selected duration buckets. Empty = no duration constraint.
	var durations: Set<DurationBucket> = []

	/// Number of active filter groups — drives the pink dot / count badge on
	/// the filter icon. A group counts once regardless of how many options
	/// inside it are selected.
	///
	/// `onlyDownloaded` is deliberately excluded: no `passesFilter` overload
	/// can honor it until a download-state query exists, and the toggle is
	/// itself UI-gated off (`showDownloaded: model.supportsDownloads`, false
	/// today). Counting it would mark the filter "active" — lighting the dot
	/// badge and triggering the no-results path — while filtering nothing.
	/// Fold it back in here the moment a `model.isDownloaded(...)` lands and
	/// the `passesFilter` overloads consult it. See audit L724.
	var activeGroupCount: Int {
		var n = 0
		if !genres.isEmpty { n += 1 }
		if yearRange != nil { n += 1 }
		if onlyFavorited { n += 1 }
		if !formats.isEmpty { n += 1 }
		if !durations.isEmpty { n += 1 }
		return n
	}

	var isActive: Bool { activeGroupCount > 0 }
}

/// 280pt popover anchored to the Library filter icon. Edits a working copy of
/// the active `LibraryFilter` and only commits it to the bound value on
/// "Apply"; "Clear all" resets the draft in place. Spec issue #214 / screen
/// spec Issue 15.
struct LibraryFilterPopover: View {
	/// The committed filter the Library is rendering with. Bound from
	/// `LibraryView`; only written on "Apply".
	@Binding var filter: LibraryFilter
	/// All genre names available across the loaded library, sorted A–Z.
	let availableGenres: [String]
	/// Release-year bounds discovered across the loaded library. Drives the
	/// year slider's track. `nil` when no item carries a year.
	let yearBounds: ClosedRange<Int>?
	/// Whether the "Only downloaded" toggle should be shown. Gated on the
	/// download engine (`AppModel.supportsDownloads`, #819) so the control
	/// doesn't appear dead while downloads are unwired.
	let showDownloaded: Bool
	/// Dismiss handler — the host owns the `isPresented` binding.
	let onClose: () -> Void

	/// Working copy the popover mutates; committed to `filter` on Apply.
	@State private var draft: LibraryFilter
	/// Lower/upper year thumbs as doubles for the slider. Seeded from the
	/// draft's `yearRange` or the discovered bounds.
	@State private var yearLow: Double
	@State private var yearHigh: Double

	init(
		filter: Binding<LibraryFilter>,
		availableGenres: [String],
		yearBounds: ClosedRange<Int>?,
		showDownloaded: Bool,
		onClose: @escaping () -> Void
	) {
		self._filter = filter
		self.availableGenres = availableGenres
		self.yearBounds = yearBounds
		self.showDownloaded = showDownloaded
		self.onClose = onClose
		let initial = filter.wrappedValue
		self._draft = State(initialValue: initial)
		let lo = Double(initial.yearRange?.lowerBound ?? yearBounds?.lowerBound ?? 0)
		let hi = Double(initial.yearRange?.upperBound ?? yearBounds?.upperBound ?? 0)
		self._yearLow = State(initialValue: lo)
		self._yearHigh = State(initialValue: hi)
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					if !availableGenres.isEmpty { genreGroup }
					if yearBounds != nil { yearGroup }
					if showDownloaded { downloadedGroup }
					favoritedGroup
					formatGroup
					durationGroup
				}
				.padding(16)
			}
			Divider().overlay(Theme.border)
			footer
		}
		.frame(width: 280)
		.frame(maxHeight: 460)
		.background(Theme.bgAlt)
	}

	// MARK: - Groups

	private func groupHeader(_ title: String) -> some View {
		Text(title.uppercased())
			.font(Theme.font(10, weight: .bold))
			.foregroundStyle(Theme.ink3)
			.tracking(1.2)
	}

	private var genreGroup: some View {
		VStack(alignment: .leading, spacing: 8) {
			groupHeader("Genre")
			VStack(alignment: .leading, spacing: 6) {
				ForEach(availableGenres, id: \.self) { genre in
					checkRow(
						label: genre,
						isOn: draft.genres.contains(genre)
					) {
						toggle(genre, in: \.genres)
					}
				}
			}
		}
	}

	private var yearGroup: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				groupHeader("Year")
				Spacer()
				Text("\(Int(yearLow))–\(Int(yearHigh))")
					.font(Theme.font(11, weight: .semibold))
					.foregroundStyle(Theme.ink2)
			}
			if let bounds = yearBounds {
				RangeSlider(
					low: $yearLow,
					high: $yearHigh,
					bounds: Double(bounds.lowerBound)...Double(bounds.upperBound)
				)
			}
		}
	}

	private var downloadedGroup: some View {
		toggleRow("Only downloaded", isOn: $draft.onlyDownloaded)
	}

	private var favoritedGroup: some View {
		toggleRow("Only favorited", isOn: $draft.onlyFavorited)
	}

	private var formatGroup: some View {
		VStack(alignment: .leading, spacing: 8) {
			groupHeader("Format")
			VStack(alignment: .leading, spacing: 6) {
				ForEach(TrackFormat.allCases) { format in
					checkRow(
						label: format.label,
						isOn: draft.formats.contains(format)
					) {
						toggle(format, in: \.formats)
					}
				}
			}
		}
	}

	private var durationGroup: some View {
		VStack(alignment: .leading, spacing: 8) {
			groupHeader("Duration")
			VStack(alignment: .leading, spacing: 6) {
				ForEach(DurationBucket.allCases) { bucket in
					checkRow(
						label: bucket.label,
						isOn: draft.durations.contains(bucket)
					) {
						toggle(bucket, in: \.durations)
					}
				}
			}
		}
	}

	// MARK: - Footer

	private var footer: some View {
		HStack {
			Button("Clear all") {
				draft = LibraryFilter()
				if let bounds = yearBounds {
					yearLow = Double(bounds.lowerBound)
					yearHigh = Double(bounds.upperBound)
				}
			}
			.buttonStyle(.plain)
			.font(Theme.font(12, weight: .semibold))
			.foregroundStyle(Theme.ink2)
			.disabled(!draftHasSelection)
			.opacity(draftHasSelection ? 1 : 0.4)

			Spacer()

			Button("Apply") {
				commit()
				onClose()
			}
			.buttonStyle(.plain)
			.font(Theme.font(12, weight: .bold))
			.foregroundStyle(Theme.ink)
			.padding(.horizontal, 16)
			.padding(.vertical, 7)
			.background(
				RoundedRectangle(cornerRadius: 8).fill(Theme.primary)
			)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	// MARK: - Reusable rows

	private func checkRow(
		label: String,
		isOn: Bool,
		toggle: @escaping () -> Void
	) -> some View {
		Button(action: toggle) {
			HStack(spacing: 8) {
				Image(systemName: isOn ? "checkmark.square.fill" : "square")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(isOn ? Theme.primary : Theme.ink3)
				Text(label)
					.font(Theme.font(12, weight: .medium))
					.foregroundStyle(Theme.ink)
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isOn ? [.isSelected] : [])
	}

	private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
		Toggle(isOn: isOn) {
			Text(label)
				.font(Theme.font(12, weight: .medium))
				.foregroundStyle(Theme.ink)
		}
		.toggleStyle(.switch)
		.tint(Theme.primary)
	}

	// MARK: - Helpers

	private var draftHasSelection: Bool {
		var working = draft
		applyYearToDraft(&working)
		return working.isActive
	}

	private func toggle<T: Hashable>(_ value: T, in keyPath: WritableKeyPath<LibraryFilter, Set<T>>) {
		if draft[keyPath: keyPath].contains(value) {
			draft[keyPath: keyPath].remove(value)
		} else {
			draft[keyPath: keyPath].insert(value)
		}
	}

	/// Fold the slider thumbs into the draft's `yearRange`. A range that
	/// covers the full discovered bounds reads as "no year filter" so the
	/// group doesn't count as active when the user never moved a thumb.
	private func applyYearToDraft(_ target: inout LibraryFilter) {
		guard let bounds = yearBounds else {
			target.yearRange = nil
			return
		}
		let lo = Int(yearLow.rounded())
		let hi = Int(yearHigh.rounded())
		if lo <= bounds.lowerBound && hi >= bounds.upperBound {
			target.yearRange = nil
		} else {
			target.yearRange = min(lo, hi)...max(lo, hi)
		}
	}

	private func commit() {
		var committed = draft
		applyYearToDraft(&committed)
		filter = committed
	}
}

/// Minimal double-thumb range slider. SwiftUI ships no native range control,
/// so this draws a track with two draggable thumbs over a `GeometryReader`.
/// Used only by the year group of `LibraryFilterPopover`.
struct RangeSlider: View {
	@Binding var low: Double
	@Binding var high: Double
	let bounds: ClosedRange<Double>

	private let thumbSize: CGFloat = 16
	private let trackHeight: CGFloat = 4

	var body: some View {
		GeometryReader { geo in
			let span = max(bounds.upperBound - bounds.lowerBound, 1)
			let usable = max(geo.size.width - thumbSize, 1)
			let lowX = CGFloat((low - bounds.lowerBound) / span) * usable
			let highX = CGFloat((high - bounds.lowerBound) / span) * usable

			ZStack(alignment: .leading) {
				Capsule()
					.fill(Theme.surface2)
					.frame(height: trackHeight)
					.frame(maxWidth: .infinity)
					.padding(.horizontal, thumbSize / 2)

				Capsule()
					.fill(Theme.primary)
					.frame(width: max(highX - lowX, 0), height: trackHeight)
					.offset(x: lowX + thumbSize / 2)

				thumb
					.offset(x: lowX)
					.gesture(drag(usable: usable, span: span, isLow: true))
					.accessibilityLabel("Minimum year")
					.accessibilityValue("\(Int(low))")

				thumb
					.offset(x: highX)
					.gesture(drag(usable: usable, span: span, isLow: false))
					.accessibilityLabel("Maximum year")
					.accessibilityValue("\(Int(high))")
			}
			.frame(height: thumbSize)
			.frame(maxHeight: .infinity)
		}
		.frame(height: 24)
	}

	private var thumb: some View {
		Circle()
			.fill(Theme.ink)
			.frame(width: thumbSize, height: thumbSize)
			.shadow(color: .black.opacity(0.3), radius: 2, y: 1)
	}

	private func drag(usable: CGFloat, span: Double, isLow: Bool) -> some Gesture {
		DragGesture()
			.onChanged { value in
				let fraction = max(0, min(1, value.location.x / usable))
				let raw = bounds.lowerBound + Double(fraction) * span
				let clamped = max(bounds.lowerBound, min(bounds.upperBound, raw)).rounded()
				if isLow {
					low = min(clamped, high)
				} else {
					high = max(clamped, low)
				}
			}
	}
}
