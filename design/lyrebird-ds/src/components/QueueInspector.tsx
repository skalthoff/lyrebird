import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'
import type { IconName } from './Icon'
import { EqualizerIcon } from './EqualizerIcon'

/** One track entry in the queue (Now Playing or an Up Next row). */
export interface QueueTrack {
	/** Stable id — used as the React key in the Up Next list. */
	id: string
	/** Track title (primary line). */
	title: string
	/** Artist (secondary line). */
	artist: string
	/** Pre-formatted duration, e.g. "3:42". Omit to drop the trailing time. */
	duration?: string
	/** Artwork image URL. Falls back to a seeded gradient when absent. */
	artworkUrl?: string
	/** Seed for the fallback artwork gradient — typically the album or track name. */
	artworkSeed?: string
}

export interface QueueRowProps {
	/** The track to render. */
	track: QueueTrack
	/** Currently playing — swaps the leading thumbnail badge for the equalizer. */
	playing?: boolean
	/** User-added rows are removable (trailing X on hover) and show a drag handle. */
	removable?: boolean
	/** Force hover visuals (for static previews). Omit for live interactivity. */
	hovered?: boolean
	onRemove?: () => void
	onPlay?: () => void
	style?: CSSProperties
}

/**
 * One track row in the Queue Inspector — mirrors the Swift `QueueInspectorRow`.
 * A 32px artwork thumbnail, a two-line title/artist stack, and (when supplied)
 * a trailing duration. The playing row overlays an animated equalizer on the
 * thumbnail; `removable` rows reveal a drag-handle affordance and a trailing X
 * on hover. Background lifts to `--lyr-native-hover` on hover (Swift parity).
 */
export function QueueRow({
	track,
	playing = false,
	removable = false,
	hovered,
	onRemove,
	onPlay,
	style,
}: QueueRowProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onPlay}
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 10,
				padding: '6px 4px',
				borderRadius: 6,
				background: isHovering ? 'var(--lyr-native-hover)' : 'transparent',
				fontFamily: 'var(--lyr-font)',
				cursor: onPlay ? 'default' : undefined,
				...style,
			}}
		>
			{/* Drag handle — only for reorderable (user-added) rows, on hover */}
			{removable && (
				<span
					aria-hidden
					style={{
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						width: 10,
						flexShrink: 0,
						color: 'var(--lyr-ink-3)',
						opacity: isHovering ? 1 : 0,
						cursor: 'grab',
					}}
				>
					<Icon name="dots-v" size={12} />
				</span>
			)}

			{/* Leading 32px artwork — overlaid with the equalizer while playing */}
			<div style={{ position: 'relative', width: 32, height: 32, flexShrink: 0 }}>
				<Artwork
					url={track.artworkUrl}
					seed={track.artworkSeed ?? track.title}
					size={32}
					radius={4}
					shadow={false}
				/>
				{playing && (
					<span
						style={{
							position: 'absolute',
							inset: 0,
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							borderRadius: 4,
							background: 'rgba(0,0,0,0.45)',
						}}
					>
						<EqualizerIcon size={14} />
					</span>
				)}
			</div>

			{/* Title + artist */}
			<div style={{ flex: 1, minWidth: 0 }}>
				<div
					style={{
						fontSize: 12,
						fontWeight: 600,
						color: playing ? 'var(--lyr-accent)' : 'var(--lyr-ink)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{track.title}
				</div>
				<div
					style={{
						fontSize: 10,
						fontWeight: 500,
						color: 'var(--lyr-ink-2)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
						marginTop: 1,
					}}
				>
					{track.artist}
				</div>
			</div>

			{/* Trailing: remove X on hover (removable rows), else duration */}
			{removable && isHovering ? (
				<button
					type="button"
					aria-label={`Remove ${track.title} from Up Next`}
					title="Remove from Up Next"
					onClick={(e) => {
						e.stopPropagation()
						onRemove?.()
					}}
					style={{
						width: 20,
						height: 20,
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						padding: 0,
						border: 'none',
						borderRadius: 999,
						background: 'var(--lyr-surface)',
						color: 'var(--lyr-ink-2)',
						cursor: 'pointer',
						flexShrink: 0,
					}}
				>
					<Icon name="close" size={10} strokeWidth={2.5} />
				</button>
			) : track.duration ? (
				<span
					style={{
						fontSize: 11,
						fontWeight: 500,
						fontVariantNumeric: 'tabular-nums',
						color: 'var(--lyr-ink-3)',
						flexShrink: 0,
					}}
				>
					{track.duration}
				</span>
			) : null}
		</div>
	)
}

export interface QueueInspectorProps {
	/** The currently-playing track. When absent, the Now Playing block is omitted. */
	nowPlaying?: QueueTrack
	/** Pre-formatted elapsed time for the Now Playing scrubber, e.g. "1:48". */
	positionLabel?: string
	/** Pre-formatted total duration for the Now Playing scrubber, e.g. "3:58". */
	durationLabel?: string
	/** Now Playing scrubber fill, 0..1. */
	progress?: number
	/** User-added "Up Next" queue rows (reorderable + removable). */
	upNext: QueueTrack[]
	/** Source label for the "Playing From {source}" section header. */
	playingFrom?: string
	/** Auto-queue tail rows under "Playing From" (read-only, not removable). */
	autoQueue?: QueueTrack[]
	/** Clears the whole queue (header/action "Clear"). Omit to hide the action. */
	onClear?: () => void
	/** Closes the panel (header X). */
	onClose?: () => void
	style?: CSSProperties
}

/**
 * The 320px right-side Queue Inspector panel — mirrors the SwiftUI
 * `QueueInspector` (`macos/Sources/Lyrebird/Components/QueueInspector.swift`).
 *
 * Top → bottom: a header ("QUEUE" eyebrow + close X, with Clear / Shuffle
 * actions), a large Now Playing card (288 artwork, title/artist/album, a
 * read-only scrubber), an "Up Next" list of reorderable `QueueRow`s, and a
 * read-only "Playing From {source}" auto-queue tail. The width and per-section
 * typography match the Swift source (header 11/bold tracking 2; section eyebrows
 * 10/bold tracking 1.5; Now Playing title 17/bold).
 */
export function QueueInspector({
	nowPlaying,
	positionLabel = '0:00',
	durationLabel = '0:00',
	progress = 0,
	upNext,
	playingFrom,
	autoQueue = [],
	onClear,
	onClose,
	style,
}: QueueInspectorProps) {
	const pct = Math.min(1, Math.max(0, progress))
	const canClear = (upNext.length + autoQueue.length) > 0
	const canShuffle = upNext.length >= 2

	return (
		<div
			style={{
				width: 320,
				display: 'flex',
				flexDirection: 'column',
				background: 'var(--lyr-bg-alt)',
				fontFamily: 'var(--lyr-font)',
				borderRadius: 'var(--lyr-radius-md)',
				overflow: 'hidden',
				...style,
			}}
		>
			{/* Header — "QUEUE" eyebrow + close X, then the action row */}
			<div
				style={{
					display: 'flex',
					flexDirection: 'column',
					gap: 10,
					padding: '12px 16px',
					borderBottom: '1px solid var(--lyr-border)',
				}}
			>
				<div style={{ display: 'flex', alignItems: 'center' }}>
					<span
						style={{
							fontSize: 11,
							fontWeight: 700,
							letterSpacing: 2,
							textTransform: 'uppercase',
							color: 'var(--lyr-ink-2)',
						}}
					>
						Queue
					</span>
					<span style={{ flex: 1 }} />
					{onClose && (
						<button
							type="button"
							aria-label="Close queue"
							title="Close queue"
							onClick={onClose}
							style={{
								width: 22,
								height: 22,
								display: 'inline-flex',
								alignItems: 'center',
								justifyContent: 'center',
								padding: 0,
								border: 'none',
								borderRadius: 999,
								background: 'var(--lyr-surface)',
								color: 'var(--lyr-ink-2)',
								cursor: 'pointer',
							}}
						>
							<Icon name="close" size={11} strokeWidth={2.5} />
						</button>
					)}
				</div>

				{/* Action row — Clear / Shuffle pills (Swift's BATCH-07b #284) */}
				<div style={{ display: 'flex', gap: 8 }}>
					<QueueActionButton
						name="dots"
						label="Clear"
						disabled={!canClear}
						onClick={onClear}
					/>
					<QueueActionButton name="shuffle" label="Shuffle" disabled={!canShuffle} />
				</div>
			</div>

			{/* Scrollable body */}
			<div
				style={{
					display: 'flex',
					flexDirection: 'column',
					gap: 18,
					padding: 16,
					overflowY: 'auto',
				}}
			>
				{/* Now Playing card */}
				{nowPlaying && (
					<div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
						<Artwork
							url={nowPlaying.artworkUrl}
							seed={nowPlaying.artworkSeed ?? nowPlaying.title}
							size={288}
							radius={10}
						/>
						<div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
							<div
								style={{
									fontSize: 17,
									fontWeight: 700,
									color: 'var(--lyr-ink)',
									lineHeight: 1.2,
								}}
							>
								{nowPlaying.title}
							</div>
							<div style={{ fontSize: 12, fontWeight: 500, color: 'var(--lyr-ink-2)' }}>
								{nowPlaying.artist}
							</div>
						</div>

						{/* Read-only scrubber — mirrors AppModel.status position/duration */}
						<div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
							<div
								style={{
									position: 'relative',
									height: 3,
									borderRadius: 999,
									background: 'var(--lyr-surface-2)',
									overflow: 'hidden',
								}}
							>
								<div
									style={{
										position: 'absolute',
										left: 0,
										top: 0,
										bottom: 0,
										width: `${pct * 100}%`,
										borderRadius: 999,
										background: 'var(--lyr-ink-2)',
									}}
								/>
							</div>
							<div style={{ display: 'flex', justifyContent: 'space-between' }}>
								<span
									style={{
										fontSize: 10,
										fontWeight: 600,
										fontVariantNumeric: 'tabular-nums',
										color: 'var(--lyr-ink-3)',
									}}
								>
									{positionLabel}
								</span>
								<span
									style={{
										fontSize: 10,
										fontWeight: 600,
										fontVariantNumeric: 'tabular-nums',
										color: 'var(--lyr-ink-3)',
									}}
								>
									{durationLabel}
								</span>
							</div>
						</div>
					</div>
				)}

				{/* Up Next (user-added) */}
				<div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
					<SectionEyebrow title="Up Next" />
					{upNext.length === 0 ? (
						<EmptyRow text="Nothing queued. Use ⌘-click → Play Next on a track." />
					) : (
						<div style={{ display: 'flex', flexDirection: 'column' }}>
							{upNext.map((track) => (
								<QueueRow key={track.id} track={track} removable />
							))}
						</div>
					)}
				</div>

				{/* Playing From (auto-queue tail) */}
				{(playingFrom || autoQueue.length > 0) && (
					<div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
						<SectionEyebrow
							title={playingFrom ? `Playing From ${playingFrom}` : 'Playing From Queue'}
						/>
						{autoQueue.length === 0 ? (
							<EmptyRow text="Nothing else queued from this source." />
						) : (
							<div style={{ display: 'flex', flexDirection: 'column' }}>
								{autoQueue.map((track) => (
									<QueueRow key={track.id} track={track} />
								))}
							</div>
						)}
					</div>
				)}
			</div>
		</div>
	)
}

/** Compact pill-style action button shared by the header's Clear / Shuffle. */
function QueueActionButton({
	name,
	label,
	disabled = false,
	onClick,
}: {
	name: IconName
	label: string
	disabled?: boolean
	onClick?: () => void
}) {
	return (
		<button
			type="button"
			aria-label={label}
			title={label}
			disabled={disabled}
			onClick={onClick}
			style={{
				flex: 1,
				display: 'inline-flex',
				alignItems: 'center',
				justifyContent: 'center',
				gap: 6,
				padding: '6px 10px',
				border: '1px solid var(--lyr-border)',
				borderRadius: 6,
				background: 'var(--lyr-surface)',
				color: 'var(--lyr-ink-2)',
				fontFamily: 'var(--lyr-font)',
				fontSize: 11,
				fontWeight: 600,
				cursor: disabled ? 'default' : 'pointer',
				opacity: disabled ? 0.4 : 1,
			}}
		>
			<Icon name={name} size={10} strokeWidth={2.5} />
			{label}
		</button>
	)
}

/** Uppercase section eyebrow — "UP NEXT" / "PLAYING FROM …" (10/bold, tracking 1.5). */
function SectionEyebrow({ title }: { title: string }) {
	return (
		<span
			style={{
				fontSize: 10,
				fontWeight: 700,
				letterSpacing: 1.5,
				textTransform: 'uppercase',
				color: 'var(--lyr-ink-2)',
			}}
		>
			{title}
		</span>
	)
}

/** Dim placeholder shown when a queue section is empty (Swift's `emptyRow`). */
function EmptyRow({ text }: { text: string }) {
	return (
		<div
			style={{
				fontSize: 11,
				fontWeight: 500,
				color: 'var(--lyr-ink-3)',
				padding: '8px 4px',
			}}
		>
			{text}
		</div>
	)
}
