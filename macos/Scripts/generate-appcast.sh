#!/usr/bin/env bash
# Regenerate docs/appcast.xml from the DMGs hosted on GitHub releases.
#
# Sparkle ships a `generate_appcast` binary inside the Sparkle framework
# that diffs a directory of DMGs against an existing appcast, signs each
# new entry with the Ed25519 private key, and rewrites the feed XML.
#
# This script wraps that binary with the Jellify-specific bits:
#   - Downloads every *.dmg asset from recent GitHub releases into a
#     throwaway staging directory.
#   - Feeds the private Ed25519 key via `SPARKLE_ED25519_PRIVATE` (base64)
#     so CI doesn't need to materialize it to disk.
#   - Points the `--download-url-prefix` at the github.com release URLs
#     (not the raw gh-pages host) so installers fetch the DMG directly
#     from the release, not a Pages mirror.
#   - Rewrites the output into docs/ so the `gh-pages` push in the
#     release workflow publishes it at skalthoff.github.io/jellify-desktop/appcast.xml.
#
# Environment:
#   SPARKLE_ED25519_PRIVATE   base64 private key (required)
#   GITHUB_REPOSITORY         owner/repo (optional, defaults to skalthoff/jellify-desktop)
#   GITHUB_TOKEN              used by gh for release downloads (optional for public repos)
#   SPARKLE_VERSION           pinned Sparkle release used to fetch generate_appcast
#                             (optional, defaults to 2.6.4)
#
# Usage: ./macos/Scripts/generate-appcast.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
DOCS="$ROOT/docs"
STAGING="$MACOS/build/appcast"
DMG_DIR="$STAGING/dmgs"
SPARKLE_DIR="$STAGING/sparkle"

: "${SPARKLE_VERSION:=2.6.4}"
: "${GITHUB_REPOSITORY:=skalthoff/jellify-desktop}"

if [[ -z "${SPARKLE_ED25519_PRIVATE:-}" ]]; then
  echo "error: SPARKLE_ED25519_PRIVATE is not set. Export the base64 private key before running." >&2
  exit 1
fi

mkdir -p "$DOCS" "$DMG_DIR" "$SPARKLE_DIR"

# Pull the Sparkle distribution tarball once; generate_appcast lives at
# bin/generate_appcast inside it. We cache inside $STAGING so reruns are
# cheap locally. CI runs are ephemeral so the cache effectively resets,
# which is fine — the download is a few MB.
SPARKLE_BIN="$SPARKLE_DIR/bin/generate_appcast"
if [[ ! -x "$SPARKLE_BIN" ]]; then
  echo "==> Fetching Sparkle $SPARKLE_VERSION"
  tar_url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  curl -fsSL "$tar_url" -o "$SPARKLE_DIR/sparkle.tar.xz"
  tar -xf "$SPARKLE_DIR/sparkle.tar.xz" -C "$SPARKLE_DIR"
  if [[ ! -x "$SPARKLE_BIN" ]]; then
    echo "error: generate_appcast not found after extract (looked at $SPARKLE_BIN)" >&2
    exit 1
  fi
fi

# Download every DMG from the latest release pages. We don't keep *every*
# historical DMG in the appcast — Sparkle only needs the current feed plus
# whatever entries we choose to keep for deltas. 10 most recent covers
# multi-step upgrades without ballooning the feed.
echo "==> Collecting DMGs from $GITHUB_REPOSITORY (last 10 releases)"
rm -f "$DMG_DIR"/*.dmg

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required to download release assets" >&2
  exit 1
fi

# `gh release list` emits tab-separated rows; extract the tag column.
# Fallback to empty list on first-ever run so the script doesn't hard-fail
# before any release exists — the workflow runs this *after* cutting the
# tag, so at minimum one release will always be present in CI.
TAGS=$(gh release list --repo "$GITHUB_REPOSITORY" --limit 10 --json tagName --jq '.[].tagName' || echo "")
if [[ -z "$TAGS" ]]; then
  echo "    no releases found yet — nothing to do."
  # Emit an empty appcast shell so `gh-pages` has something to publish.
  # Sparkle treats an empty <channel> as "no updates" which is exactly
  # what we want pre-1.0.
  cat > "$DOCS/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Jellify</title>
    <link>https://skalthoff.github.io/jellify-desktop/appcast.xml</link>
    <description>Most recent changes</description>
    <language>en</language>
  </channel>
</rss>
XML
  exit 0
fi

while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  echo "    tag: $tag"
  # Each tag's DMGs go into their own subdir so generate_appcast emits
  # relative paths like "$tag/Jellify-X.Y.Z.dmg". Combined with the
  # url-prefix below (.../releases/download/), this produces the working
  # GitHub release-asset URL .../releases/download/$tag/Jellify-X.Y.Z.dmg.
  # Flat layout would drop the $tag segment and 404. Fixes #742.
  mkdir -p "$DMG_DIR/$tag"
  gh release download "$tag" \
    --repo "$GITHUB_REPOSITORY" \
    --pattern "*.dmg" \
    --dir "$DMG_DIR/$tag" \
    --skip-existing \
    || echo "    (no DMGs on $tag — skipping)"
done <<<"$TAGS"

# Pass the private key via a temp file: generate_appcast reads the key via
# `--ed-key-file` (and older flavors via `SPARKLE_PRIVATE_ED_KEY`). Using
# the file keeps the key off `ps` and environment dumps in CI logs.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_ED25519_PRIVATE" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

# Prefix used when rewriting download URLs in the feed. Each DMG must be
# reachable at ${PREFIX}/${TAG}/${FILENAME} so Sparkle clients can fetch
# it directly from the GitHub release. The ${TAG}/${FILENAME} portion is
# emitted by generate_appcast as a *relative path* derived from each DMG's
# location under $DMG_DIR — see the per-tag subdir layout above.
DOWNLOAD_URL_PREFIX="https://github.com/${GITHUB_REPOSITORY}/releases/download"

echo "==> Running generate_appcast"
"$SPARKLE_BIN" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX/" \
  --link "https://skalthoff.github.io/jellify-desktop/" \
  -o "$DOCS/appcast.xml" \
  "$DMG_DIR"

# Sanity-check: assert the regenerated appcast contains tag-prefixed enclosure
# URLs. If we shipped an appcast with bare /releases/download/<filename>.dmg
# entries (the bug fixed in #742), every Sparkle client would 404 silently.
# This grep fails the build before publish so a broken appcast never hits
# gh-pages.
if grep -q 'enclosure url="[^"]*/releases/download/[^/"]*\.dmg"' "$DOCS/appcast.xml"; then
  echo "error: appcast contains tag-less enclosure URL. Each <enclosure url> must include the tag segment (e.g. .../releases/download/v1.0.0/Jellify-1.0.0.dmg). See #742." >&2
  exit 1
fi

echo "==> Wrote $DOCS/appcast.xml ($(wc -l < "$DOCS/appcast.xml") lines)"

