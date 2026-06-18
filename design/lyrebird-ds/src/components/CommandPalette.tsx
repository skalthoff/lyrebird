import type { CSSProperties } from 'react'
import { Icon, type IconName } from './Icon'
import { Artwork } from './Artwork'

/**
 * Result-row kind. Drives the leading glyph fallback and the trailing
 * `↩` action hint. Mirrors the Swift `CommandPalette.Row` enum:
 * `artist` → person/Open, `album` → square.stack/Open, `track` →
 * music.note/Play, `action` → the action's own symbol/Run.
 */
export type PaletteResultKind = 'artist' | 'album' | 'track' | 'action'

export interface PaletteResult {
	/**
	 * Leading glyph. Library rows map to `user` (artist), `album`, `music`
	 * (track); action rows carry their own. When omitted, `kind` picks a
	 * sensible default. Ignored when `artworkSeed` is supplied.
	 */
	icon?: IconName
	/**
	 * When set, a small gradient `Artwork` thumbnail is drawn instead of the
	 * glyph — used for tracks/albums/artists that have cover art. The seed is
	 * the item name (deterministic gradient), matching `Artwork.swift`.
	 */
	artworkSeed?: string
	/** Primary label (server-provided name, or the action's localized title). */
	title: string
	/**
	 * Secondary line under the title. In the app this is the typed prefix +
	 * metadata, e.g. "Artist · 4 albums · 52 songs", "Album · Phantom Lights",
	 * "Track · The Wayfarers · Distant Signal", or "Action".
	 */
	subtitle?: string
	/**
	 * Optional keyboard-shortcut hint rendered as a faint pill on the trailing
	 * edge (e.g. "⌘⇧S" for a command). Distinct from the per-row `↩ Run`
	 * affordance that appears on the selected row.
	 */
	shortcut?: string
	/** Row kind — selects the default glyph + the trailing `↩` verb. */
	kind?: PaletteResultKind
	/** Pinned action marker — draws a persistent `pin.fill` glyph (see #308). */
	pinned?: boolean
}

export interface CommandPaletteProps {
	/** Current text in the search field. */
	query?: string
	/** Placeholder shown when `query` is empty. Matches the Swift literal. */
	placeholder?: string
	/** Ordered result rows: library matches first, then actions. */
	results: PaletteResult[]
	/** Index of the highlighted (selected) row. Defaults to 0. */
	selectedIndex?: number
	/** Render the subtle header spinner (a debounced search is in flight). */
	searching?: boolean
	style?: CSSProperties
}

/**
 * ⌘K command palette — a Spotlight-style launcher overlaying the whole app.
 * Faithful mirror of `macos/Sources/Lyrebird/Components/CommandPalette.swift`:
 * a 640px column centered under a dim scrim, with a search input on top, a
 * results list (icon/artwork + primary + secondary + optional shortcut, one
 * row highlighted), and a footer of keyboard hints.
 *
 * Presentational only — the live view owns debounced FFI search, category
 * filtering (⌘1..5), and keyboard navigation; here those are flattened to
 * plain props (`query`, `results`, `selectedIndex`).
 */
export function CommandPalette({
	query = '',
	placeholder = 'Search library or run a command',
	results,
	selectedIndex = 0,
	searching = false,
	style,
}: CommandPaletteProps) {
	return (
		// Dim scrim (Color.black.opacity(0.76)) with the column centered
		// horizontally and pinned 120px from the top, matching the Swift layout.
		<div
			style={{
				position: 'relative',
				width: '100%',
				height: '100%',
				minHeight: 520,
				background: 'rgba(0, 0, 0, 0.76)',
				display: 'flex',
				justifyContent: 'center',
				alignItems: 'flex-start',
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			<div
				style={{
					marginTop: 120,
					width: 640,
					// Theme.bgAlt panel, 16px radius, strong hairline, deep drop shadow.
					background: 'var(--lyr-bg-alt)',
					borderRadius: 16,
					border: '1px solid var(--lyr-border-strong)',
					boxShadow: '0 20px 40px rgba(0, 0, 0, 0.35)',
					overflow: 'hidden',
				}}
			>
				{/* Search input row: magnifying glass + field + optional spinner. */}
				<div
					style={{
						display: 'flex',
						alignItems: 'center',
						gap: 12,
						padding: '16px 20px',
					}}
				>
					<Icon name="search" size={18} color="var(--lyr-ink-2)" strokeWidth={2} />
					<div
						style={{
							flex: 1,
							fontSize: 18,
							fontWeight: 500,
							color: query ? 'var(--lyr-ink)' : 'var(--lyr-ink-3)',
							whiteSpace: 'nowrap',
							overflow: 'hidden',
							textOverflow: 'ellipsis',
						}}
					>
						{query || placeholder}
					</div>
					{searching ? (
						<div
							aria-label="Searching"
							style={{
								width: 14,
								height: 14,
								borderRadius: 999,
								border: '2px solid var(--lyr-border-strong)',
								borderTopColor: 'var(--lyr-ink-2)',
							}}
						/>
					) : null}
				</div>

				<div style={{ height: 1, background: 'var(--lyr-border)' }} />

				{/* Results list (or empty state). max-height mirrors the 360pt scroll. */}
				{results.length === 0 ? (
					<div
						style={{
							display: 'flex',
							flexDirection: 'column',
							alignItems: 'center',
							gap: 6,
							padding: '48px 24px',
						}}
					>
						<div style={{ fontSize: 13, fontWeight: 600, color: 'var(--lyr-ink-2)' }}>
							No matches
						</div>
						<div style={{ fontSize: 11, fontWeight: 500, color: 'var(--lyr-ink-3)' }}>
							Try a different query or ⌘1..5 to filter by category.
						</div>
					</div>
				) : (
					<div
						style={{
							maxHeight: 360,
							overflowY: 'auto',
							padding: '6px 0',
						}}
					>
						{results.map((row, idx) => (
							<PaletteRow
								key={`${row.kind ?? 'row'}-${idx}-${row.title}`}
								row={row}
								selected={idx === selectedIndex}
							/>
						))}
					</div>
				)}

				<div style={{ height: 1, background: 'var(--lyr-border)' }} />

				{/* Footer keyboard hints. */}
				<div
					style={{
						display: 'flex',
						alignItems: 'center',
						gap: 18,
						padding: '10px 20px',
					}}
				>
					<HintPair keys="↑↓" label="navigate" />
					<HintPair keys="↩" label="select" />
					<HintPair keys="Esc" label="close" />
				</div>
			</div>
		</div>
	)
}

function HintPair({ keys, label }: { keys: string; label: string }) {
	return (
		<div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
			<span style={{ fontSize: 10, fontWeight: 700, color: 'var(--lyr-ink-2)' }}>{keys}</span>
			<span style={{ fontSize: 10, fontWeight: 500, color: 'var(--lyr-ink-3)' }}>{label}</span>
		</div>
	)
}

/** Default leading glyph per row kind (used when no explicit `icon`). */
function defaultIcon(kind: PaletteResultKind | undefined): IconName {
	switch (kind) {
		case 'artist':
			return 'user'
		case 'album':
			return 'album'
		case 'track':
			return 'music'
		default:
			return 'play'
	}
}

/** Trailing `↩` verb per row kind. Mirrors Swift's `trailingHint`. */
function trailingVerb(kind: PaletteResultKind | undefined): string {
	switch (kind) {
		case 'track':
			return 'Play'
		case 'artist':
		case 'album':
			return 'Open'
		default:
			return 'Run'
	}
}

export interface PaletteRowProps {
	/** The result this row renders. */
	row: PaletteResult
	/** Whether this is the highlighted row (native-hover fill + visible `↩` hint). */
	selected?: boolean
	style?: CSSProperties
}

/**
 * A single command-palette result row. Faithful to the SwiftUI `PaletteRow`:
 * a 22px leading glyph (or a small `Artwork` thumbnail), a two-line text stack
 * (13/semibold title over an 11/medium subtitle), an optional trailing
 * shortcut pill and pinned marker, and a `↩ <verb>` hint that fades in only on
 * the selected row. Selected rows take the `--lyr-native-hover` fill.
 */
export function PaletteRow({ row, selected = false, style }: PaletteRowProps) {
	const iconName = row.icon ?? defaultIcon(row.kind)
	const verb = trailingVerb(row.kind)
	return (
		<div
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 12,
				padding: '10px 16px',
				background: selected ? 'var(--lyr-native-hover)' : 'transparent',
				...style,
			}}
		>
			{/* Leading: artwork thumbnail when seeded, else a 22px centered glyph. */}
			{row.artworkSeed ? (
				<Artwork
					seed={row.artworkSeed}
					size={22}
					radius={row.kind === 'artist' ? 11 : 4}
					shape={row.kind === 'artist' ? 'circle' : 'rounded'}
					shadow={false}
				/>
			) : (
				<div
					style={{
						width: 22,
						height: 22,
						display: 'flex',
						alignItems: 'center',
						justifyContent: 'center',
						flexShrink: 0,
					}}
				>
					<Icon name={iconName} size={16} color="var(--lyr-ink-2)" strokeWidth={2} />
				</div>
			)}

			{/* Text stack: title over optional subtitle. */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0, flex: 1 }}>
				<div
					style={{
						fontSize: 13,
						fontWeight: 600,
						color: 'var(--lyr-ink)',
						whiteSpace: 'nowrap',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
					}}
				>
					{row.title}
				</div>
				{row.subtitle ? (
					<div
						style={{
							fontSize: 11,
							fontWeight: 500,
							color: 'var(--lyr-ink-3)',
							whiteSpace: 'nowrap',
							overflow: 'hidden',
							textOverflow: 'ellipsis',
						}}
					>
						{row.subtitle}
					</div>
				) : null}
			</div>

			{/* Optional shortcut pill (e.g. ⌘⇧S). */}
			{row.shortcut ? (
				<span
					style={{
						fontSize: 10,
						fontWeight: 700,
						color: 'var(--lyr-ink-3)',
						padding: '2px 6px',
						borderRadius: 6,
						background: 'var(--lyr-surface-2)',
						border: '1px solid var(--lyr-border)',
						whiteSpace: 'nowrap',
						flexShrink: 0,
					}}
				>
					{row.shortcut}
				</span>
			) : null}

			{/* Persistent pin marker — drawn regardless of selection (see #308). */}
			{row.pinned ? (
				<span
					aria-label="Pinned"
					style={{ fontSize: 9, fontWeight: 600, color: 'var(--lyr-ink-3)', flexShrink: 0 }}
				>
					{'\u{1F4CC}'}
				</span>
			) : null}

			{/* `↩ <verb>` hint — only visible on the selected row. */}
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					gap: 4,
					color: 'var(--lyr-ink-3)',
					opacity: selected ? 1 : 0,
					flexShrink: 0,
				}}
			>
				<span style={{ fontSize: 10, fontWeight: 700 }}>↩</span>
				<span style={{ fontSize: 11, fontWeight: 500 }}>{verb}</span>
			</div>
		</div>
	)
}
