import { TrackListRow } from '@lyrebird/design-system'

export const States = () => (
	<div style={{ display: 'flex', flexDirection: 'column', gap: 2, width: '100%', maxWidth: 720 }}>
		<TrackListRow
			title="Midnight City"
			artist="M83"
			album="Hurry Up, We're Dreaming"
			duration="4:03"
			format="FLAC"
			bitrateKbps={1411}
		/>
		<TrackListRow
			title="Nightcall"
			artist="Kavinsky"
			album="OutRun"
			duration="4:18"
			format="MP3"
			bitrateKbps={320}
			active
			playing
		/>
		<TrackListRow
			title="A Real Hero"
			artist="College & Electric Youth"
			album="Drive (Original Motion Picture Soundtrack)"
			duration="4:27"
			format="AAC"
			favorite
		/>
		<TrackListRow
			title="Resonance"
			artist="HOME"
			album="Odyssey"
			duration="3:32"
			format="FLAC"
			bitrateKbps={1058}
			selected
			hovered
		/>
	</div>
)

export const Hovered = () => (
	<div style={{ width: '100%', maxWidth: 720 }}>
		<TrackListRow
			title="Sunset"
			artist="The Midnight"
			album="Endless Summer"
			duration="4:21"
			format="FLAC"
			bitrateKbps={1411}
			playCountLabel="42 plays"
			hovered
		/>
	</div>
)

export const Transcoding = () => (
	<div style={{ width: '100%', maxWidth: 720 }}>
		<TrackListRow
			title="Bloom"
			artist="ODESZA"
			album="In Return"
			duration="3:44"
			format="OGG"
			willTranscode
		/>
	</div>
)

export const Compact = () => (
	<div style={{ display: 'flex', flexDirection: 'column', gap: 1, width: '100%', maxWidth: 720 }}>
		<TrackListRow
			title="Genesis"
			artist="Grimes"
			album="Visions"
			duration="4:15"
			format="FLAC"
			density="compact"
		/>
		<TrackListRow
			title="Oblivion"
			artist="Grimes"
			album="Visions"
			duration="4:11"
			format="FLAC"
			density="compact"
			active
			playing
		/>
		<TrackListRow
			title="Skin"
			artist="Grimes"
			album="Visions"
			duration="6:09"
			format="FLAC"
			density="compact"
			selected
			hovered
		/>
	</div>
)
