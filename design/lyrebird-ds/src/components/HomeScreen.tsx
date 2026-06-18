import { Sidebar } from './Sidebar'
import { SidebarItem } from './Sidebar'
import { SidebarSection } from './Sidebar'
import { SidebarPlaylistRow } from './Sidebar'
import { PlayerBar } from './PlayerBar'
import { Shelf } from './Shelf'
import { AlbumCard } from './AlbumCard'
import { ArtistCard } from './ArtistCard'
import { PlaylistCard } from './PlaylistCard'
import { HomeQuickTile } from './HomeQuickTile'
import { RecentlyPlayedTile } from './RecentlyPlayedTile'
import { Icon } from './Icon'

/**
 * A self-contained, full-app Home window — the composition reference for the
 * Lyrebird Desktop "Home" screen, built entirely from shipped design-system
 * components. Mirrors `macos/Sources/Lyrebird/Screens/HomeView.swift`: a fixed
 * left rail (nav + library stats + playlists), a top toolbar with a centered
 * search pill, a scrolling "content river" of shelves (greeting → Recently
 * Played → Artists You Love → Jump Back In → Made For You → Your Playlists →
 * Recently Added → Favorites), and the persistent bottom `PlayerBar`.
 *
 * Presentational only — every shelf is filled with realistic static content
 * (The Midnight, Daft Punk, Tame Impala, …). There is no data layer; this is a
 * layout reference, so the shelves render fixed cards rather than reading a
 * model. Sized for a ~1240×800 window (sidebar 252px + content + 78px player).
 */
export function HomeScreen() {
	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				width: '100%',
				height: '100%',
				background: 'var(--lyr-bg)',
				color: 'var(--lyr-ink)',
				fontFamily: 'var(--lyr-font)',
				overflow: 'hidden',
			}}
		>
			{/* ── Upper region: sidebar + content column ── */}
			<div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
				{/* Left rail — primary nav, library stats, playlists. Mirrors the
				    Sidebar FullRail preview: Home selected, aggregate counts, a
				    Playlists section with a "+" affordance, and the server footer. */}
				<Sidebar
					footer={{
						serverName: 'music.skalthoff.com',
						connected: true,
						albumCount: 20060,
					}}
				>
					{/* Primary navigation */}
					<div
						style={{
							display: 'flex',
							flexDirection: 'column',
							gap: 2,
							padding: '0 10px',
						}}
					>
						<SidebarItem icon="home" label="Home" selected />
						<SidebarItem icon="list" label="Library" />
						<SidebarItem icon="compass" label="Discover" />
						<SidebarItem icon="radio" label="Radio" />
						<SidebarItem icon="search" label="Search" />
					</div>

					{/* Your Library — favorites + aggregate stat counts */}
					<SidebarSection title="Your Library">
						<SidebarItem icon="heart" label="Favorites" compact />
						<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
						<SidebarItem icon="user" label="Artists" badge="3,839" compact plain />
						<SidebarItem icon="list" label="Playlists" badge={78} compact plain />
					</SidebarSection>

					{/* Playlists list with a "+" affordance */}
					<SidebarSection
						title="Playlists"
						compact
						trailing={
							<button
								type="button"
								aria-label="New Playlist"
								title="New Playlist (⌘N)"
								style={{
									width: 18,
									height: 18,
									display: 'inline-flex',
									alignItems: 'center',
									justifyContent: 'center',
									padding: 0,
									border: 'none',
									background: 'transparent',
									cursor: 'pointer',
									color: 'var(--lyr-ink-3)',
									fontSize: 14,
									fontWeight: 700,
									lineHeight: 1,
								}}
							>
								+
							</button>
						}
					>
						<SidebarPlaylistRow name="Late Night Drive" />
						<SidebarPlaylistRow name="Synthwave Essentials" selected />
						<SidebarPlaylistRow name="Focus Flow" />
						<SidebarPlaylistRow name="Workout Bangers" private />
						<SidebarPlaylistRow name="Rainy Day Jazz" private />
					</SidebarSection>

					{/* Smart playlists — gear glyph, rule-driven */}
					<SidebarSection title="Smart Playlists" compact>
						<SidebarPlaylistRow name="Recently Added" smart />
						<SidebarPlaylistRow name="Most Played" smart />
					</SidebarSection>
				</Sidebar>

				{/* ── Content column: toolbar + scrolling shelf river ── */}
				<div
					style={{
						flex: 1,
						minWidth: 0,
						display: 'flex',
						flexDirection: 'column',
					}}
				>
					{/* Toolbar — centered search pill, 1px bottom border, ~52px tall. */}
					<div
						style={{
							height: 52,
							flexShrink: 0,
							display: 'flex',
							alignItems: 'center',
							justifyContent: 'center',
							padding: '0 16px',
							borderBottom: '1px solid var(--lyr-border)',
						}}
					>
						<div
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 8,
								width: 360,
								maxWidth: '50%',
								height: 30,
								padding: '0 12px',
								background: 'var(--lyr-surface)',
								border: '1px solid var(--lyr-border)',
								borderRadius: 6,
								color: 'var(--lyr-ink-3)',
							}}
						>
							<Icon name="search" size={14} color="var(--lyr-ink-3)" />
							<span style={{ fontSize: 13, fontWeight: 500 }}>Search</span>
						</div>
					</div>

					{/* Scrolling body — the Home "content river". */}
					<div
						style={{
							flex: 1,
							minHeight: 0,
							overflowY: 'auto',
							padding: 24,
						}}
					>
						{/* Greeting header (#204) — eyebrow + italic-black h1 + subtitle,
						    with right-aligned Instant Mix / Shuffle All CTAs. */}
						<header
							style={{
								display: 'flex',
								alignItems: 'flex-start',
								gap: 24,
								marginBottom: 28,
							}}
						>
							<div style={{ display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}>
								<span
									style={{
										fontSize: 12,
										fontWeight: 700,
										color: 'var(--lyr-ink-2)',
										letterSpacing: 1.2,
									}}
								>
									IN ROTATION
								</span>
								<h1
									style={{
										margin: 0,
										fontSize: 42,
										fontWeight: 900,
										fontStyle: 'italic',
										color: 'var(--lyr-ink)',
										lineHeight: 1.05,
									}}
								>
									good evening, soren
								</h1>
								<span style={{ fontSize: 14, fontWeight: 500, color: 'var(--lyr-ink-2)' }}>
									Pick up where you left off, or start an{' '}
									<span
										style={{
											fontWeight: 600,
											fontStyle: 'italic',
											color: 'var(--lyr-accent)',
										}}
									>
										instant mix
									</span>{' '}
									seeded from your library.
								</span>
							</div>

							<div style={{ flex: 1, minWidth: 16 }} />

							{/* CTAs — primary "Instant Mix" (ink fill) + ghost "Shuffle All" */}
							<div style={{ display: 'flex', gap: 10, paddingTop: 22, flexShrink: 0 }}>
								<button
									type="button"
									style={{
										display: 'inline-flex',
										alignItems: 'center',
										gap: 8,
										padding: '12px 18px',
										border: 'none',
										borderRadius: 999,
										background: 'var(--lyr-ink)',
										color: 'var(--lyr-bg)',
										fontFamily: 'var(--lyr-font)',
										fontSize: 13,
										fontWeight: 700,
										cursor: 'pointer',
										boxShadow: '0 6px 12px color-mix(in srgb, var(--lyr-ink) 18%, transparent)',
									}}
								>
									<Icon name="star" size={14} color="var(--lyr-bg)" fill />
									Instant Mix
								</button>
								<button
									type="button"
									style={{
										display: 'inline-flex',
										alignItems: 'center',
										gap: 8,
										padding: '12px 16px',
										border: '1px solid var(--lyr-border-strong)',
										borderRadius: 999,
										background: 'transparent',
										color: 'var(--lyr-ink-2)',
										fontFamily: 'var(--lyr-font)',
										fontSize: 13,
										fontWeight: 600,
										cursor: 'pointer',
									}}
								>
									<Icon name="shuffle" size={13} color="var(--lyr-ink-2)" />
									Shuffle All
								</button>
							</div>
						</header>

						{/* Shelf river — order follows HomeView.swift's section catalog,
						    each shelf a SectionHeader over a horizontal card carousel. */}
						<div style={{ display: 'flex', flexDirection: 'column', gap: 28 }}>
							{/* Recently Played (#206) — track tiles. */}
							<Shelf title="Recently Played" gap={16}>
								<RecentlyPlayedTile title="Vampires" artist="The Midnight" artworkSeed="Endless Summer" />
								<RecentlyPlayedTile title="Get Lucky" artist="Daft Punk" artworkSeed="Random Access Memories" />
								<RecentlyPlayedTile title="The Less I Know the Better" artist="Tame Impala" artworkSeed="Currents" />
								<RecentlyPlayedTile title="Reckoner" artist="Radiohead" artworkSeed="In Rainbows" />
								<RecentlyPlayedTile title="Nightcall" artist="Kavinsky" artworkSeed="OutRun" />
								<RecentlyPlayedTile title="Midnight City" artist="M83" artworkSeed="Hurry Up, We're Dreaming" />
							</Shelf>

							{/* Artists You Love (#207) — favorited artists. */}
							<Shelf
								title="Artists You Love"
								subtitle="The artists you've hearted"
								actionLabel="See All"
								onAction={() => {}}
								gap={12}
							>
								<ArtistCard name="The Midnight" subtitle="6 albums" size={150} />
								<ArtistCard name="Daft Punk" subtitle="8 albums" size={150} />
								<ArtistCard name="Tame Impala" subtitle="4 albums" size={150} />
								<ArtistCard name="Bonobo" subtitle="12 albums" size={150} />
								<ArtistCard name="Khruangbin" subtitle="5 albums" size={150} />
								<ArtistCard name="ODESZA" subtitle="4 albums" size={150} />
							</Shelf>

							{/* Jump Back In (#51) — last-played albums. */}
							<Shelf
								title="Jump Back In"
								subtitle="Pick up where you left off"
								actionLabel="See All"
								onAction={() => {}}
								gap={16}
							>
								<AlbumCard title="Endless Summer" artist="The Midnight" year={2016} />
								<AlbumCard title="Discovery" artist="Daft Punk" year={2001} />
								<AlbumCard title="Currents" artist="Tame Impala" year={2015} />
								<AlbumCard title="In Rainbows" artist="Radiohead" year={2007} />
								<AlbumCard title="Migration" artist="Bonobo" year={2017} />
							</Shelf>

							{/* You Might Like / Made For You (#145) — server-curated artists. */}
							<Shelf
								title="Made For You"
								subtitle="Picks the server thinks you'll love"
								actionLabel="See All"
								onAction={() => {}}
								gap={12}
							>
								<ArtistCard name="Floating Points" subtitle="5 albums" size={150} />
								<ArtistCard name="Jon Hopkins" subtitle="7 albums" size={150} />
								<ArtistCard name="Tycho" subtitle="6 albums" size={150} />
								<ArtistCard name="Boards of Canada" subtitle="5 albums" size={150} />
								<ArtistCard name="Four Tet" subtitle="11 albums" size={150} />
							</Shelf>

							{/* Your Playlists — the user's own playlists. */}
							<Shelf
								title="Your Playlists"
								subtitle="Jump back into a playlist you've made"
								actionLabel="See All"
								onAction={() => {}}
								gap={16}
							>
								<PlaylistCard title="Late Night Drive" subtitle="42 tracks" size={180} />
								<PlaylistCard title="Synthwave Essentials" subtitle="88 tracks" size={180} />
								<PlaylistCard title="Focus Flow" subtitle="61 tracks" size={180} />
								<PlaylistCard title="Rainy Day Jazz" subtitle="35 tracks" isPrivate size={180} />
								<PlaylistCard title="Workout Bangers" subtitle="54 tracks" isPrivate size={180} />
							</Shelf>

							{/* Recently Added (#54) — new arrivals. */}
							<Shelf
								title="Recently Added"
								subtitle="Fresh arrivals in your library"
								actionLabel="See All"
								onAction={() => {}}
								gap={16}
							>
								<AlbumCard title="Blonde" artist="Frank Ocean" year={2016} />
								<AlbumCard title="A Moon Shaped Pool" artist="Radiohead" year={2016} />
								<AlbumCard title="Random Access Memories" artist="Daft Punk" year={2013} />
								<AlbumCard title="Con Todo El Mundo" artist="Khruangbin" year={2018} />
								<AlbumCard title="Settle" artist="Disclosure" year={2013} />
							</Shelf>

							{/* Quick tiles row (#205) — compact "jump straight back" tiles.
							    Rendered as a 3-up grid, matching the Swift quickTilesRow. */}
							<div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
								<span style={{ fontSize: 18, fontWeight: 700, color: 'var(--lyr-ink)' }}>
									On Repeat
								</span>
								<div
									style={{
										display: 'grid',
										gridTemplateColumns: 'repeat(3, 1fr)',
										gap: 10,
									}}
								>
									<HomeQuickTile title="Liked Songs" subtitle="438 songs" seed="Liked Songs" />
									<HomeQuickTile title="Discovery" subtitle="Daft Punk" seed="Discovery" />
									<HomeQuickTile title="Late Night Drive" subtitle="Playlist" seed="Late Night Drive" />
								</div>
							</div>

							{/* Favorites (#55) — a handful of favorite albums. */}
							<Shelf
								title="Favorites"
								subtitle="A handful of the albums you love"
								actionLabel="See All"
								onAction={() => {}}
								gap={16}
							>
								<AlbumCard title="Days of Thunder" artist="The Midnight" year={2018} />
								<AlbumCard title="Lonerism" artist="Tame Impala" year={2012} />
								<AlbumCard title="Homework" artist="Daft Punk" year={1997} />
								<AlbumCard title="OK Computer" artist="Radiohead" year={1997} />
								<AlbumCard title="The North Borders" artist="Bonobo" year={2013} />
							</Shelf>
						</div>
					</div>
				</div>
			</div>

			{/* ── Persistent bottom transport ── */}
			<PlayerBar
				title="Vampires"
				artist="The Midnight"
				album="Endless Summer"
				artworkSeed="Vampires"
				isPlaying
				favorite
				progress={0.45}
				positionLabel="1:48"
				durationLabel="3:58"
				playingFrom="Synthwave Essentials"
				volume={0.7}
			/>
		</div>
	)
}
