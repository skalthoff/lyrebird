import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Icon } from './Icon'
import { Artwork } from './Artwork'
import { FormatBadge } from './FormatBadge'
import { EqualizerIcon } from './EqualizerIcon'

/** Row density for the Library Tracks tab (#217). */
export type TrackListDensity = 'roomy' | 'compact'

/**
 * Per-density geometry — mirrors `AppearanceDensity` in the Swift app
 * (`PreferencesAppearance.swift`): 48pt roomy / 36pt compact row, 40pt / 28pt
 * artwork, and the artist subline is dropped in compact so the row can hit the
 * shorter target.
 */
const DENSITY: Record<
	TrackListDensity,
	{ rowHeight: number; artwork: number; vpad: number; playGlyph: number; showArtist: boolean }
> = {
	roomy: { rowHeight: 48, artwork: 40, vpad: 6, playGlyph: 13, showArtist: true },
	compact: { rowHeight: 36, artwork: 28, vpad: 4, playGlyph: 11, showArtist: false },
}

export interface TrackListRowProps {
	/** Track title (primary line). */
	title: string
	/** Artist (secondary line — hidden in `compact` density). */
	artist: string
	/** Pre-formatted duration, e.g. "3:42". Right-aligned, monospaced. */
	duration: string
	/** Album name shown in the trailing column (the library variant's extra column). */
	album?: string
	/** Container format → inline `FormatBadge` next to the title (e.g. "FLAC"). */
	format?: string
	/** Bitrate for the format-badge tooltip. */
	bitrateKbps?: number
	/** Optional artwork URL; falls back to a deterministic gradient keyed on the album/title. */
	artworkUrl?: string
	/** Current track — paints the title in `--lyr-accent` and tints the row `--lyr-surface-2`. */
	active?: boolean
	/** Active *and* playing — dims the artwork and overlays the animated equalizer. */
	playing?: boolean
	/** Favorited — the heart stays filled and accent-tinted. */
	favorite?: boolean
	/** Part of a multi-selection — 2px accent rail + accent-wash background, regardless of hover/active (#217). */
	selected?: boolean
	/**
	 * Container will transcode — the server can't direct-play this format, so a
	 * warning triangle sits after the title. Mirrors the Swift `willTranscode` flag.
	 */
	willTranscode?: boolean
	/**
	 * Play count revealed on hover when the user opts in. Shown as a monospaced
	 * "12 plays" readout before the duration. Omit to hide.
	 */
	playCountLabel?: string
	/** Row density. Defaults to `roomy` so non-Library call sites keep their look. */
	density?: TrackListDensity
	/** Force hover visuals (for static previews). Omit for live interactivity. */
	hovered?: boolean
	/** Plain click / double-click plays the track (single-select hosts). */
	onPlay?: () => void
	/** Toggle the favorite heart. */
	onToggleFavorite?: () => void
	/**
	 * Multi-select click router (#217). When provided, a bare click is handed to
	 * the host (so it can resolve plain-plays / Cmd-toggle / Shift-range) instead
	 * of playing immediately; the favorite heart still toggles independently.
	 */
	onSelect?: () => void
	style?: CSSProperties
}

/**
 * The compact, artwork-led track row used by the Library Tracks tab — the
 * library / multi-select sibling of `TrackRow`. Where `TrackRow` leads with a
 * 32px number column, this leads with square album artwork (40pt roomy / 28pt
 * compact) that swaps to a play glyph on hover and the now-playing equalizer
 * while playing. It adds a right-aligned album column (the library context) and
 * supports a multi-select rail + accent wash via `selected`. Density follows the
 * user's appearance preference: `compact` shrinks the artwork and drops the
 * artist subline to hit a 36pt row. Background reflects
 * selected / active / hover state with a 2px accent selection rail.
 */
export function TrackListRow({
	title,
	artist,
	duration,
	album,
	format,
	bitrateKbps,
	artworkUrl,
	active = false,
	playing = false,
	favorite = false,
	selected = false,
	willTranscode = false,
	playCountLabel,
	density = 'roomy',
	hovered,
	onPlay,
	onToggleFavorite,
	onSelect,
	style,
}: TrackListRowProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState
	const d = DENSITY[density]

	// Mirrors `rowBackground`: selected wash wins, then the active surface, then
	// the native-hover tint (the Swift folds focused + hovered into one value).
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
			onClick={onSelect ?? onPlay}
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'center',
				gap: 12,
				padding: `${d.vpad}px 12px`,
				minHeight: d.rowHeight,
				boxSizing: 'border-box',
				borderRadius: 6,
				background,
				fontFamily: 'var(--lyr-font)',
				cursor: onSelect || onPlay ? 'default' : undefined,
				...style,
			}}
		>
			{/* Selection rail — 2px accent bar, inset 2px top/bottom, square corners (Swift uses a plain Rectangle). */}
			{selected && (
				<span
					style={{
						position: 'absolute',
						left: 0,
						top: 2,
						bottom: 2,
						width: 2,
						background: 'var(--lyr-accent)',
					}}
				/>
			)}

			{/* Leading artwork with play-on-hover / now-playing equalizer overlay. */}
			<div
				style={{
					position: 'relative',
					width: d.artwork,
					height: d.artwork,
					flexShrink: 0,
				}}
			>
				<Artwork
					url={artworkUrl}
					seed={album ?? title}
					size={d.artwork}
					radius={4}
					shadow={false}
				/>
				{playing ? (
					<div
						style={{
							position: 'absolute',
							inset: 0,
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							borderRadius: 4,
							background: 'rgba(0, 0, 0, 0.55)',
						}}
					>
						<EqualizerIcon color="var(--lyr-accent)" />
					</div>
				) : isHovering ? (
					<div
						style={{
							position: 'absolute',
							inset: 0,
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							borderRadius: 4,
							background: 'rgba(0, 0, 0, 0.45)',
						}}
					>
						<Icon name="play" size={d.playGlyph} color="#ffffff" fill />
					</div>
				) : null}
			</div>

			{/* Title (+ format badge, transcode warning) and artist subline. */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
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
					{willTranscode && (
						<svg
							width={10}
							height={10}
							viewBox="0 0 24 24"
							fill="var(--lyr-warning)"
							role="img"
							aria-label="Transcoding required"
							style={{ flexShrink: 0 }}
						>
							<title>Transcoding required. Enable in Preferences → Playback.</title>
							<path d="M12 2.5a1.6 1.6 0 0 1 1.4.82l9 15.6A1.6 1.6 0 0 1 21 21.3H3a1.6 1.6 0 0 1-1.4-2.38l9-15.6A1.6 1.6 0 0 1 12 2.5zm0 5.6a1 1 0 0 0-1 1v4.2a1 1 0 0 0 2 0V9.1a1 1 0 0 0-1-1zm0 9a1.15 1.15 0 1 0 0 2.3 1.15 1.15 0 0 0 0-2.3z" />
						</svg>
					)}
				</div>
				{d.showArtist && (
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
						{artist}
					</span>
				)}
			</div>

			{/* Spacer pushes the album column + heart + duration to the trailing edge. */}
			<span style={{ flex: 1, minWidth: 0 }} />

			{/* Album column — the library variant's extra column (right-aligned, capped at 240px). */}
			{album && (
				<span
					style={{
						fontSize: 12,
						fontWeight: 500,
						color: 'var(--lyr-ink-3)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
						maxWidth: 240,
						textAlign: 'right',
						flexShrink: 1,
					}}
				>
					{album}
				</span>
			)}

			{/* Favorite heart — visible while favorited or hovering. */}
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

			{/* Play count on hover (opt-in). */}
			{playCountLabel && isHovering && (
				<span
					style={{
						fontSize: 11,
						fontWeight: 500,
						fontVariantNumeric: 'tabular-nums',
						color: 'var(--lyr-ink-3)',
						flexShrink: 0,
					}}
				>
					{playCountLabel}
				</span>
			)}

			{/* Duration. */}
			<span
				style={{
					fontSize: 12,
					fontWeight: 500,
					fontVariantNumeric: 'tabular-nums',
					color: 'var(--lyr-ink-3)',
					minWidth: 48,
					textAlign: 'right',
					flexShrink: 0,
				}}
			>
				{duration}
			</span>
		</div>
	)
}
