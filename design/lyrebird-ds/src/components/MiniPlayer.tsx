import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { IconButton } from './IconButton'
import { Icon } from './Icon'

export interface MiniPlayerProps {
	/** Now-playing track title (primary line). */
	title: string
	/** Now-playing artist (secondary, click-through line). */
	artist: string
	/** Album-art image URL. Falls back to a `seed` gradient when absent. */
	artworkUrl?: string
	/** Stable string keying the fallback gradient when `artworkUrl` is absent. Defaults to `title`. */
	artworkSeed?: string
	/** Playing → the center transport shows pause; paused → play. */
	isPlaying: boolean
	/** Playback position as a 0…1 fraction. Drives the resting line + scrubber fill. Default 0. */
	progress?: number
	/** Favorited → the heart stays filled + accent-tinted. */
	favorite?: boolean
	/**
	 * Reveal the hover controls overlay (transport + scrubber + heart + menu) in
	 * place of the resting progress line. In the app this is driven by pointer
	 * hover; expose it as a prop so a static preview can show both states.
	 * Default false (resting card).
	 */
	showControls?: boolean
	onPlayPause?: () => void
	onNext?: () => void
	onPrevious?: () => void
	onToggleFavorite?: () => void
	/** Artist line click-through (opens the artist page in the app). */
	onArtist?: () => void
	/** Album-art tap (opens the album page in the app). */
	onArtwork?: () => void
	/** Expand-to-full-window affordance. */
	onExpand?: () => void
	style?: CSSProperties
}

/**
 * The detached, borderless **Mini Player** — a compact always-available
 * now-playing surface. Mirrors `MiniPlayerView.swift`: a 12px-padded card
 * (14px continuous radius, `--lyr-border` hairline, `--lyr-bg-alt` wash) sized
 * to the app's 280–480pt window with a 96px artwork on the leading edge and a
 * title/artist column. At rest the column shows a thin 3px progress line; with
 * `showControls` it swaps in the full transport cluster (prev / 30px circular
 * play-pause / next, volume, expand) over a scrubber, and the header gains the
 * favorite heart + overflow menu.
 */
export function MiniPlayer({
	title,
	artist,
	artworkUrl,
	artworkSeed,
	isPlaying,
	progress = 0,
	favorite = false,
	showControls = false,
	onPlayPause,
	onNext,
	onPrevious,
	onToggleFavorite,
	onArtist,
	onArtwork,
	onExpand,
	style,
}: MiniPlayerProps) {
	const fraction = Math.min(Math.max(0, progress), 1)

	return (
		<div
			style={{
				// minHeight: 120, idealWidth: 320 (Swift .frame); width clamps 280–480.
				width: 320,
				minWidth: 280,
				maxWidth: 480,
				minHeight: 120,
				boxSizing: 'border-box',
				padding: 12,
				borderRadius: 14,
				// VisualEffectView(.hudWindow).overlay(bgAlt.opacity(0.6)) → flat wash.
				background: 'color-mix(in srgb, var(--lyr-bg-alt) 60%, transparent)',
				border: '1px solid var(--lyr-border)',
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			{/* content: HStack(spacing: 12) */}
			<div style={{ display: 'flex', alignItems: 'stretch', gap: 12 }}>
				<Artwork
					url={artworkUrl}
					seed={artworkSeed ?? title}
					size={96}
					radius={8}
					onClick={onArtwork}
				/>

				{/* VStack(alignment: .leading, spacing: 4) */}
				<div
					style={{
						flex: 1,
						minWidth: 0,
						display: 'flex',
						flexDirection: 'column',
						gap: 4,
					}}
				>
					{/* header: HStack(alignment: .top, spacing: 6) */}
					<div style={{ display: 'flex', alignItems: 'flex-start', gap: 6 }}>
						{/* title + artist: VStack(alignment: .leading, spacing: 2) */}
						<div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
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
							<button
								type="button"
								onClick={onArtist}
								disabled={!onArtist}
								style={{
									display: 'block',
									maxWidth: '100%',
									padding: 0,
									border: 'none',
									background: 'transparent',
									textAlign: 'left',
									cursor: onArtist ? 'pointer' : 'default',
									fontFamily: 'inherit',
									fontSize: 11,
									fontWeight: 500,
									color: 'var(--lyr-ink-2)',
									overflow: 'hidden',
									textOverflow: 'ellipsis',
									whiteSpace: 'nowrap',
								}}
							>
								{artist}
							</button>
						</div>

						{/* Favorite heart + overflow menu join the header only while controls show. */}
						{showControls && (
							<div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
								<button
									type="button"
									aria-label={favorite ? 'Unfavorite' : 'Favorite'}
									aria-pressed={favorite}
									title={favorite ? 'Unfavorite' : 'Favorite'}
									onClick={onToggleFavorite}
									style={{
										display: 'inline-flex',
										alignItems: 'center',
										justifyContent: 'center',
										padding: 0,
										border: 'none',
										background: 'transparent',
										cursor: 'pointer',
									}}
								>
									<Icon
										name="heart"
										size={12}
										fill={favorite}
										color={favorite ? 'var(--lyr-accent)' : 'var(--lyr-ink-3)'}
									/>
								</button>
								{/* ellipsis.circle (SF) → closest glyph in the set is dots. */}
								<button
									type="button"
									aria-label="Mini player options"
									title="Mini player options"
									style={{
										display: 'inline-flex',
										alignItems: 'center',
										justifyContent: 'center',
										padding: 0,
										border: 'none',
										background: 'transparent',
										cursor: 'pointer',
									}}
								>
									<Icon name="dots" size={13} color="var(--lyr-ink-3)" />
								</button>
							</div>
						)}
					</div>

					{/* Push the progress/controls to the bottom of the 96px column (Spacer). */}
					<div style={{ flex: 1 }} />

					{showControls ? (
						/* controlsOverlay: VStack(spacing: 4) */
						<div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
							{/* transportRow: HStack(spacing: 14) */}
							<div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
								<IconButton
									name="previous"
									label="Previous"
									size={13}
									hitSize={26}
									tint="var(--lyr-ink-2)"
									fill
									onClick={onPrevious}
								/>
								{/* Play/pause: 30×30 filled circle, --lyr-bg glyph on --lyr-ink. */}
								<button
									type="button"
									aria-label={isPlaying ? 'Pause' : 'Play'}
									title={isPlaying ? 'Pause' : 'Play'}
									onClick={onPlayPause}
									style={{
										width: 30,
										height: 30,
										flexShrink: 0,
										display: 'inline-flex',
										alignItems: 'center',
										justifyContent: 'center',
										padding: 0,
										border: 'none',
										borderRadius: '50%',
										background: 'var(--lyr-ink)',
										cursor: 'pointer',
									}}
								>
									<Icon
										name={isPlaying ? 'pause' : 'play'}
										size={13}
										color="var(--lyr-bg)"
										fill
									/>
								</button>
								<IconButton
									name="next"
									label="Next"
									size={13}
									hitSize={26}
									tint="var(--lyr-ink-2)"
									fill
									onClick={onNext}
								/>
								<div style={{ flex: 1 }} />
								<IconButton
									name="volume"
									label="Volume"
									size={13}
									hitSize={26}
									tint="var(--lyr-ink-2)"
								/>
								<IconButton
									name="fullscreen"
									label="Expand"
									size={12}
									hitSize={26}
									tint="var(--lyr-ink-2)"
									onClick={onExpand}
								/>
							</div>

							{/* scrubber: mini Slider, tint --lyr-ink. */}
							<div
								style={{
									position: 'relative',
									height: 4,
									borderRadius: 2,
									background: 'color-mix(in srgb, var(--lyr-ink) 15%, transparent)',
								}}
							>
								<div
									style={{
										position: 'absolute',
										left: 0,
										top: 0,
										bottom: 0,
										width: `${fraction * 100}%`,
										borderRadius: 2,
										background: 'var(--lyr-ink)',
									}}
								/>
								<div
									style={{
										position: 'absolute',
										left: `${fraction * 100}%`,
										top: '50%',
										width: 9,
										height: 9,
										marginLeft: -4.5,
										transform: 'translateY(-50%)',
										borderRadius: '50%',
										background: 'var(--lyr-ink)',
									}}
								/>
							</div>
						</div>
					) : (
						/* restingProgress: 3px capsule, ink.opacity(0.7) over ink.opacity(0.15). */
						<div style={{ paddingBottom: 4 }}>
							<div
								style={{
									position: 'relative',
									height: 3,
									borderRadius: 999,
									background: 'color-mix(in srgb, var(--lyr-ink) 15%, transparent)',
								}}
							>
								<div
									style={{
										position: 'absolute',
										left: 0,
										top: 0,
										bottom: 0,
										width: `${fraction * 100}%`,
										borderRadius: 999,
										background: 'color-mix(in srgb, var(--lyr-ink) 70%, transparent)',
									}}
								/>
							</div>
						</div>
					)}
				</div>
			</div>
		</div>
	)
}
