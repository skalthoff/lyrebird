# Colour-blindness palette verification (#354)

The shipping **Purple** accent pair (`primary #887BFF` / `accent #CC2F71`)
tests *mildly*: under protanopia and deuteranopia the primary and accent both
drift toward similar grey-browns, so a colour-blind listener can lose the
visual distinction between the brand-primary "now playing" wash and an accent
call-to-action.

This directory documents the two colour-blind-safe fallback presets added in
`Theme.swift` — **Ocean** and **Forest** — plus the reproducible numbers that
back them. The presets are modelled by `ThemePreset` and guarded by
`macos/Tests/LyrebirdTests/ThemePresetTests.swift`.

## Palettes

| Preset | Primary   | Accent    | Axis |
|--------|-----------|-----------|------|
| Purple | `#887BFF` | `#CC2F71` | violet / magenta (shipping default) |
| Ocean  | `#3D7DD6` | `#47E0D0` | blue / teal-cyan — rides the blue–yellow channel that protanopes/deuteranopes retain |
| Forest | `#178A55` | `#FFD24D` | deep green / warm gold — large lightness gap keeps the pair separable when hue is lost |

App surfaces the brand colours sit on: `Theme.bg = #0C0622`,
`Theme.bgAlt = #140B30`.

## Contrast (WCAG 2.1 §1.4.11, UI-component threshold 3:1)

Primary and accent are used as large fills (swatch rings, badges, the
now-playing wash), so the governing minimum is **3:1**. Every preset clears it
on both dark surfaces:

| Preset | Primary vs `bg` | Primary vs `bgAlt` | Accent vs `bg` | Accent vs `bgAlt` |
|--------|-----------------|--------------------|----------------|-------------------|
| Purple | 5.94 | 5.64 | 3.96 | 3.76 |
| Ocean  | 4.79 | 4.55 | 12.06 | 11.46 |
| Forest | 4.51 | 4.29 | 13.69 | 13.01 |

## Dichromat separation

Primary↔accent Euclidean distance in Viénot-1999 dichromat-projected LMS
space (higher = more distinguishable to that viewer). The shipping pairs stay
well clear of the ~400 protanopia collapse seen with a naive green/gold pair
(`#52C46B`/`#E0B341`, rejected during tuning):

| Preset | Protanopia | Deuteranopia | Tritanopia |
|--------|-----------:|-------------:|-----------:|
| Purple | 3116 | 1512 | 2218 |
| Ocean  | 8362 | 6728 | 7104 |
| Forest | 7991 | 9866 | 9547 |

`ThemePresetTests` asserts Ocean/Forest separate by ≥1000 for every type.

## Auto-suggest

`ThemePreset.suggestedForAccessibility()` returns `.ocean` when
`NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor` is
set (System Settings → Accessibility → Display → "Differentiate without
color"). The Appearance preferences pane surfaces a hint steering toward Ocean
in that case. Full per-preset token resolution is the theme-engine work in
\#405; until then the presets back the picker swatches + this suggestion.

## Reproducing the numbers

The contrast and dichromat figures above are computed by the same maths as
`Color.contrastRatio` / `ThemePresetTests`. To regenerate:

```bash
python3 macos/docs/a11y/color-blindness/verify.py
```

## Capturing the before/after screenshots

The numeric verification above is the falsifiable, CI-guarded part. The
visual before/after grid still wants a human-driven GUI pass (a headless agent
can't drive the simulator):

1. Build + launch: `./macos/Scripts/a11y-audit.sh`.
2. Open **Xcode → Open Developer Tool → Accessibility Inspector**, or the free
   **Sim Daltonism** app, and point it at the running `Lyrebird` process.
3. For each preset (Purple / Ocean / Forest), open
   **Preferences → Appearance**, pick the theme, and capture the
   `Theme.primary` + `Theme.accent` swatches side by side.
4. Simulate **normal**, **protanopia**, **deuteranopia**, and **tritanopia**
   and save each as `<preset>-<vision>.png` in this directory.
