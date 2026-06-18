import type { CSSProperties } from 'react'

export interface FormatBadgeProps {
	/** Container/codec label, e.g. "FLAC", "MP3", "AAC". Rendered upper-cased. */
	format: string
	/** Optional bitrate (kbps) shown in the hover tooltip ("FLAC · 1411 kbps"). */
	bitrateKbps?: number
	style?: CSSProperties
}

/**
 * Small pill annotating a track's container format (FLAC / MP3 / AAC …). Reads
 * as a secondary annotation — `--lyr-ink-3` on a faint `--lyr-surface` chip with
 * a hairline border. Sits inline next to the track title in `TrackRow`.
 */
export function FormatBadge({ format, bitrateKbps, style }: FormatBadgeProps) {
	const label = format.toUpperCase()
	const tip = bitrateKbps ? `${label} · ${bitrateKbps} kbps` : label
	return (
		<span
			title={tip}
			style={{
				display: 'inline-flex',
				alignItems: 'center',
				whiteSpace: 'nowrap',
				fontFamily: 'var(--lyr-font)',
				fontSize: 9,
				fontWeight: 600,
				lineHeight: 1,
				color: 'var(--lyr-ink-3)',
				padding: '2px 5px',
				borderRadius: 3,
				background: 'var(--lyr-surface)',
				border: '0.5px solid var(--lyr-border)',
				...style,
			}}
		>
			{label}
		</span>
	)
}
