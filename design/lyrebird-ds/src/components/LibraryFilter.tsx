import type { CSSProperties } from 'react'

/**
 * One selectable option in a checkbox-style filter group (Genre / Format /
 * Duration). `id` is the stable value the host toggles on; `label` is the
 * human string drawn in the row. Mirrors the Swift `ForEach` over
 * `availableGenres` / `TrackFormat` / `DurationBucket`, where each case renders
 * a `checkRow(label:isOn:)`.
 */
export interface FilterOption {
	/** Stable identifier passed back to `onToggle*` when the row is tapped. */
	id: string
	/** Visible row text, e.g. "Electronic", "ALAC (m4a)", "< 3m". */
	label: string
}

export interface LibraryFilterProps {
	/**
	 * Genre options (sorted A–Z by the host, matching the Swift
	 * `availableGenres`). The group is hidden entirely when this is empty —
	 * mirroring `if appliesGenre, !availableGenres.isEmpty`.
	 */
	genres?: FilterOption[]
	/** Set of currently-checked genre ids. */
	selectedGenres?: string[]
	/** Toggle a genre row on/off. Receives the row's `id`. */
	onToggleGenre?: (id: string) => void

	/**
	 * Audio-format options (FLAC / ALAC (m4a) / AAC (m4a) / MP3). Tracks-only in
	 * the app; pass `undefined` to hide the Format group (the Swift gates this
	 * behind `appliesTrackFields`).
	 */
	formats?: FilterOption[]
	/** Set of currently-checked format ids. */
	selectedFormats?: string[]
	/** Toggle a format row. */
	onToggleFormat?: (id: string) => void

	/**
	 * Duration-bucket options (< 3m / 3–6m / > 6m). Tracks-only; pass
	 * `undefined` to hide the Duration group.
	 */
	durations?: FilterOption[]
	/** Set of currently-checked duration ids. */
	selectedDurations?: string[]
	/** Toggle a duration row. */
	onToggleDuration?: (id: string) => void

	/**
	 * Inclusive release-year bounds discovered across the library. When set, the
	 * Year group renders a double-thumb range slider seeded from `yearLow` /
	 * `yearHigh`. Pass `undefined` to hide the Year group (mirrors
	 * `if appliesYear, yearBounds != nil`).
	 */
	yearBounds?: [number, number]
	/** Current lower thumb value. Defaults to `yearBounds[0]`. */
	yearLow?: number
	/** Current upper thumb value. Defaults to `yearBounds[1]`. */
	yearHigh?: number
	/** Fired as either year thumb is dragged. Receives `[low, high]`. */
	onYearChange?: (low: number, high: number) => void

	/** State of the "Only favorited" switch. Always rendered (every tab). */
	onlyFavorited?: boolean
	/** Toggle the "Only favorited" switch. */
	onToggleFavorited?: (on: boolean) => void

	/**
	 * Whether the "Clear all" footer action is enabled. The Swift dims it to
	 * 40% and disables it when the draft has no active selection
	 * (`draftHasSelection`). Defaults to `false`.
	 */
	hasSelection?: boolean
	/** "Clear all" footer action — resets the draft in place. */
	onClearAll?: () => void
	/** "Apply" footer action — commits the draft and dismisses the popover. */
	onApply?: () => void

	style?: CSSProperties
}

const FONT = 'var(--lyr-font)'

/** Group header: 10pt bold, uppercased, ink3, tracking 1.2 (Swift `groupHeader`). */
function groupHeaderStyle(): CSSProperties {
	return {
		fontFamily: FONT,
		fontSize: 10,
		fontWeight: 700,
		color: 'var(--lyr-ink-3)',
		letterSpacing: 1.2,
		textTransform: 'uppercase',
		lineHeight: 1,
	}
}

/**
 * Checkbox glyph mirroring the Swift `Image(systemName: isOn ?
 * "checkmark.square.fill" : "square")` at 13pt. The Icon set ships no checkbox
 * symbol, so it's drawn inline (same precedent as the inline lock/door badges).
 * Filled + primary tint when on; hollow + ink3 stroke when off.
 */
function CheckboxGlyph({ on }: { on: boolean }) {
	const tint = on ? 'var(--lyr-primary)' : 'var(--lyr-ink-3)'
	return (
		<svg
			width={13}
			height={13}
			viewBox="0 0 24 24"
			fill="none"
			style={{ display: 'inline-block', flexShrink: 0 }}
			aria-hidden="true"
		>
			<rect
				x="3"
				y="3"
				width="18"
				height="18"
				rx="4"
				fill={on ? tint : 'none'}
				stroke={tint}
				strokeWidth={2}
			/>
			{on ? (
				<path
					d="m7.5 12 3 3 6-6.5"
					fill="none"
					stroke="var(--lyr-ink)"
					strokeWidth={2.4}
					strokeLinecap="round"
					strokeLinejoin="round"
				/>
			) : null}
		</svg>
	)
}

/**
 * One tappable checkbox row. Mirrors the Swift `checkRow(label:isOn:toggle:)`:
 * an 8pt-gap HStack of [checkbox glyph][12pt medium label][spacer], the whole
 * row a borderless button.
 */
function CheckRow({ label, on, onToggle }: { label: string; on: boolean; onToggle?: () => void }) {
	return (
		<button
			type="button"
			onClick={onToggle}
			aria-pressed={on}
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 8,
				width: '100%',
				padding: 0,
				background: 'transparent',
				border: 'none',
				cursor: 'pointer',
				appearance: 'none',
				WebkitAppearance: 'none',
				textAlign: 'left',
			}}
		>
			<CheckboxGlyph on={on} />
			<span
				style={{
					fontFamily: FONT,
					fontSize: 12,
					fontWeight: 500,
					color: 'var(--lyr-ink)',
					lineHeight: 1.2,
					whiteSpace: 'nowrap',
					overflow: 'hidden',
					textOverflow: 'ellipsis',
				}}
			>
				{label}
			</span>
		</button>
	)
}

/**
 * A labelled checkbox group (Genre / Format / Duration). Header on top, 6pt-gap
 * column of rows below, 8pt between the two (Swift group VStacks).
 */
function CheckGroup({
	title,
	options,
	selected,
	onToggle,
}: {
	title: string
	options: FilterOption[]
	selected: Set<string>
	onToggle?: (id: string) => void
}) {
	return (
		<div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
			<span style={groupHeaderStyle()}>{title}</span>
			<div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
				{options.map((opt) => (
					<CheckRow
						key={opt.id}
						label={opt.label}
						on={selected.has(opt.id)}
						onToggle={onToggle ? () => onToggle(opt.id) : undefined}
					/>
				))}
			</div>
		</div>
	)
}

const THUMB = 16
const TRACK_H = 4

/**
 * Double-thumb release-year slider, mirroring the Swift `RangeSlider`: a
 * `--lyr-surface-2` track with a `--lyr-primary` selected segment between two
 * 16px white (`--lyr-ink`) thumbs. Static here — the host owns the values and
 * is notified via `onYearChange`; this presentational mirror renders the
 * geometry but does not implement drag math (the Swift drag lives in core-free
 * gesture code).
 */
function YearSlider({
	bounds,
	low,
	high,
	onChange,
}: {
	bounds: [number, number]
	low: number
	high: number
	onChange?: (low: number, high: number) => void
}) {
	const [lo, hi] = bounds
	const span = Math.max(hi - lo, 1)
	const lowPct = Math.max(0, Math.min(1, (low - lo) / span)) * 100
	const highPct = Math.max(0, Math.min(1, (high - lo) / span)) * 100

	const thumb: CSSProperties = {
		position: 'absolute',
		top: '50%',
		width: THUMB,
		height: THUMB,
		marginTop: -THUMB / 2,
		marginLeft: -THUMB / 2,
		borderRadius: 999,
		background: 'var(--lyr-ink)',
		boxShadow: '0 1px 2px rgba(0,0,0,0.3)',
	}

	return (
		<div style={{ position: 'relative', height: 24 }}>
			{/* Full track */}
			<div
				style={{
					position: 'absolute',
					top: '50%',
					left: THUMB / 2,
					right: THUMB / 2,
					height: TRACK_H,
					marginTop: -TRACK_H / 2,
					borderRadius: 999,
					background: 'var(--lyr-surface-2)',
				}}
			/>
			{/* Selected segment between the thumbs */}
			<div
				style={{
					position: 'absolute',
					top: '50%',
					left: `calc(${THUMB / 2}px + ${lowPct}% * (100% - ${THUMB}px) / 100%)`,
					width: `calc(${highPct - lowPct}% * (100% - ${THUMB}px) / 100%)`,
					height: TRACK_H,
					marginTop: -TRACK_H / 2,
					borderRadius: 999,
					background: 'var(--lyr-primary)',
				}}
			/>
			{/* Low thumb */}
			<div
				role="slider"
				aria-label="Minimum year"
				aria-valuenow={low}
				aria-valuemin={lo}
				aria-valuemax={hi}
				onClick={onChange ? () => onChange(low, high) : undefined}
				style={{ ...thumb, left: `calc(${THUMB / 2}px + ${lowPct}% * (100% - ${THUMB}px) / 100%)`, cursor: 'pointer' }}
			/>
			{/* High thumb */}
			<div
				role="slider"
				aria-label="Maximum year"
				aria-valuenow={high}
				aria-valuemin={lo}
				aria-valuemax={hi}
				onClick={onChange ? () => onChange(low, high) : undefined}
				style={{ ...thumb, left: `calc(${THUMB / 2}px + ${highPct}% * (100% - ${THUMB}px) / 100%)`, cursor: 'pointer' }}
			/>
		</div>
	)
}

/**
 * Switch-style toggle row, mirroring the Swift `toggleRow` (a `Toggle` with
 * `.switch` style tinted `Theme.primary`): a 12pt medium label on the left, a
 * pill switch on the right that fills `--lyr-primary` when on.
 */
function ToggleRow({
	label,
	on,
	onToggle,
}: {
	label: string
	on: boolean
	onToggle?: (on: boolean) => void
}) {
	return (
		<button
			type="button"
			role="switch"
			aria-checked={on}
			onClick={onToggle ? () => onToggle(!on) : undefined}
			style={{
				display: 'flex',
				alignItems: 'center',
				justifyContent: 'space-between',
				width: '100%',
				padding: 0,
				background: 'transparent',
				border: 'none',
				cursor: 'pointer',
				appearance: 'none',
				WebkitAppearance: 'none',
				textAlign: 'left',
			}}
		>
			<span
				style={{
					fontFamily: FONT,
					fontSize: 12,
					fontWeight: 500,
					color: 'var(--lyr-ink)',
					lineHeight: 1.2,
				}}
			>
				{label}
			</span>
			{/* macOS-style switch: 38×22 pill, 18px knob. */}
			<span
				style={{
					position: 'relative',
					width: 38,
					height: 22,
					flexShrink: 0,
					borderRadius: 999,
					background: on ? 'var(--lyr-primary)' : 'var(--lyr-surface-2)',
					transition: 'background 120ms ease',
				}}
			>
				<span
					style={{
						position: 'absolute',
						top: 2,
						left: on ? 18 : 2,
						width: 18,
						height: 18,
						borderRadius: 999,
						background: '#ffffff',
						boxShadow: '0 1px 2px rgba(0,0,0,0.3)',
						transition: 'left 120ms ease',
					}}
				/>
			</span>
		</button>
	)
}

/**
 * The Library filter popover panel — a faithful React mirror of the SwiftUI
 * `LibraryFilterPopover` (`macos/Sources/Lyrebird/Components/LibraryFilterPopover.swift`).
 *
 * A 280px-wide, max-460px-tall panel on a `--lyr-bg-alt` surface. The
 * scrollable body stacks (18pt gaps, 16pt padding) the filter groups in the
 * Swift order: **Genre** (checkbox rows), **Year** (double-thumb range slider
 * with a "low–high" readout), **Only favorited** (switch), **Format** and
 * **Duration** (checkbox rows). Each optional group is omitted when its data is
 * absent — exactly as the Swift gates Genre/Year/Format/Duration behind tab
 * applicability + non-empty data; "Only favorited" always shows. A hairline
 * `--lyr-border` divider separates the body from the footer, which holds a
 * dimmable "Clear all" link and a primary-filled "Apply" button.
 *
 * Note: there is **no sort section** here — sorting lives in a separate
 * `LibrarySortOrder` control in the app, not this popover. This mirror reflects
 * only what the Swift `LibraryFilterPopover` actually renders.
 *
 * Fully prop-driven: the host owns the draft state (the Swift `@State draft`)
 * and commits it on Apply; this component renders the current values and
 * surfaces every interaction as a callback.
 */
export function LibraryFilter({
	genres,
	selectedGenres = [],
	onToggleGenre,
	formats,
	selectedFormats = [],
	onToggleFormat,
	durations,
	selectedDurations = [],
	onToggleDuration,
	yearBounds,
	yearLow,
	yearHigh,
	onYearChange,
	onlyFavorited = false,
	onToggleFavorited,
	hasSelection = false,
	onClearAll,
	onApply,
	style,
}: LibraryFilterProps) {
	const genreSel = new Set(selectedGenres)
	const formatSel = new Set(selectedFormats)
	const durationSel = new Set(selectedDurations)

	const showGenre = genres != null && genres.length > 0
	const showYear = yearBounds != null
	const showFormat = formats != null && formats.length > 0
	const showDuration = durations != null && durations.length > 0

	const lo = yearBounds ? (yearLow ?? yearBounds[0]) : 0
	const hi = yearBounds ? (yearHigh ?? yearBounds[1]) : 0

	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				width: 280,
				maxHeight: 460,
				background: 'var(--lyr-bg-alt)',
				borderRadius: 'var(--lyr-radius-md)',
				border: '1px solid var(--lyr-border)',
				boxShadow: 'var(--lyr-shadow-window)',
				overflow: 'hidden',
				fontFamily: FONT,
				...style,
			}}
		>
			{/* Scrollable body */}
			<div style={{ overflowY: 'auto', flex: 1 }}>
				<div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: 16 }}>
					{showGenre ? (
						<CheckGroup
							title="Genre"
							options={genres}
							selected={genreSel}
							onToggle={onToggleGenre}
						/>
					) : null}

					{showYear ? (
						<div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
							<div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
								<span style={groupHeaderStyle()}>Year</span>
								<span
									style={{
										fontFamily: FONT,
										fontSize: 11,
										fontWeight: 600,
										color: 'var(--lyr-ink-2)',
										lineHeight: 1,
									}}
								>
									{lo}–{hi}
								</span>
							</div>
							<YearSlider bounds={yearBounds} low={lo} high={hi} onChange={onYearChange} />
						</div>
					) : null}

					{/* Only favorited — always rendered. */}
					<ToggleRow label="Only favorited" on={onlyFavorited} onToggle={onToggleFavorited} />

					{showFormat ? (
						<CheckGroup
							title="Format"
							options={formats}
							selected={formatSel}
							onToggle={onToggleFormat}
						/>
					) : null}

					{showDuration ? (
						<CheckGroup
							title="Duration"
							options={durations}
							selected={durationSel}
							onToggle={onToggleDuration}
						/>
					) : null}
				</div>
			</div>

			{/* Divider — Theme.border overlay. */}
			<div style={{ height: 1, background: 'var(--lyr-border)' }} />

			{/* Footer: Clear all (left) / Apply (right). */}
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'space-between',
					padding: '12px 16px',
				}}
			>
				<button
					type="button"
					onClick={onClearAll}
					disabled={!hasSelection}
					style={{
						fontFamily: FONT,
						fontSize: 12,
						fontWeight: 600,
						color: 'var(--lyr-ink-2)',
						background: 'transparent',
						border: 'none',
						padding: 0,
						cursor: hasSelection ? 'pointer' : 'default',
						opacity: hasSelection ? 1 : 0.4,
						appearance: 'none',
						WebkitAppearance: 'none',
					}}
				>
					Clear all
				</button>

				<button
					type="button"
					onClick={onApply}
					style={{
						fontFamily: FONT,
						fontSize: 12,
						fontWeight: 700,
						color: 'var(--lyr-ink)',
						background: 'var(--lyr-primary)',
						border: 'none',
						borderRadius: 8,
						padding: '7px 16px',
						cursor: 'pointer',
						appearance: 'none',
						WebkitAppearance: 'none',
					}}
				>
					Apply
				</button>
			</div>
		</div>
	)
}
