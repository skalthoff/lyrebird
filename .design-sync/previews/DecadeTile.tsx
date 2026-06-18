import { DecadeTile } from '@lyrebird/design-system'

// Horizontal strip mirroring DecadeBrowseRow's ScrollView(.horizontal) HStack.
const Row = ({ children }: { children: React.ReactNode }) => (
	<div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>{children}</div>
)

export const BrowseRow = () => (
	<Row>
		<DecadeTile label="'70s" startYear={1970} onClick={() => {}} />
		<DecadeTile label="'80s" startYear={1980} onClick={() => {}} />
		<DecadeTile label="'90s" startYear={1990} onClick={() => {}} />
		<DecadeTile label="'00s" startYear={2000} onClick={() => {}} />
		<DecadeTile label="'10s" startYear={2010} onClick={() => {}} />
	</Row>
)

export const SpelledOut = () => (
	<Row>
		<DecadeTile label="1980s" startYear={1980} onClick={() => {}} />
		<DecadeTile label="1990s" startYear={1990} onClick={() => {}} />
		<DecadeTile label="2000s" startYear={2000} onClick={() => {}} />
	</Row>
)

export const Single = () => <DecadeTile label="'80s" startYear={1980} onClick={() => {}} />
