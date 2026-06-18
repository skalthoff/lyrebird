import { EmptyState } from '@lyrebird/design-system'

export const NoFavorites = () => (
	<EmptyState
		icon="heart"
		title="No favorites yet"
		message="Tap the heart on any song to save it here."
	/>
)

export const NoSearchResults = () => (
	<EmptyState
		icon="search"
		title="No results for 'midnight'"
		message="Check the spelling or try a different song, album, or artist."
	/>
)

export const EmptyPlaylist = () => (
	<EmptyState
		icon="list"
		title="This playlist is empty"
		message="Add tracks from any album or your library to start building it out."
		actionLabel="Add Tracks"
		onAction={() => {}}
	/>
)
