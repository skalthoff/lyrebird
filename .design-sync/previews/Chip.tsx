import { Chip } from '@lyrebird/design-system'

const Row = ({ children }: { children: React.ReactNode }) => (
	<div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>{children}</div>
)

export const Unselected = () => (
	<Row>
		<Chip label="Electronic" onClick={() => {}} />
		<Chip label="Jazz" onClick={() => {}} />
		<Chip label="Rock" onClick={() => {}} />
		<Chip label="Hip-Hop" onClick={() => {}} />
		<Chip label="Classical" onClick={() => {}} />
	</Row>
)

export const Selected = () => (
	<Row>
		<Chip label="Electronic" selected onClick={() => {}} />
		<Chip label="Jazz" onClick={() => {}} />
		<Chip label="Rock" selected onClick={() => {}} />
		<Chip label="Hip-Hop" onClick={() => {}} />
		<Chip label="Classical" selected onClick={() => {}} />
	</Row>
)

export const AccentSelected = () => (
	<Row>
		<Chip label="Favorites" selected accent icon="heart" onClick={() => {}} />
		<Chip label="Downloaded" accent icon="download" onClick={() => {}} />
		<Chip label="Albums" selected accent onClick={() => {}} />
	</Row>
)

export const WithIcon = () => (
	<Row>
		<Chip label="Favorites" icon="heart" selected onClick={() => {}} />
		<Chip label="Downloaded" icon="download" onClick={() => {}} />
		<Chip label="Recently Added" icon="clock" onClick={() => {}} />
		<Chip label="Shuffle All" icon="shuffle" onClick={() => {}} />
	</Row>
)

export const Dismissible = () => (
	<Row>
		<Chip label="Electronic" selected onDismiss={() => {}} />
		<Chip label="Jazz" onDismiss={() => {}} />
		<Chip label="1990–2005" onDismiss={() => {}} />
		<Chip label="FLAC" icon="filter" onDismiss={() => {}} />
	</Row>
)
