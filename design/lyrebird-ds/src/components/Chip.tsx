import type { CSSProperties } from 'react'
import { Icon, type IconName } from './Icon'

export interface ChipProps {
	/** Text shown inside the pill, e.g. a genre ("Electronic") or filter ("Favorites"). */
	label: string
	/**
	 * Selected/active look. Mirrors the SwiftUI `Chip` (`Components/Chips.swift`):
	 * a high-contrast white (`--lyr-ink`) fill with dark (`--lyr-bg`) text and no
	 * border. Idle chips sit on a faint `--lyr-surface` fill, `--lyr-ink-2` text,
	 * and a hairline `--lyr-border` stroke.
	 */
	selected?: boolean
	/**
	 * Use the brand-accent selected fill instead of the default white-ink one.
	 * Matches the accent-filled pills in the app (ArtistDetailView's Follow chip,
	 * SmartPlaylistBuilder's Save): `--lyr-accent` background with white text when
	 * `selected`. Ignored when `selected` is false. Defaults to `false`.
	 */
	accent?: boolean
	/** Optional leading glyph drawn before the label (e.g. `heart` for "Favorites"). */
	icon?: IconName
	/** Click handler for the chip body. Renders as a `<button>` when present. */
	onClick?: () => void
	/**
	 * When provided, a trailing dismiss (×) affordance is shown. Invoked instead
	 * of `onClick` when the × is activated — used for removable filter/tag chips.
	 */
	onDismiss?: () => void
	style?: CSSProperties
}

/**
 * Small rounded pill for genres, library filters, and tags. Faithful mirror of
 * the SwiftUI `Chip` in `macos/Sources/Lyrebird/Components/Chips.swift`: a
 * fully-rounded capsule with a 14pt/semibold label and 7pt vertical / 14pt
 * horizontal padding.
 *
 * Selected chips read as high-contrast — a white `--lyr-ink` fill over
 * `--lyr-bg` text with no border (or `--lyr-accent` + white text when `accent`).
 * Unselected chips sit on a faint `--lyr-surface` fill, `--lyr-ink-2` text, and
 * a hairline `--lyr-border` stroke. An optional leading `icon` and a trailing
 * dismiss (×) round out the removable-filter case.
 */
export function Chip({
	label,
	selected = false,
	accent = false,
	icon,
	onClick,
	onDismiss,
	style,
}: ChipProps) {
	// Selected: white-ink fill (default) or brand-accent fill, both borderless.
	// Idle: faint surface fill with a hairline border. Mirrors Chips.swift.
	const fill = selected
		? accent
			? 'var(--lyr-accent)'
			: 'var(--lyr-ink)'
		: 'var(--lyr-surface)'
	const text = selected ? (accent ? 'var(--lyr-ink)' : 'var(--lyr-bg)') : 'var(--lyr-ink-2)'
	const border = selected ? '1px solid transparent' : '1px solid var(--lyr-border)'

	const interactive = Boolean(onClick)

	return (
		<button
			type="button"
			onClick={onClick}
			disabled={!interactive}
			aria-pressed={selected}
			style={{
				display: 'inline-flex',
				alignItems: 'center',
				gap: 6,
				// Capsule() → pill radius. Half the chip height keeps it fully rounded.
				borderRadius: 999,
				// 7pt vertical / 14pt horizontal from Chips.swift; trim the trailing
				// pad when a dismiss button supplies its own edge spacing.
				padding: onDismiss ? '7px 8px 7px 14px' : '7px 14px',
				fontFamily: 'var(--lyr-font)',
				fontSize: 14,
				fontWeight: 600,
				lineHeight: 1,
				whiteSpace: 'nowrap',
				color: text,
				background: fill,
				border,
				cursor: interactive ? 'pointer' : 'default',
				// Strip the native button chrome so the capsule reads cleanly.
				appearance: 'none',
				WebkitAppearance: 'none',
				...style,
			}}
		>
			{icon ? <Icon name={icon} size={14} color={text} strokeWidth={2.25} /> : null}
			<span>{label}</span>
			{onDismiss ? (
				<span
					role="button"
					aria-label={`Remove ${label}`}
					tabIndex={0}
					onClick={(e) => {
						// Don't let the dismiss bubble up to the chip's own onClick.
						e.stopPropagation()
						onDismiss()
					}}
					onKeyDown={(e) => {
						if (e.key === 'Enter' || e.key === ' ') {
							e.preventDefault()
							e.stopPropagation()
							onDismiss()
						}
					}}
					style={{
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						marginLeft: 1,
						width: 16,
						height: 16,
						borderRadius: 999,
						color: text,
						// Faint scrim behind the × so it reads against either fill.
						background: 'color-mix(in srgb, var(--lyr-bg) 22%, transparent)',
						cursor: 'pointer',
					}}
				>
					<Icon name="close" size={10} color={text} strokeWidth={2.5} />
				</span>
			) : null}
		</button>
	)
}
