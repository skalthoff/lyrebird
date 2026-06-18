import {
	Sidebar,
	SidebarItem,
	SidebarSection,
	SidebarPlaylistRow,
	SidebarServerFooter,
} from '@lyrebird/design-system'

/** The full rail composed: primary nav, library stats, and a playlist section. */
export const FullRail = () => (
	<div style={{ height: 720 }}>
		<Sidebar
			footer={{
				serverName: 'music.skalthoff.com',
				connected: true,
				albumCount: 20060,
			}}
		>
			{/* Primary navigation */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 2, padding: '0 10px' }}>
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
				<SidebarPlaylistRow name="Late Night Drive" selected />
				<SidebarPlaylistRow name="Focus Flow" />
				<SidebarPlaylistRow name="Synthwave Essentials" private />
				<SidebarPlaylistRow name="Workout Bangers" />
				<SidebarPlaylistRow name="Rainy Day Jazz" private />
			</SidebarSection>

			{/* Smart playlists — gear glyph, rule-driven */}
			<SidebarSection title="Smart Playlists" compact>
				<SidebarPlaylistRow name="Recently Added" smart />
				<SidebarPlaylistRow name="Most Played" smart />
			</SidebarSection>
		</Sidebar>
	</div>
)

/** Navigation rows in isolation, sweeping selected / hover / badge states. */
export const NavStates = () => (
	<div style={{ width: 232, display: 'flex', flexDirection: 'column', gap: 2 }}>
		<SidebarItem icon="home" label="Home" selected />
		<SidebarItem icon="list" label="Library" />
		<SidebarItem icon="compass" label="Discover" hovered />
		<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
		<SidebarItem icon="user" label="Artists" badge="3,839" compact plain />
	</div>
)

/** Playlist rows in isolation: active, private (lock), and a smart row. */
export const PlaylistRows = () => (
	<div style={{ width: 232, display: 'flex', flexDirection: 'column', gap: 0 }}>
		<SidebarPlaylistRow name="Late Night Drive" selected />
		<SidebarPlaylistRow name="Focus Flow" hovered />
		<SidebarPlaylistRow name="Synthwave Essentials" private />
		<SidebarPlaylistRow name="Most Played" smart />
	</div>
)

/** The server footer in both reachability states. */
export const Footer = () => (
	<div style={{ width: 252, display: 'flex', flexDirection: 'column', gap: 12 }}>
		<SidebarServerFooter connected serverName="music.skalthoff.com" albumCount={20060} />
		<SidebarServerFooter connected={false} serverName="home-nas.local" />
	</div>
)
