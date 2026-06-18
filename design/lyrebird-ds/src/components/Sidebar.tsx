import { useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { Icon, type IconName } from './Icon'

/* ------------------------------------------------------------------ *
 *  Sidebar — left-rail navigation + user-library summary.
 *
 *  Faithful React mirror of macos/Sources/Lyrebird/Components/Sidebar.swift.
 *  Presentational only: every `model.x` the Swift reads becomes a plain prop.
 *  Geometry is the literal px from the Swift; all colors/fonts are tokens.
 * ------------------------------------------------------------------ */

/** Fixed rail width — `.frame(width: 252)` in the Swift. */
const RAIL_WIDTH = 252

/* ============================== Brand ============================== */

export interface SidebarBrandProps {
	/** App name — rendered black + italic. Default "Lyrebird". */
	name?: string
	/** Eyebrow subtitle, letter-spaced + uppercase. Default "DESKTOP". */
	subtitle?: string
}

/**
 * The brand header: a 30×30 teal→primary gradient tile with a jellyfish mark,
 * the italic-black app name, and a tracked eyebrow subtitle. Mirrors the
 * Swift's brand `HStack` (top padding reserves the traffic-light strip).
 */
export function SidebarBrand({ name = 'Lyrebird', subtitle = 'DESKTOP' }: SidebarBrandProps) {
	return (
		<div
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 10,
				// .padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 12)
				padding: '28px 18px 12px',
			}}
		>
			<div
				style={{
					width: 30,
					height: 30,
					flexShrink: 0,
					borderRadius: 8,
					background:
						'linear-gradient(135deg, var(--lyr-teal) 0%, var(--lyr-primary) 100%)',
					display: 'flex',
					alignItems: 'center',
					justifyContent: 'center',
					fontSize: 16,
					lineHeight: 1,
				}}
			>
				{/* Emoji rendered verbatim — a jellyfish is a jellyfish in every locale. */}
				🪼
			</div>
			<div style={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
				<span
					style={{
						fontSize: 15,
						fontWeight: 900,
						fontStyle: 'italic',
						color: 'var(--lyr-ink)',
						lineHeight: 1.1,
					}}
				>
					{name}
				</span>
				<span
					style={{
						fontSize: 9,
						fontWeight: 700,
						color: 'var(--lyr-ink-3)',
						letterSpacing: 1.5,
						lineHeight: 1.1,
					}}
				>
					{subtitle}
				</span>
			</div>
		</div>
	)
}

/* ============================ Section header ======================= */

export interface SidebarSectionProps {
	/** Uppercase, tracked section label (e.g. "YOUR LIBRARY", "PLAYLISTS"). */
	title: string
	/** Trailing affordance (e.g. a "+" button or a collapse chevron group). */
	trailing?: ReactNode
	/** The rows under this section. */
	children?: ReactNode
	/**
	 * Use the tight playlist-style header (h8 / top2 / bottom4) instead of the
	 * roomy stats header (h18 / top20 / bottom6). The Swift uses the tight form
	 * for the Playlists / Smart-Playlists lists. Default false.
	 */
	compact?: boolean
}

/**
 * A labelled sidebar section. The label matches the Swift's `sectionHeader`
 * (`Theme.font(10, .bold)`, ink3, 1.5 tracking). `compact` switches to the
 * tighter playlist-list header padding and supports a trailing affordance.
 */
export function SidebarSection({
	title,
	trailing,
	children,
	compact = false,
}: SidebarSectionProps) {
	return (
		<div>
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					gap: 6,
					// stats header: .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 6)
					// playlist header: .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
					padding: compact ? '2px 8px 4px' : '20px 18px 6px',
				}}
			>
				<span
					style={{
						fontSize: 10,
						fontWeight: 700,
						color: 'var(--lyr-ink-3)',
						letterSpacing: 1.5,
						textTransform: 'uppercase',
					}}
				>
					{title}
				</span>
				{trailing != null && (
					<>
						<span style={{ flex: 1 }} />
						{trailing}
					</>
				)}
			</div>
			{/* Rows align to the 10px gutter the Swift applies around each list. */}
			<div style={{ display: 'flex', flexDirection: 'column', gap: 2, padding: '0 10px' }}>
				{children}
			</div>
		</div>
	)
}

/* ============================== Nav item ========================== */

export interface SidebarItemProps {
	/** Leading glyph (shared `Icon` name). */
	icon: IconName
	/** Row label. */
	label: string
	/** Selected/active tab — accent glyph, ink label, surface-2 fill + accent rail. */
	selected?: boolean
	/** Trailing count/badge (e.g. album total). Rendered as a small tabular numeral. */
	badge?: string | number
	/** Force hover visuals (static previews). Omit for live interactivity. */
	hovered?: boolean
	/**
	 * Compact vertical padding (v6) used by the Favorites / stat rows; the
	 * primary nav rows use the taller v8. Default false (tall).
	 */
	compact?: boolean
	/**
	 * Hide the selected-state accent rail + fill (stat rows in the Swift route to
	 * Library and show no active chrome). Default false.
	 */
	plain?: boolean
	onClick?: () => void
	style?: CSSProperties
}

/**
 * A primary nav / library row. Mirrors the Swift `navItem` / `favoritesRow` /
 * `libRow`: an 18px-wide glyph column, a label that goes bold + ink when
 * `selected`, an optional trailing `badge` count, a surface-2 selection fill,
 * and a 3px accent leading rail on the active row. `native-hover` on hover.
 */
export function SidebarItem({
	icon,
	label,
	selected = false,
	badge,
	hovered,
	compact = false,
	plain = false,
	onClick,
	style,
}: SidebarItemProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState
	const showActive = selected && !plain

	const background = showActive
		? 'var(--lyr-surface-2)'
		: isHovering
			? 'var(--lyr-native-hover)'
			: 'transparent'

	const glyphColor = showActive ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'
	const labelColor = selected ? 'var(--lyr-ink)' : 'var(--lyr-ink-2)'

	return (
		<button
			type="button"
			aria-label={label}
			aria-current={selected ? 'page' : undefined}
			onClick={onClick}
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'center',
				gap: 10,
				width: '100%',
				// navItem .padding(.horizontal, 10).padding(.vertical, 8)
				// favoritesRow / libRow .padding(.vertical, 6)
				padding: compact ? '6px 10px' : '8px 10px',
				border: 'none',
				borderRadius: 8,
				background,
				textAlign: 'left',
				cursor: 'pointer',
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			{/* 3px accent leading rail, inset 6px vertically (clipShape radius 1). */}
			{showActive && (
				<span
					style={{
						position: 'absolute',
						left: 0,
						top: 6,
						bottom: 6,
						width: 3,
						borderRadius: 1,
						background: 'var(--lyr-accent)',
					}}
				/>
			)}
			<span
				style={{
					width: 18,
					flexShrink: 0,
					display: 'inline-flex',
					alignItems: 'center',
					justifyContent: 'center',
				}}
			>
				<Icon name={icon} size={16} color={glyphColor} />
			</span>
			<span
				style={{
					flex: 1,
					minWidth: 0,
					fontSize: 13,
					fontWeight: selected ? 700 : 600,
					color: labelColor,
					overflow: 'hidden',
					textOverflow: 'ellipsis',
					whiteSpace: 'nowrap',
				}}
			>
				{label}
			</span>
			{badge != null && (
				<span
					style={{
						fontSize: 10,
						fontWeight: 700,
						color: 'var(--lyr-ink-3)',
						fontVariantNumeric: 'tabular-nums',
						flexShrink: 0,
						whiteSpace: 'nowrap',
					}}
				>
					{badge}
				</span>
			)}
		</button>
	)
}

/* ============================ Playlist row ======================== */

export interface SidebarPlaylistRowProps {
	/** Playlist name. */
	name: string
	/** Active screen — accent glyph, ink/bold label, surface-2 fill. */
	selected?: boolean
	/** Private playlist — shows a trailing lock affordance. */
	private?: boolean
	/** Use the gear glyph for rule-driven smart playlists instead of the list glyph. */
	smart?: boolean
	/** Force hover visuals (static previews). */
	hovered?: boolean
	onClick?: () => void
	style?: CSSProperties
}

/**
 * A single playlist (or smart-playlist) row. Mirrors the Swift `playlistRow` /
 * `smartPlaylistRow`: a list glyph (gear for `smart`), a `font(12)` name that
 * goes bold + ink when active, a trailing lock for `private`, and the
 * surface-2 / native-hover background treatment at radius 6.
 */
export function SidebarPlaylistRow({
	name,
	selected = false,
	private: isPrivate = false,
	smart = false,
	hovered,
	onClick,
	style,
}: SidebarPlaylistRowProps) {
	const [hoverState, setHoverState] = useState(false)
	const isHovering = hovered ?? hoverState

	const background = selected
		? 'var(--lyr-surface-2)'
		: isHovering
			? 'var(--lyr-native-hover)'
			: 'transparent'

	const glyphColor = selected ? 'var(--lyr-accent)' : 'var(--lyr-ink-2)'

	return (
		<div
			onClick={onClick}
			onMouseEnter={() => setHoverState(true)}
			onMouseLeave={() => setHoverState(false)}
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 10,
				// .padding(.horizontal, 10).padding(.vertical, 5)
				padding: '5px 10px',
				borderRadius: 6,
				background,
				cursor: 'pointer',
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			<span
				style={{
					width: 18,
					flexShrink: 0,
					display: 'inline-flex',
					alignItems: 'center',
					justifyContent: 'center',
				}}
			>
				{/* smart playlists use `gearshape.2.fill` → closest glyph is `settings` */}
				<Icon name={smart ? 'settings' : 'list'} size={16} color={glyphColor} />
			</span>
			<span
				style={{
					flex: 1,
					minWidth: 0,
					fontSize: 12,
					fontWeight: selected ? 700 : 500,
					color: selected ? 'var(--lyr-ink)' : 'var(--lyr-ink-2)',
					overflow: 'hidden',
					textOverflow: 'ellipsis',
					whiteSpace: 'nowrap',
				}}
			>
				{name}
			</span>
			{isPrivate && (
				// `lock.fill` (size 9) — no lock glyph in the set; `star` is wrong,
				// so we draw a tiny inline lock to match the private affordance.
				<span
					aria-label="Private playlist"
					title="Private — only visible to you"
					style={{ flexShrink: 0, display: 'inline-flex', color: 'var(--lyr-ink-3)' }}
				>
					<svg width={9} height={9} viewBox="0 0 24 24" fill="currentColor" stroke="none">
						<path d="M7 10V8a5 5 0 0 1 10 0v2h1a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2zm2 0h6V8a3 3 0 0 0-6 0z" />
					</svg>
				</span>
			)}
		</div>
	)
}

/* ============================ Server footer ======================= */

export interface SidebarServerFooterProps {
	/** Server display name (e.g. "music.skalthoff.com"). Falls back to "—". */
	serverName?: string
	/** Live reachability — drives the status dot color + the status line. */
	connected?: boolean
	/** Total album count, shown on the connected status line. */
	albumCount?: number
	onSignOut?: () => void
}

/**
 * The bottom server footer: a reachability dot (teal glow when connected, muted
 * otherwise), the server name + a connected/disconnected status line, and a
 * sign-out button. Mirrors the Swift footer (top divider, h14 / v12 padding).
 */
export function SidebarServerFooter({
	serverName,
	connected = false,
	albumCount,
	onSignOut,
}: SidebarServerFooterProps) {
	return (
		<div
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 10,
				// .padding(.horizontal, 14).padding(.vertical, 12)
				padding: '12px 14px',
				borderTop: '1px solid var(--lyr-border)',
			}}
		>
			<span
				aria-hidden
				style={{
					width: 8,
					height: 8,
					flexShrink: 0,
					borderRadius: '50%',
					background: connected ? 'var(--lyr-teal)' : 'var(--lyr-ink-3)',
					boxShadow: connected
						? '0 0 8px color-mix(in srgb, var(--lyr-teal) 70%, transparent)'
						: undefined,
				}}
			/>
			<div style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0, flex: 1 }}>
				<span
					style={{
						fontSize: 11,
						fontWeight: 700,
						color: 'var(--lyr-ink)',
						overflow: 'hidden',
						textOverflow: 'ellipsis',
						whiteSpace: 'nowrap',
					}}
				>
					{serverName ?? '—'}
				</span>
				<span style={{ fontSize: 10, fontWeight: 500, color: 'var(--lyr-ink-3)' }}>
					{connected
						? `Connected · ${albumCount ?? 0} albums`
						: 'Disconnected'}
				</span>
			</div>
			<button
				type="button"
				aria-label="Sign out"
				title="Sign out"
				onClick={onSignOut}
				style={{
					width: 24,
					height: 24,
					flexShrink: 0,
					display: 'inline-flex',
					alignItems: 'center',
					justifyContent: 'center',
					padding: 0,
					border: 'none',
					background: 'transparent',
					cursor: 'pointer',
					color: 'var(--lyr-ink-3)',
				}}
			>
				{/* `rectangle.portrait.and.arrow.right` — no logout glyph in the set;
				    inline door-with-arrow keeps the sign-out semantics. */}
				<svg width={15} height={15} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
					<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
					<path d="m16 17 5-5-5-5" />
					<path d="M21 12H9" />
				</svg>
			</button>
		</div>
	)
}

/* =============================== Sidebar =========================== */

export interface SidebarProps {
	/** Brand header props. Pass `false` to omit the header. */
	brand?: SidebarBrandProps | false
	/** Server footer props. Pass `false` to omit the footer. */
	footer?: SidebarServerFooterProps | false
	/** Composed rail body — `SidebarItem`s, `SidebarSection`s, playlist rows. */
	children?: ReactNode
	style?: CSSProperties
}

/**
 * The full left-rail container — a fixed 252px column with the translucent
 * Apple-Music-style sidebar material (`bg-alt`), an optional brand header at
 * top and server footer pinned to the bottom, with caller-composed nav /
 * library / playlist sections filling the middle. Mirrors `Sidebar.swift`.
 */
export function Sidebar({ brand = {}, footer, children, style }: SidebarProps) {
	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				width: RAIL_WIDTH,
				height: '100%',
				flexShrink: 0,
				// Translucent .sidebar material analogue: bg-alt over the window.
				background: 'color-mix(in srgb, var(--lyr-bg-alt) 55%, var(--lyr-bg))',
				fontFamily: 'var(--lyr-font)',
				...style,
			}}
		>
			{brand !== false && <SidebarBrand {...brand} />}

			{/* Scrolling middle: primary nav + library stats + playlist lists. */}
			<div style={{ flex: 1, minHeight: 0, overflowY: 'auto', display: 'flex', flexDirection: 'column' }}>
				{children}
			</div>

			{footer && <SidebarServerFooter {...footer} />}
		</div>
	)
}
