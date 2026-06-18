import { HomeQuickTile } from '@lyrebird/design-system'

export const QuickRow = () => (
	<div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: 320 }}>
		<HomeQuickTile title="Liked Songs" subtitle="438 songs" seed="Liked Songs" />
		<HomeQuickTile title="Discovery" subtitle="Daft Punk" seed="Discovery" />
		<HomeQuickTile title="Late Night Drive" subtitle="Playlist" seed="Late Night Drive" />
	</div>
)

export const Hovered = () => (
	<div style={{ width: 320 }}>
		<HomeQuickTile title="In Rainbows" subtitle="Radiohead" seed="In Rainbows" hovered />
	</div>
)

export const NoSubtitle = () => (
	<div style={{ width: 320 }}>
		<HomeQuickTile title="On Repeat" seed="On Repeat" />
	</div>
)

export const LongTitle = () => (
	<div style={{ width: 320 }}>
		<HomeQuickTile
			title="Everything Was Beautiful and Nothing Hurt"
			subtitle="Moby · 2018"
			seed="Everything Was Beautiful and Nothing Hurt"
		/>
	</div>
)
