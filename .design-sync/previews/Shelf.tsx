import { Shelf, AlbumCard, ArtistCard } from '@lyrebird/design-system'

export const RecentlyAdded = () => (
	<Shelf
		title="Recently Added"
		subtitle="Fresh arrivals in your library"
		actionLabel="See All"
		onAction={() => {}}
	>
		<AlbumCard title="Random Access Memories" artist="Daft Punk" year={2013} />
		<AlbumCard title="In Rainbows" artist="Radiohead" year={2007} />
		<AlbumCard title="Currents" artist="Tame Impala" year={2015} />
		<AlbumCard title="Endless Summer" artist="The Midnight" year={2016} />
	</Shelf>
)

export const JumpBackIn = () => (
	<Shelf title="Jump Back In" subtitle="Pick up where you left off">
		<AlbumCard title="Discovery" artist="Daft Punk" year={2001} />
		<AlbumCard title="A Moon Shaped Pool" artist="Radiohead" year={2016} />
		<AlbumCard title="Blonde" artist="Frank Ocean" year={2016} />
	</Shelf>
)

export const MadeForYou = () => (
	<Shelf
		title="Made For You"
		subtitle="Picks the server thinks you'll love"
		actionLabel="See All"
		onAction={() => {}}
		gap={12}
	>
		<ArtistCard name="Tame Impala" subtitle="8 albums" />
		<ArtistCard name="Bonobo" subtitle="12 albums" />
		<ArtistCard name="Floating Points" subtitle="5 albums" />
		<ArtistCard name="Khruangbin" subtitle="4 albums" />
	</Shelf>
)
