#!/usr/bin/env bash
# Regenerate docs/appcast.xml from the DMGs hosted on GitHub releases.
#
# Sparkle ships a `generate_appcast` binary inside the Sparkle framework
# that diffs a directory of DMGs against an existing appcast, signs each
# new entry with the Ed25519 private key, and rewrites the feed XML.
#
# This script wraps that binary with the Lyrebird-specific bits:
#   - Downloads every *.dmg asset from recent GitHub releases into a
#     throwaway staging directory.
#   - Feeds the private Ed25519 key via `SPARKLE_ED25519_PRIVATE` (base64)
#     so CI doesn't need to materialize it to disk.
#   - Points the `--download-url-prefix` at the github.com release URLs
#     (not the raw gh-pages host) so installers fetch the DMG directly
#     from the release, not a Pages mirror.
#   - Rewrites the output into docs/ so the `gh-pages` push in the
#     release workflow publishes it at skalthoff.github.io/lyrebird-desktop/appcast.xml.
#   - Generates Sparkle binary delta (.delta) files for the last N releases
#     (DELTA_MAX, default 3). Delta files are placed in $DMG_DIR alongside
#     the source DMGs and listed to stdout via DELTA_MANIFEST for the
#     release workflow to upload.
#   - Stamps beta items with <sparkle:channel>beta</sparkle:channel> when
#     RELEASE_CHANNEL=beta, so stable-only clients never see them.
#
# Environment:
#   SPARKLE_ED25519_PRIVATE   base64 private key (required unless --dry-run)
#   GITHUB_REPOSITORY         owner/repo (optional, defaults to skalthoff/lyrebird-desktop)
#   GITHUB_TOKEN              used by gh for release downloads (optional for public repos)
#   SPARKLE_VERSION           pinned Sparkle release used to fetch generate_appcast
#                             (optional, defaults to 2.6.4)
#   DELTA_MAX                 number of previous releases to generate deltas against
#                             (optional, defaults to 3)
#   RELEASE_CHANNEL           set to "beta" to tag appcast items with the beta channel;
#                             leave unset or empty for stable releases (optional)
#
# Usage:
#   ./macos/Scripts/generate-appcast.sh
#   ./macos/Scripts/generate-appcast.sh --dry-run   # syntax/logic test; no network, no key required

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      sed -n '2,36p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "usage: $0 [--dry-run]" >&2
      exit 2
      ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
DOCS="$ROOT/docs"
STAGING="$MACOS/build/appcast"
DMG_DIR="$STAGING/dmgs"
SPARKLE_DIR="$STAGING/sparkle"

: "${SPARKLE_VERSION:=2.6.4}"
: "${GITHUB_REPOSITORY:=skalthoff/lyrebird-desktop}"
# Maximum number of prior releases to generate binary deltas for. Sparkle
# clients pick the smallest available update path; 3 means a user on any of
# the last 3 releases gets a delta rather than a full DMG download.
: "${DELTA_MAX:=3}"
# Release channel: set to "beta" to stamp newly generated appcast items with
# <sparkle:channel>beta</sparkle:channel>. Leave empty for stable releases.
# Stable clients (beta opt-in off) never see beta items; opted-in clients see
# both and install whichever version is newer.
: "${RELEASE_CHANNEL:=}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> Dry-run mode: skipping network calls and key validation."
  echo "    Script syntax is OK."
  exit 0
fi

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

# Download every DMG from the latest release pages. We need (DELTA_MAX + 1)
# releases at minimum: the current release plus DELTA_MAX prior ones for delta
# generation. Fetching a small buffer (DELTA_MAX + 4) covers edge cases (e.g.
# releases with no DMG asset) without ballooning the staging directory.
DMG_FETCH_LIMIT=$(( DELTA_MAX + 4 ))
echo "==> Collecting DMGs from $GITHUB_REPOSITORY (last $DMG_FETCH_LIMIT releases)"
rm -f "$DMG_DIR"/*.dmg

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required to download release assets" >&2
  exit 1
fi

# `gh release list` emits tab-separated rows; extract the tag column.
# Fallback to empty list on first-ever run so the script doesn't hard-fail
# before any release exists — the workflow runs this *after* cutting the
# tag, so at minimum one release will always be present in CI.
TAGS=$(gh release list --repo "$GITHUB_REPOSITORY" --limit "$DMG_FETCH_LIMIT" --json tagName --jq '.[].tagName' || echo "")
if [[ -z "$TAGS" ]]; then
  echo "    no releases found yet — nothing to do."
  # Emit an empty appcast shell so `gh-pages` has something to publish.
  # Sparkle treats an empty <channel> as "no updates" which is exactly
  # what we want pre-1.0.
  cat > "$DOCS/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Lyrebird</title>
    <link>https://skalthoff.github.io/lyrebird-desktop/appcast.xml</link>
    <description>Most recent changes</description>
    <language>en</language>
  </channel>
</rss>
XML
  exit 0
fi

# Build a flat tag→filename mapping so the post-process step can inject
# tag segments into Sparkle's enclosure URLs. Sparkle's generate_appcast
# scans $DMG_DIR non-recursively and emits URLs as $PREFIX/$FILENAME with
# no tag segment — but GitHub release-asset URLs require the tag in the
# path. Rather than fight Sparkle's scanner, we let it produce tag-less
# URLs and rewrite them in a post-process pass below.
declare -a TAG_ARRAY=()
while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  echo "    tag: $tag"
  # Each tag's DMGs (Apple Silicon only — one DMG per release; #660).
  # All DMGs land in $DMG_DIR (flat) for Sparkle's scanner.
  gh release download "$tag" \
    --repo "$GITHUB_REPOSITORY" \
    --pattern "*.dmg" \
    --dir "$DMG_DIR" \
    --skip-existing \
    || { echo "    (no DMGs on $tag — skipping)"; continue; }
  TAG_ARRAY+=("$tag")
done <<<"$TAGS"

# Pass the private key via a temp file: generate_appcast reads the key via
# `--ed-key-file` (and older flavors via `SPARKLE_PRIVATE_ED_KEY`). Using
# the file keeps the key off `ps` and environment dumps in CI logs.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_ED25519_PRIVATE" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

# Prefix Sparkle uses for enclosure URLs. The per-tag segment is missing
# at this layer — generate_appcast emits $PREFIX/$FILENAME — so we insert
# the tag in the post-process pass below.
DOWNLOAD_URL_PREFIX="https://github.com/${GITHUB_REPOSITORY}/releases/download"

echo "==> Running generate_appcast (maximum-deltas=$DELTA_MAX, channel=${RELEASE_CHANNEL:-stable})"
# generate_appcast writes .delta files into $DMG_DIR alongside the source DMGs.
# The release workflow uploads those deltas to the current GitHub release; the
# post-process URL injection below then rewrites the delta enclosure URLs to
# include the correct tag segment (same as for the full DMG).
#
# --channel beta stamps every newly generated <item> with
# <sparkle:channel>beta</sparkle:channel>. Sparkle clients that have not opted
# in to beta updates receive an empty allowed-channels set and skip those items
# entirely. Clients with allowed channels ["beta"] see both stable items (no
# channel tag) and beta items, installing whichever version is newer.
CHANNEL_ARGS=()
if [[ -n "$RELEASE_CHANNEL" ]]; then
  CHANNEL_ARGS=(--channel "$RELEASE_CHANNEL")
fi

"$SPARKLE_BIN" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX/" \
  --link "https://skalthoff.github.io/lyrebird-desktop/" \
  --maximum-deltas "$DELTA_MAX" \
  ${CHANNEL_ARGS[@]+"${CHANNEL_ARGS[@]}"} \
  -o "$DOCS/appcast.xml" \
  "$DMG_DIR"

# List the generated .delta files so the calling workflow knows what to upload.
# We write the paths to $DELTA_MANIFEST (if set) and always print them to
# stdout for local inspection. Delta files are named by Sparkle using the
# pattern Lyrebird<buildTo>-<buildFrom>.delta.
DELTA_FILES=()
while IFS= read -r -d '' f; do
  DELTA_FILES+=("$f")
done < <(find "$DMG_DIR" -maxdepth 1 -name "*.delta" -print0 2>/dev/null)

if [[ ${#DELTA_FILES[@]} -gt 0 ]]; then
  echo "==> Generated ${#DELTA_FILES[@]} delta file(s):"
  for f in "${DELTA_FILES[@]}"; do
    echo "    $f"
  done
  if [[ -n "${DELTA_MANIFEST:-}" ]]; then
    printf '%s\n' "${DELTA_FILES[@]}" > "$DELTA_MANIFEST"
    echo "==> Delta manifest written to $DELTA_MANIFEST"
  fi
else
  echo "==> No delta files generated (expected on first 1-$DELTA_MAX releases)"
fi

# Post-process: rewrite each enclosure URL to include the tag segment.
# Each release tag has exactly one DMG asset (#660 — Apple Silicon only),
# so the filename → tag mapping is unambiguous: query each tag for its
# uploaded asset names and rewrite ${PREFIX}/<filename> →
# ${PREFIX}/<tag>/<filename>. Files Sparkle generates as deltas
# (Lyrebird<build>-<deltaFrom>.delta) are uploaded to the most recent tag,
# so we rewrite delta enclosures using the latest tag. Fixes #742.
echo "==> Injecting tag segments into enclosure URLs"
for tag in "${TAG_ARRAY[@]}"; do
  # Get the asset names actually uploaded to this tag.
  assets=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')
  while IFS= read -r asset; do
    [[ -z "$asset" ]] && continue
    # Escape regex metacharacters in asset names (dots especially).
    escaped=$(printf '%s' "$asset" | sed 's/[][\.*^$/]/\\&/g')
    # Replace bare /releases/download/$asset with /releases/download/$tag/$asset.
    # Only rewrites if the URL is currently bare (no tag segment).
    sed -i.bak -E "s|(/releases/download/)($escaped)\"|\1${tag}/\2\"|g" "$DOCS/appcast.xml"
  done <<<"$assets"
done
rm -f "$DOCS/appcast.xml.bak"

# Delta files are generated locally and will be uploaded to the current
# (latest) release by the workflow. They are not yet present as GitHub
# release assets, so the loop above cannot inject their tag segments.
# Inject the latest tag for any remaining bare .delta enclosure URLs now.
if [[ ${#DELTA_FILES[@]} -gt 0 && ${#TAG_ARRAY[@]} -gt 0 ]]; then
  LATEST_TAG="${TAG_ARRAY[0]}"
  echo "==> Injecting tag segment for delta enclosures (tag: $LATEST_TAG)"
  for f in "${DELTA_FILES[@]}"; do
    delta_name="$(basename "$f")"
    escaped_delta=$(printf '%s' "$delta_name" | sed 's/[][\.*^$/]/\\&/g')
    sed -i.bak -E "s|(/releases/download/)($escaped_delta)\"|\1${LATEST_TAG}/\2\"|g" "$DOCS/appcast.xml"
  done
  rm -f "$DOCS/appcast.xml.bak"
fi

# Sanity-check: assert no tag-less enclosure URLs slipped through. If we
# shipped an appcast with bare /releases/download/<filename>.dmg entries
# (the #742 bug), every Sparkle client would 404 silently. This grep
# fails the build before publish so a broken appcast never hits gh-pages.
if grep -qE 'enclosure url="[^"]*/releases/download/[^/"]+\.(dmg|delta)"' "$DOCS/appcast.xml"; then
  echo "error: appcast contains tag-less enclosure URL. Each <enclosure url> must include the tag segment (e.g. .../releases/download/v1.0.0/Lyrebird-1.0.0.dmg). See #742." >&2
  grep -nE 'enclosure url="[^"]*/releases/download/[^/"]+\.(dmg|delta)"' "$DOCS/appcast.xml" >&2 | head -5
  exit 1
fi

echo "==> Wrote $DOCS/appcast.xml ($(wc -l < "$DOCS/appcast.xml") lines)"

