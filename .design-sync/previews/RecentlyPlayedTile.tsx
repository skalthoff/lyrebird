import { RecentlyPlayedTile } from '@lyrebird/design-system'

export const Carousel = () => (
	<div style={{ display: 'flex', gap: 16 }}>
		<RecentlyPlayedTile title="Get Lucky" artist="Daft Punk" artworkSeed="Random Access Memories" />
		<RecentlyPlayedTile title="Sunset" artist="The Midnight" artworkSeed="Endless Summer" />
		<RecentlyPlayedTile title="Reckoner" artist="Radiohead" artworkSeed="In Rainbows" />
	</div>
)

export const Hovered = () => (
	<RecentlyPlayedTile title="Instant Crush" artist="Daft Punk" artworkSeed="Random Access Memories" hovered />
)

export const LongMetadata = () => (
	<RecentlyPlayedTile
		title="Such Great Heights (Acoustic Version)"
		artist="The Postal Service"
		artworkSeed="Give Up"
	/>
)
