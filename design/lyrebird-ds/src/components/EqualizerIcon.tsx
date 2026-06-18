import type { CSSProperties } from 'react'

export interface EqualizerIconProps {
	/** Bar color. Defaults to the brand accent (matches the now-playing row). */
	color?: string
	/** Square edge in px. Default 14. */
	size?: number
	/** Animate the bars. When false, renders the static reduce-motion glyph. */
	animated?: boolean
	style?: CSSProperties
}

/**
 * Three-bar equalizer shown in place of the track number on the now-playing
 * row. Animated by default; `animated={false}` renders the static
 * reduce-motion glyph (mirrors the app's `EqualizerIcon` behaviour).
 */
export function EqualizerIcon({
	color = 'var(--lyr-accent)',
	size = 14,
	animated = true,
	style,
}: EqualizerIconProps) {
	const staticPct = [64, 86, 50]
	return (
		<span
			aria-label="Now playing"
			style={{
				display: 'inline-flex',
				alignItems: 'flex-end',
				gap: 2,
				height: size,
				width: size,
				...style,
			}}
		>
			<style>{'@keyframes lyr-eq{0%,100%{height:30%}50%{height:100%}}'}</style>
			{[0, 1, 2].map((i) => (
				<span
					key={i}
					style={{
						width: 3,
						borderRadius: 1,
						background: color,
						height: animated ? '100%' : `${staticPct[i]}%`,
						animation: animated
							? `lyr-eq 0.9s ease-in-out ${i * 0.18}s infinite`
							: undefined,
					}}
				/>
			))}
		</span>
	)
}
