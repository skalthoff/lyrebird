#!/usr/bin/env bash
# Wrap the swift-build executable as a Jellify.app bundle.
#
# Info.plist is copied from `macos/Resources/Info.plist` (a real, checked-in
# template). This script injects `$VERSION` and `$BUILD` via `plutil -replace`
# before the codesign pass.
#
# Resolution order for version metadata:
#   1. $VERSION / $BUILD env vars (CI and release scripts set these).
#   2. git describe / commit count (useful for local dev builds).
#   3. Fallback: 0.0.0-dev / 0.
#
# Usage:
#   ./macos/Scripts/make-bundle.sh                      # debug build
#   ./macos/Scripts/make-bundle.sh --release            # release build
#
# Apple Silicon only — Intel was dropped from M4 distribution. swift-build
# outputs land under `<triple>/<profile>` and the bundle is single-arch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
RESOURCES="$MACOS/Resources"
INFO_TEMPLATE="$RESOURCES/Info.plist"
APP="$MACOS/build/Jellify.app"

PROFILE="debug"
for arg in "$@"; do
    case "$arg" in
        --release) PROFILE="release" ;;
        --debug)   PROFILE="debug"   ;;
        -h | --help)
            sed -n '2,17p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "usage: $0 [--release|--debug]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$INFO_TEMPLATE" ]]; then
    echo "error: Info.plist template not found at $INFO_TEMPLATE" >&2
    exit 1
fi

# swift-build single-arch output directory.
BUILD_DIR="$MACOS/.build/arm64-apple-macosx/$PROFILE"
EXE="$BUILD_DIR/Jellify"

if [[ ! -x "$EXE" ]]; then
    echo "error: Jellify executable not found at $EXE" >&2
    echo "       run './macos/Scripts/build-core.sh --release' + 'swift build -c release' first" >&2
    exit 1
fi

# Resolve version + build.
VERSION="${VERSION:-}"
BUILD="${BUILD:-}"

if [[ -z "$VERSION" ]]; then
    if VERSION_FROM_GIT="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null)"; then
        # Strip a leading "v" if the tag uses one.
        VERSION="${VERSION_FROM_GIT#v}"
    else
        VERSION="0.0.0-dev"
    fi
fi

if [[ -z "$BUILD" ]]; then
    if BUILD_FROM_GIT="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)"; then
        BUILD="$BUILD_FROM_GIT"
    else
        BUILD="0"
    fi
fi

# Clean up any half-built bundle on error so reruns start fresh.
cleanup() {
    if [[ -n "${TMP_PLIST:-}" && -f "$TMP_PLIST" ]]; then
        rm -f "$TMP_PLIST"
    fi
}
trap cleanup EXIT

echo "==> Building $APP ($PROFILE)"
echo "    version: $VERSION (build $BUILD)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/Jellify"

# Copy our resources straight into Contents/Resources/. We deliberately
# do NOT use SPM's resource processing (`resources: [.process(...)]` in
# Package.swift) because its generated accessor expects the bundle at
# the .app top level, which violates macOS .app structure rules:
#
#   codesign refuses with "unsealed contents present in the bundle root"
#   when anything other than Contents/ sits at the .app root.
#
# So `Sources/Jellify/Resources/{Fonts,Localizable.xcstrings,...}` ends
# up under `Contents/Resources/` directly. Code that needs them reads
# via `Bundle.main.url(forResource:withExtension:)` — see
# `FontRegistration.register()` in Theme.swift. SwiftUI's
# `LocalizedStringKey` auto-discovers Localizable.xcstrings in
# Bundle.main, so no Swift-side change for the i18n path.
RES_SRC="$MACOS/Sources/Jellify/Resources"
if [[ -d "$RES_SRC" ]]; then
    # Localizable.xcstrings is the source format. SwiftUI's
    # LocalizedStringKey can't read xcstrings directly — it looks for
    # compiled `<lang>.lproj/Localizable.strings` files. Compile via
    # xcstringstool so the .app gets the runtime layout SwiftUI expects.
    # Without this step, every LocalizedStringKey site falls through to
    # rendering its lookup key (`auth.sign_in`, `app.name`, etc.).
    if [[ -f "$RES_SRC/Localizable.xcstrings" ]] && command -v xcrun >/dev/null 2>&1; then
        xcrun xcstringstool compile "$RES_SRC/Localizable.xcstrings" \
            -o "$APP/Contents/Resources/" 2>/dev/null || \
            cp "$RES_SRC/Localizable.xcstrings" "$APP/Contents/Resources/"
    fi
    # Fonts/*.otf — flatten into Contents/Resources/ so Bundle.main
    # finds them with `url(forResource: "Figtree-Bold", withExtension:
    # "otf")`. The pattern matches our existing CTFontManager call site
    # which doesn't hunt subdirectories.
    if [[ -d "$RES_SRC/Fonts" ]]; then
        find "$RES_SRC/Fonts" -type f -name "*.otf" -exec cp {} "$APP/Contents/Resources/" \;
    fi
fi

# Copy the app icon if it has been produced. This is intentionally soft:
# the icon pipeline is tracked in a separate issue and we don't want to
# block dev builds on it.
if [[ -f "$RESOURCES/AppIcon.icns" ]]; then
    cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Sparkle 2 ships as a .framework bundle via SwiftPM. swift-build materializes
# it into BUILD_DIR; copy it next to the binary under Contents/Frameworks so
# the @rpath/Sparkle.framework reference resolves at runtime.
SPARKLE_SRC="$BUILD_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_SRC" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
    # The Swift binary is linked with a single @executable_path rpath (pointing
    # at Contents/MacOS/). Add @executable_path/../Frameworks so dyld can find
    # Sparkle.framework after we drop it under Contents/Frameworks.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/Jellify" 2>/dev/null || true

    # install_name_tool rewrote load commands in page 0 of __TEXT, invalidating
    # the ad-hoc signature swift-build stamped on the executable. macOS 26's
    # kernel refuses to map pages whose hashes don't match the embedded seal
    # and kills the process on launch with "CODESIGNING Invalid Page" before
    # main runs. Re-seal ad-hoc here so dev builds launch; sign.sh supersedes
    # this with a real Developer ID signature for distribution.
    #
    codesign --force --sign - "$APP/Contents/MacOS/Jellify"
fi

# Drop the template into the bundle, then patch $VERSION / $BUILD in place.
TMP_PLIST="$APP/Contents/Info.plist"
cp "$INFO_TEMPLATE" "$TMP_PLIST"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$TMP_PLIST"
plutil -replace CFBundleVersion            -string "$BUILD"   "$TMP_PLIST"

# Substitute Sparkle's public Ed25519 key. The template ships the literal
# placeholder `@@SPARKLE_PUBLIC_ED_KEY@@`; release builds replace it with
# the real key from $SPARKLE_PUBLIC_ED_KEY. Local dev runs typically leave
# it unset — we replace with an empty string so Sparkle silently disables
# auto-update at launch instead of failing its key-length check and taking
# the app down before main runs.
plutil -replace SUPublicEDKey -string "${SPARKLE_PUBLIC_ED_KEY:-}" "$TMP_PLIST"

# Fail loudly if the template drifted into something Core Foundation can't
# parse — this is the check issue #177 asks for.
plutil -lint "$TMP_PLIST" >/dev/null

TMP_PLIST=""  # disarm cleanup; the bundle owns it now

echo "==> Built $APP"
