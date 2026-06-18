import { GenreTile } from '@lyrebird/design-system'

// 3-column grid mirroring BrowseByGenreSection's LazyVGrid (3×N).
const Grid = ({ children }: { children: React.ReactNode }) => (
	<div
		style={{
			display: 'grid',
			gridTemplateColumns: 'repeat(3, 1fr)',
			gap: 16,
			width: 560,
		}}
	>
		{children}
	</div>
)

export const BrowseGrid = () => (
	<Grid>
		<GenreTile name="Electronic" onClick={() => {}} />
		<GenreTile name="Jazz" onClick={() => {}} />
		<GenreTile name="Hip-Hop" onClick={() => {}} />
		<GenreTile name="Rock" onClick={() => {}} />
		<GenreTile name="Classical" onClick={() => {}} />
		<GenreTile name="Ambient" onClick={() => {}} />
	</Grid>
)

export const LongNames = () => (
	<Grid>
		<GenreTile name="Progressive House" onClick={() => {}} />
		<GenreTile name="Drum &amp; Bass" onClick={() => {}} />
		<GenreTile name="Singer-Songwriter" onClick={() => {}} />
	</Grid>
)

export const Single = () => <GenreTile name="Synthwave" onClick={() => {}} />
