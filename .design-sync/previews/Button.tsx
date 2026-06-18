import { Button } from '@lyrebird/design-system'

export const Variants = () => (
	<div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
		<Button variant="primary" icon="play">
			Play
		</Button>
		<Button variant="secondary" icon="shuffle">
			Shuffle
		</Button>
		<Button variant="ghost">Read more</Button>
	</div>
)

export const WithIcon = () => (
	<div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
		<Button variant="secondary" icon="radio">
			Radio
		</Button>
		<Button variant="secondary" icon="plus">
			Add to Playlist
		</Button>
		<Button variant="secondary" icon="download">
			Download
		</Button>
	</div>
)

export const Sizes = () => (
	<div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
		<Button variant="primary" size="md" icon="play">
			Play
		</Button>
		<Button variant="secondary" size="sm" icon="plus">
			Add to Playlist
		</Button>
	</div>
)

export const FullWidth = () => (
	<div style={{ width: 320 }}>
		<Button variant="primary" fullWidth>
			Connect
		</Button>
	</div>
)

export const Disabled = () => (
	<div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
		<Button variant="primary" icon="play" disabled>
			Play
		</Button>
		<Button variant="secondary" icon="shuffle" disabled>
			Shuffle
		</Button>
	</div>
)
