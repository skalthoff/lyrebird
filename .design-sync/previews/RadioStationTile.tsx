import { RadioStationTile } from '@lyrebird/design-system'

/** Genre-radio row tiles — default 20/bold title, deterministic gradient per seed. */
export function GenreStations() {
	return (
		<div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
			<RadioStationTile
				title="Synthwave Radio"
				seed="Synthwave"
				accessibilityVerb="Start Synthwave radio"
			/>
			<RadioStationTile
				title="Shoegaze Radio"
				seed="Shoegaze"
				accessibilityVerb="Start Shoegaze radio"
			/>
			<RadioStationTile
				title="Neo-Soul Radio"
				seed="Neo-Soul"
				accessibilityVerb="Start Neo-Soul radio"
			/>
		</div>
	)
}

/** Decade-radio row tiles — the 34/black/italic title override. */
export function DecadeStations() {
	return (
		<div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
			<RadioStationTile
				title="’80s"
				seed="decade-1980"
				titleSize={34}
				titleBlackItalic
				accessibilityVerb="Start eighties radio"
			/>
			<RadioStationTile
				title="’90s"
				seed="decade-1990"
				titleSize={34}
				titleBlackItalic
				accessibilityVerb="Start nineties radio"
			/>
			<RadioStationTile
				title="’00s"
				seed="decade-2000"
				titleSize={34}
				titleBlackItalic
				accessibilityVerb="Start two-thousands radio"
			/>
		</div>
	)
}

/** Forced-hover state — brighter glyph + stroke, lift, stronger seed-tinted shadow. */
export function HoveredStation() {
	return (
		<div style={{ display: 'flex', gap: 14 }}>
			<RadioStationTile title="Daft Punk Radio" seed="Daft Punk" />
			<RadioStationTile title="Daft Punk Radio" seed="Daft Punk" hovered />
		</div>
	)
}
