import type { CSSProperties } from 'react'
import {
	Sidebar,
	SidebarItem,
	SidebarSection,
	SidebarPlaylistRow,
} from './Sidebar'
import { PlayerBar } from './PlayerBar'
import { Artwork } from './Artwork'
import { TopTrackRow } from './TopTrackRow'
import { AlbumCard } from './AlbumCard'
import { ArtistCard } from './ArtistCard'
import { Shelf } from './Shelf'
import { Button } from './Button'
import { Icon } from './Icon'

/* ------------------------------------------------------------------ *
 *  ArtistDetailScreen — a self-contained full app window mirroring
 *  macos/Sources/Lyrebird/Screens/ArtistDetailView.swift.
 *
 *  Composes EXISTING design-system components into the live app shell:
 *  a column [row: Sidebar | content] with the persistent PlayerBar pinned
 *  to the bottom over `var(--lyr-bg)`. The content column is a toolbar
 *  (search pill + bottom hairline) above a scrolling body: the artist
 *  header (large SQUARE artwork — radius 8, NOT a circle in this app —
 *  the name, a "monthly listeners" / genre meta line, and Play + Follow
 *  affordances), a "Top Tracks" list of `TopTrackRow`s, a "Discography"
 *  `Shelf` of `AlbumCard`s, and a "Similar Artists" `Shelf` of
 *  `ArtistCard`s.
 *
 *  Presentational only — every value is a literal here (this is an example
 *  screen, not a live view); all colors/fonts are `var(--lyr-*)` tokens and
 *  geometry is the literal px from the Swift source.
 * ------------------------------------------------------------------ */

/** A top-track row's data, mirroring the Swift `Track` fields the row reads. */
interface TopTrackData {
	title: string
	album: string
	artworkSeed: string
	playCount: number
	duration: string
	favorite?: boolean
	active?: boolean
	playing?: boolean
}

/** A discography album tile's data. */
interface DiscographyAlbum {
	title: string
	year: number
	artworkSeed: string
}

/** A similar-artist tile's data. */
interface SimilarArtistData {
	name: string
	subtitle: string
	artworkSeed: string
}

export interface ArtistDetailScreenProps {
	/** Artist name — the large header title. */
	artistName?: string
	/** Stat / meta line under the name (e.g. "1,284,902 monthly listeners"). */
	monthlyListeners?: string
	/** Genre line shown above the stats (e.g. "Synthwave · Electronic"). */
	genres?: string
	/** Whether the current user already follows this artist. */
	following?: boolean
	/** Header artwork seed (drives the deterministic gradient when no URL). */
	artworkSeed?: string
	style?: CSSProperties
}

/* The example artist + content. Real names, never foo/bar — matches the
   preview-content convention. */
const TOP_TRACKS: TopTrackData[] = [
	{
		title: 'Sunset',
		album: 'Endless Summer',
		artworkSeed: 'Endless Summer',
		playCount: 342,
		duration: '4:39',
		favorite: true,
	},
	{
		title: 'Vampires',
		album: 'Endless Summer',
		artworkSeed: 'Endless Summer',
		playCount: 287,
		duration: '3:58',
		active: true,
		playing: true,
	},
	{
		title: 'Days of Thunder',
		album: 'Days of Thunder',
		artworkSeed: 'Days of Thunder',
		playCount: 196,
		duration: '5:12',
	},
	{
		title: 'Lost Boy',
		album: 'Nocturnal',
		artworkSeed: 'Nocturnal',
		playCount: 154,
		duration: '4:21',
	},
	{
		title: 'Crystalline',
		album: 'Kids',
		artworkSeed: 'Kids',
		playCount: 88,
		duration: '3:47',
	},
]

const DISCOGRAPHY: DiscographyAlbum[] = [
	{ title: 'Endless Summer', year: 2016, artworkSeed: 'Endless Summer' },
	{ title: 'Nocturnal', year: 2017, artworkSeed: 'Nocturnal' },
	{ title: 'Kids', year: 2018, artworkSeed: 'Kids' },
	{ title: 'Monsters', year: 2020, artworkSeed: 'Monsters' },
	{ title: 'Heroes', year: 2022, artworkSeed: 'Heroes' },
]

const SIMILAR_ARTISTS: SimilarArtistData[] = [
	{ name: 'FM-84', subtitle: '4 albums', artworkSeed: 'FM-84' },
	{ name: 'Timecop1983', subtitle: '7 albums', artworkSeed: 'Timecop1983' },
	{ name: 'GUNSHIP', subtitle: '3 albums', artworkSeed: 'GUNSHIP' },
	{ name: 'Carpenter Brut', subtitle: '5 albums', artworkSeed: 'Carpenter Brut' },
	{ name: 'Com Truise', subtitle: '6 albums', artworkSeed: 'Com Truise' },
]

/**
 * The artist eyebrow + name + meta block. Mirrors `heroTypeBlock` /
 * `heroStatsStrip` in the Swift hero: a tracked "ARTIST" eyebrow in accent,
 * a large heavy italic name, a genre line, and a stats line.
 */
function ArtistHeaderText({
	artistName,
	monthlyListeners,
	genres,
}: {
	artistName: string
	monthlyListeners: string
	genres: string
}) {
	return (
		<div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
			<span
				style={{
					fontSize: 11,
					fontWeight: 700,
					color: 'var(--lyr-accent)',
					letterSpacing: 3,
				}}
			>
				ARTIST
			</span>
			<span
				style={{
					fontSize: 64,
					fontWeight: 900,
					fontStyle: 'italic',
					color: 'var(--lyr-ink)',
					letterSpacing: -2,
					lineHeight: 1.02,
				}}
			>
				{artistName}
			</span>
			<span
				style={{
					fontSize: 15,
					fontWeight: 500,
					color: 'var(--lyr-ink-2)',
					marginTop: 2,
				}}
			>
				{genres}
			</span>
			<span
				style={{
					fontSize: 13,
					fontWeight: 600,
					color: 'var(--lyr-ink-3)',
					letterSpacing: 0.3,
					marginTop: 2,
				}}
			>
				{monthlyListeners}
			</span>
		</div>
	)
}

/**
 * A small, non-interactive search field for the content toolbar — a rounded
 * pill with a leading magnifier + placeholder, mirroring the macOS toolbar
 * search affordance that sits above each detail surface.
 */
function ToolbarSearch() {
	return (
		<div
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 8,
				width: 240,
				height: 30,
				padding: '0 12px',
				borderRadius: 999,
				background: 'var(--lyr-surface)',
				border: '1px solid var(--lyr-border)',
			}}
		>
			<Icon name="search" size={13} color="var(--lyr-ink-3)" />
			<span style={{ fontSize: 12, fontWeight: 500, color: 'var(--lyr-ink-3)' }}>
				Search library
			</span>
		</div>
	)
}

/**
 * A full-window example screen mirroring the app's Artist Detail surface.
 * Self-contained: it renders its own shell (Sidebar + content + PlayerBar)
 * and example artist content, so it can be dropped in as a single component.
 */
export function ArtistDetailScreen({
	artistName = 'The Midnight',
	monthlyListeners = '1,284,902 monthly listeners',
	genres = 'Synthwave · Electronic · Dream Pop',
	following = false,
	artworkSeed = 'The Midnight',
	style,
}: ArtistDetailScreenProps) {
	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				width: '100%',
				height: '100%',
				minHeight: 0,
				overflow: 'hidden',
				background: 'var(--lyr-bg)',
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			{/* ── Row: Sidebar | content ── */}
			<div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
				{/* Left rail */}
				<Sidebar
					footer={{
						serverName: 'music.skalthoff.com',
						connected: true,
						albumCount: 20060,
					}}
				>
					<div
						style={{
							display: 'flex',
							flexDirection: 'column',
							gap: 2,
							padding: '0 10px',
						}}
					>
						<SidebarItem icon="home" label="Home" />
						<SidebarItem icon="list" label="Library" />
						<SidebarItem icon="compass" label="Discover" />
						<SidebarItem icon="radio" label="Radio" />
						<SidebarItem icon="search" label="Search" />
					</div>

					<SidebarSection title="Your Library">
						<SidebarItem icon="heart" label="Favorites" compact />
						<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
						<SidebarItem icon="user" label="Artists" badge="3,839" compact plain selected />
						<SidebarItem icon="list" label="Playlists" badge={78} compact plain />
					</SidebarSection>

					<SidebarSection title="Playlists" compact>
						<SidebarPlaylistRow name="Late Night Drive" />
						<SidebarPlaylistRow name="Synthwave Essentials" />
						<SidebarPlaylistRow name="Focus Flow" private />
						<SidebarPlaylistRow name="Recently Added" smart />
					</SidebarSection>
				</Sidebar>

				{/* Content column: toolbar + scrolling body */}
				<div
					style={{
						flex: 1,
						minWidth: 0,
						display: 'flex',
						flexDirection: 'column',
						minHeight: 0,
						background: 'var(--lyr-bg)',
					}}
				>
					{/* Toolbar — search pill + bottom hairline */}
					<div
						style={{
							display: 'flex',
							alignItems: 'center',
							gap: 12,
							height: 52,
							flexShrink: 0,
							padding: '0 32px',
							borderBottom: '1px solid var(--lyr-border)',
						}}
					>
						<button
							type="button"
							aria-label="Back"
							title="Back"
							style={{
								width: 28,
								height: 28,
								display: 'inline-flex',
								alignItems: 'center',
								justifyContent: 'center',
								padding: 0,
								border: 'none',
								background: 'transparent',
								cursor: 'pointer',
								color: 'var(--lyr-ink-2)',
							}}
						>
							<Icon name="chevron-left" size={18} color="var(--lyr-ink-2)" />
						</button>
						<span style={{ flex: 1 }} />
						<ToolbarSearch />
					</div>

					{/* Scrolling body */}
					<div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
						{/* Artist header — large SQUARE artwork + type block + transport */}
						<div style={{ padding: '32px 32px 8px' }}>
							<div style={{ display: 'flex', alignItems: 'flex-end', gap: 28 }}>
								{/* Artist artwork is SQUARE (radius 8) in this app — not a circle. */}
								<Artwork seed={artworkSeed} size={208} radius={8} />
								<div
									style={{
										flex: 1,
										minWidth: 0,
										display: 'flex',
										flexDirection: 'column',
										gap: 18,
									}}
								>
									<ArtistHeaderText
										artistName={artistName}
										monthlyListeners={monthlyListeners}
										genres={genres}
									/>

									{/* Transport — Play + Follow */}
									<div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
										<Button variant="primary" icon="play">
											Play
										</Button>
										<Button variant="secondary" icon="shuffle">
											Shuffle
										</Button>
										<Button variant={following ? 'primary' : 'secondary'} icon="plus">
											{following ? 'Following' : 'Follow'}
										</Button>
										<Button variant="secondary" icon="radio">
											Artist Radio
										</Button>
									</div>
								</div>
							</div>
						</div>

						{/* Top Tracks */}
						<div style={{ padding: '28px 32px 0' }}>
							<div style={{ marginBottom: 12 }}>
								<span
									style={{
										fontSize: 10,
										fontWeight: 700,
										color: 'var(--lyr-accent)',
										letterSpacing: 3,
									}}
								>
									MOST PLAYED
								</span>
								<div
									style={{
										fontSize: 24,
										fontWeight: 800,
										color: 'var(--lyr-ink)',
										marginTop: 4,
									}}
								>
									Top Songs
								</div>
							</div>
							<div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
								{TOP_TRACKS.map((track, i) => (
									<TopTrackRow
										key={track.title}
										rank={i + 1}
										title={track.title}
										album={track.album}
										artworkSeed={track.artworkSeed}
										playCount={track.playCount}
										duration={track.duration}
										favorite={track.favorite}
										active={track.active}
										playing={track.playing}
									/>
								))}
							</div>
						</div>

						{/* Discography — horizontal shelf of album cards */}
						<div style={{ padding: '36px 32px 0' }}>
							<Shelf title="Discography" subtitle="Albums, singles & EPs" actionLabel="See All" onAction={() => {}}>
								{DISCOGRAPHY.map((album) => (
									<AlbumCard
										key={album.title}
										title={album.title}
										artist={artistName}
										year={album.year}
										artworkSeed={album.artworkSeed}
									/>
								))}
							</Shelf>
						</div>

						{/* Similar Artists — horizontal shelf of artist cards */}
						<div style={{ padding: '36px 32px 40px' }}>
							<Shelf title="Similar Artists" subtitle="You might also like">
								{SIMILAR_ARTISTS.map((artist) => (
									<ArtistCard
										key={artist.name}
										name={artist.name}
										subtitle={artist.subtitle}
										artworkSeed={artist.artworkSeed}
									/>
								))}
							</Shelf>
						</div>
					</div>
				</div>
			</div>

			{/* ── Persistent transport bar pinned to the bottom ── */}
			<PlayerBar
				title="Vampires"
				artist={artistName}
				album="Endless Summer"
				artworkSeed="Endless Summer"
				isPlaying
				favorite
				shuffle
				repeat="all"
				positionLabel="1:48"
				durationLabel="3:58"
				progress={0.45}
				volume={0.7}
				playingFrom="The Midnight"
			/>
		</div>
	)
}
