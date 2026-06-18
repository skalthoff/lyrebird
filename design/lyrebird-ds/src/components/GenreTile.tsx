import type { CSSProperties } from 'react'
import { useState } from 'react'

/**
 * FNV-1a over the genre name's unicode scalars → a 0–1 hue, mirroring
 * `GenreBrowseTile.hue` in `BrowseByGenreSection.swift`. Stable, well-spread,
 * so the same genre always lands on the same color across renders. JS bitwise
 * ops are 32-bit, matching Swift's `UInt32` `&*`/`^` wrap exactly when kept in
 * the unsigned domain via `>>> 0`.
 */
function hueForName(name: string): number {
	let hash = 2166136261
	for (let i = 0; i < name.length; i++) {
		// Swift iterates unicode scalars; charCodeAt gives UTF-16 code units, which
		// agree for the BMP. Both ^ then *16777619 with 32-bit wrap.
		hash = (hash ^ name.charCodeAt(i)) >>> 0
		hash = Math.imul(hash, 16777619) >>> 0
	}
	return (hash % 360) / 360.0
}

/**
 * SwiftUI `Color(hue:saturation:brightness:)` is HSB; CSS has no HSB, so convert
 * HSB→HSL for an `hsl()` string. `hue` is 0–1 (turns), `s`/`b` are 0–1.
 */
function hsbCss(hue: number, s: number, b: number): string {
	const l = b * (1 - s / 2)
	const sl = l === 0 || l === 1 ? 0 : (b - l) / Math.min(l, 1 - l)
	return `hsl(${(hue * 360).toFixed(1)}deg ${(sl * 100).toFixed(1)}% ${(l * 100).toFixed(1)}%)`
}

export interface GenreTileProps {
	/** Genre name shown over the gradient (e.g. "Electronic"). Clamps to 2 lines. */
	name: string
	/**
	 * Stable string the deterministic gradient hue is hashed from. Defaults to
	 * `name` — pass the genre's name (or id) so the same genre always lands on
	 * the same color, matching `GenreBrowseTile`'s FNV-1a-of-name behavior.
	 */
	seed?: string
	/**
	 * Explicit base hue in 0–1 turns, bypassing the name hash. Mirrors how
	 * `DecadeTile` seeds its hue by ordinal — provide it only when you need a
	 * fixed color; otherwise the `seed`/`name` hash drives it.
	 */
	hue?: number
	/** Click handler — taps open the genre detail screen in the app. */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * One gradient genre browse tile. Faithful mirror of the SwiftUI
 * `GenreBrowseTile` (`macos/Sources/Lyrebird/Components/BrowseByGenreSection.swift`):
 * a 96px-tall, full-width continuous-corner card (radius 14) with a deterministic
 * per-genre diagonal HSB wash and the genre name in 16pt bold white at the
 * bottom-leading corner, so the Search browse grid reads as a colorful mosaic
 * rather than a wall of identical chips.
 *
 * Hover lifts the white hairline stroke from 0.12 → 0.35, scales the card to
 * 1.03, and deepens the seed-colored drop shadow — the same hover vocabulary the
 * Decade row and genre-explore shelves share.
 */
export function GenreTile({ name, seed, hue: hueProp, onClick, style }: GenreTileProps) {
	const [hovering, setHovering] = useState(false)

	// Deterministic base hue: explicit prop wins, else FNV-1a over seed ?? name.
	const hue = hueProp ?? hueForName(seed ?? name)

	// Matches GenreBrowseTile: seedColor (shadow) = HSB(hue, 0.55, 0.62); the
	// diagonal gradient runs HSB(hue, 0.62, 0.66) → HSB(hue, 0.70, 0.34).
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
			aria-label={`Browse ${name}`}
			title={`Browse ${name}`}
			style={{
				// Layout: full-width 96pt card, label pinned bottom-leading.
				position: 'relative',
				display: 'flex',
				alignItems: 'flex-end',
				width: '100%',
				height: 96,
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
					fontSize: 16,
					fontWeight: 700,
					lineHeight: 1.15,
					color: '#ffffff',
					// .lineLimit(2) — clamp to two lines.
					display: '-webkit-box',
					WebkitLineClamp: 2,
					WebkitBoxOrient: 'vertical',
					overflow: 'hidden',
					// .shadow(color: .black.opacity(0.45), radius: 4, y: 1).
					textShadow: '0 1px 4px rgba(0,0,0,0.45)',
				}}
			>
				{name}
			</span>
		</button>
	)
}
