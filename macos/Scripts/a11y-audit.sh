#!/usr/bin/env bash
# Build and launch the current Lyrebird.app for Accessibility Inspector
# audits. Accessibility Inspector itself cannot be driven from the command
# line, so the manual steps are:
#
#   1. Run this script.
#   2. Open Xcode -> Open Developer Tool -> Accessibility Inspector.
#   3. In Accessibility Inspector, use the target chooser at the top-left to
#      select the running "Lyrebird" process.
#   4. Switch to the Audit panel, click Run Audit, and walk the app through
#      each screen listed in ../docs/a11y/README.md.
#   5. Save each report as plain text to
#      ../docs/a11y/audits/<YYYY-MM-DD>/<screen>.txt.
#   6. Ctrl-C this script (or `kill $PID`) when done.
#
# By default this script only rebuilds the app and launches it; it does not
# touch any per-user state. Pass --fresh to wipe Lyrebird's saved preferences
# and Application Support data before launch so repeated audits run against
# a comparable empty state.
#
# Usage:
#   ./macos/Scripts/a11y-audit.sh           # build + launch current app
#   ./macos/Scripts/a11y-audit.sh --fresh   # also clear per-user state first
set -euo pipefail

BUNDLE_ID="org.lyrebird.desktop"
FRESH=0
for arg in "$@"; do
  case "$arg" in
    --fresh)
      FRESH=1
      ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "usage: $0 [--fresh]" >&2
      exit 2
      ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"

cd "$MACOS"

if [[ "$FRESH" -eq 1 ]]; then
  echo "==> Clearing per-user state for $BUNDLE_ID"
  PREFS="$HOME/Library/Preferences/${BUNDLE_ID}.plist"
  APP_SUPPORT="$HOME/Library/Application Support/lyrebird-desktop"
  if [[ -e "$PREFS" ]]; then
    rm -f "$PREFS"
    echo "   removed $PREFS"
  fi
  if [[ -d "$APP_SUPPORT" ]]; then
    rm -rf "$APP_SUPPORT"
    echo "   removed $APP_SUPPORT"
  fi
  # `defaults` caches preferences per-process; flush so the next launch
  # sees the deletion.
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

echo "==> Building lyrebird_core (xcframework)"
./Scripts/build-core.sh

echo "==> swift build"
swift build

echo "==> Wrapping as Lyrebird.app"
./Scripts/make-bundle.sh

APP="$MACOS/build/Lyrebird.app"
EXE="$APP/Contents/MacOS/Lyrebird"

if [[ ! -x "$EXE" ]]; then
  echo "error: Lyrebird executable not found at $EXE" >&2
  exit 1
fi

echo "==> Launching $APP"
"$EXE" &
PID=$!

cleanup() {
  if kill -0 "$PID" 2>/dev/null; then
    echo
    echo "==> Stopping Lyrebird (PID $PID)"
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

cat <<EOF

App is running (PID $PID).

Next steps:
  1. Xcode -> Open Developer Tool -> Accessibility Inspector.
  2. In Accessibility Inspector, select "Lyrebird" in the target chooser
     (top-left of the Inspector window).
  3. Open the Audit panel and run it against each screen listed in
     macos/docs/a11y/README.md (Login, Library, Search, Album Detail,
     empty-state Home, PlayerBar playing, PlayerBar idle).
  4. Save each audit report as plain text to
     macos/docs/a11y/audits/\$(date +%Y-%m-%d)/<screen>.txt.

Press Ctrl-C (or run: kill $PID) to stop the app when the sweep is done.
EOF

wait "$PID"
