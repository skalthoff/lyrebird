import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'

export interface RecentlyPlayedTileProps {
	/** Track title (primary line, bold, single-line ellipsis). */
	title: string
	/** Artist name (secondary line, `--lyr-ink-2`, single-line ellipsis). */
	artist: string
	/** Cover art URL. Absent → deterministic gradient keyed on `artworkSeed`. */
	artworkUrl?: string
	/** Seed for the fallback gradient. Defaults to `title` (the app seeds on `album.name ?? track.name`). */
	artworkSeed?: string
	/** Force hover visuals (play affordance lift) for static previews. Omit for live interactivity. */
	hovered?: boolean
	/** Fires when the floating play button is clicked (stops propagation to `onClick`). */
	onPlay?: () => void
	/** Fires when the tile is clicked (plays the track in the app). */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * Square-artwork track tile used in horizontal carousels on Home (Recently
 * Played) and Discover (For You). A 160px cover over a bold title + artist line;
 * a circular play button lifts in from the bottom-trailing corner on hover.
 * Mirrors `RecentlyPlayedTile` in `RecentlyPlayedTile.swift`.
 */
export function RecentlyPlayedTile({
	title,
	artist,
	artworkUrl,
	artworkSeed,
	hovered,
	onPlay,
	onClick,
	style,
}: RecentlyPlayedTileProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onClick}
			style={{
				display: 'inline-flex',
				flexDirection: 'column',
				gap: 8,
				fontFamily: 'var(--lyr-font)',
				cursor: onClick ? 'pointer' : undefined,
				...style,
			}}
		>
			{/* Artwork + bottom-trailing hover play button */}
			<div style={{ position: 'relative', width: 160, height: 160 }}>
				<Artwork url={artworkUrl} seed={artworkSeed ?? title} size={160} radius={8} />

				<button
					type="button"
					aria-label={`Play ${title}`}
					title={`Play ${title}`}
					onClick={(e) => {
						e.stopPropagation()
						onPlay?.()
					}}
					style={{
						position: 'absolute',
						right: 8,
						bottom: 8,
						width: 36,
						height: 36,
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						padding: 0,
						border: 'none',
						borderRadius: '50%',
						background: 'var(--lyr-primary)',
						boxShadow: '0 3px 8px color-mix(in srgb, var(--lyr-primary) 50%, transparent)',
						cursor: 'pointer',
						opacity: isHovering ? 1 : 0,
						transform: isHovering ? 'translateY(0)' : 'translateY(8px)',
						transition: 'opacity 0.15s ease-out, transform 0.15s ease-out',
						pointerEvents: isHovering ? 'auto' : 'none',
					}}
				>
					<Icon name="play" size={14} color="#ffffff" fill />
				</button>
			</div>

			{/* Title + artist */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 2, width: 160 }}>
				<div
					style={{
						fontSize: 13,
						fontWeight: 700,
						color: 'var(--lyr-ink)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{title}
				</div>
				<div
					style={{
						fontSize: 11,
						fontWeight: 500,
						color: 'var(--lyr-ink-2)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{artist}
				</div>
			</div>
		</div>
	)
}
