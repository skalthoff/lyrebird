import { Artwork } from '@lyrebird/design-system'

export const Sizes = () => (
	<div style={{ display: 'flex', gap: 16, alignItems: 'flex-end' }}>
		<Artwork seed="Abbey Road" size={120} />
		<Artwork seed="Kind of Blue" size={80} />
		<Artwork seed="Random Access Memories" size={56} radius={6} />
	</div>
)

export const Artist = () => <Artwork seed="Miles Davis" size={104} shape="circle" />

export const PlaylistLabel = () => (
	<Artwork seed="Liked Songs" size={120} overlayLabel="Liked Songs" />
)
