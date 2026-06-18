import { SidebarServerFooter } from '@lyrebird/design-system'

export const Reachability = () => (
	<div style={{ width: 252, display: 'flex', flexDirection: 'column', gap: 12 }}>
		<SidebarServerFooter connected serverName="music.skalthoff.com" albumCount={20060} />
		<SidebarServerFooter connected={false} serverName="home-nas.local" />
	</div>
)
