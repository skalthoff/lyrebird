import type { CSSProperties } from 'react'
import { Sidebar, SidebarItem, SidebarSection, SidebarPlaylistRow } from './Sidebar'
import { PlayerBar } from './PlayerBar'
import { AlbumCard } from './AlbumCard'
import { Chip } from './Chip'
import { IconButton } from './IconButton'
import { Icon } from './Icon'

/* ------------------------------------------------------------------ *
 *  LibraryScreen — a full Lyrebird Desktop window assembled from the
 *  existing design-system components, mirroring the live SwiftUI
 *  `macos/Sources/Lyrebird/Screens/LibraryView.swift`.
 *
 *  Shell: a column whose top is a [Sidebar | content] row and whose
 *  bottom is a pinned PlayerBar. The content column is a centered
 *  search toolbar over the library body — a header row (view-tab
 *  Chips + Filter / Sort affordances) above a responsive grid of
 *  AlbumCards. Presentational only; no AppModel, no data fetching —
 *  every value is a literal so the screen renders standalone.
 * ------------------------------------------------------------------ */

/** One album tile's worth of data for the demo grid. */
interface DemoAlbum {
	title: string
	artist: string
	year: number
}

/**
 * Realistic library contents — the same kind of catalog the app shows
 * against `music.skalthoff.com` (electronic / synthwave / indie leaning).
 * 15 albums → three full rows in the ~5-column grid.
 */
const ALBUMS: DemoAlbum[] = [
	{ title: 'Random Access Memories', artist: 'Daft Punk', year: 2013 },
	{ title: 'Endless Summer', artist: 'The Midnight', year: 2016 },
	{ title: 'In Rainbows', artist: 'Radiohead', year: 2007 },
	{ title: 'Currents', artist: 'Tame Impala', year: 2015 },
	{ title: 'Discovery', artist: 'Daft Punk', year: 2001 },
	{ title: 'Hyperdrama', artist: 'Justice', year: 2024 },
	{ title: 'Cyan Nights', artist: 'FM-84', year: 2016 },
	{ title: 'Dimension', artist: 'Wolfgang Gartner', year: 2011 },
	{ title: 'A Moment Apart', artist: 'ODESZA', year: 2017 },
	{ title: 'Settle', artist: 'Disclosure', year: 2013 },
	{ title: 'Singularity', artist: 'Jon Hopkins', year: 2018 },
	{ title: 'Cross', artist: 'Justice', year: 2007 },
	{ title: 'Drive (Original Soundtrack)', artist: 'Cliff Martinez', year: 2011 },
	{ title: 'The Fragile', artist: 'Nine Inch Nails', year: 1999 },
	{ title: 'Lost in the Dream', artist: 'The War on Drugs', year: 2014 },
]

/** The four library view-tabs surfaced as Chips. "Albums" is active. */
const TABS = ['Albums', 'Artists', 'Songs', 'Genres'] as const

export interface LibraryScreenProps {
	style?: CSSProperties
}

/**
 * The full Library window. A faithful, self-contained mirror of the
 * shipped SwiftUI Library screen, composed entirely from existing
 * design-system components (Sidebar, PlayerBar, AlbumCard, Chip,
 * IconButton, Icon). Renders standalone with no provider beyond the
 * tokens — pass it straight into a preview cell.
 */
export function LibraryScreen({ style }: LibraryScreenProps) {
	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				height: '100%',
				minHeight: 0,
				width: '100%',
				background: 'var(--lyr-bg)',
				fontFamily: 'var(--lyr-font)',
				color: 'var(--lyr-ink)',
				overflow: 'hidden',
				...style,
			}}
		>
			{/* Top region: [ Sidebar | content ] */}
			<div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
				{/* ----------------------------- Sidebar ----------------------------- */}
				<Sidebar
					footer={{
						serverName: 'music.skalthoff.com',
						connected: true,
						albumCount: 20060,
					}}
				>
					{/* Primary navigation — Library is the active destination. */}
					<div
						style={{
							display: 'flex',
							flexDirection: 'column',
							gap: 2,
							padding: '0 10px',
						}}
					>
						<SidebarItem icon="home" label="Home" />
						<SidebarItem icon="list" label="Library" selected />
						<SidebarItem icon="compass" label="Discover" />
						<SidebarItem icon="radio" label="Radio" />
						<SidebarItem icon="search" label="Search" />
					</div>

					{/* Your Library — favorites + aggregate stat counts. */}
					<SidebarSection title="Your Library">
						<SidebarItem icon="heart" label="Favorites" compact />
						<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
						<SidebarItem icon="user" label="Artists" badge="3,839" compact plain />
						<SidebarItem icon="list" label="Playlists" badge={78} compact plain />
					</SidebarSection>

					{/* Playlists. */}
					<SidebarSection title="Playlists" compact>
						<SidebarPlaylistRow name="Late Night Drive" />
						<SidebarPlaylistRow name="Focus Flow" />
						<SidebarPlaylistRow name="Synthwave Essentials" private />
						<SidebarPlaylistRow name="Workout Bangers" />
						<SidebarPlaylistRow name="Rainy Day Jazz" private />
					</SidebarSection>
				</Sidebar>

				{/* ----------------------------- Content ----------------------------- */}
				<div
					style={{
						display: 'flex',
						flexDirection: 'column',
						flex: 1,
						minWidth: 0,
						minHeight: 0,
						background: 'var(--lyr-bg)',
					}}
				>
					{/* Toolbar — centered search pill, hairline bottom border. */}
					<div
						style={{
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							flexShrink: 0,
							height: 52,
							padding: '0 24px',
							borderBottom: '1px solid var(--lyr-border)',
						}}
					>
						<div
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 8,
								width: 360,
								maxWidth: '100%',
								height: 30,
								padding: '0 12px',
								background: 'var(--lyr-surface)',
								border: '1px solid var(--lyr-border)',
								borderRadius: 6,
							}}
						>
							<Icon name="search" size={14} color="var(--lyr-ink-3)" />
							<span style={{ fontSize: 13, fontWeight: 500, color: 'var(--lyr-ink-3)' }}>
								Search
							</span>
						</div>
					</div>

					{/* Body — scrolls under the fixed toolbar + player bar. */}
					<div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '28px 32px' }}>
						{/* Page heading — eyebrow + italic-black title + count subline. */}
						<div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 20 }}>
							<span
								style={{
									fontSize: 12,
									fontWeight: 700,
									letterSpacing: 2,
									color: 'var(--lyr-ink-2)',
								}}
							>
								YOUR LIBRARY
							</span>
							<span
								style={{
									fontSize: 36,
									fontWeight: 900,
									fontStyle: 'italic',
									lineHeight: 1.05,
									color: 'var(--lyr-ink)',
								}}
							>
								Library
							</span>
							<span
								style={{
									fontSize: 11,
									fontWeight: 700,
									letterSpacing: 1.2,
									color: 'var(--lyr-ink-3)',
								}}
							>
								20,060 ALBUMS
							</span>
						</div>

						{/* Header row — view-tab Chips on the left, Filter + Sort on the right. */}
						<div
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 12,
								marginBottom: 18,
							}}
						>
							<div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
								{TABS.map((tab) => (
									<Chip
										key={tab}
										label={tab}
										selected={tab === 'Albums'}
										onClick={() => {}}
									/>
								))}
							</div>

							<span style={{ flex: 1 }} />

							{/* Filter + Sort affordances — mirror the Swift header's icon controls. */}
							<div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
								<IconButton
									name="filter"
									label="Filter library"
									size={14}
									hitSize={30}
									style={{
										background: 'var(--lyr-surface)',
										border: '1px solid var(--lyr-border)',
									}}
								/>
								<IconButton
									name="sort"
									label="Sort library"
									size={14}
									hitSize={30}
									style={{
										background: 'var(--lyr-surface)',
										border: '1px solid var(--lyr-border)',
									}}
								/>
							</div>
						</div>

						{/* Responsive album grid — ~5 columns, 20px gap. */}
						<div
							style={{
								display: 'grid',
								gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
								gap: 20,
								justifyItems: 'start',
							}}
						>
							{ALBUMS.map((album) => (
								<AlbumCard
									key={`${album.artist}-${album.title}`}
									title={album.title}
									artist={album.artist}
									year={album.year}
									onClick={() => {}}
									onPlay={() => {}}
								/>
							))}
						</div>
					</div>
				</div>
			</div>

			{/* ----------------------------- Player bar ---------------------------- */}
			<div style={{ flexShrink: 0 }}>
				<PlayerBar
					title="Vampires"
					artist="The Midnight"
					album="Endless Summer"
					artworkSeed="Vampires"
					isPlaying
					favorite
					shuffle
					repeat="all"
					positionLabel="1:48"
					durationLabel="3:58"
					progress={0.45}
					volume={0.7}
					playingFrom="Synthwave Essentials"
				/>
			</div>
		</div>
	)
}
