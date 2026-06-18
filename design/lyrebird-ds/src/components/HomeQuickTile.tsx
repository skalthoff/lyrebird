import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'

export interface HomeQuickTileProps {
	/** Primary line (bold, single-line ellipsis). */
	title: string
	/** Secondary line (`--lyr-ink-2`, single-line ellipsis). Hidden when empty. */
	subtitle?: string
	/** Artwork URL. Absent → deterministic gradient keyed on `seed`. */
	artworkUrl?: string
	/** Seed for the fallback gradient when artwork is missing. */
	seed: string
	/** Force hover visuals (surface lift + play affordance) for static previews. Omit for live interactivity. */
	hovered?: boolean
	/** Fires when the floating play button is clicked (stops propagation to `onClick`). */
	onPlay?: () => void
	/** Fires when the tile surface is clicked. */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * Compact home-screen quick-action tile: a 48px artwork + title/subtitle with a
 * floating play-on-hover circle that slides in from the right. Lives in the
 * 3-column quick-tiles row at the top of Home. On hover the surface lifts from
 * `--lyr-surface` to `--lyr-surface-2` and the trailing play button fades + slides
 * in. Mirrors `HomeQuickTile` in `HomeQuickTile.swift`.
 */
export function HomeQuickTile({
	title,
	subtitle,
	artworkUrl,
	seed,
	hovered,
	onPlay,
	onClick,
	style,
}: HomeQuickTileProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onClick}
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 12,
				width: '100%',
				minHeight: 60,
				boxSizing: 'border-box',
				paddingTop: 10,
				paddingBottom: 10,
				paddingLeft: 10,
				paddingRight: 14,
				borderRadius: 8,
				background: isHovering ? 'var(--lyr-surface-2)' : 'var(--lyr-surface)',
				fontFamily: 'var(--lyr-font)',
				cursor: onClick ? 'pointer' : undefined,
				...style,
			}}
		>
			<Artwork url={artworkUrl} seed={seed} size={48} radius={4} />

			<div
				style={{
					display: 'flex',
					flexDirection: 'column',
					gap: 2,
					flex: 1,
					minWidth: 0,
				}}
			>
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
				{subtitle && (
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
						{subtitle}
					</div>
				)}
			</div>

			<button
				type="button"
				aria-label={`Play ${title}`}
				title={`Play ${title}`}
				onClick={(e) => {
					e.stopPropagation()
					onPlay?.()
				}}
				style={{
					flexShrink: 0,
					width: 36,
					height: 36,
					display: 'inline-flex',
					alignItems: 'center',
					justifyContent: 'center',
					padding: 0,
					border: 'none',
					borderRadius: '50%',
					background: 'var(--lyr-primary)',
					boxShadow: '0 6px 7px color-mix(in srgb, var(--lyr-primary) 40%, transparent)',
					cursor: 'pointer',
					opacity: isHovering ? 1 : 0,
					transform: isHovering ? 'translateX(0)' : 'translateX(8px)',
					transition: 'opacity 0.2s ease-out, transform 0.2s ease-out',
					pointerEvents: isHovering ? 'auto' : 'none',
				}}
			>
				<Icon name="play" size={12} color="#ffffff" fill />
			</button>
		</div>
	)
}
