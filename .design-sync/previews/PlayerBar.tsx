import { PlayerBar } from '@lyrebird/design-system'

export const Playing = () => (
	<div style={{ width: '100%' }}>
		<PlayerBar
			title="Vampires"
			artist="The Midnight"
			album="Endless Summer"
			artworkSeed="Vampires"
			isPlaying
			favorite
			shuffle
			repeat="all"
			positionLabel="1:48"
			durationLabel="3:58"
			progress={0.45}
			volume={0.7}
			playingFrom="Synthwave Essentials"
		/>
	</div>
)

export const Paused = () => (
	<div style={{ width: '100%' }}>
		<PlayerBar
			title="Sunset"
			artist="The Midnight"
			album="Endless Summer"
			artworkSeed="Sunset"
			isPlaying={false}
			repeat="one"
			positionLabel="0:32"
			durationLabel="4:21"
			progress={0.12}
			volume={0.55}
			playingFrom="Endless Summer"
		/>
	</div>
)

export const NothingPlaying = () => (
	<div style={{ width: '100%' }}>
		<PlayerBar progress={0} volume={0.7} />
	</div>
)
