# CLAUDE.md — lyrebird-desktop

Guidance for Claude Code sessions working in this repo. Complements the
workspace-level CLAUDE.md one directory up.

## Repo shape

- `core/` — Rust library (UniFFI-exposed). All network + state lives here.
  Synchronous API, `parking_lot::Mutex` guards `Inner`. Every FFI call
  serializes through that mutex.
- `macos/` — SwiftUI app. Consumes `LyrebirdCore` via the committed
  `macos/Lyrebird.xcframework` + generated `macos/Sources/LyrebirdCore/Generated/lyrebird_core.swift`.
  AudioEngine wraps AVQueuePlayer; Nuke handles artwork.
- `core/src/client.rs` (3,400+ lines) — Jellyfin REST client. Heavy
  rebase-conflict hotspot; see "Merge hygiene".
- `core/src/tests/` — the core test suite, split by domain (`client.rs`,
  `playlists.rs`, `playback.rs`, `session_auth.rs`, `discovery.rs`, …) under
  `tests/mod.rs`, which holds the shared imports + fixtures (`mock_client`,
  `install_mock_keyring`, …) that each submodule pulls in via `use super::*`.
  Add a new test to the domain file matching its subject — or add a new
  `mod <bucket>;` to `tests/mod.rs` — instead of appending to one giant file.
  The June 2026 split retired the old single ~9.5k-line `tests.rs`; see
  "Merge hygiene".
- `macos/Sources/Lyrebird/AppModel.swift` (~7,100 lines) — the single
  `@MainActor` view model. Every screen reads from it. Conflict hotspot
  #1. Never parallelize two agents against this file.
- `macos/Sources/Lyrebird/LyrebirdApp.swift` — app scaffold. Conflict hotspot #2.

## Build gates

`swift build` alone is not a full gate — it happily skips recompilation of
files whose sources didn't change. Before merging FFI-adjacent work:

```bash
rm -rf macos/.build && swift build --package-path macos
```

If a PR modifies `core/src/lib.rs` or anything in `core/src/models.rs` that
carries `uniffi::Record` / `uniffi::Enum`, the xcframework and
`lyrebird_core.swift` bindings need regeneration:

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
`/Users/skalthoff/Code/active/openSourceWork/workspaces/lyrebird-desktop`
and `.claude/worktrees/cool-fermat-316d1d/` have pointed to different
branches inside the same session. If you `cd` between them and forget,
you'll spend real time chasing phantom "main is broken" reports.

Agents sometimes push to the parent session branch (`claude/...`) instead
of their own `fix/<name>` branch. Every agent prompt should include:

> First: `git branch --show-current`. If you're on `claude/*` or `main`,
> create `fix/<descriptive-name>` off `origin/main` before making changes.

### Hotspot files — never parallelize

- `macos/Sources/Lyrebird/AppModel.swift`
- `macos/Sources/Lyrebird/LyrebirdApp.swift`
- `core/src/client.rs`
- `core/src/tests/<domain>.rs` — far lower risk since the June 2026 domain
  split; two agents now collide only if they append to the *same* domain
  file (see merge hygiene)

If two agents both need to touch one of these, run them sequentially and
merge the first before spawning the second.

### Tight scoping

Target per agent: 1 new file + ≤2 issues + 10–15 min completion. Longer
scopes collide on rebase because of the hotspots above. The audit sweep
ran ~27 agents through 8 waves this way; every wave that broke the tight-
scope rule regretted it at rebase time.

### Merge hygiene — test collisions

The core test suite used to be one ~9.5k-line `core/src/tests.rs` that every
PR appended to at EOF, so every concurrent PR collided on rebase. As of the
June 2026 domain split it lives in `core/src/tests/<domain>.rs`. Two PRs now
collide only when they append to the *same* domain file — append your test to
the file matching its subject (or add a new `mod <bucket>;` to `tests/mod.rs`)
and concurrent PRs in different domains rebase cleanly.

When two PRs do land tests in the same domain file, the tail-append
resolution still applies, scoped to that one file:

```bash
# Pick the main-side tests, then manually append the incoming PR's tests.
git checkout --ours core/src/tests/<domain>.rs
# Find the line where the incoming PR's tests start in the commit
# (usually after the pre-rebase EOF), then:
git show <incoming-commit>:core/src/tests/<domain>.rs | sed -n '<start>,$p' >> core/src/tests/<domain>.rs
# Verify no stray '<<<<<<< HEAD' markers remain:
grep -n '<<<<<<< HEAD' core/src/tests/<domain>.rs   # should be empty
```

If a leftover conflict marker slips through, clippy will fail —
`sed -i '' '/<<<<<<< HEAD/d; />>>>>>> /d' core/src/tests/<domain>.rs` is the
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

## Feature-burn campaign — the reviewer-calibration bug (Jun 2026)

Big M3 feature push (`drive` with `auditEvery:0, ciGated:false, buildCeiling:7,
builderModel:opus`). Builders worked great — every wave produced mergeable, green-CI PRs
(`gate=pass`). But **throughput cratered to ~0 merges/wave** and runs kept self-stopping
`idle` with the backlog barely moving. Root cause (found by reading a run's journal:
`BUILD→REVIEW(request-changes)→refix→REVIEW(request-changes)` on every PR, 7/7):

- **The adversarial-reviewer rejected essentially everything — including a literal 2-line
  dict fix.** The cause is the reviewer prompt/agent-def framing: *"Approving is the
  exception, not the default"* + *"emit one finding per category; silence is not valid."*
  That turns the 8-category checklist into a **quota** — the reviewer manufactures a
  finding to avoid "rubber-stamping," so correct PRs get `request-changes` forever. The
  drive workflow's review prompt now **OVERRIDES** that default with an explicit
  CALIBRATION block: approve when (1) diff does what the issue asks, (2) scope-locked,
  (3) CI green/pending, (4) you cannot cite a CONCRETE file:line defect; the 8 categories
  are a LENS, not a quota; do NOT reject for "could add a test" on trivial/UI changes,
  style, or hypotheticals. After this change the SAME reviewer agent approved 7/7 of the
  same PRs (all genuinely correct) — and still legitimately caught real defects when
  present (e.g. it earlier rejected #913 for a falsified "tests added" claim + a wrong
  uninstall path). Calibration ≠ rubber-stamp.
  NOTE: the shared `.claude/agents/adversarial-reviewer.md` keeps the strict default on
  purpose (it's right for the single-issue bug pipeline / `/desktop-review`); the override
  lives in the drive workflow prompt only.

- **"Commits not landing" was a MERGE-gap, not a build-gap.** The builders committed +
  opened mergeable green PRs every time; they just never reached `approve`→auto-merge
  because the reviewer never approved and runs died mid-review-round (e.g. 36 started /
  29 results = 7 agents cut off). Diagnose merge stalls by checking review *outcomes* in
  the journal, not whether PRs exist.

- **`gh pr review --approve` self-approval is blocked when PR author == the merging user
  (skalthoff).** A reviewer agent's approve call fails; the merge still works via
  `gh pr merge <n> --squash [--auto] --delete-branch`. Have reviewers merge directly
  rather than relying on a separate --approve gate for self-authored PRs.

- **Tar-pit PRs stall every relaunch.** Conflicting/DIRTY or repeatedly-rejected PRs make
  the resolve-open-PRs phase burn whole waves re-trying the unfixable, then stop `idle`
  with features untouched. Before each relaunch, CLOSE such PRs (their issue stays open →
  rebuilt clean next wave); keep only mergeable+green+unreviewed ones. Now enforced in the
  babysitter prompt.

## HYPER / CI-gated campaign — findings (Jun 2026)

Third campaign: `drive` with `ciGated:true` + `builderModel:opus`, args `{maxWaves:30,
buildCeiling:14, backlogBatch:20, auditEvery:5}`, run across a 9h unlimited-token
window via the ~45-min babysitter (relaunched once after a mid-run death). The idea:
move the CPU-bound build gate OFF the local 10-core box onto GitHub Actions so local
agents reason→edit→push fast and cloud CI verifies in parallel. **MEASURED (git/gh
truth): ~10 PRs merged overnight (#879 #881 #877 #885 #887 #893 #894 #898 #900 #903 —
incl. the release-prerelease fix and a Library filter popover), 0 junk closed.** But at
wind-down **14 PRs sat open and NONE were mergeable: 10 failing CI, 2 conflicting, 2
pending, 0 reviewed.** Findings:

- **CI-gated mode trades local-compile time for a red-PR pileup.** Because builders skip
  the local `swift build`/`cargo` gate, a large fraction of pushed PRs fail CI (the
  `macOS app` job most often). Throughput per *merged* PR did NOT clearly beat the local-
  build mode — the work just moved from "agent waits on compile" to "PR sits red waiting
  for a builder to come back and fix CI." Builders rarely came back (the run died / moved
  on), so red PRs accumulated. **Verdict: only worth it if the refix loop aggressively
  re-drives red-CI PRs; otherwise local-build mode lands a higher fraction of what it opens.**

- **Builders outrun the single serial reviewer, badly, at buildCeiling:14.** 14 PRs open,
  0 reviewed at stop. The reviewer is the bottleneck; opening more PRs just grows an
  unreviewed+unmergeable queue. Keep buildCeiling near the review throughput (≈ the agent
  cap, 8), not above it.

- **`gh issue list --label X` / `--search 'label:"X"'` intermittently returns `[]` (no
  error) on this box mid-session**, making the backlog look drained (0/0/0) when it is NOT.
  ALWAYS cross-check by pulling the full open list and aggregating labels client-side
  (`gh issue list --state open --limit 200 --json labels --jq ...`). The full-list read is
  trustworthy; the filtered read is not. (Bit my own wind-down report — reported 0 bugs
  when there were 4 + 83 open M3.)

- **FFI-adjacent PRs can't skip the local build** — they must regen the xcframework +
  bindings and commit them, or CI goes red on stale bindings. Confirm those builders
  actually ran `build-core.sh` before trusting their green.

- **Stale `wf_*-N` worktrees hit 99.** `git worktree prune` + remove abandoned ones is now
  overdue; keep only those backing a still-open PR.

- **Poisoned SwiftPM cache breaks `main` CI reproducibly (not a flake).** Symptom: the
  `macOS app` CI job fails with `error: XCFramework Info.plist not found at
  .build/artifacts/sparkle/Sparkle/Sparkle.xcframework` while `test (macos-15)` passes.
  Cause: ci.yml caches `macos/.build` keyed on `hashFiles(Package.swift, Package.resolved)`;
  when those files don't change, every run restores a `.build` that references Sparkle's
  artifact path without the extracted xcframework present → dangling ref. Reruns fail
  identically (it is NOT transient). Fix: bust the cache —
  `gh cache list --json key --jq '.[]|select(.key|test("spm";"i")).key'` then
  `gh cache delete <key>` for each, and re-run; the cache-less rebuild resolves Sparkle
  clean. Permanent fix (TODO): add Sparkle's resolved revision (or a manual bump input) to
  the cache key, or `rm -rf .build` unconditionally when the restored cache lacks
  `.build/artifacts/sparkle/.../Sparkle.xcframework/Info.plist`.

## Overnight opus campaign — findings (May 2026)

Second campaign: `drive` with `builderModel: opus` (all bug-fixers + feature-
builders + in-place PR refixers on Opus; reviewer stayed Sonnet-first + Opus-
on-dispute — wired via the new `cfg.builderModel`/`cfg.reviewModel`). Args
`{maxWaves:14, buildCeiling:8, backlogBatch:16, builderModel:'opus'}`. Ran
unattended via a ~45-min ScheduleWakeup babysitter (check-alive →
relaunch-if-dead → stop-on-drain). **MEASURED result (git/gh truth, not the
workflow's self-report): 4 PRs merged to main (#865, #867, #875, #876 — two of
which, #865/#867, were stalled in-flight PRs the run finished), 1 junk closed
(#871), 6 left open unreviewed (#877, #878, #879, #880, #881, #885); backlog p0 2→1
(audio p0 #848 cleared via #867; only #431 DB-cache XL feat remains), bugs 8→9
(audit filed new ones), M3 feats 30→30. main green throughout.** The honest read:
the overnight run mostly *finished what was already in flight* and barely moved
the feature backlog. Findings explaining why:

- **`budget-exhausted` is the binding constraint, NOT the wave cap.** At ~1.3M
  tok/wave, Opus drains the turn's shared token pool in a handful of waves
  regardless of `maxWaves:14`. The run self-stopped on budget; net new
  throughput per launch is only ~2-4 merges. To actually grind a big backlog
  overnight you need the babysitter to RELAUNCH repeatedly (each launch = fresh
  budget) AND you must accept the spend — a single launch does little.

- **Opus didn't obviously out-yield Sonnet here.** Merges/launch were similar to
  the Sonnet runs; the bottleneck was budget + review throughput, not builder
  model quality. Don't assume "Opus = more shipped" — for drain campaigns the
  limiter is token budget and the single-reviewer serialization, not codegen IQ.
  Reserve Opus builders for genuinely hard core/FFI changes; Sonnet is fine for
  the UI bulk and far cheaper per wave.

- **Review is the throughput bottleneck.** 6 PRs sat open unreviewed at stop —
  builders outran the (serial, worktree-isolated) reviewer. Raising
  `buildCeiling` without parallelizing review just grows the open-PR queue.

- **Babysitter pattern works but needs explicit spend consent.** It would have
  relaunched on the next tick (backlog remained) and kept spending. Confirm you
  want continuous overnight spend before arming; it does not self-limit on cost,
  only on drain/human-gated/red-main.

- **Dedup risk on relaunch.** After a budget-stop, the resolve-open-PRs phase
  must close PRs whose `Closes #n` issue already merged via another squash, or
  two PRs race the same issue. TODO: backlog selector should cross-check open
  PRs' linked issues against recently-merged squashes, not just open-PR topics.

- **Title/junk guard still leaks under load.** Despite the conventional-commit
  title rule, junk PRs still reached open state (the reviewer closed 3). Title +
  no-op detection needs to be a REVIEWER checklist item, not just a builder
  instruction — builders under load treat prompt niceties as optional.

- **Stale `wf_*-N` worktrees pile up fast** — 58 now accumulated across
  campaigns. After a run, `git worktree prune` and remove abandoned ones (keep
  any backing an open PR). They're disk + diagnostic noise: SourceKit indexes
  them, producing the "No such module 'LyrebirdCore'" / "Cannot find Theme/
  AppModel" cascades that look alarming but are just unbuilt worktrees — always
  confirm against `main` CI before treating a diagnostic as breakage.

- **Trust git/gh, not the workflow's self-tally.** The run's structured summary
  over-counted merges (counted `--auto`-queued PRs that never landed, and
  re-counted in-flight ones). Always reconcile the final report against
  `git log origin/main` + `gh pr list --state merged` before believing numbers.

## Workflow-driven campaigns — lessons (May 2026)

Two deterministic orchestration scripts now live in `.claude/workflows/`:
`drive-lyrebird-desktop.js` (resolve open PRs → drain the real open backlog:
bugs p0→p2 then M3 feats → periodic audit → build → adversarial review →
auto-merge) and `finalize-lyrebird-desktop.js` (audit-driven; same back half).
Prefer **drive** to actually move the backlog; finalize only fixes
freshly-audited bugs. Run via `Workflow({scriptPath, args:{maxWaves,
buildCeiling, backlogBatch}})`. Lessons from the first campaign (8 PRs merged:
#849 #62 #108 #856 #64 #342 #860 #850 — incl. the Mini Player p0):

- **Concurrency cap = `min(16, cores−2)`** (8 on this 10-core box). Set
  `buildCeiling` = the cap; more builders than cores just thrash — `cargo`/
  `swift` compiles are CPU-bound. Do **not** run two workflows on this repo at
  once (oversubscribes CPU + collides on hotspots/PRs). "More agents" past the
  core count is a loss, not a win.

- **CI gates auto-merge, so `main` stays green.** `--squash --auto` only lands
  on green CI; nothing red merged across the whole campaign. This is the load-
  bearing safety property — rely on it rather than reasoning about each merge.

- **`wave-budget.sh` is a no-op gate under the JS workflows.** `Scripts/wave-budget.sh
  start` writes two space-separated ints (`<start> <deadline>`) to `.wave-start`, and
  `remaining` reads `awk '{print $2}'`. The drive/finalize workflows never call `start`,
  so `.wave-start` is absent → `remaining` returns `0` → reads as "expired" → `area-fixer`
  (≤1800s) and `problem-triager` (≤600s) would abort. (An earlier preflight step also
  wrote a `key=value` form `awk` couldn't parse — same zero result.) Either way both
  workflows now tell downstream agents to **ignore the wave-budget gate** (the JS wave-cap
  + token budget govern). If you invoke those agents OUTSIDE these workflows, run
  `Scripts/wave-budget.sh start 14400` first or tell them to ignore it.

- **Background runs die mid-flight** (turn end, user interrupt, multi-hour
  runtime). Recovery is cheap: relaunch `drive` — its wave-1 *resolve-open-PRs*
  phase re-reviews/refixes/merges whatever was left in flight, and it re-reads
  the live backlog, so nothing is lost. The `Workflow` tool's `resumeFromRunId`
  also works for any script (drive or finalize) — it replays the cached agent
  prefix instantly; neither workflow needs special script-level resume support.

- **Builder quality failures to guard:** agents have leaked internal monologue
  into PR titles (e.g. #872 "wait. these aren't matching…") and opened
  near-duplicate follow-up PRs on a topic already covered. The adversarial
  reviewer + resolve-open-PRs phase self-heal (merge good, **close** junk), but
  builder prompts now require a conventional-commit one-line title.

- **Core hotspots drain slowly.** `client.rs` / `models.rs` / `state` /
  `tests.rs` allow ≤1 in-flight item per hotspot — enforced in JS (`pickWork`),
  not `area-lock.sh` (which doesn't coordinate across isolated worktrees).
  Expect ~1 core fix per wave; UI/screens/components parallelize freely.

- **Red diagnostics are usually environmental.** "No such module 'LyrebirdCore'"
  + cascading "cannot find AppModel/Theme/…" in a worktree just means it was
  never built (`./macos/Scripts/build-core.sh && (cd macos && swift build)` to
  clear). An in-progress builder worktree can momentarily show real syntax
  errors mid-edit — ignore unless they reach a PR (CI catches those). Always
  confirm against `main` CI before treating a diagnostic as breakage.

- **Stale worktrees accumulate** under `.claude/worktrees/wf_*-N/` — one per
  builder. Unchanged ones auto-clean; changed ones persist. `git worktree
  prune` + remove abandoned ones periodically, but never those backing an open
  PR (e.g. the `fix/848-*`, `fix/861-*` branches still in flight).

## Runtime gaps — common patterns

Catalogued during the April 2026 audit sweep. Recurring shapes to check
for when PRs land:

1. **`try?` + `print` stubs rot silently.** Any function whose body is
   `print("[AppModel] X not yet wired — see #Y")` should be treated as
   a live bug, not a TODO. As of rc12 the `print(...)` form has been
   replaced with `Log.app.notice(...)` so the messages now surface in
   Console.app under `subsystem == "org.lyrebird.desktop"` instead of
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

- ✅ `/Sessions/Playing*` reporting — wired in LyrebirdAudio/AudioEngine
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
