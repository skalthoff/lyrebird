import type { CSSProperties, ReactNode } from 'react'
import { SectionHeader } from './SectionHeader'

export interface ShelfProps {
	/** Shelf title, passed through to the `SectionHeader`. */
	title: string
	/** Optional dim subtitle shown inline after the title. */
	subtitle?: string
	/** Trailing "See All" pill label. Omit to drop the affordance. */
	actionLabel?: string
	/** Fires when the trailing "See All" pill is clicked. Required for the pill to render. */
	onAction?: () => void
	/** The card carousel — typically a row of `AlbumCard` / `ArtistCard` / `PlaylistCard`. */
	children: ReactNode
	/** Horizontal gap between cards in px. Default 16 (the Home album-shelf spacing). */
	gap?: number
	style?: CSSProperties
}

/**
 * A Home / Library section: a {@link SectionHeader} stacked above a
 * horizontally-scrolling row of cards. Mirrors `carouselSection` in
 * `macos/Sources/Lyrebird/Screens/HomeView.swift` — a leading-aligned VStack
 * with 12px between the header and the scroll row, an inner HStack of cards at
 * `gap` spacing (16px for albums, 12px for artist circles, 18px for tiles),
 * and 4px of vertical padding so hover lift / play overlays aren't clipped.
 */
export function Shelf({
	title,
	subtitle,
	actionLabel,
	onAction,
	children,
	gap = 16,
	style,
}: ShelfProps) {
	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				alignItems: 'stretch',
				gap: 12,
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			<SectionHeader
				title={title}
				subtitle={subtitle}
				actionLabel={actionLabel}
				onAction={onAction}
			/>

			{/* ScrollView(.horizontal) → HStack(spacing: gap), .padding(.vertical, 4) */}
			<div
				style={{
					display: 'flex',
					flexDirection: 'row',
					alignItems: 'flex-start',
					gap,
					paddingTop: 4,
					paddingBottom: 4,
					overflowX: 'auto',
					overflowY: 'hidden',
				}}
			>
				{children}
			</div>
		</div>
	)
}
