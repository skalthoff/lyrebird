import { NowPlaying } from '@lyrebird/design-system'

const QUEUE = [
	{ title: 'Vampires', artist: 'The Midnight', artworkSeed: 'Vampires' },
	{ title: 'Lost Boy', artist: 'The Midnight', artworkSeed: 'Lost Boy' },
	{ title: 'Brooklyn. Friday. Love.', artist: 'The Midnight', artworkSeed: 'Brooklyn' },
	{ title: 'Days of Thunder', artist: 'The Midnight', artworkSeed: 'Days of Thunder' },
]

const LYRICS = [
	'Neon lights against the night',
	'Driving down the coast tonight',
	"We're vampires, we don't sleep",
	'Chasing summers we can keep',
	'Headlights on the empty road',
	'Every secret that we hold',
]

export const Playing = () => (
	<div style={{ width: 920 }}>
		<NowPlaying
			title="Vampires"
			artist="The Midnight"
			album="Endless Summer"
			artworkSeed="Vampires"
			isPlaying
			favorite
			shuffle
			repeat="all"
			progress={0.45}
			positionLabel="1:48"
			durationLabel="3:58"
			activeTab="queue"
			factTagline="Played 42 times · FLAC · last played yesterday"
			queueRows={QUEUE}
		/>
	</div>
)

export const LyricsTab = () => (
	<div style={{ width: 920 }}>
		<NowPlaying
			title="Vampires"
			artist="The Midnight"
			album="Endless Summer"
			artworkSeed="Vampires"
			isPlaying
			progress={0.32}
			positionLabel="1:16"
			durationLabel="3:58"
			activeTab="lyrics"
			lyrics={LYRICS}
			activeLyricIndex={2}
		/>
	</div>
)

export const Paused = () => (
	<div style={{ width: 920 }}>
		<NowPlaying
			title="Sunset"
			artist="The Midnight"
			album="Endless Summer"
			artworkSeed="Sunset"
			isPlaying={false}
			repeat="one"
			progress={0.12}
			positionLabel="0:32"
			durationLabel="4:21"
			activeTab="about"
			queueRows={QUEUE}
		/>
	</div>
)
