import { AlbumCard } from '@lyrebird/design-system'

export const Grid = () => (
	<div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
		<AlbumCard title="Random Access Memories" artist="Daft Punk" year={2013} />
		<AlbumCard title="Endless Summer" artist="The Midnight" year={2016} />
		<AlbumCard title="In Rainbows" artist="Radiohead" year={2007} />
	</div>
)

export const Hovered = () => (
	<AlbumCard title="Discovery" artist="Daft Punk" year={2001} hovered />
)

export const LongTitle = () => (
	<AlbumCard
		title="Everything Was Beautiful and Nothing Hurt"
		artist="Moby"
		year={2018}
	/>
)

export const ArtistOnly = () => (
	<AlbumCard title="Currents" artist="Tame Impala" />
)
