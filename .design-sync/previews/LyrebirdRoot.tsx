import { LyrebirdRoot, type ThemePreset } from '@lyrebird/design-system'

function PresetCard({ preset }: { preset: ThemePreset }) {
	return (
		<LyrebirdRoot preset={preset} fill={false} style={{ padding: 16, borderRadius: 12, width: 180 }}>
			<div style={{ fontSize: 12, fontWeight: 700, textTransform: 'capitalize', marginBottom: 10 }}>
				{preset}
			</div>
			<div style={{ display: 'flex', gap: 10 }}>
				<div style={{ width: 44, height: 44, borderRadius: 8, background: 'var(--lyr-primary)' }} />
				<div style={{ width: 44, height: 44, borderRadius: 8, background: 'var(--lyr-accent)' }} />
				<div style={{ width: 44, height: 44, borderRadius: 8, background: 'var(--lyr-surface-2)', border: '1px solid var(--lyr-border)' }} />
			</div>
		</LyrebirdRoot>
	)
}

export const Purple = () => <PresetCard preset="purple" />
export const Ocean = () => <PresetCard preset="ocean" />
export const Forest = () => <PresetCard preset="forest" />
