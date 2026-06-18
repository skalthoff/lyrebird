import { PlaylistCard } from '@lyrebird/design-system'

export const Grid = () => (
	<div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, width: '100%' }}>
		<PlaylistCard title="Synthwave Essentials" subtitle="42 songs" />
		<PlaylistCard title="Liked Songs" subtitle="318 songs" isPrivate />
		<PlaylistCard title="Focus Flow" subtitle="64 songs" />
		<PlaylistCard title="New Playlist" subtitle="Empty" isPrivate />
	</div>
)

export const Hovered = () => (
	<div style={{ width: 220 }}>
		<PlaylistCard title="Late Night Drive" subtitle="27 songs" hovered />
	</div>
)

export const PrivateHovered = () => (
	<div style={{ width: 220 }}>
		<PlaylistCard title="Demos & Voice Memos" subtitle="9 songs" isPrivate hovered />
	</div>
)

export const Mosaic = () => (
	<div style={{ width: 220 }}>
		<PlaylistCard
			title="Decades Mix"
			subtitle="120 songs"
			mosaicSeeds={['Daft Punk', 'Tame Impala', 'Boards of Canada', 'Aphex Twin']}
		/>
	</div>
)
