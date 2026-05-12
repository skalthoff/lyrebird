---
description: Run one full agentic wave (audit → triage → fix → review → merge → cooldown) under a 4-hour wall-clock budget. Designed for use with `/loop /desktop-loop` to run continuously between waves. Stops on first stop-condition.
argument-hint: "[budget-seconds]"
---

You are running ONE full wave of the lyrebird-desktop adversarial pipeline.

The user invoked `/desktop-loop $ARGUMENTS`. If `$ARGUMENTS` is provided, treat it as a budget-seconds override (default 14400 = 4h).

## Wave orchestration

### Step 1 — Wave start

```
Scripts/wave-budget.sh start <budget-seconds-or-default>
```

Record the start timestamp for the wave-report at the end.

### Step 2 — Drain check

```
gh pr list --state open --search 'head:fix/' --json number,title | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'
```

If ≥ 5 open agent-PRs (`fix/*` head branches) already exist:
> "drain ceiling hit: <N> open agent-PRs. Wave aborts; merge or close existing PRs first."
Exit cleanly. No audit, no fix.

### Step 3 — Audit phase

Invoke `/desktop-sweep all` (or implement equivalent: spawn 8 parallel `area-auditor` subagents). Aggregate findings.

**Stop conditions during/after audit:**
- All 8 slices return `M == 0` (zero issues filed): wave is done. Skip to **Step 7 (report)** with status "polished — no findings this sweep."
- Combined `issues_filed > 10`: HALT. Surface to user:
  > "audit produced <N> findings — exceeds the 10-finding ceiling. Either there's a real regression or auditors are hallucinating. Pausing wave for user review."
  Skip to Step 7.

### Step 4 — Triage phase

Spawn ONE `problem-triager` agent. Input: list of issue numbers filed since wave start (`gh issue list --label "source:auto-audit" --search "created:>$(awk '{print $1}' .wave-start | xargs -I {} date -u -r {} +%Y-%m-%dT%H:%M:%SZ)"`).

Receive the fix manifest. If manifest is empty, skip to Step 7.

### Step 5 — Fix phase

Per the manifest, spawn `area-fixer` agents:

- **Wave A** (parallel): up to 3 NON-hotspot fixers from different slices, all spawned in a single message with multiple Agent tool calls.
- **Wave B** (after A drains): if the manifest contains a hotspot-touching issue, spawn ONE hotspot fixer (claim its lock first).
- **Wave C** (after B drains): if a second hotspot is in the manifest, spawn its fixer.

Between sub-waves, check `Scripts/wave-budget.sh expired`. If expired, halt fix dispatch (don't spawn new fixers; existing work continues).

### Step 6 — Review phase

For each PR opened by fixers:
- Spawn ONE `adversarial-reviewer` (Sonnet first pass).
- On `request-changes`: respawn the fixer with reviewer findings, max 2 round-trips per PR within the wave (saves Step-5 budget for next wave).
- On `dispute-needs-opus`: spawn an Opus reviewer. Whichever side Opus picks is final.
- On `approve`: reviewer queues `gh pr merge --squash --auto --delete-branch`.

Reviewers run in parallel — spawn all of them in a single message.

### Step 7 — Wave report

```
Scripts/wave-report.sh > /tmp/wave-report.txt
cat /tmp/wave-report.txt
Scripts/wave-budget.sh end
```

Emit a final summary to the user:
```
wave complete
budget used: <X>s of <Y>s
issues filed: <N>
PRs opened: <M>  merged: <K>  pending: <P>
hotspot-locks released: [...]
slices quiet: [...]
slices auto-downgraded: [...] (require manual review)
next: invoke /loop /desktop-loop to run continuously, or /desktop-loop to run another single wave
```

## Stop conditions (any halts the wave)

1. Wall-clock cap (`Scripts/wave-budget.sh expired`).
2. Drain ceiling: ≥ 5 open `fix/*` PRs at audit time.
3. Audit yields > 10 findings.
4. Audit yields 0 findings across all slices.
5. Manifest is empty after triage.
6. POLISH_TARGETS.md (when present) all check ✓ — pipeline idle, ping user.

## What you do NOT do

- Do not bypass `Scripts/wave-budget.sh expired`. The budget is the entire reason for the time-boxed design.
- Do not spawn more than 3 non-hotspot fixers at once.
- Do not spawn 2 hotspot fixers against the same hotspot (the lock script will reject the second anyway).
- Do not touch `kind:feat` issues at any point.
- Do not auto-close `triage:quiet-30d` issues mid-wave; the cooldown is a feature.
