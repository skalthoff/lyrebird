import type { CSSProperties, MouseEvent as ReactMouseEvent } from 'react'
import { Icon } from './Icon'
import { IconButton } from './IconButton'
import { Artwork } from './Artwork'

/** Repeat cycle state, mirroring the Swift `RepeatMode` enum. */
export type RepeatMode = 'off' | 'all' | 'one'

export interface PlayerBarProps {
	/** Track title (primary line). When absent, the nothing-playing state shows. */
	title?: string
	/** Artist name (first half of the "artist · album" secondary line). */
	artist?: string
	/** Album name (second half of the "artist · album" secondary line). */
	album?: string
	/** Artwork image URL. Falls back to a seeded gradient when absent. */
	artworkUrl?: string
	/** Seed for the fallback artwork gradient — typically the track name. */
	artworkSeed?: string
	/** Playing vs paused — swaps the center glyph between pause and play. */
	isPlaying?: boolean
	/** Current track is favorited — fills + accent-tints the heart. */
	favorite?: boolean
	/** Shuffle enabled — accent-tints the shuffle glyph. */
	shuffle?: boolean
	/** Repeat cycle state — accent-tints the glyph (and swaps to repeat-one). */
	repeat?: RepeatMode
	/** Pre-formatted elapsed time, e.g. "1:23". */
	positionLabel?: string
	/** Pre-formatted total duration, e.g. "4:10". */
	durationLabel?: string
	/** Scrubber fill, 0..1. */
	progress?: number
	/** Volume fill, 0..1. */
	volume?: number
	/** Source label for the "Playing from {source}" affordance below the scrubber. */
	playingFrom?: string
	onPlayPause?: () => void
	onNext?: () => void
	onPrevious?: () => void
	onToggleShuffle?: () => void
	onToggleRepeat?: () => void
	onToggleFavorite?: () => void
	/** Fires with a 0..1 fraction when the progress bar is clicked. */
	onSeek?: (fraction: number) => void
	/** Fires with a 0..1 fraction when the volume bar is clicked. */
	onVolume?: (fraction: number) => void
	style?: CSSProperties
}

/** Translate a horizontal click on a bar element into a 0..1 fraction. */
function fractionFromClick(e: ReactMouseEvent<HTMLDivElement>): number {
	const rect = e.currentTarget.getBoundingClientRect()
	if (rect.width <= 0) return 0
	return Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width))
}

/**
 * A presentational div-based slider — a track, a filled portion, and a thumb.
 * Mirrors the SwiftUI `Slider` look (a thin tinted rail with a round knob)
 * without a real `<input type="range">`. Used for both the scrubber and the
 * volume control. `fill` is the tint color token.
 */
function BarSlider({
	value,
	fill,
	width,
	onChange,
	ariaLabel,
}: {
	value: number
	fill: string
	width?: number | string
	onChange?: (fraction: number) => void
	ariaLabel: string
}) {
	const pct = `${Math.min(1, Math.max(0, value)) * 100}%`
	return (
		<div
			role="slider"
			aria-label={ariaLabel}
			aria-valuenow={Math.round(Math.min(1, Math.max(0, value)) * 100)}
			aria-valuemin={0}
			aria-valuemax={100}
			onClick={onChange ? (e) => onChange(fractionFromClick(e)) : undefined}
			style={{
				position: 'relative',
				flex: width == null ? 1 : undefined,
				width: width ?? undefined,
				height: 12,
				display: 'flex',
				alignItems: 'center',
				cursor: onChange ? 'pointer' : 'default',
			}}
		>
			{/* Unfilled rail */}
			<div
				style={{
					position: 'absolute',
					left: 0,
					right: 0,
					height: 3,
					borderRadius: 1.5,
					background: 'color-mix(in srgb, var(--lyr-ink-2) 30%, transparent)',
				}}
			/>
			{/* Filled portion */}
			<div
				style={{
					position: 'absolute',
					left: 0,
					width: pct,
					height: 3,
					borderRadius: 1.5,
					background: fill,
				}}
			/>
			{/* Thumb */}
			<div
				style={{
					position: 'absolute',
					left: pct,
					width: 10,
					height: 10,
					marginLeft: -5,
					borderRadius: 5,
					background: fill,
					boxShadow: '0 1px 3px rgba(0,0,0,0.4)',
				}}
			/>
		</div>
	)
}

/**
 * The unified bottom transport bar — the app's persistent `PlayerBar` chrome.
 * Three horizontal regions over a translucent dark HUD wash with a 1px top
 * border: left track meta (54px artwork + title/artist·album + favorite heart),
 * center transport (shuffle / previous / 36px play circle / next / repeat with a
 * time-flanked scrubber and a "Playing from {source}" link), and right output
 * controls (speaker + ~100px volume). Renders a nothing-playing state when no
 * `title` is supplied.
 */
export function PlayerBar({
	title,
	artist,
	album,
	artworkUrl,
	artworkSeed,
	isPlaying = false,
	favorite = false,
	shuffle = false,
	repeat = 'off',
	positionLabel = '0:00',
	durationLabel = '0:00',
	progress = 0,
	volume = 0.7,
	playingFrom,
	onPlayPause,
	onNext,
	onPrevious,
	onToggleShuffle,
	onToggleRepeat,
	onToggleFavorite,
	onSeek,
	onVolume,
	style,
}: PlayerBarProps) {
	const hasTrack = title != null && title !== ''

	return (
		<div
			role="group"
			aria-label="Playback controls"
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'center',
				gap: 16,
				width: '100%',
				minHeight: 78,
				padding: '0 16px',
				boxSizing: 'border-box',
				fontFamily: 'var(--lyr-font)',
				// HUD-style translucent dark wash (VisualEffectView(.hudWindow)
				// + Theme.bgAlt.opacity(0.7)) — approximated as bg-alt @ 0.7 over
				// a blurred dark backdrop so the chrome reads as system panel.
				background: 'color-mix(in srgb, var(--lyr-bg-alt) 70%, transparent)',
				backdropFilter: 'blur(24px) saturate(1.2)',
				WebkitBackdropFilter: 'blur(24px) saturate(1.2)',
				...style,
			}}
		>
			{/* 1px top border — overlay(alignment: .top) Rectangle */}
			<div
				style={{
					position: 'absolute',
					top: 0,
					left: 0,
					right: 0,
					height: 1,
					background: 'var(--lyr-border)',
				}}
			/>

			{/* ── Left meta (width 280, leading) ── */}
			<div
				style={{
					width: 280,
					flexShrink: 0,
					display: 'flex',
					alignItems: 'center',
					gap: 8,
				}}
			>
				{hasTrack ? (
					<>
						<div
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 12,
								flex: 1,
								minWidth: 0,
							}}
						>
							<Artwork
								url={artworkUrl}
								seed={artworkSeed ?? title}
								size={54}
								radius={6}
							/>
							<div style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
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
									{title}
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
									{`${artist ?? ''} · ${album ?? ''}`}
								</span>
							</div>
						</div>
						<IconButton
							name="heart"
							label={favorite ? 'Unfavorite' : 'Favorite'}
							fill={favorite}
							tint={favorite ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
							onClick={onToggleFavorite}
						/>
					</>
				) : (
					<span
						style={{
							fontSize: 12,
							fontWeight: 500,
							color: 'var(--lyr-ink-3)',
						}}
					>
						Nothing playing
					</span>
				)}
			</div>

			{/* ── Center transport (maxWidth 640) ── */}
			<div
				style={{
					flex: 1,
					maxWidth: 640,
					margin: '0 auto',
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					gap: 6,
				}}
			>
				{/* Transport buttons — HStack(spacing: 20) */}
				<div style={{ display: 'flex', alignItems: 'center', gap: 20 }}>
					<IconButton
						name="shuffle"
						label="Shuffle"
						active={shuffle}
						tint={shuffle ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
						onClick={onToggleShuffle}
					/>
					<IconButton
						name="previous"
						label="Previous track"
						size={16}
						fill
						onClick={onPrevious}
					/>
					{/* 36px circle filled --lyr-ink with the glyph in --lyr-bg */}
					<button
						type="button"
						aria-label={isPlaying ? 'Pause' : 'Play'}
						title={isPlaying ? 'Pause · Space' : 'Play · Space'}
						onClick={onPlayPause}
						style={{
							width: 36,
							height: 36,
							display: 'inline-flex',
							alignItems: 'center',
							justifyContent: 'center',
							padding: 0,
							border: 'none',
							borderRadius: 18,
							background: 'var(--lyr-ink)',
							cursor: 'pointer',
							flexShrink: 0,
						}}
					>
						<Icon
							name={isPlaying ? 'pause' : 'play'}
							size={15}
							color="var(--lyr-bg)"
							fill
						/>
					</button>
					<IconButton
						name="next"
						label="Next track"
						size={16}
						fill
						onClick={onNext}
					/>
					<IconButton
						name={repeat === 'one' ? 'repeat-one' : 'repeat'}
						label="Repeat"
						active={repeat !== 'off'}
						tint={repeat !== 'off' ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
						onClick={onToggleRepeat}
					/>
				</div>

				{/* Scrubber — time labels flanking the progress slider */}
				<div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 4 }}>
					<div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
						<span
							style={{
								width: 36,
								textAlign: 'right',
								fontSize: 10,
								fontWeight: 600,
								color: 'var(--lyr-ink-3)',
								fontVariantNumeric: 'tabular-nums',
								fontFamily:
									'ui-monospace, SFMono-Regular, Menlo, monospace',
							}}
						>
							{positionLabel}
						</span>
						<BarSlider
							value={progress}
							fill="var(--lyr-ink)"
							ariaLabel="Playback position"
							onChange={hasTrack ? onSeek : undefined}
						/>
						<span
							style={{
								width: 36,
								textAlign: 'left',
								fontSize: 10,
								fontWeight: 600,
								color: 'var(--lyr-ink-3)',
								fontVariantNumeric: 'tabular-nums',
								fontFamily:
									'ui-monospace, SFMono-Regular, Menlo, monospace',
							}}
						>
							{durationLabel}
						</span>
					</div>

					{/* "Playing from {source}" — centered link */}
					{playingFrom && (
						<div
							style={{
								display: 'flex',
								justifyContent: 'center',
								alignItems: 'center',
								gap: 4,
								lineHeight: 1,
							}}
						>
							<span
								style={{
									fontSize: 10,
									fontWeight: 500,
									color: 'var(--lyr-ink-3)',
								}}
							>
								Playing from
							</span>
							<span
								style={{
									fontSize: 10,
									fontWeight: 700,
									color: 'var(--lyr-ink-2)',
									textDecoration: 'underline',
									textDecorationColor:
										'color-mix(in srgb, var(--lyr-ink-2) 60%, transparent)',
								}}
							>
								{playingFrom}
							</span>
						</div>
					)}
				</div>
			</div>

			{/* ── Right controls (width 220, trailing) ── */}
			<div
				style={{
					width: 220,
					flexShrink: 0,
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'flex-end',
					gap: 6,
				}}
			>
				<Icon name="volume" size={14} color="var(--lyr-ink-2)" fill />
				<BarSlider
					value={volume}
					fill="var(--lyr-ink-2)"
					width={100}
					ariaLabel="Volume"
					onChange={onVolume}
				/>
			</div>
		</div>
	)
}
