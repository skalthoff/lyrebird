import { ArtistRadioTile } from '@lyrebird/design-system'

/** A row of artist-radio seed tiles — gradient fallback art, "<Artist> / Radio" label. */
export function ArtistStations() {
	return (
		<div style={{ display: 'flex', gap: 24, flexWrap: 'wrap' }}>
			<ArtistRadioTile name="Daft Punk" />
			<ArtistRadioTile name="Tame Impala" />
			<ArtistRadioTile name="Khruangbin" />
		</div>
	)
}

/** Forced-hover state — radio glyph reveal over the scrim, accent ring + glow. */
export function HoveredArtistStation() {
	return (
		<div style={{ display: 'flex', gap: 24 }}>
			<ArtistRadioTile name="Bonobo" />
			<ArtistRadioTile name="Bonobo" hovered />
		</div>
	)
}
