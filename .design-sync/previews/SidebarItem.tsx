import { SidebarItem } from '@lyrebird/design-system'

export const NavStates = () => (
	<div style={{ width: 232, display: 'flex', flexDirection: 'column', gap: 2 }}>
		<SidebarItem icon="home" label="Home" selected />
		<SidebarItem icon="list" label="Library" />
		<SidebarItem icon="compass" label="Discover" hovered />
		<SidebarItem icon="radio" label="Radio" />
		<SidebarItem icon="search" label="Search" />
	</div>
)

export const WithCounts = () => (
	<div style={{ width: 232, display: 'flex', flexDirection: 'column', gap: 2 }}>
		<SidebarItem icon="heart" label="Favorites" compact />
		<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
		<SidebarItem icon="user" label="Artists" badge="3,839" compact plain />
		<SidebarItem icon="list" label="Playlists" badge={78} compact plain />
	</div>
)
