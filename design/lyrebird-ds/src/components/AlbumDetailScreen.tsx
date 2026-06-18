import { Sidebar, SidebarItem, SidebarSection, SidebarPlaylistRow } from './Sidebar'
import { PlayerBar } from './PlayerBar'
import { Artwork } from './Artwork'
import { TrackRow } from './TrackRow'
import { Button } from './Button'
import { IconButton } from './IconButton'
import { Icon } from './Icon'

/**
 * One example track in the album tracklist. A trimmed-down stand-in for the
 * Swift `Track` model — only the fields the row renders.
 */
interface ExampleTrack {
	number: number
	title: string
	artist: string
	duration: string
	format?: string
	bitrateKbps?: number
	active?: boolean
	playing?: boolean
	favorite?: boolean
}

/**
 * The canonical example album used by the showcase. Mirrors the shape the
 * Swift `AlbumDetailView` resolves from `AppModel` (artwork seed, title,
 * artist, year, aggregate stats) plus the flat tracklist it renders.
 */
const ALBUM = {
	title: 'Endless Summer',
	artist: 'The Midnight',
	artworkSeed: 'Endless Summer',
	year: 2016,
	songCount: 11,
	duration: '54 min',
}

/**
 * Twelve realistic tracks (one active/playing) for the example tracklist.
 * Durations + formats are literal so the row's `FormatBadge` + tabular
 * duration column read like the shipping screen.
 */
const TRACKS: ExampleTrack[] = [
	{ number: 1, title: 'Sunset', artist: 'The Midnight', duration: '4:21', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 2, title: 'Gloria', artist: 'The Midnight', duration: '5:09', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 3, title: 'Vampires', artist: 'The Midnight', duration: '3:58', format: 'FLAC', bitrateKbps: 1411, active: true, playing: true },
	{ number: 4, title: 'Endless Summer', artist: 'The Midnight', duration: '4:47', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 5, title: 'Jason', artist: 'The Midnight', duration: '4:33', format: 'FLAC', bitrateKbps: 1411, favorite: true },
	{ number: 6, title: 'Springtime', artist: 'The Midnight feat. Nikki Flores', duration: '4:58', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 7, title: 'Crystalline', artist: 'The Midnight', duration: '4:12', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 8, title: 'Synthetic', artist: 'The Midnight', duration: '5:24', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 9, title: 'Lost Boy', artist: 'The Midnight', duration: '5:02', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 10, title: 'Daytona', artist: 'The Midnight', duration: '3:47', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 11, title: 'Memories', artist: 'The Midnight', duration: '4:30', format: 'FLAC', bitrateKbps: 1411 },
	{ number: 12, title: 'The Comeback Kid', artist: 'The Midnight', duration: '3:44', format: 'FLAC', bitrateKbps: 1411 },
]

export interface AlbumDetailScreenProps {
	/**
	 * Whether the album is favorited — drives the heart `IconButton` in the
	 * header CTA row (filled + accent when true). Default false.
	 */
	favorite?: boolean
}

/**
 * A full-window **Album Detail** example screen, composed entirely from the
 * shipping design-system components. It mirrors the live SwiftUI
 * `AlbumDetailView`: the same app shell (left `Sidebar` rail, a search-pill
 * toolbar, a bottom `PlayerBar`) wrapping the album body — a hero header
 * (large `Artwork` + title / artist / "year · N songs · duration" meta + a
 * Play / Shuffle / favorite CTA row) over a numbered `TrackRow` list with the
 * current track shown active/playing.
 *
 * Presentational only — static example data, no `AppModel` or core FFI. This
 * is the design-system's reference "what a real page looks like" surface, the
 * peer of the SwiftUI screen the mirror tracks.
 */
export function AlbumDetailScreen({ favorite = false }: AlbumDetailScreenProps) {
	return (
		// Window shell: column [ row: Sidebar | content ] + PlayerBar pinned bottom.
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				width: '100%',
				height: '100%',
				minHeight: 0,
				overflow: 'hidden',
				borderRadius: 'var(--lyr-radius-window)',
				background: 'var(--lyr-bg)',
				fontFamily: 'var(--lyr-font)',
				boxShadow: 'var(--lyr-shadow-window)',
			}}
		>
			{/* ── Upper region: sidebar rail + main content column ── */}
			<div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
				<Sidebar
					footer={{
						serverName: 'music.skalthoff.com',
						connected: true,
						albumCount: 20060,
					}}
				>
					<div style={{ display: 'flex', flexDirection: 'column', gap: 2, padding: '0 10px' }}>
						<SidebarItem icon="home" label="Home" />
						<SidebarItem icon="list" label="Library" selected />
						<SidebarItem icon="compass" label="Discover" />
						<SidebarItem icon="radio" label="Radio" />
						<SidebarItem icon="search" label="Search" />
					</div>

					<SidebarSection title="Your Library">
						<SidebarItem icon="heart" label="Favorites" compact />
						<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
						<SidebarItem icon="user" label="Artists" badge="3,839" compact plain />
						<SidebarItem icon="list" label="Playlists" badge={78} compact plain />
					</SidebarSection>

					<SidebarSection title="Playlists" compact>
						<SidebarPlaylistRow name="Late Night Drive" />
						<SidebarPlaylistRow name="Synthwave Essentials" />
						<SidebarPlaylistRow name="Focus Flow" />
						<SidebarPlaylistRow name="Rainy Day Jazz" private />
					</SidebarSection>
				</Sidebar>

				{/* Main content column: toolbar over the scrolling album body. */}
				<div
					style={{
						flex: 1,
						minWidth: 0,
						display: 'flex',
						flexDirection: 'column',
						background: 'var(--lyr-bg)',
					}}
				>
					{/* Toolbar: search pill + bottom hairline. */}
					<div
						style={{
							display: 'flex',
							alignItems: 'center',
							gap: 12,
							padding: '12px 32px',
							borderBottom: '1px solid var(--lyr-border)',
							flexShrink: 0,
						}}
					>
						<div
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 8,
								flex: 1,
								maxWidth: 420,
								padding: '7px 12px',
								borderRadius: 999,
								background: 'var(--lyr-surface)',
								border: '1px solid var(--lyr-border)',
							}}
						>
							<Icon name="search" size={13} color="var(--lyr-ink-3)" />
							<span style={{ fontSize: 13, fontWeight: 500, color: 'var(--lyr-ink-3)' }}>
								Search your library…
							</span>
						</div>
						<span style={{ flex: 1 }} />
						<IconButton name="grid" label="Grid view" />
						<IconButton name="list" label="List view" active />
					</div>

					{/* Scrolling album body: hero header → CTA row → tracklist. */}
					<div style={{ flex: 1, minHeight: 0, overflowY: 'auto' }}>
						{/* ── Album hero header ── */}
						<div
							style={{
								display: 'flex',
								alignItems: 'flex-end',
								gap: 36,
								padding: '44px 40px 28px',
								borderBottom: '1px solid var(--lyr-border)',
							}}
						>
							<Artwork seed={ALBUM.artworkSeed} size={232} radius={6} />
							<div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0, flex: 1 }}>
								<span
									style={{
										fontSize: 11,
										fontWeight: 700,
										color: 'var(--lyr-accent)',
										letterSpacing: 3,
									}}
								>
									{`LONG-PLAYER · ${ALBUM.year}`}
								</span>
								<h1
									style={{
										margin: 0,
										fontSize: 56,
										fontWeight: 900,
										fontStyle: 'italic',
										letterSpacing: -1.5,
										lineHeight: 1.02,
										color: 'var(--lyr-ink)',
									}}
								>
									{ALBUM.title}
								</h1>
								{/* Artist link — accent-underlined, mirrors the Swift artistNameLine. */}
								<button
									type="button"
									aria-label={`Go to artist ${ALBUM.artist}`}
									title="Open the artist page"
									style={{
										alignSelf: 'flex-start',
										marginTop: 2,
										padding: 0,
										border: 'none',
										background: 'transparent',
										cursor: 'pointer',
										fontFamily: 'var(--lyr-font)',
										fontSize: 20,
										fontWeight: 600,
										color: 'var(--lyr-ink)',
										borderBottom: '2px solid var(--lyr-accent)',
										lineHeight: 1.3,
									}}
								>
									{`by ${ALBUM.artist}`}
								</button>
								{/* Meta line: year · N songs · duration. */}
								<span
									style={{
										marginTop: 12,
										fontSize: 13,
										fontWeight: 500,
										color: 'var(--lyr-ink-2)',
										fontVariantNumeric: 'tabular-nums',
									}}
								>
									{`${ALBUM.year} · ${ALBUM.songCount} songs · ${ALBUM.duration}`}
								</span>

								{/* CTA row: Play (primary) · Shuffle (secondary) · favorite. */}
								<div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 18 }}>
									<Button variant="primary" icon="play">
										Play
									</Button>
									<Button variant="secondary" icon="shuffle">
										Shuffle
									</Button>
									<IconButton
										name="heart"
										label={favorite ? 'Remove from favorites' : 'Add to favorites'}
										hitSize={36}
										size={16}
										fill={favorite}
										tint={favorite ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'}
										style={{ border: '1px solid var(--lyr-border)', borderRadius: 999 }}
									/>
									<IconButton
										name="plus"
										label="Add to playlist"
										hitSize={36}
										size={16}
										style={{ border: '1px solid var(--lyr-border)', borderRadius: 999 }}
									/>
									<span style={{ flex: 1 }} />
									<IconButton
										name="dots"
										label="More actions"
										hitSize={36}
										size={16}
										style={{ border: '1px solid var(--lyr-border)', borderRadius: 999 }}
									/>
								</div>
							</div>
						</div>

						{/* ── Numbered tracklist ── */}
						<div style={{ padding: '12px 32px 40px' }}>
							{TRACKS.map((t) => (
								<TrackRow
									key={t.number}
									number={t.number}
									title={t.title}
									artist={t.artist}
									duration={t.duration}
									format={t.format}
									bitrateKbps={t.bitrateKbps}
									active={t.active}
									playing={t.playing}
									favorite={t.favorite}
								/>
							))}
						</div>
					</div>
				</div>
			</div>

			{/* ── Bottom transport bar ── */}
			<PlayerBar
				title="Vampires"
				artist="The Midnight"
				album="Endless Summer"
				artworkSeed="Endless Summer"
				isPlaying
				shuffle
				repeat="all"
				positionLabel="1:48"
				durationLabel="3:58"
				progress={0.45}
				volume={0.7}
				playingFrom="Endless Summer"
			/>
		</div>
	)
}
