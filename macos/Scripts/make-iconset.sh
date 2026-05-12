#!/usr/bin/env bash
# Render the Lyrebird app icon out of an SVG source, build the standard
# macOS .iconset directory, and compile it into Resources/AppIcon.icns.
#
# The .icns is what Finder, the Dock, Cmd-Tab, and Launchpad display, and
# what Sparkle shows in the "Install Update" dialog. Signed DMGs carry it
# too, so every release needs a fresh rebuild if the source SVG changed.
#
# Source resolution order:
#   1. design/icons/lyrebird-app.svg  (canonical — add here when the final
#      icon lands; doesn't exist yet as of this script's introduction)
#   2. design/project/assets/teal-icon.svg  (current placeholder in-tree)
#
# Output:
#   macos/Resources/AppIcon.icns
#   (filename matches CFBundleIconFile in Info.plist and the `cp` in
#   make-bundle.sh, so the produced .app actually picks up the icon.)
#
# Dependencies: macOS-native `sips` (renderer) and `iconutil` (compiler).
# No Homebrew packages required — both ship with Command Line Tools, so
# this works on a fresh `macos-14` GitHub runner with zero extra setup.
#
# Usage: ./macos/Scripts/make-iconset.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
RESOURCES="$MACOS/Resources"
BUILD="$MACOS/build/icon"
ICONSET="$BUILD/Lyrebird.iconset"
OUT="$RESOURCES/AppIcon.icns"

# Prefer the canonical icon, fall back to the teal placeholder in design/.
CANDIDATES=(
  "$ROOT/design/icons/lyrebird-app.svg"
  "$ROOT/design/project/assets/teal-icon.svg"
)
SRC=""
for c in "${CANDIDATES[@]}"; do
  if [[ -f "$c" ]]; then
    SRC="$c"
    break
  fi
done

if [[ -z "$SRC" ]]; then
  echo "error: no icon source found. Tried:" >&2
  for c in "${CANDIDATES[@]}"; do
    echo "  - $c" >&2
  done
  exit 1
fi

echo "==> Icon source: $SRC"

# sips can rasterize SVG on macOS 13+ via its built-in ImageIO/CoreSVG
# integration, but the behaviour is flaky — some complex gradients don't
# render. To stay robust, we try sips first and fall back to qlmanage when
# sips emits a blank image (detected by comparing output file size).
#
# Either path produces a PNG at the target resolution.
render_png() {
  local size=$1
  local output=$2

  # First attempt: sips directly off the SVG.
  if sips -s format png -z "$size" "$size" "$SRC" --out "$output" >/dev/null 2>&1; then
    # Trust sips only if it produced something plausibly non-empty.
    # SVGs this simple should never render under ~1 KB; empty PNG is
    # ~500 bytes. Anything below 1024 is suspect.
    if [[ -s "$output" ]] && [[ "$(stat -f%z "$output")" -gt 1024 ]]; then
      return 0
    fi
  fi

  # Fallback: qlmanage renders a preview then sips downsizes that.
  local tmp_preview
  tmp_preview="$(mktemp -d)/preview.png"
  qlmanage -t -s 1024 -o "$(dirname "$tmp_preview")" "$SRC" >/dev/null 2>&1 || true
  # qlmanage writes "<basename>.png" into the out-dir.
  local rendered
  rendered="$(dirname "$tmp_preview")/$(basename "$SRC").png"
  if [[ ! -f "$rendered" ]]; then
    echo "error: neither sips nor qlmanage could rasterize $SRC" >&2
    exit 1
  fi
  sips -s format png -z "$size" "$size" "$rendered" --out "$output" >/dev/null
}

mkdir -p "$RESOURCES" "$ICONSET"
rm -f "$ICONSET"/*.png "$OUT"

# macOS iconset layout — sizes and filenames are fixed by `iconutil`. Each
# logical size has a 1x and @2x variant. Omitting any entry causes
# iconutil to error out, so keep the full set even if a few look identical.
#
#   16x16     icon_16x16.png         | 16   1x
#   32x32     icon_16x16@2x.png      | 32   2x  (shared with 32 1x)
#   32x32     icon_32x32.png         | 32   1x
#   64x64     icon_32x32@2x.png      | 64   2x
#   128x128   icon_128x128.png       | 128  1x
#   256x256   icon_128x128@2x.png    | 256  2x  (shared with 256 1x)
#   256x256   icon_256x256.png       | 256  1x
#   512x512   icon_256x256@2x.png    | 512  2x  (shared with 512 1x)
#   512x512   icon_512x512.png       | 512  1x
#   1024x1024 icon_512x512@2x.png    | 1024 2x
declare -a SIZES=(16 32 32 64 128 256 256 512 512 1024)
declare -a NAMES=(
  "icon_16x16.png"
  "icon_16x16@2x.png"
  "icon_32x32.png"
  "icon_32x32@2x.png"
  "icon_128x128.png"
  "icon_128x128@2x.png"
  "icon_256x256.png"
  "icon_256x256@2x.png"
  "icon_512x512.png"
  "icon_512x512@2x.png"
)

for i in "${!SIZES[@]}"; do
  size="${SIZES[$i]}"
  name="${NAMES[$i]}"
  echo "    rendering $name (${size}x${size})"
  render_png "$size" "$ICONSET/$name"
done

echo "==> Compiling iconset -> $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "==> Done. $(ls -lh "$OUT" | awk '{print $5}') $OUT"
