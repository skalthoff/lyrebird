import type { CSSProperties, ReactNode } from 'react'

/** Visual severity of the strip. Drives icon tint, background wash, and left rule. */
export type BannerTone = 'info' | 'warning' | 'error'

export interface BannerProps {
	/**
	 * Severity. `error` mirrors `OfflineBanner` (danger/red), `warning` mirrors
	 * `ServerUnreachableBanner` (amber). `info` is a neutral variant (ink-2 rule
	 * on a faint surface wash) — the app ships only the danger/amber pair today.
	 * Default `info`.
	 */
	tone?: BannerTone
	/**
	 * Optional leading glyph. Pass an `<Icon>` (or any node) to override the
	 * tone's built-in default. The app draws `wifi.slash` for offline and
	 * `exclamationmark.triangle.fill` for server-unreachable — neither exists in
	 * the shared `Icon` set yet, so the tone defaults are drawn inline here.
	 */
	icon?: ReactNode
	/** The status copy. One or two lines (`OfflineBanner` clamps to 2). */
	message: string
	/** Label for the trailing pill action (the app's "Retry"). Omit to hide it. */
	actionLabel?: string
	/** Invoked when the action pill is pressed (`onRetry` in the Swift). */
	onAction?: () => void
	/** Optional dismiss handler — renders a trailing close affordance. */
	onDismiss?: () => void
	style?: CSSProperties
}

/** Per-tone color resolution. Mirrors the Swift `Theme.danger` / `Theme.warning`
 * banners; `info` falls back to the neutral ink-2 rule used elsewhere. */
function toneColor(tone: BannerTone): string {
	switch (tone) {
		case 'error':
			return 'var(--lyr-danger)'
		case 'warning':
			return 'var(--lyr-warning)'
		default:
			return 'var(--lyr-ink-2)'
	}
}

/** Built-in leading glyph per tone, matching the SF Symbols the app uses. Drawn
 * inline because the shared `Icon` set has no `wifi.slash` / alert-triangle yet. */
function DefaultIcon({ tone, color }: { tone: BannerTone; color: string }) {
	if (tone === 'error') {
		// wifi.slash — offline
		return (
			<svg
				width={14}
				height={14}
				viewBox="0 0 24 24"
				fill="none"
				stroke={color}
				strokeWidth={2}
				strokeLinecap="round"
				strokeLinejoin="round"
				style={{ display: 'block', flexShrink: 0 }}
				aria-hidden="true"
			>
				<path d="M2 3 22 21" />
				<path d="M5 12.5a10 10 0 0 1 4-2.4" />
				<path d="M2 8.8a16 16 0 0 1 5-3" />
				<path d="M16.7 10.3A10 10 0 0 1 19 12.5" />
				<path d="M22 8.8a16 16 0 0 0-6.9-3.3" />
				<path d="M8.5 16a5 5 0 0 1 5.6-.9" />
				<path d="M12 20h.01" />
			</svg>
		)
	}
	// exclamationmark.triangle.fill — warning / info
	return (
		<svg
			width={14}
			height={14}
			viewBox="0 0 24 24"
			fill={color}
			stroke="none"
			style={{ display: 'block', flexShrink: 0 }}
			aria-hidden="true"
		>
			<path d="M10.3 3.2a2 2 0 0 1 3.4 0l8.4 14.5A2 2 0 0 1 20.4 21H3.6a2 2 0 0 1-1.7-3.3z" />
			<rect x="11" y="8.5" width="2" height="6" rx="1" fill="var(--lyr-bg)" />
			<circle cx="12" cy="17" r="1.1" fill="var(--lyr-bg)" />
		</svg>
	)
}

/**
 * Inline status strip — the app's `OfflineBanner` / `ServerUnreachableBanner`
 * pattern. A leading glyph + message, an optional trailing "Retry" pill, and an
 * optional dismiss. Full-width across the content column: the tone washes the
 * background at 10% and paints a 3px leading rule in the tone color. `error`
 * matches the danger (offline) banner; `warning` the amber (server-unreachable)
 * banner.
 */
export function Banner({
	tone = 'info',
	icon,
	message,
	actionLabel,
	onAction,
	onDismiss,
	style,
}: BannerProps) {
	const color = toneColor(tone)
	return (
		<div
			role="status"
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'center',
				gap: 12,
				width: '100%',
				boxSizing: 'border-box',
				padding: '10px 16px',
				fontFamily: 'var(--lyr-font)',
				// tone wash at 10%, matching `Theme.danger/warning.opacity(0.10)`
				background: `color-mix(in srgb, ${color} 10%, transparent)`,
				...style,
			}}
		>
			{/* 3px leading rule */}
			<span
				aria-hidden="true"
				style={{
					position: 'absolute',
					left: 0,
					top: 0,
					bottom: 0,
					width: 3,
					background: color,
				}}
			/>

			{icon ?? <DefaultIcon tone={tone} color={color} />}

			<span
				style={{
					flex: 1,
					minWidth: 0,
					fontSize: 12,
					fontWeight: 600,
					lineHeight: 1.35,
					color: 'var(--lyr-ink)',
				}}
			>
				{message}
			</span>

			{actionLabel && (
				<button
					type="button"
					onClick={onAction}
					style={{
						flexShrink: 0,
						padding: '6px 12px',
						fontFamily: 'var(--lyr-font)',
						fontSize: 12,
						fontWeight: 700,
						lineHeight: 1,
						color: 'var(--lyr-ink)',
						borderRadius: 6,
						cursor: 'pointer',
						// pill fill at 25% + 1px tone border, per the Swift Retry button
						background: `color-mix(in srgb, ${color} 25%, transparent)`,
						border: `1px solid ${color}`,
					}}
				>
					{actionLabel}
				</button>
			)}

			{onDismiss && (
				<button
					type="button"
					aria-label="Dismiss"
					title="Dismiss"
					onClick={onDismiss}
					style={{
						flexShrink: 0,
						width: 20,
						height: 20,
						display: 'inline-flex',
						alignItems: 'center',
						justifyContent: 'center',
						padding: 0,
						border: 'none',
						background: 'transparent',
						borderRadius: 6,
						cursor: 'pointer',
						color: 'var(--lyr-ink-3)',
					}}
				>
					<svg
						width={11}
						height={11}
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						strokeWidth={2.5}
						strokeLinecap="round"
						strokeLinejoin="round"
						aria-hidden="true"
					>
						<path d="M6 6l12 12M18 6 6 18" />
					</svg>
				</button>
			)}
		</div>
	)
}
