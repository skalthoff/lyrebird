import { Icon, type IconName } from '@lyrebird/design-system'

const NAMES: IconName[] = [
	'home', 'search', 'library', 'compass', 'radio', 'heart',
	'play', 'pause', 'next', 'previous', 'shuffle', 'repeat',
	'queue', 'download', 'settings', 'dots',
]

export const Glyphs = () => (
	<div style={{ display: 'flex', flexWrap: 'wrap', gap: 18, maxWidth: 320, color: 'var(--lyr-ink-2)' }}>
		{NAMES.map((n) => (
			<Icon key={n} name={n} size={22} />
		))}
	</div>
)
