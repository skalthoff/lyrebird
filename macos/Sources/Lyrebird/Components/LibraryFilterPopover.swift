import SwiftUI
@preconcurrency import LyrebirdCore

/// Audio formats the filter offers. Matching is done against the track's
/// (case-insensitive) `container` string only — the loaded `Track` payload
/// carries no codec field, so matching is *container-level*, not codec-level.
///
/// FLAC and MP3 each map to a dedicated container, so those are exact. ALAC
/// and AAC, however, both ship inside the same `m4a`/`mp4` container, and the
/// container alone can't tell them apart. Rather than claim a codec-level
/// distinction we can't honour (the prior code mapped M4A/MP4 to ALAC, which
/// silently kept lossy AAC files too), both ALAC and AAC match the shared
/// `m4a`/`mp4` containers. Selecting either therefore keeps every m4a/mp4
/// track; tightening this to true codec granularity needs a codec/profile
/// signal on the `Track` model (see #819-adjacent work).
enum TrackFormat: String, CaseIterable, Identifiable, Hashable {
	case flac = "FLAC"
	case alac = "ALAC"
	case aac = "AAC"
	case mp3 = "MP3"

	var id: String { rawValue }

	var label: String {
		switch self {
		// Make the shared-container caveat visible in the UI so a user who
		// selects ALAC isn't surprised that AAC m4a/mp4 files come along.
		case .alac: return "ALAC (m4a)"
		case .aac: return "AAC (m4a)"
		default: return rawValue
		}
	}

	/// Upper-cased container tokens that count as this format. M4A/MP4 is
	/// shared by ALAC and AAC because the container is the only signal we have.
	private var containerTokens: Set<String> {
		switch self {
		case .flac: return ["FLAC"]
		case .alac, .aac: return ["M4A", "MP4", "M4B", "ALAC", "AAC"]
		case .mp3: return ["MP3", "MPEG"]
		}
	}

	/// Whether a track's `container` string matches this format. Container-level
	/// only — see the type doc for why ALAC/AAC can't be told apart here.
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

	// MARK: - Per-tab applicability

	/// Which filter dimensions the given `LibraryTab` actually consults in its
	/// `passesFilter` predicate. The popover renders only the matching groups
	/// so a control can never appear active on a tab that ignores it (#214
	/// follow-up). Mirrors `LibraryView.passesFilter(_:)`:
	/// - genre → albums, artists
	/// - year → albums, tracks
	/// - format / duration → tracks only
	/// - favorited → every tab (always rendered)
	static func appliesGenre(on tab: LibraryTab) -> Bool {
		tab == .albums || tab == .artists
	}

	static func appliesYear(on tab: LibraryTab) -> Bool {
		tab == .albums || tab == .tracks
	}

	static func appliesTrackFields(on tab: LibraryTab) -> Bool {
		tab == .tracks
	}
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
	/// The Library tab the popover is filtering. Only the dimensions the
	/// active tab's `passesFilter` actually consults are rendered, so a
	/// Format/Duration/Year group never appears "active" on a tab that
	/// ignores it (#214 follow-up). See `appliesYear` / `appliesTrackFields`.
	let tab: LibraryTab
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
		tab: LibraryTab,
		onClose: @escaping () -> Void
	) {
		self._filter = filter
		self.availableGenres = availableGenres
		self.yearBounds = yearBounds
		self.tab = tab
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
					if appliesGenre, !availableGenres.isEmpty { genreGroup }
					if appliesYear, yearBounds != nil { yearGroup }
					favoritedGroup
					if appliesTrackFields {
						formatGroup
						durationGroup
					}
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

	// MARK: - Tab applicability

	private var appliesGenre: Bool { LibraryFilter.appliesGenre(on: tab) }
	private var appliesYear: Bool { LibraryFilter.appliesYear(on: tab) }
	private var appliesTrackFields: Bool { LibraryFilter.appliesTrackFields(on: tab) }

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

	@Environment(\.layoutDirection) private var layoutDirection

	private let thumbSize: CGFloat = 16
	private let trackHeight: CGFloat = 4

	/// Name for the container coordinate space the drag is measured in, so
	/// `value.location.x` reads against the track instead of the thumb's own
	/// (offset) coordinate space.
	private let coordinateSpace = "rangeSlider"

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
					.gesture(drag(usable: usable, totalWidth: geo.size.width, isLow: true))
					.accessibilityLabel("Minimum year")
					.accessibilityValue("\(Int(low))")
					.accessibilityAdjustableAction { direction in
						adjust(isLow: true, direction: direction)
					}

				thumb
					.offset(x: highX)
					.gesture(drag(usable: usable, totalWidth: geo.size.width, isLow: false))
					.accessibilityLabel("Maximum year")
					.accessibilityValue("\(Int(high))")
					.accessibilityAdjustableAction { direction in
						adjust(isLow: false, direction: direction)
					}
			}
			.frame(height: thumbSize)
			.frame(maxHeight: .infinity)
			.coordinateSpace(name: coordinateSpace)
			// Mirror the entire pixel-geometry track in RTL so "low" sits on the
			// right (reading start) and "high" on the left (reading end).
			// GeometryReader always uses screen coordinates (left = 0), so we
			// flip the rendered layer and compensate cursor x in `drag`.
			.scaleEffect(x: layoutDirection == .rightToLeft ? -1 : 1, y: 1)
		}
		.frame(height: 24)
	}

	private var thumb: some View {
		Circle()
			.fill(Theme.ink)
			.frame(width: thumbSize, height: thumbSize)
			.shadow(color: .black.opacity(0.3), radius: 2, y: 1)
	}

	private func drag(usable: CGFloat, totalWidth: CGFloat, isLow: Bool) -> some Gesture {
		// Measured in the ZStack's coordinate space (see `coordinateSpace`), so
		// `value.location.x` is the cursor's position along the track, not an
		// offset relative to the dragged thumb.
		// In RTL the layer is mirrored via scaleEffect(x: -1), so the drag
		// coordinate space is also mirrored: reflect the x back to match the
		// logical (value-space) orientation.
		DragGesture(coordinateSpace: .named(coordinateSpace))
			.onChanged { value in
				let rawX = value.location.x
				let cursorX = layoutDirection == .rightToLeft ? (totalWidth - rawX) : rawX
				let clamped = Self.value(
					forCursorX: cursorX,
					usable: usable,
					thumbSize: thumbSize,
					bounds: bounds)
				if isLow {
					low = min(clamped, high)
				} else {
					high = max(clamped, low)
				}
			}
	}

	/// Convert a cursor x-position (in the track's coordinate space) to a
	/// rounded value in `bounds`. The thumb is `thumbSize` wide and drawn
	/// leading-aligned, so its centre sits half a thumb in from the track
	/// origin; subtracting `thumbSize / 2` maps the cursor to the thumb-centre
	/// travel that `usable` (= width − thumbSize) describes. Factored out so the
	/// drag math is unit-testable (it was the source of the year-slider snapping
	/// bug, #214). `internal` rather than `private` for `@testable` access.
	static func value(
		forCursorX cursorX: CGFloat,
		usable: CGFloat,
		thumbSize: CGFloat,
		bounds: ClosedRange<Double>
	) -> Double {
		let span = max(bounds.upperBound - bounds.lowerBound, 1)
		let centred = cursorX - thumbSize / 2
		let fraction = max(0, min(1, centred / max(usable, 1)))
		let raw = bounds.lowerBound + Double(fraction) * span
		return max(bounds.lowerBound, min(bounds.upperBound, raw)).rounded()
	}

	/// VoiceOver / keyboard adjustable action: nudge the given thumb by one
	/// year per increment, clamped to the bounds and to the other thumb so the
	/// low thumb can't cross above the high (or vice versa). Keeps the control
	/// operable without a pointer drag (#214 a11y follow-up).
	private func adjust(isLow: Bool, direction: AccessibilityAdjustmentDirection) {
		let delta: Double = direction == .increment ? 1 : -1
		if isLow {
			let next = (low + delta).rounded()
			low = max(bounds.lowerBound, min(next, high))
		} else {
			let next = (high + delta).rounded()
			high = min(bounds.upperBound, max(next, low))
		}
	}
}
