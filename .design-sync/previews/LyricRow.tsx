import { LyricRow } from '@lyrebird/design-system'

export const Lines = () => (
	<div style={{ width: '100%', maxWidth: 480, display: 'flex', flexDirection: 'column', gap: 8 }}>
		<LyricRow text="Streetlights fade to amethyst" />
		<LyricRow text="Every echo finds its way back home" active />
		<LyricRow text="We were never meant to drift like this" />
	</div>
)
