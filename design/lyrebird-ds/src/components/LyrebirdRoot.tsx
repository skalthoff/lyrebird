import type { CSSProperties, ReactNode } from 'react'

export type ThemePreset = 'purple' | 'ocean' | 'forest'

export interface LyrebirdRootProps {
	/**
	 * Brand color preset. Maps 1:1 to the app's live `ThemePreset` (#405):
	 * `purple` (default), `ocean`, or `forest`. Sets the `--lyr-primary` /
	 * `--lyr-accent` tokens for everything inside.
	 */
	preset?: ThemePreset
	/** Stretch to fill the parent (the real app fills its window). Default true. */
	fill?: boolean
	children?: ReactNode
	className?: string
	style?: CSSProperties
}

/**
 * Root wrapper for every Lyrebird design. Establishes the dark surface
 * (`--lyr-bg`), the Figtree type family, the default ink color, and the active
 * brand `preset`, exposing all `--lyr-*` design tokens to descendants. Mirrors
 * the app's top-level window background + `Theme` token resolution.
 *
 * Wrap any composition of Lyrebird components in this so tokens and fonts
 * resolve correctly.
 */
export function LyrebirdRoot({
	preset = 'purple',
	fill = true,
	children,
	className,
	style,
}: LyrebirdRootProps) {
	return (
		<div
			data-lyr-preset={preset}
			className={className}
			style={{
				background: 'var(--lyr-bg)',
				color: 'var(--lyr-ink)',
				fontFamily: 'var(--lyr-font)',
				WebkitFontSmoothing: 'antialiased',
				width: fill ? '100%' : undefined,
				height: fill ? '100%' : undefined,
				...style,
			}}
		>
			{children}
		</div>
	)
}
