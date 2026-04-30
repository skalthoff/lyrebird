# CLAUDE.md — jellify-desktop

Guidance for Claude Code sessions working in this repo. Complements the
workspace-level CLAUDE.md one directory up.

## Repo shape

- `core/` — Rust library (UniFFI-exposed). All network + state lives here.
  Synchronous API, `parking_lot::Mutex` guards `Inner`. Every FFI call
  serializes through that mutex.
- `macos/` — SwiftUI app. Consumes `JellifyCore` via the committed
  `macos/Jellify.xcframework` + generated `macos/Sources/JellifyCore/Generated/jellify_core.swift`.
  AudioEngine wraps AVQueuePlayer; Nuke handles artwork.
- `core/src/client.rs` (92KB) — Jellyfin REST client. Heavy rebase-conflict
  hotspot; see "Merge hygiene".
- `core/src/tests.rs` (4000+ lines) — tests always append at EOF, so every
  concurrent PR collides on rebase. See "Merge hygiene".
- `macos/Sources/Jellify/AppModel.swift` (~4000 lines) — the single
  `@MainActor` view model. Every screen reads from it. Conflict hotspot
  #1. Never parallelize two agents against this file.
- `macos/Sources/Jellify/JellifyApp.swift` — app scaffold. Conflict hotspot #2.

## Build gates

`swift build` alone is not a full gate — it happily skips recompilation of
files whose sources didn't change. Before merging FFI-adjacent work:

```bash
rm -rf macos/.build && swift build --package-path macos
```

If a PR modifies `core/src/lib.rs` or anything in `core/src/models.rs` that
carries `uniffi::Record` / `uniffi::Enum`, the xcframework and
`jellify_core.swift` bindings need regeneration:

```bash
./macos/Scripts/build-core.sh                      # dev (debug)
./macos/Scripts/build-core.sh --release            # ship
```

Stale bindings compile fine against a stale xcframework — you only notice
when the app runs against an up-to-date one, or when someone pulls and
rebuilds the core fresh. Always commit regenerated bindings + xcframework
together in the same commit as the Rust change.

## Real-server smoke test

The user (skalthoff) **explicitly authorizes** Claude sessions in this
repo to query `https://music.skalthoff.com` with the `test` / `test`
read-only test account. This is the canonical fastest way to tell
whether a "page is broken" is server-side or client-side. The library
returns ~20060 albums / 3839 artists / 78 playlists / 254 genres, plus
real `UserData.IsFavorite` / `PlayCount` projections so favorite-flow
and played-flow regressions can be reproduced end-to-end against a
real Jellyfin without spinning up Docker.

```bash
TOKEN=$(curl -sS -X POST "https://music.skalthoff.com/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'Authorization: MediaBrowser Client="probe", Device="probe", DeviceId="probe-001", Version="0.0.0"' \
  -d '{"Username":"test","Pw":"test"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["AccessToken"])')
```

Then curl whatever endpoint the Swift side is hitting. The
`test` account is read-isolated — favorites / played flags written by
this account are scoped to the user and don't pollute production data.

This authorization stands for the lifetime of this branch / worktree;
sessions don't have to re-ask before running the curl. If the sandbox
still blocks the curl, ask the user to add a Bash permission rule to
their Claude settings — it's a sandbox-config gap, not a missing
authorization.

## Multi-agent playbook

Lessons from the 46-issue audit sweep + the gap-fix iteration that
followed.

### Branch hygiene

Before every agent action:

```bash
git branch --show-current          # confirm where you are
git worktree list                  # confirm which worktree is on which branch
```

Multiple worktrees in this repo can be on different branches at once.
`/Users/skalthoff/Code/active/openSourceWork/workspaces/jellify-desktop`
and `.claude/worktrees/cool-fermat-316d1d/` have pointed to different
branches inside the same session. If you `cd` between them and forget,
you'll spend real time chasing phantom "main is broken" reports.

Agents sometimes push to the parent session branch (`claude/...`) instead
of their own `fix/<name>` branch. Every agent prompt should include:

> First: `git branch --show-current`. If you're on `claude/*` or `main`,
> create `fix/<descriptive-name>` off `origin/main` before making changes.

### Hotspot files — never parallelize

- `macos/Sources/Jellify/AppModel.swift`
- `macos/Sources/Jellify/JellifyApp.swift`
- `core/src/client.rs`
- `core/src/tests.rs` (see merge hygiene)

If two agents both need to touch one of these, run them sequentially and
merge the first before spawning the second.

### Tight scoping

Target per agent: 1 new file + ≤2 issues + 10–15 min completion. Longer
scopes collide on rebase because of the hotspots above. The audit sweep
ran ~27 agents through 8 waves this way; every wave that broke the tight-
scope rule regretted it at rebase time.

### Merge hygiene — tests.rs collision pattern

Every PR appending tests at EOF of `core/src/tests.rs` collides on rebase.
Resolution script:

```bash
# Pick the main-side tests, then manually append the incoming PR's tests.
git checkout --ours core/src/tests.rs
# Find the line where the incoming PR's tests start in the commit
# (usually after the pre-rebase EOF), then:
git show <incoming-commit>:core/src/tests.rs | sed -n '<start>,$p' >> core/src/tests.rs
# Verify no stray '<<<<<<< HEAD' markers remain:
grep -n '<<<<<<< HEAD' core/src/tests.rs   # should be empty
```

If a leftover conflict marker slips through, clippy will fail —
`sed -i '' '/<<<<<<< HEAD/d; />>>>>>> /d' core/src/tests.rs` is the
emergency cleanup.

### gpgsign constraint for background agents

The user's git config has `commit.gpgsign=true`. Background-agent
environments without access to the signing key will fail the commit hook.
Two workable patterns:

1. Have the agent produce the diff, and let the foreground session do the
   `git commit` (so the signature comes from the user's real key).
2. If the agent must commit, it can only do so when the work lands on a
   branch that will be squash-merged — the squash commit signature comes
   from the merger, not the source commits.

Never bypass signing with `--no-gpg-sign` unless the user explicitly
asks. Don't use `--amend` after a hook failure either; create a new
commit instead.

### Auto-merge is cheap

`gh pr merge <n> --squash --auto --delete-branch` queues the merge when
CI goes green; it returns immediately, so you can queue several PRs and
keep working. Check completion with
`gh pr view <n> --json state,mergedAt`. Do NOT poll in a sleep loop — the
merge either happens instantly (if CI is clean + branch protection
allows) or waits for CI.

### No AI attribution

Per workspace-level CLAUDE.md and the user's global rules: never add
`Co-Authored-By` lines, never mention Claude / AI / AI tooling in commit
messages, PR descriptions, issue comments, or any public context.
Everything is authored by the user (skalthoff).

## Runtime gaps — common patterns

Catalogued during the April 2026 audit sweep. Recurring shapes to check
for when PRs land:

1. **`try?` + `print` stubs rot silently.** Any function whose body is
   `print("[AppModel] X not yet wired — see #Y")` should be treated as
   a live bug, not a TODO. As of rc12 the `print(...)` form has been
   replaced with `Log.app.notice(...)` so the messages now surface in
   Console.app under `subsystem == "org.jellify.desktop"` instead of
   vanishing into Xcode's debug console — grep pattern updated:
   `Log.app.notice.*not yet wired`.

2. **Sync FFI on the MainActor.** Every `try core.X(...)` on a
   `@MainActor`-attributed function takes the Rust `Inner` mutex on the
   main thread. Per-scroll / per-cell call sites beach-ball the UI
   under contention. Patterns:
   - Memoize idempotent ones (e.g. `imageURL`).
   - Wrap the call in `Task.detached` and marshal the result back to
     main.
   - Polling: as of rc11 the `core.status()` poll runs at 1Hz and skips
     entirely when `status.state != .playing`; the AVPlayer
     `periodicTimeObserver` matches at 1Hz and skips `core.markPosition`
     when `player.rate == 0`. Together they cut idle wakes from
     ~14,400/h to zero. Don't reintroduce a faster cadence without
     measuring Activity Monitor's "Energy Impact" column.

3. **Paged-cache-only resolution.** Any screen that resolves its subject
   via `model.<things>.first { $0.id == targetId }` breaks for libraries
   larger than one page. Resolvers should always fall back to a core
   FFI on cache miss. `AppModel.resolveArtist` / `resolveAlbum` are the
   reference pattern.

4. **Tuple-destructure awaits.** `try await (a, b, c)` cancels
   assignment for all three on any single error. Prefer independent
   do/catch blocks so one flaky endpoint doesn't sink a whole page.

5. **Optimistic UI without server echo.** Any mutation that updates
   local state + a swallowed `try?` on the corresponding FFI is a
   silent-corruption bug. As of rc12 the playlist mutations
   (`removeFromPlaylist`, `undoRemoveFromPlaylist`, `addToPlaylist`)
   surface errors via `errorMessage` and roll back local state on
   failure — pattern to match for any future mutation. Search for
   `Task.detached.*core\.` and check each for proper do/catch +
   rollback.

## Deferred / known-open work

- Queue `playNext` / `addToQueue` semantics: fall through to `play()`
  and clobber queue. Needs core `insert_next` / `append_to_queue`
  primitives (#282).
- PRs still open needing rebase: #555 (typed enums + ItemsQuery), #560
  (i18n String Catalog), #639 (heartbeat scheduler).
- Print-stub features (`Log.app.notice` after rc12) gated behind
  `Capabilities.swift` flags: downloads (#70/#222), edit album (#96),
  export playlist (#98/#125), genre actions (#144/#248/#318),
  new-playlist picker (#72/#126). All flagged false by default; flip
  one only when the corresponding FFI lands.

## Resolved (don't re-file)

- ✅ `/Sessions/Playing*` reporting — wired in JellifyAudio/AudioEngine
  (`reportPlaybackStarted/Progress/Stopped`). PlayCount, Now Playing on
  other clients, and resume points all flow through it. Earlier CLAUDE.md
  versions claimed this was unwired; that was stale.
- ✅ 500ms polling on MainActor (rc11). See gap pattern #2 for the
  current cadence + skip-when-paused contract.
- ✅ Album-tracks `Recursive=true` (rc7). Removed because Jellyfin's
  flat-tree walk on a 100k+-track library was 3.6s/request; the flag
  bought nothing for music albums (multi-disc lives on
  `ParentIndexNumber`, not nested folders).
- ✅ ArtistDetailView `LazyHStack` UAF on macOS 26.4 + Apple Silicon
  (rc9). Replaced with eager `HStack` for discography + similar artists
  shelves.
- ✅ Favorite cache snapshot fallback (rc6). `model.isFavorite(track:)`
  / `(album:)` / `(artist:)` walk cache → `userData?.isFavorite` →
  legacy mirror, so tap-to-favorite on a server-favorited item correctly
  un-favorites instead of redundantly favoriting.
- ✅ Playlist mutations (`removeFromPlaylist`, `undoRemoveFromPlaylist`,
  `addToPlaylist`) now surface errors + roll back optimistic state on
  server failure (rc12).
