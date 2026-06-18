import type { CSSProperties } from 'react'

/** Severity of the toast. The app ships only `error`; reserved for future use. */
export type ToastTone = 'info' | 'warning' | 'error'

export interface ToastProps {
	/**
	 * Severity — drives the leading-rule color. `error` (default) matches the
	 * app's `ErrorToast` danger treatment. `warning` / `info` swap the rule to
	 * the amber / neutral token for forward compatibility.
	 */
	tone?: ToastTone
	/** The user-facing message. Presentation-quality; clamps to 3 lines. */
	message: string
	/** Clears the toast (the caller owns the message slot, as in the Swift). */
	onDismiss?: () => void
	style?: CSSProperties
}

/** Leading-rule color per tone. `error` → danger, matching `ErrorToast`. */
function toneColor(tone: ToastTone): string {
	switch (tone) {
		case 'warning':
			return 'var(--lyr-warning)'
		case 'info':
			return 'var(--lyr-ink-2)'
		default:
			return 'var(--lyr-danger)'
	}
}

/**
 * Floating error toast — the app's `ErrorToast`, mounted top-trailing over the
 * active screen. An alert glyph + message and a trailing close button on a
 * `--lyr-bg-alt` card: a 3px danger leading rule, a hairline border, 8px radius,
 * and a drop shadow. Capped at 420px wide. Presentational only — the host owns
 * the auto-dismiss timer the Swift view runs.
 */
export function Toast({ tone = 'error', message, onDismiss, style }: ToastProps) {
	const color = toneColor(tone)
	return (
		<div
			role="alert"
			style={{
				position: 'relative',
				display: 'flex',
				alignItems: 'center',
				gap: 12,
				maxWidth: 420,
				boxSizing: 'border-box',
				padding: '10px 16px',
				fontFamily: 'var(--lyr-font)',
				background: 'var(--lyr-bg-alt)',
				border: '1px solid var(--lyr-border)',
				borderRadius: 8,
				boxShadow: '0 4px 12px rgba(0, 0, 0, 0.35)',
				overflow: 'hidden',
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

			{/* exclamationmark.triangle.fill — drawn inline (no alert glyph in Icon yet) */}
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
				<rect x="11" y="8.5" width="2" height="6" rx="1" fill="var(--lyr-bg-alt)" />
				<circle cx="12" cy="17" r="1.1" fill="var(--lyr-bg-alt)" />
			</svg>

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
