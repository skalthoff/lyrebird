import { IconButton } from '@lyrebird/design-system'

export const Transport = () => (
	<div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
		<IconButton name="shuffle" label="Shuffle" active />
		<IconButton name="previous" label="Previous" fill size={16} />
		<IconButton name="next" label="Next" fill size={16} />
		<IconButton name="repeat" label="Repeat" />
	</div>
)

export const Toggles = () => (
	<div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
		<IconButton name="heart" label="Favorite (on)" active fill />
		<IconButton name="heart" label="Favorite (off)" />
		<IconButton name="queue" label="Queue" />
		<IconButton name="cast" label="AirPlay" />
	</div>
)
