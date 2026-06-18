import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'

export interface AlbumCardProps {
	/** Album title (primary line, bold, single-line ellipsis). */
	title: string
	/** Artist name (secondary line, `--lyr-ink-2`). */
	artist?: string
	/** Release year — rendered after the artist as `· 2016` in `--lyr-ink-3`. */
	year?: number
	/** Cover art URL. Absent → deterministic gradient keyed on `artworkSeed`. */
	artworkUrl?: string
	/** Seed for the fallback gradient. Defaults to `title` (matches the app, which seeds on `album.name`). */
	artworkSeed?: string
	/** Artwork edge in px. Default 180 (the Library grid tile size). */
	size?: number
	/** Force hover visuals (play affordance + tint + lift) for static previews. Omit for live interactivity. */
	hovered?: boolean
	/** Fires when the hover play button is clicked (stops propagation to `onClick`). */
	onPlay?: () => void
	/** Fires when the card body is clicked (navigates to the album in the app). */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * Square grid tile used in the Library Albums tab. A cover-art square over a
 * bold title + artist/year line. On hover the card lifts (1.02×), tints with
 * `--lyr-native-hover`, and reveals a circular play button in the artwork's
 * bottom-trailing corner. Mirrors `AlbumCard` in `LibraryView.swift`.
 */
export function AlbumCard({
	title,
	artist,
	year,
	artworkUrl,
	artworkSeed,
	size = 180,
	hovered,
	onPlay,
	onClick,
	style,
}: AlbumCardProps) {
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
				gap: 10,
				padding: 10,
				borderRadius: 12,
				background: isHovering ? 'var(--lyr-native-hover)' : 'transparent',
				transform: isHovering ? 'scale(1.02)' : 'scale(1)',
				transition: 'transform 0.12s ease-out, background 0.12s ease-out',
				fontFamily: 'var(--lyr-font)',
				cursor: onClick ? 'pointer' : undefined,
				...style,
			}}
		>
			{/* Artwork + bottom-trailing hover play button */}
			<div style={{ position: 'relative', width: size, height: size }}>
				<Artwork url={artworkUrl} seed={artworkSeed ?? title} size={size} radius={8} />

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
						pointerEvents: isHovering ? 'auto' : 'none',
					}}
				>
					<Icon name="play" size={16} color="#ffffff" fill />
				</button>
			</div>

			{/* Title + artist · year */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 2, width: size }}>
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
				<div style={{ display: 'flex', alignItems: 'baseline', gap: 6, minWidth: 0 }}>
					{artist && (
						<span
							style={{
								fontSize: 11,
								fontWeight: 500,
								color: 'var(--lyr-ink-2)',
								overflow: 'hidden',
								textOverflow: 'ellipsis',
								whiteSpace: 'nowrap',
								minWidth: 0,
							}}
						>
							{artist}
						</span>
					)}
					{year != null && (
						<span
							style={{
								fontSize: 11,
								fontWeight: 500,
								color: 'var(--lyr-ink-3)',
								flexShrink: 0,
							}}
						>
							· {year}
						</span>
					)}
				</div>
			</div>
		</div>
	)
}
