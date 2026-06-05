#!/usr/bin/env bash
# rebase-tests-rs.sh — resolve the EOF-append collision in a core test file.
#
# Before the June 2026 domain split this targeted the single
# core/src/tests.rs. That file is now split into core/src/tests/<domain>.rs,
# so the collision is far rarer — but two PRs that both append tests to the
# *same* domain file still collide on its EOF. Pass the conflicted file:
#
#   Scripts/rebase-tests-rs.sh core/src/tests/<domain>.rs
#
# Behavior:
#   1. Take the main-side tests as the base (`git checkout --ours`).
#   2. Find the incoming commit's tests in the rebased commit's diff.
#   3. Append those tests to the end of the (main-side) file.
#   4. Sweep any leftover conflict markers as a last-resort cleanup.
#   5. Stage the file and remind the user to `git rebase --continue`.
set -euo pipefail

FILE="${1:-}"

if [[ -z "$FILE" ]]; then
  echo "usage: Scripts/rebase-tests-rs.sh core/src/tests/<domain>.rs" >&2
  echo "  (resolves an EOF-append conflict in one core test file)" >&2
  exit 2
fi

if [[ ! -f "$FILE" ]]; then
  echo "error: $FILE not found (cwd: $(pwd))" >&2
  exit 1
fi

# Are we mid-rebase?
if [[ ! -d ".git/rebase-merge" && ! -d ".git/rebase-apply" ]]; then
  echo "error: not in a rebase. Start one first (git rebase origin/main)." >&2
  exit 1
fi

# Check for conflict markers — if none, nothing to do.
if ! grep -q '^<<<<<<< ' "$FILE"; then
  echo "no conflict markers in $FILE; nothing to rebase here."
  exit 0
fi

echo "rebase-tests-rs: resolving $FILE..."

# Take main-side base and grab incoming side via git ls-files --unmerged.
# Stage 2 = ours (HEAD during rebase = main), Stage 3 = theirs (incoming PR).
ours_blob=$(git ls-files --unmerged "$FILE" | awk '$3 == 2 { print $2 }')
theirs_blob=$(git ls-files --unmerged "$FILE" | awk '$3 == 3 { print $2 }')

if [[ -z "$ours_blob" || -z "$theirs_blob" ]]; then
  echo "error: couldn't find both stage 2 (ours) and stage 3 (theirs) blobs" >&2
  exit 1
fi

# 1. Reset working file to ours (main-side).
git show ":2:$FILE" > "$FILE"

# 2. Compute the diff between (ours) and (theirs). The PR appended at EOF,
#    so the new content is everything after the last common line. Use a
#    diff and pull the lines marked +.
ours_tmp=$(mktemp)
theirs_tmp=$(mktemp)
trap 'rm -f "$ours_tmp" "$theirs_tmp"' EXIT
git show ":2:$FILE" > "$ours_tmp"
git show ":3:$FILE" > "$theirs_tmp"

# diff -u: extract pure-add hunks at EOF. Strip diff prefix.
# We rely on the convention that PR additions are appended after the
# pre-rebase EOF — so the tail of the unified diff is a single + block.
appended=$(diff -u "$ours_tmp" "$theirs_tmp" | awk '
  /^\+\+\+/ { next }
  /^\+/ { sub(/^\+/, ""); print }
') || true

if [[ -z "$appended" ]]; then
  echo "warning: no appended content detected — manual review needed."
  exit 1
fi

# 3. Append.
{
  echo ""
  echo "$appended"
} >> "$FILE"

# 4. Sweep stragglers (defense in depth).
sed -i.bak '/^<<<<<<< /d; /^>>>>>>> /d; /^=======$/d' "$FILE"
rm -f "$FILE.bak"

# Verify clean.
if grep -nE '^(<<<<<<< |=======$|>>>>>>> )' "$FILE"; then
  echo "error: leftover conflict markers in $FILE" >&2
  exit 1
fi

git add "$FILE"
echo "rebase-tests-rs: $FILE resolved and staged."
echo "next: git rebase --continue"
