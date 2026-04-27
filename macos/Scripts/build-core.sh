#!/usr/bin/env bash
# Build the jellify_core Rust library for macOS and wrap it as an XCFramework
# that the Swift package can consume.
#
# Apple Silicon only. The Intel slice was dropped after the audit (the
# install base no longer justifies the multi-arch build complexity, and
# SwiftPM xcframework consumption with `swift build --arch arm64 --arch
# x86_64` is broken under Xcode 26 — see #660).
#
# Usage:
#   ./macos/Scripts/build-core.sh                 # debug
#   ./macos/Scripts/build-core.sh --release       # release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
PROFILE="debug"
CARGO_FLAGS=""

for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            CARGO_FLAGS="--release"
            ;;
        --debug)
            PROFILE="debug"
            CARGO_FLAGS=""
            ;;
        -h | --help)
            sed -n '2,12p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "usage: $0 [--release|--debug]" >&2
            exit 2
            ;;
    esac
done

ARM64_TARGET="aarch64-apple-darwin"
ARM64_STATIC="$ROOT/target/$ARM64_TARGET/$PROFILE/libjellify_core.a"

# Scratch dirs we might touch; cleaned up on failure so a re-run isn't
# bitten by a half-written xcframework.
GEN="$MACOS/build/generated"
HEADERS="$MACOS/build/Headers"
XCF="$MACOS/Jellify.xcframework"

cleanup_on_failure() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "==> build-core.sh failed (exit $code); cleaning scratch dirs" >&2
        rm -rf "$GEN" "$HEADERS"
        # Leave the xcframework alone if it was a completed prior run —
        # only remove it if we started rewriting it this run.
        if [[ -n "${XCF_IN_PROGRESS:-}" ]]; then
            rm -rf "$XCF"
        fi
    fi
    return $code
}
trap cleanup_on_failure EXIT

echo "==> Building jellify_core ($PROFILE)"
(cd "$ROOT" && cargo build $CARGO_FLAGS --target "$ARM64_TARGET" -p jellify_core)
if [[ ! -f "$ARM64_STATIC" ]]; then
    echo "error: arm64 static lib not found at $ARM64_STATIC" >&2
    exit 1
fi

echo "==> Building uniffi-bindgen"
(cd "$ROOT" && cargo build $CARGO_FLAGS --bin uniffi-bindgen -p jellify_core)

# The library was built for arm64 above; that's where the dylib lives.
# (When building only the uniffi-bindgen bin, cargo doesn't materialize the
# cdylib for the host target, so we can't rely on target/$PROFILE/ for it.)
DYLIB="$ROOT/target/$ARM64_TARGET/$PROFILE/libjellify_core.dylib"
BINDGEN="$ROOT/target/$PROFILE/uniffi-bindgen"

if [[ ! -f "$DYLIB" ]]; then
    echo "error: dylib not found at $DYLIB" >&2
    exit 1
fi

echo "==> Generating Swift bindings -> $GEN"
rm -rf "$GEN"
mkdir -p "$GEN"
# bindgen's --library mode runs `cargo metadata` internally, which needs to be
# invoked from inside the workspace.
(cd "$ROOT" && "$BINDGEN" generate --library "$DYLIB" --language swift --out-dir "$GEN")

# UniFFI produces: <name>.swift, <name>FFI.h, <name>FFI.modulemap.
# We consume the Swift in our own target and the header+modulemap in the xcframework.
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$GEN"/*.h "$HEADERS/"

# The generated Swift file looks for `import jellify_coreFFI` (see the
# `#if canImport(jellify_coreFFI)` block). The C module name must match.
cat > "$HEADERS/module.modulemap" <<'EOF'
module jellify_coreFFI {
    header "jellify_coreFFI.h"
    export *
}
EOF

echo "==> Creating $XCF"
XCF_IN_PROGRESS=1
rm -rf "$XCF"
xcodebuild -create-xcframework \
    -library "$ARM64_STATIC" \
    -headers "$HEADERS" \
    -output "$XCF" >/dev/null
XCF_IN_PROGRESS=

# Place the generated Swift source where the SPM target picks it up.
DEST="$MACOS/Sources/JellifyCore/Generated"
mkdir -p "$DEST"
cp "$GEN/jellify_core.swift" "$DEST/jellify_core.swift"

echo "==> Done."
echo "    xcframework : $XCF"
echo "    swift source: $DEST/jellify_core.swift"
