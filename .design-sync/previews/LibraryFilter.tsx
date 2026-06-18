import { LibraryFilter } from '@lyrebird/design-system'

const GENRES = [
	{ id: 'ambient', label: 'Ambient' },
	{ id: 'electronic', label: 'Electronic' },
	{ id: 'jazz', label: 'Jazz' },
	{ id: 'post-rock', label: 'Post-Rock' },
	{ id: 'shoegaze', label: 'Shoegaze' },
]

const FORMATS = [
	{ id: 'flac', label: 'FLAC' },
	{ id: 'alac', label: 'ALAC (m4a)' },
	{ id: 'aac', label: 'AAC (m4a)' },
	{ id: 'mp3', label: 'MP3' },
]

const DURATIONS = [
	{ id: 'short', label: '< 3m' },
	{ id: 'medium', label: '3–6m' },
	{ id: 'long', label: '> 6m' },
]

/** Albums tab: Genre + Year groups + the always-on "Only favorited", with selections. */
export function AlbumsTabFilter() {
	return (
		<LibraryFilter
			genres={GENRES}
			selectedGenres={['electronic', 'shoegaze']}
			yearBounds={[1971, 2024]}
			yearLow={1990}
			yearHigh={2018}
			onlyFavorited={true}
			hasSelection={true}
		/>
	)
}

/** Tracks tab: the full panel — Genre is dropped, Format + Duration appear (tracks-only). */
export function TracksTabFilter() {
	return (
		<LibraryFilter
			yearBounds={[1971, 2024]}
			yearLow={1971}
			yearHigh={2024}
			formats={FORMATS}
			selectedFormats={['flac', 'alac']}
			durations={DURATIONS}
			selectedDurations={['long']}
			onlyFavorited={false}
			hasSelection={true}
		/>
	)
}

/** Empty / pristine state: only the always-on favorited toggle, "Clear all" disabled. */
export function PristineFilter() {
	return (
		<LibraryFilter
			genres={GENRES}
			selectedGenres={[]}
			onlyFavorited={false}
			hasSelection={false}
		/>
	)
}
