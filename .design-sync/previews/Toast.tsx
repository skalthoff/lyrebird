import { Toast } from '@lyrebird/design-system'

export const FailedToLoad = () => (
	<Toast tone="error" message="Failed to load album" onDismiss={() => {}} />
)

export const LibraryError = () => (
	<Toast
		tone="error"
		message="Couldn't load your library. Check the server and try again."
		onDismiss={() => {}}
	/>
)

export const Stalled = () => (
	<Toast tone="error" message="Playback stalled, retrying…" onDismiss={() => {}} />
)
