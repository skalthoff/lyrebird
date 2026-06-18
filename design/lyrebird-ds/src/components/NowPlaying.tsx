import type { CSSProperties, MouseEvent as ReactMouseEvent, ReactNode } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'
import { IconButton } from './IconButton'
import { EqualizerIcon } from './EqualizerIcon'

/** Repeat cycle state, mirroring the Swift `RepeatMode` enum. */
export type NowPlayingRepeatMode = 'off' | 'all' | 'one'

/** Right-pane tab, mirroring `NowPlayingView.Tab`. */
export type NowPlayingTab = 'queue' | 'lyrics' | 'about' | 'credits'

/** One row rendered in the embedded Queue tab (a slice of `QueueInspector`). */
export interface NowPlayingQueueRow {
	/** Track title (primary line). */
	title: string
	/** Artist (secondary line). */
	artist: string
	/** Row artwork URL — falls back to a seeded gradient when absent. */
	artworkUrl?: string
	/** Seed for the fallback gradient (album or track name). */
	artworkSeed?: string
}

export interface NowPlayingProps {
	/** Track title — the large hero headline (`Theme.font(26, .heavy)`). */
	title: string
	/** Artist name — secondary hero line, navigable in the app. */
	artist: string
	/** Album name — tertiary hero line. Omitted (singles) when absent. */
	album?: string
	/** Hero artwork URL. Falls back to a seeded gradient when absent. */
	artworkUrl?: string
	/** Seed for the fallback artwork gradient — typically the track name. */
	artworkSeed?: string
	/** Playing vs paused — swaps the transport glyph and animates the queue equalizer. */
	isPlaying?: boolean
	/** Current track is favorited — fills + accent-tints the hero heart. */
	favorite?: boolean
	/** Scrubber fill, 0..1. */
	progress?: number
	/** Pre-formatted elapsed time, e.g. "1:48". */
	positionLabel?: string
	/** Pre-formatted total duration, e.g. "3:58". */
	durationLabel?: string
	/** Shuffle enabled — accent-tints the shuffle glyph. */
	shuffle?: boolean
	/** Repeat cycle state — accent-tints the glyph (and swaps to repeat-one). */
	repeat?: NowPlayingRepeatMode
	/** Active right-pane tab. Defaults to `queue` (the Swift resets to it on open). */
	activeTab?: NowPlayingTab
	/** Italic rotating fact tagline under the metadata (e.g. "Played 42 times"). */
	factTagline?: string
	/** Hero artwork square edge in px. Default 360 (the Swift caps at 520, floors ~240). */
	artSize?: number
	/** Rows for the embedded Queue tab. */
	queueRows?: NowPlayingQueueRow[]
	/** Lyrics lines for the Lyrics tab. The line at `activeLyricIndex` is highlighted. */
	lyrics?: string[]
	/** Index of the current synced lyric line (accent-highlighted). */
	activeLyricIndex?: number
	/** Custom content slot for the active tab — overrides the built-in tab body when set. */
	tabContent?: ReactNode
	onPlayPause?: () => void
	onNext?: () => void
	onPrevious?: () => void
	onToggleShuffle?: () => void
	onToggleRepeat?: () => void
	onToggleFavorite?: () => void
	onSelectTab?: (tab: NowPlayingTab) => void
	onClose?: () => void
	/** Fires with a 0..1 fraction when the scrubber is clicked. */
	onSeek?: (fraction: number) => void
	style?: CSSProperties
}

const TABS: ReadonlyArray<{ id: NowPlayingTab; label: string }> = [
	{ id: 'queue', label: 'Queue' },
	{ id: 'lyrics', label: 'Lyrics' },
	{ id: 'about', label: 'About' },
	{ id: 'credits', label: 'Credits' },
]

/** Translate a horizontal click on a bar element into a 0..1 fraction. */
function fractionFromClick(e: ReactMouseEvent<HTMLDivElement>): number {
	const rect = e.currentTarget.getBoundingClientRect()
	if (rect.width <= 0) return 0
	return Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width))
}

const TIME_LABEL_STYLE: CSSProperties = {
	width: 36,
	fontSize: 10,
	fontWeight: 600,
	color: 'var(--lyr-ink-3)',
	fontVariantNumeric: 'tabular-nums',
	fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
}

/**
 * The full Now Playing pane — the takeover surface the app pushes from the
 * `PlayerBar` artwork tap or `⌘L`. Mirrors `Screens/NowPlayingView.swift`: a
 * two-pane split with a large hero (close affordance, square artwork, title /
 * artist / album, favorite heart, rotating fact tagline) on the left ~50%, and
 * a `bgAlt`-washed detail pane on the right carrying the "NOW PLAYING" eyebrow,
 * a segmented Queue / Lyrics / About / Credits picker, and the active tab body.
 *
 * The transport row + scrubber under the hero metadata mirror the persistent
 * `PlayerBar`'s controls (the Swift `NowPlayingView` defers transport to that
 * shared bar; this pane surfaces them inline per the design-system brief).
 */
export function NowPlaying({
	title,
	artist,
	album,
	artworkUrl,
	artworkSeed,
	isPlaying = false,
	favorite = false,
	progress = 0,
	positionLabel = '0:00',
	durationLabel = '0:00',
	shuffle = false,
	repeat = 'off',
	activeTab = 'queue',
	factTagline,
	artSize = 360,
	queueRows,
	lyrics,
	activeLyricIndex,
	tabContent,
	onPlayPause,
	onNext,
	onPrevious,
	onToggleShuffle,
	onToggleRepeat,
	onToggleFavorite,
	onSelectTab,
	onClose,
	onSeek,
	style,
}: NowPlayingProps) {
	const fillPct = `${Math.min(1, Math.max(0, progress)) * 100}%`

	return (
		<div
			role="group"
			aria-label="Now Playing"
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'stretch',
				width: '100%',
				minHeight: 560,
				boxSizing: 'border-box',
				fontFamily: 'var(--lyr-font)',
				color: 'var(--lyr-ink)',
				// Stand-in for the AmbientWash (Theme.bg base + sampled palette)
				// the Swift composes behind the hero; the converter wraps the
				// cell in LyrebirdRoot's darker surface already.
				background: 'var(--lyr-bg)',
				overflow: 'hidden',
				...style,
			}}
		>
			{/* ── Hero pane (≈50% width, leading) ── */}
			<div
				style={{
					flex: '1 1 50%',
					minWidth: 0,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'flex-start',
					gap: 22,
					padding: '28px 36px',
					boxSizing: 'border-box',
				}}
			>
				{/* Close affordance — chevron.down + "Close" capsule */}
				<button
					type="button"
					aria-label="Close Now Playing"
					title="Close"
					onClick={onClose}
					style={{
						display: 'inline-flex',
						alignItems: 'center',
						gap: 6,
						padding: '7px 12px',
						border: '1px solid var(--lyr-border)',
						borderRadius: 999,
						background: 'var(--lyr-surface)',
						color: 'var(--lyr-ink-2)',
						cursor: 'pointer',
					}}
				>
					<Icon name="chevron-down" size={11} color="var(--lyr-ink-2)" strokeWidth={2.5} />
					<span style={{ fontSize: 11, fontWeight: 600 }}>Close</span>
				</button>

				{/* Hero artwork (radius 14) */}
				<Artwork url={artworkUrl} seed={artworkSeed ?? title} size={artSize} radius={14} />

				{/* Primary metadata block — VStack(spacing: 6) */}
				<div style={{ display: 'flex', flexDirection: 'column', gap: 6, alignSelf: 'stretch' }}>
					<span
						style={{
							fontSize: 26,
							fontWeight: 800,
							lineHeight: 1.15,
							color: 'var(--lyr-ink)',
							display: '-webkit-box',
							WebkitBoxOrient: 'vertical',
							WebkitLineClamp: 3,
							overflow: 'hidden',
						}}
					>
						{title}
					</span>
					<span
						style={{
							fontSize: 15,
							fontWeight: 600,
							color: 'var(--lyr-ink-2)',
							overflow: 'hidden',
							textOverflow: 'ellipsis',
							whiteSpace: 'nowrap',
						}}
					>
						{artist}
					</span>
					{album && album !== '' && (
						<span
							style={{
								fontSize: 12,
								fontWeight: 500,
								color: 'var(--lyr-ink-3)',
								overflow: 'hidden',
								textOverflow: 'ellipsis',
								whiteSpace: 'nowrap',
							}}
						>
							{album}
						</span>
					)}

					{/* Favorite heart — 22px glyph in a 44×44 hit area */}
					<IconButton
						name="heart"
						label={favorite ? 'Unfavorite' : 'Favorite'}
						size={22}
						hitSize={44}
						fill={favorite}
						tint={favorite ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
						onClick={onToggleFavorite}
						style={{ marginLeft: -10 }}
					/>
				</div>

				{/* Rotating fact tagline — Theme.font(11, .regular, italic) */}
				{factTagline && (
					<div
						style={{
							alignSelf: 'stretch',
							marginTop: -10,
							fontSize: 11,
							fontWeight: 400,
							fontStyle: 'italic',
							color: 'var(--lyr-ink-3)',
							textAlign: 'center',
						}}
					>
						{factTagline}
					</div>
				)}

				{/* Transport + scrubber (mirrors the shared PlayerBar controls) */}
				<div
					style={{
						alignSelf: 'stretch',
						marginTop: 'auto',
						display: 'flex',
						flexDirection: 'column',
						alignItems: 'center',
						gap: 10,
					}}
				>
					{/* Transport row — HStack(spacing: 20) */}
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
							<Icon name={isPlaying ? 'pause' : 'play'} size={15} color="var(--lyr-bg)" fill />
						</button>
						<IconButton name="next" label="Next track" size={16} fill onClick={onNext} />
						<IconButton
							name={repeat === 'one' ? 'repeat-one' : 'repeat'}
							label="Repeat"
							active={repeat !== 'off'}
							tint={repeat !== 'off' ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
							onClick={onToggleRepeat}
						/>
					</div>

					{/* Scrubber — time labels flanking the progress rail */}
					<div style={{ alignSelf: 'stretch', display: 'flex', alignItems: 'center', gap: 10 }}>
						<span style={{ ...TIME_LABEL_STYLE, textAlign: 'right' }}>{positionLabel}</span>
						<div
							role="slider"
							aria-label="Playback position"
							aria-valuenow={Math.round(Math.min(1, Math.max(0, progress)) * 100)}
							aria-valuemin={0}
							aria-valuemax={100}
							onClick={onSeek ? (e) => onSeek(fractionFromClick(e)) : undefined}
							style={{
								position: 'relative',
								flex: 1,
								height: 12,
								display: 'flex',
								alignItems: 'center',
								cursor: onSeek ? 'pointer' : 'default',
							}}
						>
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
							<div
								style={{
									position: 'absolute',
									left: 0,
									width: fillPct,
									height: 3,
									borderRadius: 1.5,
									background: 'var(--lyr-ink)',
								}}
							/>
							<div
								style={{
									position: 'absolute',
									left: fillPct,
									width: 10,
									height: 10,
									marginLeft: -5,
									borderRadius: 5,
									background: 'var(--lyr-ink)',
									boxShadow: '0 1px 3px rgba(0,0,0,0.4)',
								}}
							/>
						</div>
						<span style={{ ...TIME_LABEL_STYLE, textAlign: 'left' }}>{durationLabel}</span>
					</div>
				</div>
			</div>

			{/* ── Detail pane — segmented tabs over the active body ── */}
			<div
				style={{
					flex: '1 1 50%',
					minWidth: 0,
					display: 'flex',
					flexDirection: 'column',
					gap: 18,
					padding: '28px 28px',
					boxSizing: 'border-box',
					// Rectangle().fill(Theme.bgAlt.opacity(0.35))
					background: 'color-mix(in srgb, var(--lyr-bg-alt) 35%, transparent)',
				}}
			>
				{/* "NOW PLAYING" eyebrow — Theme.font(10, .bold), tracking 3, accent */}
				<span
					style={{
						fontSize: 10,
						fontWeight: 700,
						letterSpacing: 3,
						color: 'var(--lyr-accent)',
					}}
				>
					NOW PLAYING
				</span>

				{/* Segmented picker (Queue / Lyrics / About / Credits) */}
				<div
					role="tablist"
					aria-label="Now Playing sections"
					style={{
						display: 'flex',
						padding: 2,
						gap: 2,
						borderRadius: 8,
						background: 'var(--lyr-surface)',
						border: '1px solid var(--lyr-border)',
					}}
				>
					{TABS.map((t) => {
						const selected = t.id === activeTab
						return (
							<button
								key={t.id}
								type="button"
								role="tab"
								aria-selected={selected}
								onClick={() => onSelectTab?.(t.id)}
								style={{
									flex: 1,
									padding: '5px 0',
									border: 'none',
									borderRadius: 6,
									cursor: 'pointer',
									fontSize: 12,
									fontWeight: selected ? 700 : 500,
									fontFamily: 'var(--lyr-font)',
									color: selected ? 'var(--lyr-ink)' : 'var(--lyr-ink-2)',
									background: selected ? 'var(--lyr-surface-2)' : 'transparent',
								}}
							>
								{t.label}
							</button>
						)
					})}
				</div>

				{/* Active tab body */}
				<div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
					{tabContent ?? (
						<TabBody
							tab={activeTab}
							queueRows={queueRows}
							lyrics={lyrics}
							activeLyricIndex={activeLyricIndex}
							isPlaying={isPlaying}
							artist={artist}
							album={album}
							durationLabel={durationLabel}
						/>
					)}
				</div>
			</div>
		</div>
	)
}

/** Built-in body for each detail-pane tab. */
function TabBody({
	tab,
	queueRows,
	lyrics,
	activeLyricIndex,
	isPlaying,
	artist,
	album,
	durationLabel,
}: {
	tab: NowPlayingTab
	queueRows?: NowPlayingQueueRow[]
	lyrics?: string[]
	activeLyricIndex?: number
	isPlaying: boolean
	artist: string
	album?: string
	durationLabel: string
}) {
	switch (tab) {
		case 'queue':
			return <QueueTab rows={queueRows} isPlaying={isPlaying} />
		case 'lyrics':
			return <LyricsTab lines={lyrics} activeIndex={activeLyricIndex} />
		case 'about':
			return <AboutTab artist={artist} album={album} durationLabel={durationLabel} />
		case 'credits':
			return <CreditsTab />
	}
}

/** Queue tab — a slice of `QueueInspector`'s "Up Next" rows. */
function QueueTab({ rows, isPlaying }: { rows?: NowPlayingQueueRow[]; isPlaying: boolean }) {
	if (!rows || rows.length === 0) {
		return (
			<EmptyTab text="Nothing queued. Use ⌘-click → Play Next on a track." />
		)
	}
	return (
		<div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
			<span
				style={{
					fontSize: 10,
					fontWeight: 700,
					letterSpacing: 1.5,
					textTransform: 'uppercase',
					color: 'var(--lyr-ink-2)',
				}}
			>
				Up Next
			</span>
			<div style={{ display: 'flex', flexDirection: 'column' }}>
				{rows.map((row, i) => (
					<div
						key={`${row.title}-${i}`}
						style={{
							display: 'flex',
							alignItems: 'center',
							gap: 10,
							padding: '6px 4px',
							borderRadius: 6,
						}}
					>
						{/* First row reads as the now-playing entry → equalizer in place of art chrome */}
						{i === 0 && isPlaying ? (
							<div
								style={{
									width: 32,
									height: 32,
									flexShrink: 0,
									display: 'flex',
									alignItems: 'center',
									justifyContent: 'center',
								}}
							>
								<EqualizerIcon size={16} />
							</div>
						) : (
							<Artwork
								url={row.artworkUrl}
								seed={row.artworkSeed ?? row.artist}
								size={32}
								radius={4}
								shadow={false}
							/>
						)}
						<div style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
							<span
								style={{
									fontSize: 12,
									fontWeight: 600,
									color: 'var(--lyr-ink)',
									overflow: 'hidden',
									textOverflow: 'ellipsis',
									whiteSpace: 'nowrap',
								}}
							>
								{row.title}
							</span>
							<span
								style={{
									fontSize: 10,
									fontWeight: 500,
									color: 'var(--lyr-ink-2)',
									overflow: 'hidden',
									textOverflow: 'ellipsis',
									whiteSpace: 'nowrap',
								}}
							>
								{row.artist}
							</span>
						</div>
					</div>
				))}
			</div>
		</div>
	)
}

/** Lyrics tab — synced lines with the active line accent-highlighted (`LyricsView`). */
function LyricsTab({ lines, activeIndex }: { lines?: string[]; activeIndex?: number }) {
	if (!lines || lines.length === 0) {
		return <EmptyTab text="No lyrics for this track." />
	}
	return (
		<div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '4px 0' }}>
			{lines.map((line, i) => {
				const active = i === activeIndex
				return (
					<span
						key={`${i}-${line}`}
						style={{
							fontSize: active ? 18 : 15,
							fontWeight: active ? 700 : 500,
							lineHeight: 1.35,
							color: active ? 'var(--lyr-ink)' : 'var(--lyr-ink-3)',
							transition: 'color 0.2s, font-size 0.2s',
						}}
					>
						{line}
					</span>
				)
			})}
		</div>
	)
}

/** About tab — the metadata subset surfaced on the `Track` (`aboutSection` rows). */
function AboutTab({
	artist,
	album,
	durationLabel,
}: {
	artist: string
	album?: string
	durationLabel: string
}) {
	const rows: Array<{ label: string; value: string }> = [{ label: 'Artist', value: artist }]
	if (album && album !== '') rows.push({ label: 'Album', value: album })
	rows.push({ label: 'Runtime', value: durationLabel })
	return (
		<div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: '8px 0' }}>
			{rows.map((row) => (
				<div key={row.label} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
					<span
						style={{
							fontSize: 10,
							fontWeight: 700,
							letterSpacing: 1.5,
							textTransform: 'uppercase',
							color: 'var(--lyr-ink-3)',
						}}
					>
						{row.label}
					</span>
					<span style={{ fontSize: 14, fontWeight: 600, color: 'var(--lyr-ink)' }}>{row.value}</span>
				</div>
			))}
		</div>
	)
}

/** Credits tab — placeholder for the `NowPlayingCredits` rows (People array). */
function CreditsTab() {
	return <EmptyTab text="No credits for this track." />
}

/** Shared empty-state line for a detail tab with no content. */
function EmptyTab({ text }: { text: string }) {
	return (
		<div
			style={{
				flex: 1,
				display: 'flex',
				alignItems: 'center',
				justifyContent: 'center',
				textAlign: 'center',
				padding: '24px 8px',
				fontSize: 12,
				fontWeight: 500,
				color: 'var(--lyr-ink-3)',
			}}
		>
			{text}
		</div>
	)
}
