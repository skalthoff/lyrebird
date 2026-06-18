import { useState } from 'react'
import type { CSSProperties } from 'react'

/**
 * Deterministic base hue from a small FNV-1a over the seed's UTF-16 code units.
 * Mirrors `RadioStationTile.hue` in `RadioStationRows.swift` (and `GenreExploreTile`)
 * so a given station keeps the same color across renders. The Swift hashes over
 * `unicodeScalars`; for the ASCII station/genre/decade seeds used here the UTF-16
 * code units coincide, so the hue lands on the same value.
 */
function hueFor(seed: string): number {
	let hash = 2166136261
	for (let i = 0; i < seed.length; i++) {
		hash = (hash ^ seed.charCodeAt(i)) >>> 0
		hash = Math.imul(hash, 16777619) >>> 0
	}
	return (hash % 360) / 360
}

/** `Color(hue:saturation:brightness:)` → `hsl()`. SwiftUI HSB maps to HSL when
 *  lightness = brightness * (1 - saturation/2); we emit that so the rendered hue
 *  and tone match the Swift gradient stops. */
function hsb(hue: number, saturation: number, brightness: number): string {
	const h = hue * 360
	const l = brightness * (1 - saturation / 2)
	const s = l === 0 || l === 1 ? 0 : (brightness - l) / Math.min(l, 1 - l)
	return `hsl(${h.toFixed(1)}, ${(s * 100).toFixed(1)}%, ${(l * 100).toFixed(1)}%)`
}

export interface RadioStationTileProps {
	/** Station name drawn bottom-left over the gradient (e.g. a genre, decade, or mood). */
	title: string
	/**
	 * Deterministic color seed — the same seed always lands on the same hue, so a
	 * given station keeps its color. The Swift seeds genres on `genre.name`,
	 * decades on `decade-<startYear>`, moods on `mood-<tag>`.
	 */
	seed: string
	/**
	 * Title font size in px. Default 20 (bold). The Swift decade row overrides this
	 * to 34 (black, italic) — pass `titleSize={34} titleBlackItalic` to match.
	 */
	titleSize?: number
	/** Render the title at weight 900 + italic (the decade-row treatment). */
	titleBlackItalic?: boolean
	/** Force hover visuals (brighter glyph + stroke, lift, stronger shadow) for static previews. */
	hovered?: boolean
	/** Fires when the tile is pressed — starts the station in the app. */
	onStart?: () => void
	/** Spoken/title-attribute verb, e.g. "Start Synthwave radio". */
	accessibilityVerb?: string
	style?: CSSProperties
}

/**
 * One radio-station tile: a 150×120 continuous-corner gradient card with a
 * station title bottom-left and a radio glyph top-trailing that brightens on
 * hover, so the tile reads as a "press to start a station" affordance rather
 * than a passive label. The gradient + drop-shadow color derive deterministically
 * from `seed` (FNV-1a → hue), matching `DecadeBrowseRow` / `GenresToExploreSection`.
 * Mirrors the private `RadioStationTile` in `RadioStationRows.swift`.
 */
export function RadioStationTile({
	title,
	seed,
	titleSize = 20,
	titleBlackItalic = false,
	hovered,
	onStart,
	accessibilityVerb,
	style,
}: RadioStationTileProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	const hue = hueFor(seed)
	const seedColor = hsb(hue, 0.55, 0.62)
	const gradient = `linear-gradient(135deg, ${hsb(hue, 0.62, 0.66)} 0%, ${hsb(
		hue,
		0.7,
		0.34,
	)} 100%)`

	return (
		<button
			type="button"
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onStart}
			title={accessibilityVerb}
			aria-label={`${title} Radio`}
			style={{
				position: 'relative',
				width: 150,
				height: 120,
				flexShrink: 0,
				padding: 0,
				border: 'none',
				borderRadius: 14,
				background: gradient,
				cursor: onStart ? 'pointer' : undefined,
				fontFamily: 'var(--lyr-font)',
				transform: isHovering ? 'scale(1.03)' : 'scale(1)',
				boxShadow: `0 ${isHovering ? 8 : 4}px ${
					isHovering ? 14 : 8
				}px color-mix(in srgb, ${seedColor} ${isHovering ? 45 : 25}%, transparent)`,
				transition: 'transform 0.15s ease-out, box-shadow 0.15s ease-out',
				...style,
			}}
		>
			{/* Continuous-corner stroke — brightens on hover. */}
			<div
				style={{
					position: 'absolute',
					inset: 0,
					borderRadius: 14,
					border: `1px solid rgba(255,255,255,${isHovering ? 0.35 : 0.12})`,
					transition: 'border-color 0.15s ease-out',
					pointerEvents: 'none',
				}}
			/>

			{/* Radio glyph, top-trailing — the "this is a station" cue. */}
			<div
				style={{
					position: 'absolute',
					top: 12,
					right: 12,
					color: `rgba(255,255,255,${isHovering ? 1 : 0.7})`,
					filter: 'drop-shadow(0 1px 3px rgba(0,0,0,0.35))',
					transition: 'color 0.15s ease-out',
					lineHeight: 0,
				}}
			>
				<svg
					width={16}
					height={16}
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					strokeWidth={2.4}
					strokeLinecap="round"
					strokeLinejoin="round"
				>
					<circle cx="12" cy="12" r="2" fill="currentColor" stroke="none" />
					<path d="M8.5 8.5a5 5 0 0 0 0 7M6 6a8.5 8.5 0 0 0 0 12M15.5 8.5a5 5 0 0 1 0 7M18 6a8.5 8.5 0 0 1 0 12" />
				</svg>
			</div>

			{/* Station title, bottom-leading. */}
			<div
				style={{
					position: 'absolute',
					left: 14,
					right: 14,
					bottom: 14,
					textAlign: 'left',
					color: '#ffffff',
					fontSize: titleSize,
					fontWeight: titleBlackItalic ? 900 : 700,
					fontStyle: titleBlackItalic ? 'italic' : 'normal',
					lineHeight: 1.05,
					display: '-webkit-box',
					WebkitLineClamp: 2,
					WebkitBoxOrient: 'vertical',
					overflow: 'hidden',
					textShadow: '0 1px 4px rgba(0,0,0,0.45)',
				}}
			>
				{title}
			</div>
		</button>
	)
}
