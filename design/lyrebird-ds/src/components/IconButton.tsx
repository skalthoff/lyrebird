import type { CSSProperties } from 'react'
import { Icon, type IconName } from './Icon'

export interface IconButtonProps {
	/** Glyph to render. */
	name: IconName
	/** Accessible label (also the native tooltip). */
	label: string
	/** Glyph size in px. Default 14 (the player-bar transport size). */
	size?: number
	/** Square hit-area edge in px. Default 28. */
	hitSize?: number
	/** Toggled/active — tints the glyph with `--lyr-accent`. */
	active?: boolean
	/** Override tint. Defaults to `--lyr-ink-2`, or `--lyr-accent` when active. */
	tint?: string
	/** Fill the glyph (transport play/pause). */
	fill?: boolean
	disabled?: boolean
	onClick?: () => void
	style?: CSSProperties
}

/**
 * Flat icon button — the app's `iconBtn` transport/affordance pattern. A
 * 28×28 hit area with a 14px glyph, tinted `--lyr-ink-2` and lifting to
 * `--lyr-accent` when `active` (shuffle/repeat/favorite toggles).
 */
export function IconButton({
	name,
	label,
	size = 14,
	hitSize = 28,
	active = false,
	tint,
	fill,
	disabled = false,
	onClick,
	style,
}: IconButtonProps) {
	const color = tint ?? (active ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)')
	return (
		<button
			type="button"
			aria-label={label}
			aria-pressed={active}
			title={label}
			disabled={disabled}
			onClick={onClick}
			style={{
				width: hitSize,
				height: hitSize,
				display: 'inline-flex',
				alignItems: 'center',
				justifyContent: 'center',
				padding: 0,
				border: 'none',
				background: 'transparent',
				borderRadius: 6,
				cursor: disabled ? 'default' : 'pointer',
				opacity: disabled ? 0.4 : 1,
				...style,
			}}
		>
			<Icon name={name} size={size} color={color} fill={fill} />
		</button>
	)
}
