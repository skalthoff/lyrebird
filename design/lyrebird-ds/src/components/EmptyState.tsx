import type { CSSProperties } from 'react'
import { Icon, type IconName } from './Icon'

export interface EmptyStateProps {
	/**
	 * Optional glyph drawn in the pill-backed illustration, via the shared
	 * `Icon` component. Mirrors the SwiftUI `Image(systemName:)` illustration
	 * (`heart` for favorites, `search` for no-results, `list` for an empty
	 * playlist). Omit for a text-only empty state.
	 */
	icon?: IconName
	/**
	 * Short headline — "No favorites yet", "Empty playlist". Rendered in
	 * Figtree black italic to match the Swift `Theme.font(22, .black, italic)`
	 * headline.
	 */
	title: string
	/**
	 * Optional descriptive copy below the title. Omit for surfaces that are
	 * self-explanatory from the title alone. Constrained to a 420px measure and
	 * centered, matching the Swift body copy.
	 */
	message?: string
	/** Optional primary action label. Rendered as the amethyst pill CTA when set alongside `onAction`. */
	actionLabel?: string
	/** Handler for the primary action. */
	onAction?: () => void
}

/**
 * The app's centered "nothing here yet" surface — a faithful mirror of
 * `macos/Sources/Lyrebird/Components/EmptyStateView.swift`. A pill-backed glyph
 * illustration, an `--lyr-ink` black-italic headline, muted `--lyr-ink-2` body
 * copy, and an optional amethyst (`--lyr-primary`) pill CTA. Used across
 * Favorites, Search (no results), Library (no filter matches), and empty
 * playlists.
 *
 * Geometry/typography are literal px lifted from the Swift view: the glyph is a
 * 44px semibold symbol inside a 112×112 `--lyr-surface-2` circle with a 1px
 * `--lyr-border` stroke; VStack spacing 18 with a 6px title/body gap; 56px
 * vertical outer padding; the body copy caps at a 420px measure. Note the CTA
 * is the amethyst `--lyr-primary` (filled at 20%, 1px primary stroke, radius
 * 22), NOT the pink `--lyr-accent` — matching the Swift primary CTA.
 *
 * The Swift component also supports a secondary text CTA; this mirror exposes
 * the single-action prop shape (`actionLabel` / `onAction`).
 */
export function EmptyState({ icon, title, message, actionLabel, onAction }: EmptyStateProps) {
	const hasAction = Boolean(actionLabel && onAction)

	// VStack(spacing: 18), .padding(.vertical, 56), .frame(maxWidth: .infinity).
	const root: CSSProperties = {
		display: 'flex',
		flexDirection: 'column',
		alignItems: 'center',
		gap: 18,
		width: '100%',
		paddingTop: 56,
		paddingBottom: 56,
		fontFamily: 'var(--lyr-font)',
		boxSizing: 'border-box',
		textAlign: 'center',
	}

	// Image(systemName:) size 44 semibold ink2, in a 112×112 Circle filled
	// surface2 + 1px border stroke.
	const illustration: CSSProperties = {
		display: 'flex',
		alignItems: 'center',
		justifyContent: 'center',
		width: 112,
		height: 112,
		borderRadius: '50%',
		background: 'var(--lyr-surface-2)',
		border: '1px solid var(--lyr-border)',
		color: 'var(--lyr-ink-2)',
		flexShrink: 0,
	}

	// Inner VStack(spacing: 6) — headline + optional body copy.
	const textBlock: CSSProperties = {
		display: 'flex',
		flexDirection: 'column',
		alignItems: 'center',
		gap: 6,
	}

	// Theme.font(22, weight: .black, italic: true), foreground ink.
	const headline: CSSProperties = {
		margin: 0,
		fontSize: 22,
		fontWeight: 900,
		fontStyle: 'italic',
		lineHeight: 1.15,
		color: 'var(--lyr-ink)',
	}

	// Theme.font(13, weight: .medium), foreground ink2, max width 420 centered.
	const body: CSSProperties = {
		margin: 0,
		fontSize: 13,
		fontWeight: 500,
		lineHeight: 1.45,
		color: 'var(--lyr-ink-2)',
		maxWidth: 420,
	}

	// Primary CTA: font(13, .bold) ink label, padding 18h/10v, RoundedRectangle
	// radius 22 filled primary @ 20% + 1px primary stroke. (Amethyst primary,
	// not accent.)
	const primaryButton: CSSProperties = {
		marginTop: 0,
		display: 'inline-flex',
		alignItems: 'center',
		justifyContent: 'center',
		padding: '10px 18px',
		fontFamily: 'var(--lyr-font)',
		fontSize: 13,
		fontWeight: 700,
		lineHeight: 1,
		color: 'var(--lyr-ink)',
		background: 'color-mix(in srgb, var(--lyr-primary) 20%, transparent)',
		border: '1px solid var(--lyr-primary)',
		borderRadius: 22,
		cursor: 'pointer',
		whiteSpace: 'nowrap',
		userSelect: 'none',
	}

	return (
		<div style={root}>
			{icon ? (
				<div style={illustration} aria-hidden="true">
					<Icon name={icon} size={44} color="currentColor" strokeWidth={2} />
				</div>
			) : null}

			<div style={textBlock}>
				<h2 style={headline}>{title}</h2>
				{message ? <p style={body}>{message}</p> : null}
			</div>

			{hasAction ? (
				<button type="button" onClick={onAction} style={primaryButton}>
					{actionLabel}
				</button>
			) : null}
		</div>
	)
}
