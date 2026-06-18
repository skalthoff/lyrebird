import { QueueInspector } from '@lyrebird/design-system'

export const Playing = () => (
	<QueueInspector
		nowPlaying={{
			id: 'np',
			title: 'Vampires',
			artist: 'The Midnight',
			artworkSeed: 'Endless Summer',
		}}
		positionLabel="1:48"
		durationLabel="3:58"
		progress={0.45}
		upNext={[
			{ id: 'u1', title: 'Sunset', artist: 'The Midnight', duration: '4:21', artworkSeed: 'Endless Summer' },
			{ id: 'u2', title: 'Lost Boy', artist: 'The Midnight', duration: '5:02', artworkSeed: 'Days of Thunder' },
			{ id: 'u3', title: 'Crystalline', artist: 'FM-84', duration: '3:36', artworkSeed: 'Atlas' },
			{ id: 'u4', title: 'Running in the Night', artist: 'FM-84', duration: '5:14', artworkSeed: 'Atlas' },
		]}
		playingFrom="Synthwave Essentials"
		autoQueue={[
			{ id: 'a1', title: 'Nightcall', artist: 'Kavinsky', duration: '4:18', artworkSeed: 'OutRun' },
			{ id: 'a2', title: 'Dreams', artist: 'Gunship', duration: '4:42', artworkSeed: 'Gunship' },
			{ id: 'a3', title: 'Turbo Killer', artist: 'Carpenter Brut', duration: '4:01', artworkSeed: 'Trilogy' },
		]}
		onClear={() => {}}
		onClose={() => {}}
	/>
)

export const EmptyUpNext = () => (
	<QueueInspector
		nowPlaying={{
			id: 'np',
			title: 'Sunset',
			artist: 'The Midnight',
			artworkSeed: 'Endless Summer',
		}}
		positionLabel="0:32"
		durationLabel="4:21"
		progress={0.12}
		upNext={[]}
		playingFrom="Endless Summer"
		autoQueue={[
			{ id: 'a1', title: 'Days of Thunder', artist: 'The Midnight', duration: '4:55', artworkSeed: 'Days of Thunder' },
			{ id: 'a2', title: 'Lonely City', artist: 'The Midnight', duration: '4:12', artworkSeed: 'Nocturnal' },
		]}
		onClear={() => {}}
		onClose={() => {}}
	/>
)

export const NothingPlaying = () => (
	<QueueInspector upNext={[]} onClose={() => {}} />
)
