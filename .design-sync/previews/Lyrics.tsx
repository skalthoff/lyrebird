import { Lyrics } from '@lyrebird/design-system'

const syncedLines = [
	{ text: 'Hold the line until the morning' },
	{ text: 'Streetlights fade to amethyst' },
	{ text: 'Every echo finds its way back home' },
	{ text: 'We were never meant to drift like this' },
	{ text: 'So sing it one more time' },
	{ text: 'Let the chorus carry on' },
]

const staticLines = [
	{ text: 'Quiet rooms and open windows' },
	{ text: 'Coffee going cold beside the radio' },
	{ text: 'An afternoon that never asks for more' },
	{ text: 'Just the hum of something slow' },
]

export const Synced = () => (
	<div style={{ width: '100%', maxWidth: 480 }}>
		<Lyrics lines={syncedLines} activeIndex={2} synced />
	</div>
)

export const SyncedReduceMotion = () => (
	<div style={{ width: '100%', maxWidth: 480 }}>
		<Lyrics lines={syncedLines} activeIndex={4} synced reduceMotion />
	</div>
)

export const Static = () => (
	<div style={{ width: '100%', maxWidth: 480 }}>
		<Lyrics lines={staticLines} synced={false} />
	</div>
)

export const Empty = () => (
	<div style={{ width: '100%', maxWidth: 480 }}>
		<Lyrics lines={[]} />
	</div>
)
