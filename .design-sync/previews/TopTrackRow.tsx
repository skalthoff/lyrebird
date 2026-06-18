import { TopTrackRow } from '@lyrebird/design-system'

export const TopTracks = () => (
	<div style={{ display: 'flex', flexDirection: 'column', gap: 2, width: '100%', maxWidth: 560 }}>
		<TopTrackRow
			rank={1}
			title="Midnight City"
			album="Hurry Up, We're Dreaming"
			artworkSeed="Midnight City"
			playCount={342}
			duration="4:03"
			favorite
		/>
		<TopTrackRow
			rank={2}
			title="Reunion"
			album="Hurry Up, We're Dreaming"
			artworkSeed="Reunion"
			playCount={128}
			duration="5:01"
			active
			playing
		/>
		<TopTrackRow
			rank={3}
			title="Steve McQueen"
			album="Junk"
			artworkSeed="Steve McQueen"
			playCount={64}
			duration="3:46"
		/>
		<TopTrackRow
			rank={4}
			title="Wait"
			album="Hurry Up, We're Dreaming"
			artworkSeed="Wait"
			playCount={1}
			duration="3:13"
		/>
		<TopTrackRow
			rank={5}
			title="Outro"
			artist="M83"
			artworkSeed="Outro"
			playCount={0}
			duration="4:42"
			hovered
		/>
	</div>
)
