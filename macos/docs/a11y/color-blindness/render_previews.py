#!/usr/bin/env python3
"""Render the before/after colour-blindness preview grids for the theme presets.

The picker swatch + accent a preset shows are fully determined by their hex
values, and the dichromat simulation is the same Viénot-1999 projection used by
`ThemePresetTests` / `verify.py`. So these grids are an exact, reproducible
render of the relevant pixels rather than a hand-captured simulator grab — which
also means they regenerate deterministically after any palette change:

    python3 macos/docs/a11y/color-blindness/render_previews.py

Each grid shows the Purple (shipping) pair beside the colour-blind-safe
Ocean/Forest pairs, under normal vision and under protanopia / deuteranopia —
the two deficiencies called out in the issue. "before" = Purple only (the prior
state). "after" = Purple + Ocean + Forest (the shipped state). Pure stdlib; no
Pillow required.
"""
import os
import struct
import zlib

BG = 0x0C0622  # Theme.bg

# (label, primaryHex, accentHex) — mirrors ThemePreset.
PURPLE = ("Purple", 0x887BFF, 0xCC2F71)
OCEAN = ("Ocean", 0x3D7DD6, 0x47E0D0)
FOREST = ("Forest", 0x178A55, 0xFFD24D)

# Viénot-1999 dichromat simulation (same matrices as ThemePresetTests / verify.py).
RGB2LMS = [
    [17.8824, 43.5161, 4.11935],
    [3.45565, 27.1554, 3.86714],
    [0.0299566, 0.184309, 1.46709],
]
LMS2RGB = [
    [0.0809444479, -0.130504409, 0.116721066],
    [-0.0102485335, 0.0540193266, -0.113614708],
    [-0.000365296938, -0.00412161469, 0.693511405],
]
DICHROMAT = {
    "normal": None,
    "protanopia": [[0, 2.02344, -2.52581], [0, 1, 0], [0, 0, 1]],
    "deuteranopia": [[1, 0, 0], [0.494207, 0, 1.24827], [0, 0, 1]],
}


def _channels(hexv):
    return ((hexv >> 16) & 0xFF, (hexv >> 8) & 0xFF, hexv & 0xFF)


def _matmul(m, v):
    return [m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] for i in range(3)]


def _srgb_to_linear(c):
    c /= 255.0
    return (c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4) * 255.0


def _linear_to_srgb(c):
    c = max(0.0, min(255.0, c)) / 255.0
    s = c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055
    return int(round(max(0.0, min(1.0, s)) * 255.0))


def simulate(hexv, kind):
    """Return an (r,g,b) tuple as seen by the given dichromat (or as-is)."""
    proj = DICHROMAT[kind]
    if proj is None:
        return _channels(hexv)
    lin = [_srgb_to_linear(c) for c in _channels(hexv)]
    lms = _matmul(RGB2LMS, lin)
    proj_lms = _matmul(proj, lms)
    back = _matmul(LMS2RGB, proj_lms)
    return tuple(_linear_to_srgb(c) for c in back)


def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw += bytes(pixels[y * width + x])
    comp = zlib.compressobj()
    data = comp.compress(bytes(raw)) + comp.flush()

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", data))
        f.write(chunk(b"IEND", b""))


SW = 70   # swatch size
GAP = 10  # gap between primary/accent within a pair
PAD = 18
COL_W = SW * 2 + GAP            # one preset pair
COL_GAP = 26
ROW_H = SW
ROW_GAP = 26


def render(presets, kinds, out_path):
    cols = len(presets)
    rows = len(kinds)
    width = PAD * 2 + cols * COL_W + (cols - 1) * COL_GAP
    height = PAD * 2 + rows * ROW_H + (rows - 1) * ROW_GAP
    bg = _channels(BG)
    pixels = [bg] * (width * height)

    def fill(x0, y0, w, h, color):
        for y in range(y0, min(y0 + h, height)):
            base = y * width
            for x in range(x0, min(x0 + w, width)):
                pixels[base + x] = color

    for r, kind in enumerate(kinds):
        y0 = PAD + r * (ROW_H + ROW_GAP)
        for c, (_, ph, ah) in enumerate(presets):
            x0 = PAD + c * (COL_W + COL_GAP)
            fill(x0, y0, SW, SW, simulate(ph, kind))
            fill(x0 + SW + GAP, y0, SW, SW, simulate(ah, kind))

    write_png(out_path, width, height, pixels)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    kinds = ["normal", "protanopia", "deuteranopia"]
    render([PURPLE], kinds, os.path.join(here, "before.png"))
    render([PURPLE, OCEAN, FOREST], kinds, os.path.join(here, "after.png"))
    print("wrote before.png (Purple) and after.png (Purple / Ocean / Forest)")
    print("rows: normal / protanopia / deuteranopia; each pair = primary + accent")


if __name__ == "__main__":
    main()
