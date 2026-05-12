#!/usr/bin/env bash
# Submit a signed artifact (DMG or zipped .app) to Apple's notary service,
# wait for the verdict, and staple the ticket on success.
#
# Uses a keychain profile (see the one-time bootstrap below). The profile
# name defaults to `lyrebird-notary` but can be overridden via $NOTARY_PROFILE.
#
# One-time local bootstrap (do this once per machine):
#
#   xcrun notarytool store-credentials lyrebird-notary \
#     --apple-id       "$APPLE_ID" \
#     --team-id        "$APPLE_TEAM_ID" \
#     --password       "$APPLE_NOTARY_APP_PASSWORD"
#
# Create the app-specific password at https://appleid.apple.com (Sign-In
# and Security → App-Specific Passwords). Team ID is on your Membership
# page in the developer portal.
#
# Usage:
#   ./macos/Scripts/notarize.sh path/to/Lyrebird-0.2.0.dmg
#   NOTARY_PROFILE=other-profile ./macos/Scripts/notarize.sh some.dmg
set -euo pipefail

usage() {
    sed -n '2,21p' "${BASH_SOURCE[0]}"
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 2
fi

TARGET="$1"
PROFILE="${NOTARY_PROFILE:-lyrebird-notary}"

if [[ ! -e "$TARGET" ]]; then
    echo "error: target not found: $TARGET" >&2
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun not in PATH — install Xcode command line tools" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq not installed (brew install jq)" >&2
    exit 1
fi

# Work inside a temp dir so a failed / cancelled run doesn't litter logs
# alongside the target artifact.
SCRATCH="$(mktemp -d -t lyrebird-notarize.XXXXXX)"
LOG="$SCRATCH/submit.json"
LOG_DETAIL="$SCRATCH/detail.json"

cleanup() {
    local code=$?
    # Preserve logs on failure — they're the only clue to *why* notarization
    # was rejected. Success path: purge.
    if [[ $code -ne 0 ]]; then
        echo "" >&2
        echo "==> notarize.sh failed (exit $code)." >&2
        echo "    submission log: $LOG" >&2
        echo "    detail log:     $LOG_DETAIL" >&2
    else
        rm -rf "$SCRATCH"
    fi
}
trap cleanup EXIT

echo "==> Submitting $TARGET to Apple notary"
echo "    keychain profile: $PROFILE"
echo "    (this blocks until Apple returns a verdict — usually 1-10 min)"

set +e
xcrun notarytool submit "$TARGET" \
    --keychain-profile "$PROFILE" \
    --wait \
    --output-format json \
    > "$LOG"
submit_exit=$?
set -e

if [[ $submit_exit -ne 0 ]]; then
    echo "error: notarytool submit exited with status $submit_exit" >&2
    cat "$LOG" >&2 || true
    exit 1
fi

STATUS="$(jq -r '.status // ""' "$LOG")"
SUB_ID="$(jq -r '.id // ""' "$LOG")"

echo "==> Verdict: $STATUS"
echo "    submission id: $SUB_ID"

if [[ "$STATUS" != "Accepted" ]]; then
    if [[ -n "$SUB_ID" ]]; then
        echo "==> Fetching detail log for rejected submission"
        xcrun notarytool log "$SUB_ID" --keychain-profile "$PROFILE" "$LOG_DETAIL" || true
        if [[ -s "$LOG_DETAIL" ]]; then
            jq . "$LOG_DETAIL" || cat "$LOG_DETAIL"
        fi
    fi
    exit 1
fi

echo "==> Stapling notarization ticket to $TARGET"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

echo "==> $TARGET is notarized and stapled."
