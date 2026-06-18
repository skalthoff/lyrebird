import { Banner } from '@lyrebird/design-system'

export const Offline = () => (
	<Banner
		tone="error"
		message="You're offline — showing downloaded music"
		actionLabel="Retry"
		onAction={() => {}}
	/>
)

export const ServerUnreachable = () => (
	<Banner
		tone="warning"
		message="Couldn't reach music.skalthoff.com — trying again…"
		actionLabel="Retry"
		onAction={() => {}}
	/>
)

export const Info = () => (
	<Banner
		tone="info"
		message="Syncing your library — 18,420 of 20,060 albums"
	/>
)

export const Dismissible = () => (
	<Banner
		tone="warning"
		message="Some tracks failed to download and will retry on Wi-Fi"
		actionLabel="Retry"
		onAction={() => {}}
		onDismiss={() => {}}
	/>
)
