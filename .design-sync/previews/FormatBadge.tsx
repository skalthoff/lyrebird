import { FormatBadge } from '@lyrebird/design-system'

export const Formats = () => (
	<div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
		<FormatBadge format="FLAC" bitrateKbps={1411} />
		<FormatBadge format="MP3" bitrateKbps={320} />
		<FormatBadge format="AAC" />
	</div>
)
