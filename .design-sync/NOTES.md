# design-sync NOTES — Lyrebird Desktop → Claude Design

## What this sync is

This repo is **lyrebird-desktop** (Rust core + SwiftUI macOS app). It has no
shippable React component library. To get the app's *current* design language
into Claude Design (whose runtime is React, not SwiftUI), we **author a React
mirror** of the live SwiftUI UI at `design/lyrebird-ds/`, then run the
design-sync converter on it.

- **Source of truth = the Swift code**, specifically `macos/Sources/Lyrebird/`
  (`Theme/Theme.swift` for tokens; `Components/*.swift` and `Screens/*.swift`
  for components). NOT the `design/project/` folder — that is a *stale* Claude
  Design export and must be ignored.
- The mirror is a faithful re-creation of the shipped look, not a reimagining.

## Package shape

- `design/lyrebird-ds/` — React 18 + TS, `tsc` → `dist/` (JS + `.d.ts`).
  `@lyrebird/design-system`, global `LyrebirdDS`.
- Build: `npm --prefix design/lyrebird-ds run build` (cfg.buildCmd).
- Converter run from repo root:
  `node .ds-sync/package-build.mjs --config .design-sync/config.json --node-modules design/lyrebird-ds/node_modules --entry design/lyrebird-ds/dist/index.js --out ./ds-bundle`

## Authoring conventions (FOLLOW THESE for every component)

1. **Prop-driven, presentational only.** No `AppModel`, no data fetching, no
   core FFI. The SwiftUI views read a model; the React mirror takes plain props
   (strings, booleans, callbacks). Translate `model.x` → a prop.
2. **Styling = inline styles using `var(--lyr-*)` tokens + literal geometry.**
   No CSS files per component, no CSS modules. Colors/fonts come from tokens
   (`var(--lyr-ink)`, `var(--lyr-accent)`, …); sizes/spacing are literal px
   matching the Swift source. `color-mix(in srgb, var(--lyr-accent) 18%, transparent)`
   for token alphas.
3. **Tokens** are defined in `src/theme/tokens.css` (shipped via cfg.cssEntry →
   `_ds_bundle.css` → `styles.css` closure). Full list: `--lyr-bg`, `--lyr-bg-alt`,
   `--lyr-surface`, `--lyr-surface-2`, `--lyr-row-hover`, `--lyr-native-hover`,
   `--lyr-ink`, `--lyr-ink-2`, `--lyr-ink-3`, `--lyr-primary`, `--lyr-accent`,
   `--lyr-accent-hot`, `--lyr-teal`, `--lyr-danger`, `--lyr-warning`,
   `--lyr-border`, `--lyr-border-strong`, `--lyr-font`, `--lyr-radius-{sm,md,lg,window}`,
   `--lyr-shadow-{card,window}`. Three presets via `[data-lyr-preset]` (purple
   default / ocean / forest) set by `<LyrebirdRoot>`.
4. **Typography**: Figtree. Map SwiftUI `Theme.font(size, weight)` → inline
   `fontSize` + `fontWeight` (regular 400, medium 500, semibold 600, bold 700,
   heavy/extraBold 800, black 900). Use `fontFamily: 'var(--lyr-font)'` on text
   roots (or rely on LyrebirdRoot inheritance).
5. **File layout**: one component per `src/components/<Name>.tsx`, exported
   (value + Props type) from `src/index.ts`. PascalCase. Export a `<Name>Props`
   interface with a JSDoc on the component + each non-obvious prop (the converter
   turns JSDoc into `.prompt.md`).
6. **Icons**: use the shared `Icon` component (`name` is a typed `IconName`
   union) — don't inline SVG in other components. Add new glyphs to `Icon.tsx`
   if the app uses one not yet present.

## Preview conventions (`.design-sync/previews/<Name>.tsx`)

- PascalCase **function exports**, each = one card cell. Import from
  `'@lyrebird/design-system'`. Realistic content (real song/artist/album names,
  never foo/bar).
- **Do NOT wrap in `<LyrebirdRoot>`** — `cfg.provider` already wraps every cell
  in `LyrebirdRoot` (dark surface + tokens + Figtree). (Exception: when *demoing*
  presets, an inner `<LyrebirdRoot preset=…>` is the point — see LyrebirdRoot.tsx.)
- Sweep the primary variant axis + show stateful variants (active/selected/etc.).
  `TrackRow` accepts `hovered` to force hover visuals in a static card.
- **`cardMode: column`** in `cfg.overrides.<Name>` for any component whose
  variants/width exceed a grid cell (rows, bars, full-width chrome, multi-variant
  showcases). Most components here use it.

## Config facts

- `cfg.provider = LyrebirdRoot` (dark surface). `cfg.cssEntry = src/theme/tokens.css`.
  `cfg.extraFonts = fonts/fonts.css`. `tokensGlob` does NOT work without a
  `tokensPkg` (separate npm pkg) — that's why tokens ship via cssEntry instead.
- Render check: Playwright + Chromium installed under `.ds-sync/node_modules`
  + `~/Library/Caches/ms-playwright/` (chromium-1228). User authorized the install.

## Known render warns

- `[GRID_OVERFLOW]` is expected for variant-row / full-width components and is
  resolved by `cardMode: column` (presentation-only, non-blocking).

## Wave findings (fold-ins)

- **ArtistCard is SQUARE (radius 8), not circular** — `ArtistCard.swift` mirrors
  `AlbumCard` ("square artwork"). Don't "fix" it to a circle.
- **Missing Icon glyphs** drawn inline by components for now: `lock`/`lock.fill`
  (private playlist badge — Sidebar, PlaylistCard) and a door/sign-out glyph
  (Sidebar footer). If many components need these, add real glyphs to `Icon.tsx`.
- Cards (Album/Artist/Playlist) use 180px artwork, radius 12 card, 40px primary
  play button bottom-trailing on hover. Reuse the `Artwork` component.

## Upload target (first sync — 2026-06-18)

- Synced into the existing **"Design System"** project
  `f36e8898-c7d8-438e-9694-b169a54dd268` (now pinned as `cfg.projectId`), NOT a
  fresh project — chosen to consolidate rather than fragment the account.
- That project previously held an **older-skill-version** Lyrebird DS (~11
  components in a flat `components/core/` + `components/media/` layout, plus
  `ui_kits/`, `assets/`, `tokens/*.css`, `guidelines/*.html`, `SKILL.md`,
  `readme.md`). It had **no `_ds_sync.json` anchor**, so this first sync ran
  full-scope and the upload reconciled by **deleting 72 orphan files** the new
  build doesn't produce. That manual delete pass is a one-time cost: the project
  now carries `_ds_sync.json`, so future re-syncs diff cleanly and derive
  deletes from the anchor automatically.
- 45 components uploaded (43 authored previews all graded `good`; PaletteRow +
  QueueRow render functionally from their `.d.ts` props — no authored preview).

## Re-sync risks (watch-list)

- The mirror can drift from the SwiftUI app as the app evolves. When re-syncing,
  re-read `Theme.swift` + changed `Components/*.swift` and update the mirror.
- Tokens are duplicated conceptually between `Theme.swift` (Swift) and
  `tokens.css` (mirror) — keep them in step.
