import type { CSSProperties, ReactNode } from 'react'
import { Icon, type IconName } from './Icon'

/** Visual treatment. Mirrors the three button shapes the app actually ships. */
export type ButtonVariant = 'primary' | 'secondary' | 'ghost'

/** Control height / padding scale. */
export type ButtonSize = 'sm' | 'md'

export interface ButtonProps {
	/**
	 * Visual treatment:
	 * - `primary` — filled accent pill with a coloured drop shadow, white
	 *   label. The album-header "Play" CTA.
	 * - `secondary` — surface fill + hairline border pill, `--lyr-ink` label.
	 *   The "Shuffle" / "Radio" peer actions.
	 * - `ghost` — transparent, no border, accent-tinted label. The inline
	 *   "Read more" / link-style affordance.
	 * @default 'primary'
	 */
	variant?: ButtonVariant
	/** Control size. `md` is the album-CTA size; `sm` is the compact inline size. @default 'md' */
	size?: ButtonSize
	/** Optional leading glyph, rendered via the shared `Icon` component. */
	icon?: IconName
	/** Stretch to fill the container width (the login "Connect" CTA). @default false */
	fullWidth?: boolean
	disabled?: boolean
	onClick?: () => void
	/** Button label. */
	children: ReactNode
	style?: CSSProperties
}

/** Per-size geometry, matching the Swift CTA padding / font sizes. */
const SIZES: Record<ButtonSize, { padV: number; padH: number; font: number; icon: number; gap: number }> = {
	// AlbumDetailView Play / secondaryCTA: 10pt vertical, 13pt semibold label.
	md: { padV: 10, padH: 18, font: 13, icon: 14, gap: 8 },
	// Compact inline affordance (chips / "Read more"-scale rows).
	sm: { padV: 6, padH: 12, font: 12, icon: 12, gap: 6 },
}

/**
 * The app's text-label action button. Three variants mirror the live SwiftUI
 * treatments: the filled accent **pill** "Play" CTA
 * (`Capsule().fill(Theme.accent)` + an accent drop shadow, white label —
 * `AlbumDetailView.playButton`), the **secondary** surface-fill pill with a
 * hairline border ("Shuffle" / "Radio" — `AlbumDetailView.secondaryCTA`), and
 * the transparent **ghost** link ("Read more"). All buttons are full pills
 * (`borderRadius: 999`) at Figtree semibold, matching the Swift `Capsule()`
 * shape. Geometry is literal px lifted from the Swift padding / font sizes.
 */
export function Button({
	variant = 'primary',
	size = 'md',
	icon,
	fullWidth = false,
	disabled = false,
	onClick,
	children,
	style,
}: ButtonProps) {
	const s = SIZES[size]

	// Pill shape across all variants — the Swift CTAs are `Capsule()`.
	const base: CSSProperties = {
		display: variant === 'ghost' && !fullWidth ? 'inline-flex' : fullWidth ? 'flex' : 'inline-flex',
		width: fullWidth ? '100%' : undefined,
		alignItems: 'center',
		justifyContent: 'center',
		gap: s.gap,
		fontFamily: 'var(--lyr-font)',
		fontSize: s.font,
		fontWeight: 600,
		lineHeight: 1,
		borderRadius: 999,
		cursor: disabled ? 'default' : 'pointer',
		opacity: disabled ? 0.5 : 1,
		whiteSpace: 'nowrap',
		userSelect: 'none',
		transition: 'background 120ms ease, opacity 120ms ease',
	}

	const variantStyle: CSSProperties =
		variant === 'primary'
			? {
					// Capsule().fill(Theme.accent) + white label + accent shadow
					// (opacity 0.35, radius 10, y 6).
					padding: `${s.padV}px ${s.padH}px`,
					color: '#ffffff',
					background: 'var(--lyr-accent)',
					border: 'none',
					boxShadow: '0 6px 10px color-mix(in srgb, var(--lyr-accent) 35%, transparent)',
			  }
			: variant === 'secondary'
				? {
						// Capsule().fill(Theme.surface) + 1px Theme.border stroke,
						// Theme.ink label.
						padding: `${s.padV}px ${s.padH}px`,
						color: 'var(--lyr-ink)',
						background: 'var(--lyr-surface)',
						border: '1px solid var(--lyr-border)',
				  }
				: {
						// Transparent link affordance — accent label, no chrome.
						padding: `${s.padV}px 0`,
						color: 'var(--lyr-accent)',
						background: 'transparent',
						border: 'none',
						boxShadow: 'none',
				  }

	return (
		<button
			type="button"
			disabled={disabled}
			onClick={onClick}
			style={{ ...base, ...variantStyle, ...style }}
		>
			{icon ? <Icon name={icon} size={s.icon} color="currentColor" fill={icon === 'play'} /> : null}
			{children}
		</button>
	)
}
