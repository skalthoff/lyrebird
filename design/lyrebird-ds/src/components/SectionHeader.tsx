import type { CSSProperties } from 'react'
import { Icon } from './Icon'

export interface SectionHeaderProps {
	/** Section title (primary line, bold `--lyr-ink`). */
	title: string
	/** Optional subtitle rendered inline after the title in dim `--lyr-ink-3`. */
	subtitle?: string
	/** Trailing "See All" pill label. Omit to drop the affordance entirely. */
	actionLabel?: string
	/** Fires when the trailing action pill is clicked. Required for the pill to render. */
	onAction?: () => void
	style?: CSSProperties
}

/**
 * The header row shared by every Home shelf (and Library section). A bold
 * title with an optional dim subtitle on the left, baseline-aligned, and an
 * optional outlined "See All" pill (label + chevron, `--lyr-ink-2`) pushed to
 * the trailing edge. Mirrors the `carouselSection` header in
 * `macos/Sources/Lyrebird/Screens/HomeView.swift`: title 18/bold, subtitle
 * 12/medium, "See All" 12/semibold + 10px chevron in a 1px capsule.
 */
export function SectionHeader({
	title,
	subtitle,
	actionLabel,
	onAction,
	style,
}: SectionHeaderProps) {
	return (
		<div
			style={{
				display: 'flex',
				alignItems: 'baseline',
				gap: 8,
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			<span
				style={{
					fontSize: 18,
					fontWeight: 700,
					color: 'var(--lyr-ink)',
				}}
			>
				{title}
			</span>
			{subtitle && (
				<span
					style={{
						fontSize: 12,
						fontWeight: 500,
						color: 'var(--lyr-ink-3)',
					}}
				>
					{subtitle}
				</span>
			)}

			{/* Spacer(minLength: 12) — push the action pill to the trailing edge */}
			<span style={{ flex: 1, minWidth: 12 }} />

			{actionLabel && onAction && (
				<button
					type="button"
					onClick={onAction}
					aria-label={`See all ${title}`}
					title={`Open ${title} in full`}
					style={{
						display: 'inline-flex',
						alignItems: 'center',
						gap: 4,
						alignSelf: 'center',
						padding: '6px 10px',
						border: '1px solid var(--lyr-border)',
						borderRadius: 999,
						background: 'transparent',
						color: 'var(--lyr-ink-2)',
						fontFamily: 'var(--lyr-font)',
						fontSize: 12,
						fontWeight: 600,
						cursor: 'pointer',
						whiteSpace: 'nowrap',
					}}
				>
					{actionLabel}
					<Icon name="chevron-right" size={10} strokeWidth={2.5} />
				</button>
			)}
		</div>
	)
}
