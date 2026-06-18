import { SidebarSection, SidebarItem, SidebarPlaylistRow } from '@lyrebird/design-system'

export const LibrarySection = () => (
	<div style={{ width: 232 }}>
		<SidebarSection title="Your Library">
			<SidebarItem icon="heart" label="Favorites" compact />
			<SidebarItem icon="album" label="Albums" badge="20,060" compact plain />
			<SidebarItem icon="user" label="Artists" badge="3,839" compact plain />
		</SidebarSection>
	</div>
)

export const PlaylistsSection = () => (
	<div style={{ width: 232 }}>
		<SidebarSection title="Playlists" compact>
			<SidebarPlaylistRow name="Late Night Drive" selected />
			<SidebarPlaylistRow name="Focus Flow" />
			<SidebarPlaylistRow name="Synthwave Essentials" private />
		</SidebarSection>
	</div>
)
