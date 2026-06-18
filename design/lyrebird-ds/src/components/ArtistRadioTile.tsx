import { useState } from 'react'
import type { CSSProperties } from 'react'
import { Artwork } from './Artwork'

export interface ArtistRadioTileProps {
	/** Artist name — primary label, and the gradient seed when no artwork is given. */
	name: string
	/** Round artwork URL. Absent → deterministic gradient keyed on `name`. */
	artworkUrl?: string
	/** Circle diameter in px. Default 140. The radio glyph + label scale off this. */
	size?: number
	/** Force hover visuals (glyph reveal + accent ring + accent glow) for static previews. */
	hovered?: boolean
	/** Fires when the tile is pressed — starts an artist radio (Instant Mix) seeded by this artist. */
	onStart?: () => void
	style?: CSSProperties
}

/**
 * Circular "artist radio" seed tile used on Home: a round artwork thumbnail with
 * a "<Artist> / Radio" label beneath it. On hover a radio glyph fades in over a
 * dark scrim, the ring lifts to `--lyr-accent`, and an accent glow appears — the
 * same play-button-reveal idiom as `AlbumCard`, signalling "press to start a
 * station" rather than "just an artist photo". Mirrors `ArtistRadioTile` in
 * `ArtistRadioTile.swift`.
 */
export function ArtistRadioTile({
	name,
	artworkUrl,
	size = 140,
	hovered,
	onStart,
	style,
}: ArtistRadioTileProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	return (
		<button
			type="button"
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			onClick={onStart}
			title={`Start ${name} Radio`}
			aria-label={`${name} Radio`}
			style={{
				display: 'inline-flex',
				flexDirection: 'column',
				alignItems: 'center',
				gap: 10,
				padding: 0,
				border: 'none',
				background: 'transparent',
				cursor: onStart ? 'pointer' : undefined,
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			{/* Round artwork + hover-reveal radio glyph + ring */}
			<div
				style={{
					position: 'relative',
					width: size,
					height: size,
					borderRadius: '50%',
					boxShadow: isHovering
						? '0 0 12px color-mix(in srgb, var(--lyr-accent) 35%, transparent)'
						: 'none',
					transition: 'box-shadow 0.15s ease-out',
				}}
			>
				<Artwork url={artworkUrl} seed={name} size={size} shape="circle" shadow={false} />

				{/* Radio glyph overlay — surfaces the radio affordance on hover. */}
				<div
					style={{
						position: 'absolute',
						inset: 0,
						borderRadius: '50%',
						display: 'flex',
						alignItems: 'center',
						justifyContent: 'center',
						background: 'rgba(0,0,0,0.45)',
						color: '#ffffff',
						opacity: isHovering ? 1 : 0,
						transition: 'opacity 0.15s ease-out',
						lineHeight: 0,
					}}
				>
					<svg
						width={size * 0.28}
						height={size * 0.28}
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						strokeWidth={2.4}
						strokeLinecap="round"
						strokeLinejoin="round"
					>
						<circle cx="12" cy="12" r="2" fill="currentColor" stroke="none" />
						<path d="M8.5 8.5a5 5 0 0 0 0 7M6 6a8.5 8.5 0 0 0 0 12M15.5 8.5a5 5 0 0 1 0 7M18 6a8.5 8.5 0 0 1 0 12" />
					</svg>
				</div>

				{/* Ring — border → accent, 1 → 2px, on hover. */}
				<div
					style={{
						position: 'absolute',
						inset: 0,
						borderRadius: '50%',
						border: isHovering
							? '2px solid var(--lyr-accent)'
							: '1px solid var(--lyr-border)',
						transition: 'border-color 0.15s ease-out',
						pointerEvents: 'none',
					}}
				/>
			</div>

			{/* "<Artist>" + "Radio" label */}
			<div
				style={{
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					gap: 2,
					width: size,
				}}
			>
				<div
					style={{
						fontSize: 13,
						fontWeight: 700,
						color: 'var(--lyr-ink)',
						maxWidth: size,
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{name}
				</div>
				<div
					style={{
						fontSize: 11,
						fontWeight: 600,
						color: 'var(--lyr-ink-3)',
						letterSpacing: '0.5px',
					}}
				>
					Radio
				</div>
			</div>
		</button>
	)
}
