import type { CSSProperties, SVGProps } from 'react'

export type IconName =
	| 'home'
	| 'library'
	| 'search'
	| 'compass'
	| 'settings'
	| 'heart'
	| 'download'
	| 'check-circle'
	| 'dots'
	| 'dots-v'
	| 'plus'
	| 'play'
	| 'pause'
	| 'next'
	| 'previous'
	| 'shuffle'
	| 'repeat'
	| 'repeat-one'
	| 'queue'
	| 'filter'
	| 'sort'
	| 'close'
	| 'chevron-right'
	| 'chevron-left'
	| 'chevron-down'
	| 'chevron-up'
	| 'cast'
	| 'mic'
	| 'user'
	| 'music'
	| 'clock'
	| 'album'
	| 'list'
	| 'grid'
	| 'volume'
	| 'volume-off'
	| 'mix'
	| 'bell'
	| 'star'
	| 'radio'
	| 'folder'
	| 'fullscreen'
	| 'minimize'
	| 'trending'
	| 'history'
	| 'cloud'
	| 'server'
	| 'sidebar'
	| 'warning'
	| 'lock'
	| 'wifi-off'
	| 'sign-out'

export interface IconProps {
	/** Which glyph to draw. Lucide-style strokes matching the app's SF Symbol set. */
	name: IconName
	/** Square edge length in px. Default 18. */
	size?: number
	/** Stroke (and fill, when `fill`) color. Defaults to `currentColor`. */
	color?: string
	/** Fill the glyph instead of stroking it (used for transport play/pause). */
	fill?: boolean
	/** Stroke width. Default 2. */
	strokeWidth?: number
	style?: CSSProperties
}

/**
 * The Lyrebird icon set — a single inline-SVG glyph component. Mirrors the
 * Lucide-style stroke icons the app renders via SF Symbols. Color follows
 * `currentColor` so it inherits the surrounding text/tint color (e.g. inside
 * `IconButton`, where it lifts to `--lyr-accent` when active).
 */
export function Icon({
	name,
	size = 18,
	color = 'currentColor',
	fill = false,
	strokeWidth = 2,
	style,
}: IconProps) {
	const common: SVGProps<SVGSVGElement> = {
		width: size,
		height: size,
		viewBox: '0 0 24 24',
		fill: fill ? color : 'none',
		stroke: color,
		strokeWidth,
		strokeLinecap: 'round',
		strokeLinejoin: 'round',
		style: { display: 'inline-block', verticalAlign: 'middle', flexShrink: 0, ...style },
	}
	const solid = { ...common, fill: color, stroke: 'none' } as SVGProps<SVGSVGElement>

	switch (name) {
		case 'home':
			return <svg {...common}><path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-7h-6v7H4a1 1 0 0 1-1-1z" /></svg>
		case 'library':
			return <svg {...common}><path d="M8 5v14" /><path d="M5 5h3l4 14h-3z" /><path d="M14 5h3l4 14h-3z" /></svg>
		case 'search':
			return <svg {...common}><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg>
		case 'compass':
			return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="m15.5 8.5-2 5.5-5.5 2 2-5.5z" /></svg>
		case 'settings':
			return <svg {...common}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" /></svg>
		case 'heart':
			return <svg {...common}><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 1 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z" /></svg>
		case 'download':
			return <svg {...common}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="m7 10 5 5 5-5" /><path d="M12 15V3" /></svg>
		case 'check-circle':
			return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="m8 12 3 3 5-6" /></svg>
		case 'dots':
			return <svg {...common}><circle cx="5" cy="12" r="1.3" fill={color} /><circle cx="12" cy="12" r="1.3" fill={color} /><circle cx="19" cy="12" r="1.3" fill={color} /></svg>
		case 'dots-v':
			return <svg {...common}><circle cx="12" cy="5" r="1.3" fill={color} /><circle cx="12" cy="12" r="1.3" fill={color} /><circle cx="12" cy="19" r="1.3" fill={color} /></svg>
		case 'plus':
			return <svg {...common}><path d="M12 5v14M5 12h14" /></svg>
		case 'play':
			return <svg {...solid}><path d="M7 4.5v15a1 1 0 0 0 1.5.87l13-7.5a1 1 0 0 0 0-1.74l-13-7.5A1 1 0 0 0 7 4.5z" /></svg>
		case 'pause':
			return <svg {...solid}><rect x="6" y="4.5" width="4" height="15" rx="1" /><rect x="14" y="4.5" width="4" height="15" rx="1" /></svg>
		case 'next':
			return <svg {...solid}><path d="M5 5v14l10-7z" /><rect x="16" y="5" width="3" height="14" rx="1" /></svg>
		case 'previous':
			return <svg {...solid}><path d="M19 5v14L9 12z" /><rect x="5" y="5" width="3" height="14" rx="1" /></svg>
		case 'shuffle':
			return <svg {...common}><path d="M16 3h5v5" /><path d="M4 20 21 3" /><path d="M21 16v5h-5" /><path d="m15 15 6 6" /><path d="m4 4 5 5" /></svg>
		case 'repeat':
			return <svg {...common}><path d="M17 2l4 4-4 4" /><path d="M3 11v-1a4 4 0 0 1 4-4h14" /><path d="m7 22-4-4 4-4" /><path d="M21 13v1a4 4 0 0 1-4 4H3" /></svg>
		case 'repeat-one':
			return <svg {...common}><path d="M17 2l4 4-4 4" /><path d="M3 11v-1a4 4 0 0 1 4-4h14" /><path d="m7 22-4-4 4-4" /><path d="M21 13v1a4 4 0 0 1-4 4H3" /><path d="M11 14v-4l-1.5 1" /></svg>
		case 'queue':
			return <svg {...common}><path d="M3 6h13M3 12h13M3 18h9" /><path d="M19 14v8l5-4z" fill={color} stroke="none" /></svg>
		case 'filter':
			return <svg {...common}><path d="M3 5h18M6 12h12M10 19h4" /></svg>
		case 'sort':
			return <svg {...common}><path d="M3 6h18M6 12h12M10 18h4" /></svg>
		case 'close':
			return <svg {...common}><path d="M6 6l12 12M18 6 6 18" /></svg>
		case 'chevron-right':
			return <svg {...common}><path d="m9 6 6 6-6 6" /></svg>
		case 'chevron-left':
			return <svg {...common}><path d="m15 6-6 6 6 6" /></svg>
		case 'chevron-down':
			return <svg {...common}><path d="m6 9 6 6 6-6" /></svg>
		case 'chevron-up':
			return <svg {...common}><path d="m6 15 6-6 6 6" /></svg>
		case 'cast':
			return <svg {...common}><path d="M2 18a4 4 0 0 1 4 4" /><path d="M2 14a8 8 0 0 1 8 8" /><path d="M2 10a12 12 0 0 1 12 12" /><path d="M20 20v-12a2 2 0 0 0-2-2h-14" /></svg>
		case 'mic':
			return <svg {...common}><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0" /><path d="M12 18v3" /></svg>
		case 'user':
			return <svg {...common}><circle cx="12" cy="8" r="4" /><path d="M4 21a8 8 0 0 1 16 0" /></svg>
		case 'music':
			return <svg {...common}><path d="M9 18V5l12-2v13" /><circle cx="6" cy="18" r="3" /><circle cx="18" cy="16" r="3" /></svg>
		case 'clock':
			return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>
		case 'album':
			return <svg {...common}><circle cx="12" cy="12" r="9" /><circle cx="12" cy="12" r="3" /></svg>
		case 'list':
			return <svg {...common}><path d="M8 6h13M8 12h13M8 18h13" /><circle cx="4" cy="6" r="1" fill={color} /><circle cx="4" cy="12" r="1" fill={color} /><circle cx="4" cy="18" r="1" fill={color} /></svg>
		case 'grid':
			return <svg {...common}><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></svg>
		case 'volume':
			return <svg {...common}><path d="M11 5 6 9H3v6h3l5 4z" /><path d="M15 9a4 4 0 0 1 0 6" /><path d="M18 6a8 8 0 0 1 0 12" /></svg>
		case 'volume-off':
			return <svg {...common}><path d="M11 5 6 9H3v6h3l5 4z" /><path d="m17 9 4 6M21 9l-4 6" /></svg>
		case 'mix':
			return <svg {...common}><path d="M3 12h3l3-8 4 16 3-8h5" /></svg>
		case 'bell':
			return <svg {...common}><path d="M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9" /><path d="M10 21a2 2 0 0 0 4 0" /></svg>
		case 'star':
			return <svg {...common}><path d="m12 3 2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.8 6.2 20.9l1.1-6.5L2.6 9.8l6.5-.9z" /></svg>
		case 'radio':
			return <svg {...common}><circle cx="12" cy="12" r="2" /><path d="M16.2 7.8a6 6 0 0 1 0 8.4M19 5a10 10 0 0 1 0 14M7.8 7.8a6 6 0 0 0 0 8.4M5 5a10 10 0 0 0 0 14" /></svg>
		case 'folder':
			return <svg {...common}><path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></svg>
		case 'fullscreen':
			return <svg {...common}><path d="M4 9V5a1 1 0 0 1 1-1h4M20 9V5a1 1 0 0 0-1-1h-4M4 15v4a1 1 0 0 0 1 1h4M20 15v4a1 1 0 0 1-1 1h-4" /></svg>
		case 'minimize':
			return <svg {...common}><path d="M8 3v4a1 1 0 0 1-1 1H3M21 8h-4a1 1 0 0 1-1-1V3M3 16h4a1 1 0 0 1 1 1v4M16 21v-4a1 1 0 0 1 1-1h4" /></svg>
		case 'trending':
			return <svg {...common}><path d="m3 17 6-6 4 4 8-8" /><path d="M14 7h7v7" /></svg>
		case 'history':
			return <svg {...common}><path d="M3 3v5h5" /><path d="M3.1 13a9 9 0 1 0 1-5.3L3 8" /><path d="M12 7v5l4 2" /></svg>
		case 'cloud':
			return <svg {...common}><path d="M17 8a5 5 0 0 0-9.6-1.4A4.5 4.5 0 1 0 6.5 19H17a5.5 5.5 0 0 0 0-11z" /></svg>
		case 'server':
			return <svg {...common}><rect x="3" y="4" width="18" height="7" rx="1" /><rect x="3" y="13" width="18" height="7" rx="1" /><circle cx="7" cy="7.5" r="0.7" fill={color} /><circle cx="7" cy="16.5" r="0.7" fill={color} /></svg>
		case 'sidebar':
			return <svg {...common}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16" /></svg>
		case 'warning':
			return <svg {...common}><path d="m12 3 9.5 16.5a1 1 0 0 1-.87 1.5H3.37a1 1 0 0 1-.87-1.5z" /><path d="M12 9v4" /><path d="M12 17h.01" /></svg>
		case 'lock':
			return <svg {...common}><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
		case 'wifi-off':
			return <svg {...common}><path d="M2 8a16 16 0 0 1 4-2.6" /><path d="M5 12a10 10 0 0 1 3-1.9" /><path d="M8.5 15.5a4 4 0 0 1 5 0" /><path d="M12 19h.01" /><path d="m2 2 20 20" /></svg>
		case 'sign-out':
			return <svg {...common}><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" /><path d="m16 17 5-5-5-5" /><path d="M21 12H9" /></svg>
		default:
			return <svg {...common}><circle cx="12" cy="12" r="9" /></svg>
	}
}
