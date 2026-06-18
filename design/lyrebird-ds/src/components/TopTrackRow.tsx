import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Icon } from './Icon'
import { Artwork } from './Artwork'
import { EqualizerIcon } from './EqualizerIcon'

/** Lifetime-play-count label. Mirrors Swift's `playCountLabel`: 0 → an em dash,
 *  otherwise the pluralized `count.plays` string ("1 play" / "N plays"). */
function playCountLabel(playCount?: number): string {
	if (playCount == null || playCount === 0) return '—'
	return playCount === 1 ? '1 play' : `${playCount} plays`
}

export interface TopTrackRowProps {
	/** 1-based rank shown in the leading 28px column. */
	rank: number
	/** Track title (primary line). */
	title: string
	/** Artist — secondary-line fallback when no `album` is given (mirrors
	 *  Swift's `track.albumName ?? track.artistName`). */
	artist?: string
	/** Album — preferred secondary line. Falls back to `artist` when absent. */
	album?: string
	/** Per-row artwork URL (the track's album art). Gradient fallback when absent. */
	artworkUrl?: string
	/** Stable seed for the artwork gradient fallback. Defaults to `title`. */
	artworkSeed?: string
	/** Lifetime play count. `0`/undefined renders an em dash. */
	playCount?: number
	/** Pre-formatted duration, e.g. "3:42". */
	duration: string
	/** Favorited — keeps the heart filled + accent-tinted. */
	favorite?: boolean
	/** Current track — paints rank + title in `--lyr-accent` and tints the row. */
	active?: boolean
	/** Active *and* playing — swaps the rank for the animated equalizer. */
	playing?: boolean
	/** Force hover visuals (for static previews). Omit for live interactivity. */
	hovered?: boolean
	onPlay?: () => void
	onToggleFavorite?: () => void
	style?: CSSProperties
}

/**
 * The ranked "Top Tracks" row on the Artist detail screen (#229). Denser than
 * `TrackRow`: a leading rank column (28px) that swaps to a play glyph on hover
 * and an animated equalizer while playing, a 40px per-row album thumbnail (the
 * visual anchor when rows span many albums), the title / album, a right-aligned
 * play-count label, and the duration. The title and rank go accent when the row
 * is the current track; the background tints to `--lyr-surface-2` when active or
 * `--lyr-native-hover` on hover.
 */
export function TopTrackRow({
	rank,
	title,
	artist,
	album,
	artworkUrl,
	artworkSeed,
	playCount,
	duration,
	favorite = false,
	active = false,
	playing = false,
	hovered,
	onPlay,
	onToggleFavorite,
	style,
}: TopTrackRowProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	const background = active
		? 'var(--lyr-surface-2)'
		: isHovering
			? 'var(--lyr-native-hover)'
			: 'transparent'

	const countText = playCountLabel(playCount)

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onPlay}
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 14,
				padding: '8px 14px',
				borderRadius: 6,
				background,
				fontFamily: 'var(--lyr-font)',
				cursor: onPlay ? 'default' : undefined,
				...style,
			}}
		>
			{/* Rank / play / equalizer column */}
			<div
				style={{
					width: 28,
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'center',
					flexShrink: 0,
				}}
			>
				{playing ? (
					<EqualizerIcon />
				) : isHovering ? (
					<Icon name="play" size={12} color="var(--lyr-ink)" fill />
				) : (
					<span
						style={{
							fontSize: 14,
							fontWeight: 800,
							fontVariantNumeric: 'tabular-nums',
							color: active ? 'var(--lyr-accent)' : 'var(--lyr-ink-3)',
						}}
					>
						{rank}
					</span>
				)}
			</div>

			{/* Per-row album artwork */}
			<Artwork
				url={artworkUrl}
				seed={artworkSeed ?? title}
				size={40}
				radius={4}
				shadow={false}
			/>

			{/* Title + album/artist */}
			<div style={{ flex: 1, minWidth: 0 }}>
				<div
					style={{
						fontSize: 13,
						fontWeight: 600,
						color: active ? 'var(--lyr-accent)' : 'var(--lyr-ink)',
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
						marginTop: 2,
					}}
				>
					{album ?? artist ?? ''}
				</div>
			</div>

			{/* Favorite heart — visible while favorited or hovering. (Not in the
			    Swift TopTrackRow, which exposes favorite via the context menu; kept
			    here to honor the `favorite` / `onToggleFavorite` props.) */}
			{(favorite || isHovering) && (
				<button
					type="button"
					aria-label={favorite ? 'Unfavorite' : 'Favorite'}
					title={favorite ? 'Unfavorite' : 'Favorite'}
					onClick={(e) => {
						e.stopPropagation()
						onToggleFavorite?.()
					}}
					style={{
						width: 28,
						height: 28,
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						padding: 0,
						border: 'none',
						background: 'transparent',
						cursor: 'pointer',
						flexShrink: 0,
					}}
				>
					<Icon
						name="heart"
						size={13}
						fill={favorite}
						color={favorite ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
					/>
				</button>
			)}

			{/* Play-count label */}
			<span
				style={{
					minWidth: 72,
					textAlign: 'right',
					fontSize: 11,
					fontWeight: 600,
					letterSpacing: '0.5px',
					color: 'var(--lyr-ink-3)',
					flexShrink: 0,
				}}
			>
				{countText}
			</span>

			{/* Duration */}
			<span
				style={{
					minWidth: 42,
					textAlign: 'right',
					fontSize: 12,
					fontWeight: 500,
					fontVariantNumeric: 'tabular-nums',
					color: 'var(--lyr-ink-3)',
					flexShrink: 0,
				}}
			>
				{duration}
			</span>
		</div>
	)
}
