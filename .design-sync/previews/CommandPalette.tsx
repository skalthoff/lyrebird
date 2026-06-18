import { CommandPalette } from '@lyrebird/design-system'

export const QueryWithResults = () => (
	<CommandPalette
		query="vamp"
		selectedIndex={2}
		results={[
			{
				kind: 'artist',
				artworkSeed: 'The Hollow Coast',
				title: 'The Hollow Coast',
				subtitle: 'Artist · 4 albums · 52 songs',
			},
			{
				kind: 'album',
				artworkSeed: 'Vampires of the City',
				title: 'Vampires of the City',
				subtitle: 'Album · The Hollow Coast',
			},
			{
				kind: 'track',
				artworkSeed: 'Vampires',
				title: 'Vampires',
				subtitle: 'Track · The Hollow Coast · Vampires of the City',
			},
			{
				kind: 'action',
				icon: 'play',
				title: 'Play Vampires',
				subtitle: 'Action',
			},
			{
				kind: 'action',
				icon: 'shuffle',
				title: 'Toggle Shuffle',
				subtitle: 'Action',
				shortcut: '⌘⇧S',
			},
		]}
	/>
)

export const EmptyQueryActions = () => (
	<CommandPalette
		query=""
		selectedIndex={0}
		results={[
			{ kind: 'action', icon: 'library', title: 'Go to Library', subtitle: 'Action', pinned: true },
			{ kind: 'action', icon: 'heart', title: 'Go to Favorites', subtitle: 'Action', shortcut: '⌘F' },
			{ kind: 'action', icon: 'shuffle', title: 'Toggle Shuffle', subtitle: 'Action', shortcut: '⌘⇧S' },
			{ kind: 'action', icon: 'queue', title: 'Clear Queue', subtitle: 'Action' },
			{ kind: 'action', icon: 'settings', title: 'Open Preferences', subtitle: 'Action', shortcut: '⌘,' },
		]}
	/>
)

export const Searching = () => (
	<CommandPalette
		query="the wayfarers"
		searching
		selectedIndex={1}
		results={[
			{
				kind: 'artist',
				artworkSeed: 'The Wayfarers',
				title: 'The Wayfarers',
				subtitle: 'Artist · 7 albums · 94 songs',
			},
			{
				kind: 'album',
				artworkSeed: 'Distant Signal',
				title: 'Distant Signal',
				subtitle: 'Album · The Wayfarers',
			},
			{
				kind: 'track',
				artworkSeed: 'Northbound',
				title: 'Northbound',
				subtitle: 'Track · The Wayfarers · Distant Signal',
			},
		]}
	/>
)

export const NoMatches = () => (
	<CommandPalette query="zzzxyq" results={[]} />
)
