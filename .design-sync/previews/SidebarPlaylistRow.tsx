import { SidebarPlaylistRow } from '@lyrebird/design-system'

export const Rows = () => (
	<div style={{ width: 232, display: 'flex', flexDirection: 'column', gap: 0 }}>
		<SidebarPlaylistRow name="Late Night Drive" selected />
		<SidebarPlaylistRow name="Focus Flow" hovered />
		<SidebarPlaylistRow name="Synthwave Essentials" private />
		<SidebarPlaylistRow name="Most Played" smart />
	</div>
)
