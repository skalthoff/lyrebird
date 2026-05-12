#!/usr/bin/env bash
# Build a distribution DMG from a signed Lyrebird.app.
#
# Uses `create-dmg` (`brew install create-dmg`). We sign the DMG with the
# same identity the app was signed with, but deliberately do NOT pass
# `--notarize` to create-dmg — notarization happens via
# `macos/Scripts/notarize.sh` as a separate, retriable step. Driving
# notarization from two places leads to double-submissions and opaque
# failure modes.
#
# Layout assumptions:
#   - App bundle is at build/Lyrebird.app (or passed as $1).
#   - Output DMG goes to build/Lyrebird-$VERSION.dmg.
#   - Optional cosmetic assets (volume icon + background image) live in
#     macos/Resources/. They're soft-optional; a missing background just
#     drops the arguments.
#
# Usage:
#   VERSION=0.2.0 DEVELOPER_ID="Developer ID Application: Jane (TEAMID)" \
#     ./macos/Scripts/make-dmg.sh                      # uses build/Lyrebird.app
#   ./macos/Scripts/make-dmg.sh path/to/Lyrebird.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$MACOS_DIR/.." && pwd)"
RESOURCES="$MACOS_DIR/Resources"
BUILD_DIR="$MACOS_DIR/build"

APP="${1:-$BUILD_DIR/Lyrebird.app}"

if [[ ! -d "$APP" ]]; then
    echo "error: Lyrebird.app not found at $APP" >&2
    echo "       pass an explicit path or run make-bundle.sh first" >&2
    exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not installed (brew install create-dmg)" >&2
    exit 1
fi

# Resolve version — same order as make-bundle.sh so the DMG filename and
# CFBundleShortVersionString stay in lockstep.
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
    if VERSION_FROM_GIT="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null)"; then
        VERSION="${VERSION_FROM_GIT#v}"
    else
        VERSION="0.0.0-dev"
    fi
fi

IDENTITY="${DEVELOPER_ID:-}"
DMG_NAME="Lyrebird-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# create-dmg expects to be pointed at a staging directory containing
# exactly the files that should appear in the mounted volume. Anything
# else in build/ would otherwise get swept in.
STAGE="$(mktemp -d -t lyrebird-dmg.XXXXXX)"

cleanup() {
    local code=$?
    rm -rf "$STAGE"
    # Half-built DMGs are useless; scrub on failure so a rerun is clean.
    if [[ $code -ne 0 && -f "$DMG_PATH" ]]; then
        rm -f "$DMG_PATH"
    fi
}
trap cleanup EXIT

echo "==> Preparing DMG staging"
cp -R "$APP" "$STAGE/"

mkdir -p "$BUILD_DIR"
rm -f "$DMG_PATH"
# create-dmg also writes a "rw.<target>.dmg" scratch file next to the
# output; clean stale ones up front.
rm -f "$BUILD_DIR"/rw.*.dmg 2>/dev/null || true

CREATE_DMG_ARGS=(
    --volname          "Lyrebird"
    --window-pos       200 120
    --window-size      660 400
    --icon-size        96
    --icon             "Lyrebird.app" 180 170
    --hide-extension   "Lyrebird.app"
    --app-drop-link    480 170
)

if [[ -f "$RESOURCES/AppIcon.icns" ]]; then
    CREATE_DMG_ARGS+=( --volicon "$RESOURCES/AppIcon.icns" )
fi
if [[ -f "$RESOURCES/dmg-background.png" ]]; then
    CREATE_DMG_ARGS+=( --background "$RESOURCES/dmg-background.png" )
fi
if [[ -n "$IDENTITY" ]]; then
    CREATE_DMG_ARGS+=( --codesign "$IDENTITY" )
else
    echo "warning: DEVELOPER_ID not set — DMG will not be signed." >&2
    echo "         notarization will reject an unsigned DMG. Set DEVELOPER_ID" >&2
    echo "         and re-run before shipping." >&2
fi

echo "==> Building $DMG_PATH"
create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGE/"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: create-dmg exited 0 but $DMG_PATH is missing" >&2
    exit 1
fi

echo "==> Built $DMG_PATH"
echo "    next step: ./macos/Scripts/notarize.sh \"$DMG_PATH\""
