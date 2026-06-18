import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Icon } from './Icon'
import { FormatBadge } from './FormatBadge'
import { EqualizerIcon } from './EqualizerIcon'

export interface TrackRowProps {
	/** Track title (primary line). */
	title: string
	/** Artist (secondary line). */
	artist: string
	/** Pre-formatted duration, e.g. "3:42". */
	duration: string
	/** Ordinal shown in the leading 32px column when `showNumber`. */
	number?: number
	/** Container format → inline `FormatBadge` (e.g. "FLAC"). */
	format?: string
	/** Bitrate for the format-badge tooltip. */
	bitrateKbps?: number
	/** Current track — paints the title in `--lyr-accent` and tints the row. */
	active?: boolean
	/** Active *and* playing — swaps the number for the animated equalizer. */
	playing?: boolean
	/** Favorited — the heart stays filled and accent-tinted. */
	favorite?: boolean
	/** Part of a multi-selection — accent rail + tint. */
	selected?: boolean
	/** Show the leading track number. Default true. */
	showNumber?: boolean
	/** Force hover visuals (for static previews). Omit for live interactivity. */
	hovered?: boolean
	onPlay?: () => void
	onToggleFavorite?: () => void
	style?: CSSProperties
}

/**
 * The numbered track row used across album, playlist, and search results.
 * Leading 32px column shows the number, a play glyph on hover, or an animated
 * equalizer while playing; the title goes accent when the row is the current
 * track. Hover reveals the favorite heart. Background reflects
 * selected / active / hover state, with a 2px accent selection rail.
 */
export function TrackRow({
	title,
	artist,
	duration,
	number,
	format,
	bitrateKbps,
	active = false,
	playing = false,
	favorite = false,
	selected = false,
	showNumber = true,
	hovered,
	onPlay,
	onToggleFavorite,
	style,
}: TrackRowProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	const background = selected
		? 'color-mix(in srgb, var(--lyr-accent) 18%, transparent)'
		: active
			? 'var(--lyr-surface-2)'
			: isHovering
				? 'var(--lyr-native-hover)'
				: 'transparent'

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onPlay}
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'center',
				gap: 12,
				padding: '8px 16px',
				borderRadius: 6,
				background,
				fontFamily: 'var(--lyr-font)',
				cursor: onPlay ? 'default' : undefined,
				...style,
			}}
		>
			{selected && (
				<span
					style={{
						position: 'absolute',
						left: 0,
						top: 2,
						bottom: 2,
						width: 2,
						borderRadius: 1,
						background: 'var(--lyr-accent)',
					}}
				/>
			)}

			{/* Leading number / play / equalizer column */}
			<div
				style={{
					width: 32,
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'center',
					flexShrink: 0,
				}}
			>
				{playing ? (
					<EqualizerIcon />
				) : isHovering ? (
					<Icon name="play" size={11} color="var(--lyr-ink)" fill />
				) : showNumber && number != null ? (
					<span
						style={{
							fontSize: 12,
							fontWeight: 500,
							fontVariantNumeric: 'tabular-nums',
							color: active ? 'var(--lyr-accent)' : 'var(--lyr-ink-3)',
						}}
					>
						{number}
					</span>
				) : null}
			</div>

			{/* Title + artist */}
			<div style={{ flex: 1, minWidth: 0 }}>
				<div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
					<span
						style={{
							fontSize: 13,
							fontWeight: 600,
							color: active ? 'var(--lyr-accent)' : 'var(--lyr-ink)',
							overflow: 'hidden',
							textOverflow: 'ellipsis',
							whiteSpace: 'nowrap',
							minWidth: 0,
						}}
					>
						{title}
					</span>
					{format && <FormatBadge format={format} bitrateKbps={bitrateKbps} />}
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
					{artist}
				</div>
			</div>

			{/* Favorite heart — visible while favorited or hovering */}
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

			{/* Duration */}
			<span
				style={{
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
