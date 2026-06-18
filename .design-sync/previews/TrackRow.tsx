import { TrackRow } from '@lyrebird/design-system'

export const States = () => (
	<div style={{ display: 'flex', flexDirection: 'column', gap: 2, width: '100%', maxWidth: 560 }}>
		<TrackRow number={1} title="Sunset" artist="The Midnight" duration="4:21" format="FLAC" bitrateKbps={1411} />
		<TrackRow number={2} title="Vampires" artist="The Midnight" duration="3:58" active playing />
		<TrackRow number={3} title="Lost Boy" artist="The Midnight" duration="5:02" favorite />
		<TrackRow number={4} title="Comeback Kid" artist="The Midnight" duration="3:44" selected hovered />
	</div>
)
