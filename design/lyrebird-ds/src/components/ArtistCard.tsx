import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'

export interface ArtistCardProps {
	/** Artist name (primary line, bold). */
	name: string
	/** Artwork image URL. When absent, a deterministic gradient renders. */
	artworkUrl?: string
	/** Stable seed for the fallback gradient. Defaults to `name`. */
	artworkSeed?: string
	/** Subline under the name, e.g. "12 albums" / "84 songs" / "Artist". Default "Artist". */
	subtitle?: string
	/** Artwork edge in px. Default 180 (the library grid tile size). */
	size?: number
	/** Force hover visuals (surface tint + revealed play overlay) for static previews. */
	hovered?: boolean
	/** Bottom-trailing play overlay tap. Reveals on hover. */
	onPlay?: () => void
	/** Card tap — pushes the artist detail route in the app. */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * Square grid tile used in the Library → Artists tab. Mirrors `AlbumCard`'s
 * visual language: square artwork (radius 8), name + count below, and a hover
 * play overlay in the bottom-trailing corner. Hovering tints the card with a
 * `--lyr-surface` rounded background and lifts the play button into view.
 *
 * Faithful to `macos/Sources/Lyrebird/Components/ArtistCard.swift`: 180pt
 * artwork, 10pt VStack spacing, 10pt padding, 12pt card corner; 40×40 primary
 * play circle with a `play.fill` glyph; name at 13/bold (`--lyr-ink`), subline
 * at 11/medium (`--lyr-ink-2`).
 */
export function ArtistCard({
	name,
	artworkUrl,
	artworkSeed,
	subtitle = 'Artist',
	size = 180,
	hovered,
	onPlay,
	onClick,
	style,
}: ArtistCardProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onClick}
			style={{
				display: 'flex',
				flexDirection: 'column',
				alignItems: 'flex-start',
				gap: 10,
				padding: 10,
				borderRadius: 12,
				background: isHovering ? 'var(--lyr-surface)' : 'transparent',
				fontFamily: 'var(--lyr-font)',
				cursor: onClick ? 'pointer' : undefined,
				width: 'fit-content',
				...style,
			}}
		>
			{/* Artwork + bottom-trailing play overlay */}
			<div style={{ position: 'relative', width: size, height: size }}>
				<Artwork url={artworkUrl} seed={artworkSeed ?? name} size={size} radius={8} />

				<button
					type="button"
					aria-label={`Play all tracks by ${name}`}
					title={`Play all tracks by ${name}`}
					onClick={(e) => {
						e.stopPropagation()
						onPlay?.()
					}}
					style={{
						position: 'absolute',
						right: 8,
						bottom: 8,
						width: 40,
						height: 40,
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						padding: 0,
						border: 'none',
						borderRadius: '50%',
						background: 'var(--lyr-primary)',
						boxShadow:
							'0 4px 10px color-mix(in srgb, var(--lyr-primary) 50%, transparent)',
						cursor: 'pointer',
						opacity: isHovering ? 1 : 0,
						transform: isHovering ? 'translateY(0)' : 'translateY(8px)',
						transition: 'opacity 0.15s ease-out, transform 0.15s ease-out',
					}}
				>
					<Icon name="play" size={16} color="#ffffff" fill />
				</button>
			</div>

			{/* Name + count */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 2, width: size, minWidth: 0 }}>
				<span
					style={{
						fontSize: 13,
						fontWeight: 700,
						color: 'var(--lyr-ink)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{name}
				</span>
				<span
					style={{
						fontSize: 11,
						fontWeight: 500,
						color: 'var(--lyr-ink-2)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{subtitle}
				</span>
			</div>
		</div>
	)
}
