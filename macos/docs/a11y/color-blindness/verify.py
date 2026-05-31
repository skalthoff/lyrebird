#!/usr/bin/env python3
"""Reproduce the contrast + dichromat-separation numbers for the Lyrebird
theme presets.

Mirrors `Color.contrastRatio` (WCAG 2.1) and the Viénot-1999 dichromat
projection used in `ThemePresetTests`. Pure-stdlib so it runs anywhere.
"""

BG = 0x0C0622
BG_ALT = 0x140B30

PRESETS = {
    "Purple": (0x887BFF, 0xCC2F71),
    "Ocean": (0x3D7DD6, 0x47E0D0),
    "Forest": (0x178A55, 0xFFD24D),
}

# sRGB -> LMS (Hunt-Pointer-Estevez, Viénot 1999).
RGB2LMS = [
    [17.8824, 43.5161, 4.11935],
    [3.45565, 27.1554, 3.86714],
    [0.0299566, 0.184309, 1.46709],
]
DICHROMAT = {
    "protanopia": [[0, 2.02344, -2.52581], [0, 1, 0], [0, 0, 1]],
    "deuteranopia": [[1, 0, 0], [0.494207, 0, 1.24827], [0, 0, 1]],
    "tritanopia": [[1, 0, 0], [0, 1, 0], [-0.395913, 0.801109, 0]],
}


def _channels(hex_value):
    return ((hex_value >> 16) & 0xFF, (hex_value >> 8) & 0xFF, hex_value & 0xFF)


def relative_luminance(hex_value):
    def lin(raw):
        c = raw / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = _channels(hex_value)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast_ratio(a, b):
    la, lb = relative_luminance(a), relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _linear_rgb(hex_value):
    out = []
    for raw in _channels(hex_value):
        c = raw / 255.0
        lin = c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
        out.append(lin * 255.0)
    return out


def _matmul(m, v):
    return [m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] for i in range(3)]


def separation(a, b, kind):
    proj = DICHROMAT[kind]
    pa = _matmul(proj, _matmul(RGB2LMS, _linear_rgb(a)))
    pb = _matmul(proj, _matmul(RGB2LMS, _linear_rgb(b)))
    return sum((x - y) ** 2 for x, y in zip(pa, pb)) ** 0.5


def main():
    print("Contrast (WCAG 2.1) vs bg #0C0622 / bgAlt #140B30:")
    for name, (p, a) in PRESETS.items():
        print(
            f"  {name:7} primary {contrast_ratio(p, BG):5.2f}/{contrast_ratio(p, BG_ALT):5.2f}"
            f"   accent {contrast_ratio(a, BG):5.2f}/{contrast_ratio(a, BG_ALT):5.2f}"
        )
    print("\nPrimary/accent dichromat separation (higher = more distinguishable):")
    for name, (p, a) in PRESETS.items():
        sims = "  ".join(f"{k[:4]}={separation(p, a, k):4.0f}" for k in DICHROMAT)
        print(f"  {name:7} {sims}")


if __name__ == "__main__":
    main()
