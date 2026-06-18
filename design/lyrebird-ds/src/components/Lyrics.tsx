import type { CSSProperties } from 'react'

/** A single lyric line in the {@link Lyrics} list. */
export interface LyricLineModel {
	/** The lyric text for this line. */
	text: string
}

export interface LyricRowProps {
	/** The lyric text to render. */
	text: string
	/**
	 * Whether this is the current line. Active rows bloom to 22px bold `--lyr-ink`
	 * with a soft accent glow; inactive rows dim to 18px medium `--lyr-ink-3` at
	 * 55% opacity and rest at 99% scale, mirroring `LyricLineStyle.resolve`.
	 */
	active?: boolean
	/**
	 * Suppress the scale bloom + glow (the only motion in the row) — the mirror
	 * of the SwiftUI Reduce-Motion gate. Active lines still get the brighter
	 * `--lyr-ink` + bold/size swap, just without the scale/glow. Default false.
	 */
	reduceMotion?: boolean
	style?: CSSProperties
}

/**
 * One rendered synced-lyric row. Faithful to the SwiftUI `LyricRow` /
 * `LyricLineStyle.resolve` contract in
 * `macos/Sources/Lyrebird/Components/LyricsView.swift`: the active line is
 * 22px bold `--lyr-ink` at full opacity with a soft `--lyr-accent`-tinted
 * glow and 100% scale; inactive lines are 18px medium `--lyr-ink-3` at 55%
 * opacity and 99% scale so the eye is pulled to the current line. Under
 * `reduceMotion` the scale + glow drop away (the active line still swaps to
 * the brighter/bolder treatment instantly), matching the Swift Reduce-Motion
 * fallback.
 */
export function LyricRow({ text, active = false, reduceMotion = false, style }: LyricRowProps) {
	// LyricLineStyle.resolve(isActive:reduceMotion:) — the active/inactive
	// font / weight / colour / opacity contract, plus the motion-gated
	// scale + glow.
	const fontSize = active ? 22 : 18
	const fontWeight = active ? 700 : 500
	const color = active ? 'var(--lyr-ink)' : 'var(--lyr-ink-3)'
	const opacity = active ? 1 : 0.55
	const scale = reduceMotion ? 1 : active ? 1 : 0.99
	// Glow rides only on the active line, and only when motion is allowed.
	// Tinted with the active ink (accent) so it reads as the line lighting up
	// rather than a drop shadow.
	const glow = active && !reduceMotion
		? '0 0 10px color-mix(in srgb, var(--lyr-accent) 45%, transparent)'
		: 'none'

	return (
		<div
			style={{
				fontFamily: 'var(--lyr-font)',
				fontSize,
				fontWeight,
				lineHeight: 1.3,
				color,
				opacity,
				transform: `scale(${scale})`,
				transformOrigin: 'left center',
				textShadow: glow,
				...style,
			}}
		>
			{text}
		</div>
	)
}

export interface LyricsProps {
	/** The ordered lyric lines. Empty renders the "No Lyrics" state. */
	lines: LyricLineModel[]
	/**
	 * Index of the current line in {@link lines}. Drives the highlight. Omit (or
	 * pass `null`) for the static, un-highlighted treatment — the mirror of an
	 * LRC-less blob where no line auto-activates.
	 */
	activeIndex?: number | null
	/**
	 * Whether the lyrics carry timing (LRC). When `true`, the list renders with
	 * the synced active-line emphasis; when `false`, every line renders as a
	 * uniform 15px `--lyr-ink-2` static column with no highlight, mirroring the
	 * SwiftUI `staticText` branch. Default: inferred — synced when `activeIndex`
	 * is a number, static otherwise.
	 */
	synced?: boolean
	/**
	 * Mirror of the SwiftUI Reduce-Motion gate — drops the active line's scale
	 * bloom + glow while keeping the brighter/bolder swap. Default false.
	 */
	reduceMotion?: boolean
	style?: CSSProperties
}

/**
 * The lyrics viewer used inside Now Playing — a faithful mirror of
 * `macos/Sources/Lyrebird/Components/LyricsView.swift`. Renders one of three
 * states:
 *
 * - **Empty** (`lines` empty): the "No Lyrics" placeholder — a `music` glyph,
 *   an `--lyr-ink-3` headline, and a one-line description, mirroring the
 *   SwiftUI `ContentUnavailableView`.
 * - **Static** (`synced` false / no `activeIndex`): a left-aligned column of
 *   uniform 15px medium `--lyr-ink-2` lines with 10px spacing and 28h/24v
 *   padding, mirroring the `staticText` branch for LRC-less lyrics.
 * - **Synced** (`synced` true with an `activeIndex`): the vertical list with
 *   the active line emphasized (22px bold `--lyr-ink` + glow) and the rest
 *   dimmed (18px medium `--lyr-ink-3` @ 55%), 14px spacing and 28h padding.
 *   Auto-scroll/seek-on-tap are app concerns the presentational mirror omits;
 *   the visual active-line contract is preserved via {@link LyricRow}.
 *
 * Presentational only: the SwiftUI view owns a 200ms ticker that resolves the
 * active line from playback position; here the resolved index arrives as the
 * `activeIndex` prop.
 */
export function Lyrics({ lines, activeIndex, synced, reduceMotion = false, style }: LyricsProps) {
	const isEmpty = lines.length === 0
	// SwiftUI infers "static" when no line carries a timestamp; here the caller
	// signals it via `synced=false`, or we infer it from a missing activeIndex.
	const hasActive = activeIndex != null
	const isSynced = synced ?? hasActive

	const root: CSSProperties = {
		fontFamily: 'var(--lyr-font)',
		width: '100%',
		background: 'var(--lyr-bg)',
		boxSizing: 'border-box',
		...style,
	}

	// MARK: - Empty state — ContentUnavailableView("No Lyrics", music.note.list)
	if (isEmpty) {
		return (
			<div
				style={{
					...root,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					justifyContent: 'center',
					gap: 10,
					padding: '48px 28px',
					textAlign: 'center',
					color: 'var(--lyr-ink-3)',
				}}
			>
				<svg
					width={40}
					height={40}
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					strokeWidth={1.6}
					strokeLinecap="round"
					strokeLinejoin="round"
					aria-hidden="true"
					style={{ display: 'block' }}
				>
					{/* music.note.list — a list of lines with a note on the trailing edge */}
					<path d="M3 6h11M3 12h8M3 18h8" />
					<path d="M15 18V9l5-1.5v8" />
					<circle cx="13.5" cy="18" r="1.5" />
					<circle cx="18.5" cy="15.5" r="1.5" />
				</svg>
				<div style={{ fontSize: 17, fontWeight: 600, color: 'var(--lyr-ink-3)' }}>No Lyrics</div>
				<div style={{ fontSize: 13, fontWeight: 500, color: 'var(--lyr-ink-3)', maxWidth: 320 }}>
					This track doesn&rsquo;t have lyrics available.
				</div>
			</div>
		)
	}

	// MARK: - Static (untimed) text — uniform 15px medium ink2 column.
	if (!isSynced) {
		return (
			<div style={{ ...root, padding: '24px 28px' }}>
				<div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
					{lines.map((line, i) => (
						<div
							key={i}
							style={{
								fontSize: 15,
								fontWeight: 500,
								lineHeight: 1.35,
								color: 'var(--lyr-ink-2)',
							}}
						>
							{line.text}
						</div>
					))}
				</div>
			</div>
		)
	}

	// MARK: - Synced lyrics — active line emphasized, rest dimmed.
	// SwiftUI uses 120px top/bottom padding so the active line can rest near the
	// viewport centre during auto-scroll; the static mirror keeps a gentler 28px.
	return (
		<div style={{ ...root, padding: '28px' }}>
			<div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
				{lines.map((line, i) => (
					<LyricRow key={i} text={line.text} active={i === activeIndex} reduceMotion={reduceMotion} />
				))}
			</div>
		</div>
	)
}
