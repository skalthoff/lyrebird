# Lyrebird Desktop — design system

A faithful React mirror of the **Lyrebird Desktop** macOS app (a Jellyfin music
player). Dark mode only, **Figtree** type, three brand presets. Compose designs
from these components; they already match the shipping app.

## Always wrap in `<LyrebirdRoot>`

`LyrebirdRoot` establishes the dark surface (`--lyr-bg`), the Figtree font, the
default ink color, and the active brand **preset** — it defines the `--lyr-*`
tokens every component reads. **Without it, components render unstyled.**

```tsx
import { LyrebirdRoot, Shelf, AlbumCard, PlayerBar } from '@lyrebird/design-system'

export default function Example() {
  return (
    <LyrebirdRoot preset="purple">{/* "purple" | "ocean" | "forest" */}
      <div style={{ padding: 24 }}>
        <Shelf title="Recently Added" actionLabel="See All">
          <AlbumCard title="Endless Summer" artist="The Midnight" year={2016} artworkSeed="Endless Summer" />
          <AlbumCard title="Discovery"      artist="Daft Punk"    year={2001} artworkSeed="Discovery" />
        </Shelf>
      </div>
    </LyrebirdRoot>
  )
}
```

## Styling idiom: tokens, not classes

Components are **self-styling** — compose them and pass props; there are **no
CSS classes** to apply. For your own layout glue around them, use the same
design tokens as `var(--lyr-*)` and the Figtree family `var(--lyr-font)`. Don't
hard-code hex colors — use the tokens so designs track the active preset.

| Group | Tokens |
|---|---|
| Surfaces | `--lyr-bg` `--lyr-bg-alt` `--lyr-surface` `--lyr-surface-2` `--lyr-row-hover` `--lyr-native-hover` |
| Text | `--lyr-ink` (primary/white) `--lyr-ink-2` (secondary) `--lyr-ink-3` (tertiary) |
| Brand | `--lyr-primary` `--lyr-accent` (both shift per preset) · `--lyr-accent-hot` `--lyr-teal` |
| Status | `--lyr-danger` `--lyr-warning` |
| Lines | `--lyr-border` `--lyr-border-strong` |
| Radius | `--lyr-radius-sm` (6) `--lyr-radius-md` (10) `--lyr-radius-lg` (16) `--lyr-radius-window` (26) |
| Type / elevation | `--lyr-font` · `--lyr-shadow-card` `--lyr-shadow-window` |

## What to compose with

- **Shell**: `Sidebar` (+ `SidebarItem`, `SidebarSection`, `SidebarPlaylistRow`, `SidebarBrand`, `SidebarServerFooter`), `PlayerBar`, `MiniPlayer`, `QueueInspector`, `CommandPalette`, `NowPlaying`, `LibraryFilter`.
- **Content**: `AlbumCard`, `ArtistCard`, `PlaylistCard`, `TrackRow`, `TrackListRow`, `TopTrackRow`, `Artwork`, `FormatBadge`, `Lyrics`.
- **Tiles** (home/discover/radio): `HomeQuickTile`, `RecentlyPlayedTile`, `GenreTile`, `DecadeTile`, `RadioStationTile`, `ArtistRadioTile`.
- **Layout / controls / feedback**: `SectionHeader`, `Shelf`, `Button`, `Chip`, `IconButton`, `Icon`, `EqualizerIcon`, `Banner`, `Toast`, `EmptyState`.
- **Full-window references**: `HomeScreen`, `LibraryScreen`, `AlbumDetailScreen`, `ArtistDetailScreen` — complete app windows you can study or drop in (give them a sized parent, e.g. `width/height` of a desktop window).

## Where the truth lives

Read the bound `styles.css` (and its `@import`s) for the exact token values, and
each component's `<Name>.d.ts` (props) + `<Name>.prompt.md` (usage) before
composing. `Icon`'s `name` is a typed set (home, search, play, pause, next,
previous, shuffle, repeat, heart, queue, download, settings, …).
