import { MiniPlayer } from '@lyrebird/design-system'

export const RestingPlaying = () => (
	<MiniPlayer
		title="Midnight City"
		artist="M83"
		artworkSeed="Hurry Up, We're Dreaming"
		isPlaying
		progress={0.42}
	/>
)

export const HoverControls = () => (
	<MiniPlayer
		title="Nightcall"
		artist="Kavinsky"
		artworkSeed="OutRun"
		isPlaying
		progress={0.61}
		favorite
		showControls
	/>
)

export const PausedControls = () => (
	<MiniPlayer
		title="A Real Hero"
		artist="College & Electric Youth"
		artworkSeed="Drive Soundtrack"
		isPlaying={false}
		progress={0.18}
		showControls
	/>
)
