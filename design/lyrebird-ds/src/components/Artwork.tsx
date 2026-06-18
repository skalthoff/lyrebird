import type { CSSProperties } from 'react'

/** Fallback gradient palette — sourced verbatim from the app's `Artwork.swift`. */
const PALETTE: ReadonlyArray<readonly [string, string]> = [
	['#2B1E5C', '#887BFF'],
	['#4B0FD6', '#FF066F'],
	['#0F3D48', '#57E9C9'],
	['#3A1655', '#CC2F71'],
	['#1F1A4A', '#4B7DD7'],
	['#271055', '#A96BFF'],
	['#541A2E', '#FF6625'],
	['#10314F', '#2FA6D9'],
	['#4A2260', '#ECECEC'],
	['#223355', '#887BFF'],
]

/** Deterministic palette pick — matches Swift's `hash = hash &* 31 &+ byte`. */
function paletteFor(seed: string): readonly [string, string] {
	let hash = 0
	for (let i = 0; i < seed.length; i++) {
		hash = (Math.imul(hash, 31) + seed.charCodeAt(i)) >>> 0
	}
	return PALETTE[hash % PALETTE.length]
}

export interface ArtworkProps {
	/** Image URL. When absent (or while loading/failed) a gradient renders. */
	url?: string
	/** Stable string (track/album/artist name) that picks the fallback gradient. */
	seed?: string
	/** Square edge in px. Default 120. */
	size?: number
	/** Corner radius in px. Default 8. Ignored when `shape="circle"`. */
	radius?: number
	/** `rounded` (default) for albums/tracks; `circle` for artists. */
	shape?: 'rounded' | 'circle'
	/** Label drawn bottom-left over the gradient fallback (e.g. a playlist name). */
	overlayLabel?: string
	/** Drop shadow. Default true. */
	shadow?: boolean
	style?: CSSProperties
	onClick?: () => void
}

/**
 * Album / artist / playlist / track artwork. Renders the image when a `url` is
 * given, otherwise a deterministic two-stop gradient keyed on `seed` — the same
 * placedholder the app shows before/without server art. `shape="circle"` is the
 * artist treatment.
 */
export function Artwork({
	url,
	seed = '',
	size = 120,
	radius = 8,
	shape = 'rounded',
	overlayLabel,
	shadow = true,
	style,
	onClick,
}: ArtworkProps) {
	const [a, b] = paletteFor(seed)
	const borderRadius = shape === 'circle' ? size / 2 : radius
	return (
		<div
			onClick={onClick}
			style={{
				position: 'relative',
				width: size,
				height: size,
				flexShrink: 0,
				overflow: 'hidden',
				borderRadius,
				background: `linear-gradient(135deg, ${a} 0%, ${b} 100%)`,
				boxShadow: shadow ? 'var(--lyr-shadow-card)' : undefined,
				cursor: onClick ? 'pointer' : undefined,
				...style,
			}}
		>
			{url && (
				<img
					src={url}
					alt=""
					style={{ width: '100%', height: '100%', objectFit: 'cover', display: 'block' }}
				/>
			)}
			{overlayLabel && !url && (
				<div
					style={{
						position: 'absolute',
						left: '8%',
						right: '8%',
						bottom: '7%',
						fontFamily: 'var(--lyr-font)',
						fontWeight: 800,
						color: 'rgba(255,255,255,0.95)',
						fontSize: Math.max(9, size * 0.085),
						lineHeight: 1.1,
						letterSpacing: '-0.01em',
						textShadow: '0 2px 6px rgba(0,0,0,0.55)',
					}}
				>
					{overlayLabel}
				</div>
			)}
		</div>
	)
}
