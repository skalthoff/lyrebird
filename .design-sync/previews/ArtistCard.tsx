import { ArtistCard } from '@lyrebird/design-system'

export const Grid = () => (
	<div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
		<ArtistCard name="The Midnight" subtitle="8 albums" />
		<ArtistCard name="Daft Punk" subtitle="6 albums" />
		<ArtistCard name="Miles Davis" subtitle="124 songs" />
	</div>
)

export const Hovered = () => <ArtistCard name="Tycho" subtitle="5 albums" hovered />

export const NoCount = () => <ArtistCard name="Bonobo" />
