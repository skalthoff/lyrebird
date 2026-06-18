import type { CSSProperties } from 'react'
import { useState } from 'react'

/**
 * SwiftUI `Color(hue:saturation:brightness:)` is HSB; CSS has no HSB, so convert
 * HSB→HSL for an `hsl()` string. `hue` is 0–1 (turns), `s`/`b` are 0–1.
 */
function hsbCss(hue: number, s: number, b: number): string {
	const l = b * (1 - s / 2)
	const sl = l === 0 || l === 1 ? 0 : (b - l) / Math.min(l, 1 - l)
	return `hsl(${(hue * 360).toFixed(1)}deg ${(sl * 100).toFixed(1)}% ${(l * 100).toFixed(1)}%)`
}

/**
 * Decade ordinal → 0–1 hue, mirroring `DecadeTile.hue` in `DecadeBrowseRow.swift`:
 * `((startYear - 1960) / 10) / 7.0`, so the '60s→'20s ramp spreads as a rainbow
 * (0 for the '60s … 6 for the '20s) and the same decade always lands on the same
 * hue. Falls back to 0 for years before 1960.
 */
function hueForStartYear(startYear: number): number {
	const ordinal = Math.floor((startYear - 1960) / 10)
	return Math.max(0, ordinal) / 7.0
}

export interface DecadeTileProps {
	/**
	 * Decade label shown big-and-italic over the gradient. Mirrors
	 * `Decade.shortLabel` — pass the apostrophe form ("'80s") for the exact app
	 * face, or a full form ("1980s") if you prefer; it's rendered verbatim.
	 */
	label: string
	/**
	 * Inclusive lower bound of the decade (e.g. `1980`). Drives the deterministic
	 * rainbow hue exactly as the Swift tile does (`(startYear-1960)/10/7`). Prefer
	 * this over `hue` so a row of decades reproduces the app's ordinal ramp.
	 */
	startYear?: number
	/**
	 * Explicit base hue in 0–1 turns, bypassing the ordinal ramp. Use only when
	 * you need a fixed color; otherwise pass `startYear`.
	 */
	hue?: number
	/** Click handler — taps deep-link to the Library filtered to this decade. */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * One gradient decade browse tile. Faithful mirror of the SwiftUI `DecadeTile`
 * (`macos/Sources/Lyrebird/Components/DecadeBrowseRow.swift`): a fixed 150×120
 * continuous-corner card (radius 14) with a deterministic per-decade diagonal HSB
 * wash and an oversized 40pt black-italic white label at the bottom-leading
 * corner — the "default artwork gradient + huge italic decade text" the Discover
 * row renders.
 *
 * Hue is spread by decade ordinal across the '60s→'20s ramp so a row reads as a
 * rainbow. Hover lifts the white hairline stroke from 0.12 → 0.35, scales the
 * card to 1.03, and deepens the seed-colored shadow — matching `GenreTile` and
 * the genre-explore shelves so the Discover surface reads as one family.
 */
export function DecadeTile({ label, startYear, hue: hueProp, onClick, style }: DecadeTileProps) {
	const [hovering, setHovering] = useState(false)

	// Deterministic base hue: explicit prop wins, else the ordinal ramp; if
	// neither is given, fall back to hue 0 (the '60s slot) like a year-less tile.
	const hue = hueProp ?? (startYear !== undefined ? hueForStartYear(startYear) : 0)

	// Matches DecadeTile: seedColor (shadow) = HSB(hue, 0.55, 0.62); the diagonal
	// gradient runs HSB(hue, 0.62, 0.66) → HSB(hue, 0.70, 0.34).
	const seedColor = hsbCss(hue, 0.55, 0.62)
	const gradient = `linear-gradient(to bottom right, ${hsbCss(hue, 0.62, 0.66)}, ${hsbCss(
		hue,
		0.7,
		0.34,
	)})`

	return (
		<button
			type="button"
			onClick={onClick}
			onMouseEnter={() => setHovering(true)}
			onMouseLeave={() => setHovering(false)}
			aria-label={`Browse ${label}`}
			title={`Browse ${label}`}
			style={{
				// Layout: fixed 150×120 card, label pinned bottom-leading.
				position: 'relative',
				display: 'flex',
				alignItems: 'flex-end',
				flexShrink: 0,
				width: 150,
				height: 120,
				padding: 14,
				boxSizing: 'border-box',
				textAlign: 'left',
				// RoundedRectangle(cornerRadius: 14, style: .continuous).
				borderRadius: 14,
				background: gradient,
				// Hairline white stroke 0.12 idle → 0.35 hover.
				border: `1px solid rgba(255,255,255,${hovering ? 0.35 : 0.12})`,
				// seedColor.opacity(0.25 → 0.45) shadow, radius 8→14, y 4→8.
				boxShadow: hovering
					? `0 8px 14px color-mix(in srgb, ${seedColor} 45%, transparent)`
					: `0 4px 8px color-mix(in srgb, ${seedColor} 25%, transparent)`,
				transform: hovering ? 'scale(1.03)' : 'scale(1)',
				transition: 'transform 0.15s ease-out, border-color 0.15s ease-out, box-shadow 0.15s ease-out',
				cursor: onClick ? 'pointer' : 'default',
				appearance: 'none',
				WebkitAppearance: 'none',
				...style,
			}}
		>
			<span
				style={{
					fontFamily: 'var(--lyr-font)',
					// Theme.font(40, weight: .black, italic: true).
					fontSize: 40,
					fontWeight: 900,
					fontStyle: 'italic',
					lineHeight: 1,
					color: '#ffffff',
					whiteSpace: 'nowrap',
					// .shadow(color: .black.opacity(0.45), radius: 4, y: 1).
					textShadow: '0 1px 4px rgba(0,0,0,0.45)',
				}}
			>
				{label}
			</span>
		</button>
	)
}
