import { SectionHeader } from '@lyrebird/design-system'

export const WithSeeAll = () => (
	<div style={{ width: 520 }}>
		<SectionHeader
			title="Recently Added"
			subtitle="Fresh arrivals in your library"
			actionLabel="See All"
			onAction={() => {}}
		/>
	</div>
)

export const TitleOnly = () => (
	<div style={{ width: 520 }}>
		<SectionHeader title="Recently Played" />
	</div>
)

export const SubtitleNoAction = () => (
	<div style={{ width: 520 }}>
		<SectionHeader title="Jump Back In" subtitle="Pick up where you left off" />
	</div>
)

export const MadeForYou = () => (
	<div style={{ width: 520 }}>
		<SectionHeader
			title="Made For You"
			subtitle="Picks the server thinks you'll love"
			actionLabel="See All"
			onAction={() => {}}
		/>
	</div>
)
