import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'
import { Icon } from './Icon'

export interface PlaylistCardProps {
	/** Playlist name — primary line, also the artwork gradient seed when no `artworkSeed`. */
	title: string
	/** Secondary line, e.g. "42 tracks" / "Empty". Mirrors the Swift `subtitle`. */
	subtitle?: string
	/** Server artwork URL. When absent, a deterministic gradient renders (keyed on the seed). */
	artworkUrl?: string
	/** Gradient seed override. Defaults to `title` (matches the Swift `seed: playlist.name`). */
	artworkSeed?: string
	/**
	 * Optional four-tile mosaic seeds. The shipping SwiftUI `PlaylistCard` uses a
	 * single `Artwork`; this is an additive variant for playlists rendered as a
	 * 2x2 grid of constituent covers. When provided (and no `artworkUrl`), draws
	 * four small `Artwork` tiles instead of one.
	 */
	mosaicSeeds?: string[]
	/** Artwork edge in px. Default 180 (the Swift `size: 180`). */
	size?: number
	/** Force hover visuals for static previews. Omit for live interactivity. */
	hovered?: boolean
	/** Private playlist → shows the lock corner badge (Swift `!playlist.isPublic`). */
	isPrivate?: boolean
	/** Play-button tap (Swift `model.play(playlist:)`). */
	onPlay?: () => void
	/** Card tap → playlist detail (Swift `navPath.append(.playlist)`). */
	onClick?: () => void
	style?: CSSProperties
}

/**
 * Grid card for a Jellyfin playlist. Faithful mirror of the SwiftUI
 * `PlaylistCard`: a square artwork (180px) with a hover-revealed circular play
 * button, an optional private-lock corner badge, then a bold title and a muted
 * subtitle ("N tracks"). The whole card tints `--lyr-native-hover` and scales
 * 1.02 on hover. Shape matches `AlbumCard`; the only differences are the
 * subtitle and the tap target.
 */
export function PlaylistCard({
	title,
	subtitle,
	artworkUrl,
	artworkSeed,
	mosaicSeeds,
	size = 180,
	hovered,
	isPrivate = false,
	onPlay,
	onClick,
	style,
}: PlaylistCardProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState
	const seed = artworkSeed ?? title
	const useMosaic = !artworkUrl && mosaicSeeds != null && mosaicSeeds.length > 0

	return (
		<div
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onClick}
			style={{
				display: 'flex',
				flexDirection: 'column',
				alignItems: 'stretch',
				gap: 10,
				padding: 10,
				borderRadius: 12,
				background: isHovering ? 'var(--lyr-native-hover)' : 'transparent',
				transform: isHovering ? 'scale(1.02)' : 'scale(1)',
				transformOrigin: 'center',
				transition: 'transform 0.12s ease-out, background 0.12s ease-out',
				fontFamily: 'var(--lyr-font)',
				cursor: onClick ? 'pointer' : undefined,
				...style,
			}}
		>
			{/* Artwork + overlays (Swift ZStack, bottomTrailing) */}
			<div style={{ position: 'relative', width: '100%', aspectRatio: '1 / 1' }}>
				{useMosaic ? (
					<Mosaic seeds={mosaicSeeds!} size={size} />
				) : (
					<Artwork
						url={artworkUrl}
						seed={seed}
						size={size}
						radius={8}
						style={{ width: '100%', height: '100%' }}
					/>
				)}

				{/* Private lock badge — top-leading, hidden while play button shows */}
				{isPrivate && (
					<div
						style={{
							position: 'absolute',
							top: 6,
							left: 6,
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							padding: 5,
							borderRadius: 999,
							background: 'rgba(0,0,0,0.45)',
							opacity: isHovering ? 0 : 1,
							transition: 'opacity 0.12s ease-out',
							pointerEvents: 'none',
						}}
						aria-hidden
					>
						<LockGlyph size={9} />
					</div>
				)}

				{/* Hover-revealed play button — 40x40 --lyr-primary circle */}
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
						borderRadius: 999,
						background: 'var(--lyr-primary)',
						color: '#ffffff',
						boxShadow: '0 4px 10px color-mix(in srgb, var(--lyr-primary) 50%, transparent)',
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

			{/* Title + subtitle (Swift inner VStack, spacing 2) */}
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
				{subtitle != null && (
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
						{subtitle}
					</span>
				)}
			</div>
		</div>
	)
}

/** 2x2 cover mosaic — four `Artwork` tiles in a square, matching the card radius. */
function Mosaic({ seeds, size }: { seeds: string[]; size: number }) {
	// Pad to four tiles by cycling the provided seeds so the grid is always full.
	const tiles = [0, 1, 2, 3].map((i) => seeds[i % seeds.length])
	const tile = (size - 2) / 2 // 2px gutter between tiles
	return (
		<div
			style={{
				position: 'absolute',
				inset: 0,
				display: 'grid',
				gridTemplateColumns: '1fr 1fr',
				gridTemplateRows: '1fr 1fr',
				gap: 2,
				borderRadius: 8,
				overflow: 'hidden',
				boxShadow: 'var(--lyr-shadow-card)',
			}}
		>
			{tiles.map((s, i) => (
				<Artwork
					key={i}
					seed={s}
					size={tile}
					radius={0}
					shadow={false}
					style={{ width: '100%', height: '100%' }}
				/>
			))}
		</div>
	)
}

/**
 * Inline lock glyph for the private badge. The shared `Icon` set has no `lock`
 * member, and editing `Icon.tsx` is out of scope here, so this draws a minimal
 * filled padlock inline. See learnings — `lock`/`lock.fill` is a missing glyph.
 */
function LockGlyph({ size }: { size: number }) {
	return (
		<svg
			width={size}
			height={size}
			viewBox="0 0 24 24"
			fill="none"
			style={{ display: 'block' }}
			aria-hidden
		>
			<rect x="5" y="11" width="14" height="9" rx="2" fill="#ffffff" />
			<path
				d="M8 11V8a4 4 0 0 1 8 0v3"
				stroke="#ffffff"
				strokeWidth="2"
				strokeLinecap="round"
				fill="none"
			/>
		</svg>
	)
}
