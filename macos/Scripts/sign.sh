#!/usr/bin/env bash
# Code-sign a Lyrebird.app bundle inside-out with the hardened runtime.
#
# Uses the Developer ID Application identity named in $DEVELOPER_ID
# (falls back to the literal "Developer ID Application" which lets
# codesign auto-pick the unique cert in the keychain when there is only
# one).
#
# Run order matters: every nested Mach-O (frameworks, XPC services,
# embedded dylibs) must be signed before the enclosing bundle. We
# explicitly avoid `--deep`; it papers over real problems and is the
# most common cause of notary rejections.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Jane Doe (TEAMID123)" \
#     ./macos/Scripts/sign.sh path/to/Lyrebird.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS="$MACOS_DIR/Resources/Lyrebird.entitlements"

usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}"
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 2
fi

APP="$1"
IDENTITY="${DEVELOPER_ID:-Developer ID Application}"

if [[ ! -d "$APP" ]]; then
    echo "error: bundle not found: $APP" >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: entitlements file not found: $ENTITLEMENTS" >&2
    exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
    echo "error: codesign not in PATH — install Xcode command line tools" >&2
    exit 1
fi

# Detect "no identity" early so we don't partially sign the bundle.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    echo "warning: no 'Developer ID Application' identity visible in the default keychain." >&2
    echo "         set DEVELOPER_ID to your cert's exact common name, or install one." >&2
    echo "         continuing anyway — codesign will produce the definitive error." >&2
fi

echo "==> Signing $APP"
echo "    identity:    $IDENTITY"
echo "    entitlements: $ENTITLEMENTS"

# Any non-zero exit below leaves the bundle partially signed, which is a
# landmine. Emit a loud reminder to rebuild from scratch before retrying.
on_fail() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "" >&2
        echo "==> sign.sh failed (exit $code) — bundle at $APP is partially signed." >&2
        echo "    rerun make-bundle.sh to regenerate from scratch before retrying." >&2
    fi
}
trap on_fail EXIT

sign_one() {
    # Sign a single path with the hardened runtime + entitlements.
    # Entitlements are applied to bundle-level binaries (frameworks, the
    # app itself). Inner helper binaries (XPC / loose Mach-O) are signed
    # without entitlements — they inherit from the enclosing app.
    local target="$1"
    local with_ents="${2:-yes}"

    if [[ "$with_ents" == "yes" ]]; then
        codesign \
            --force \
            --timestamp \
            --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$IDENTITY" \
            "$target"
    else
        codesign \
            --force \
            --timestamp \
            --options runtime \
            --sign "$IDENTITY" \
            "$target"
    fi
}

# 1. Frameworks/*.framework — includes Sparkle.
#    codesign is inside-out: the seal of an outer bundle references the
#    seals of inner bundles, so any nested bundle or Mach-O must be
#    signed BEFORE the bundle that contains it. The earlier flat
#    "framework first, xpc after" loop signed in the wrong order and
#    missed Sparkle's nested .app + loose Autoupdate Mach-O entirely.
#
#    Sparkle's framework hosts a multi-tier internal layout:
#       Sparkle.framework/Versions/B/Sparkle           (framework binary)
#       Sparkle.framework/Versions/B/Autoupdate        (loose Mach-O)
#       Sparkle.framework/Versions/B/Updater.app/...   (nested .app)
#       Sparkle.framework/Versions/B/XPCServices/      (.xpc bundles)
#    Notary rejects the build if any fragment arrives unsigned. See
#    https://sparkle-project.org/documentation/sandboxing/ — we
#    implement the non-sandboxed recipe.
if [[ -d "$APP/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' fw; do
        fw_short="${fw#"$APP/"}"

        # 1a. Nested .xpc bundles inside the framework. Sort
        #     deepest-first so a nested-inside-nested arrangement still
        #     signs in dep order.
        while IFS= read -r -d '' xpc; do
            echo "    -> xpc:        ${xpc#"$APP/"}"
            sign_one "$xpc" no
        done < <(find "$fw" -type d -name "*.xpc" -print0 2>/dev/null | sort -rz)

        # 1b. Nested .app bundles inside the framework (Sparkle's
        #     Updater.app). Same deepest-first ordering.
        while IFS= read -r -d '' nested_app; do
            echo "    -> nested-app: ${nested_app#"$APP/"}"
            sign_one "$nested_app" no
        done < <(find "$fw" -type d -name "*.app" -print0 2>/dev/null | sort -rz)

        # 1c. Loose Mach-O binaries directly under Versions/*/ that
        #     aren't part of any nested bundle (Sparkle's Autoupdate).
        if [[ -d "$fw/Versions" ]]; then
            fw_basename="$(basename "$fw" .framework)"
            while IFS= read -r -d '' bin; do
                # Path RELATIVE to this framework — used for the case
                # patterns below so they match nested bundles inside
                # this framework without spuriously matching the outer
                # `.framework/` path component itself (the bug rc8
                # tripped: `*/*.framework/*` matched every file inside
                # Sparkle.framework and skipped them all, including
                # Autoupdate).
                rel="${bin#"$fw/"}"
                case "$rel" in
                    */*.app/*|*/*.xpc/*|*/*.framework/*) continue ;;
                    */Headers/*|*/Resources/*|*/Modules/*) continue ;;
                    *.app/*|*.xpc/*|*.framework/*) continue ;;
                    Headers/*|Resources/*|Modules/*|_CodeSignature/*) continue ;;
                esac
                [[ -f "$bin" && -x "$bin" ]] || continue
                file -b "$bin" 2>/dev/null | grep -q "Mach-O" || continue
                # The framework's own main binary is named after the
                # framework; signing the outer framework in 1d covers it.
                [[ "$(basename "$bin")" == "$fw_basename" ]] && continue
                echo "    -> fw-bin:     ${bin#"$APP/"}"
                sign_one "$bin" no
            done < <(find "$fw/Versions" -type f -print0 2>/dev/null)
        fi

        # 1d. Finally, the framework bundle itself. Its seal now
        #     references the freshly-signed inner bundles + binaries,
        #     which is what Apple's notary verifies.
        echo "    -> framework:  $fw_short"
        sign_one "$fw" yes
    done < <(find "$APP/Contents/Frameworks" -maxdepth 2 -type d -name "*.framework" -print0 2>/dev/null)

    # 2. Loose dylibs in Contents/Frameworks that aren't inside a
    #    framework bundle. Rare, but guard for the future.
    while IFS= read -r -d '' dylib; do
        echo "    -> dylib:      ${dylib#"$APP/"}"
        sign_one "$dylib" no
    done < <(find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null)
fi

# 3. Top-level XPC services (App.app/Contents/XPCServices/*.xpc) — if
#    an app ever ships its own beyond Sparkle's framework-internal ones.
if [[ -d "$APP/Contents/XPCServices" ]]; then
    while IFS= read -r -d '' xpc; do
        echo "    -> xpc:        ${xpc#"$APP/"}"
        sign_one "$xpc" no
    done < <(find "$APP/Contents/XPCServices" -maxdepth 1 -type d -name "*.xpc" -print0 2>/dev/null)
fi

# 4. Auxiliary helper executables under Contents/MacOS that aren't the
#    main binary. There usually aren't any, but guard for the future.
MAIN_EXE="$APP/Contents/MacOS/Lyrebird"
if [[ -d "$APP/Contents/MacOS" ]]; then
    while IFS= read -r -d '' helper; do
        if [[ "$helper" == "$MAIN_EXE" ]]; then
            continue
        fi
        echo "    -> helper: ${helper#"$APP/"}"
        sign_one "$helper" no
    done < <(find "$APP/Contents/MacOS" -type f -perm +111 -print0 2>/dev/null)
fi

# 5. Finally, the main app bundle itself.
echo "    -> bundle: $APP"
sign_one "$APP" yes

# 6. Verification. `--strict` rejects nested bundles with mismatched seals
#    (the classic notarization failure mode).
echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

# spctl's Developer ID verdict requires the app to have been notarized +
# stapled; run it anyway so the user sees what Gatekeeper will say.
# A "rejected: source=Unnotarized Developer ID" result is expected
# before notarize.sh + stapler runs.
echo "==> Gatekeeper preview (will say 'rejected' until notarization + stapling):"
spctl --assess --type execute --verbose=2 "$APP" || true

# Disarm failure trap now that we finished cleanly.
trap - EXIT
echo "==> Signed $APP"
