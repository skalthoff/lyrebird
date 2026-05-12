---
description: Run the agentic audit phase across one or all 8 slices of lyrebird-desktop. Files falsifiable issues for confirmed problems; default verdict is "no problem found."
argument-hint: "[slice:components | slice:client | slice:tests | ... | all]"
---

You are running the **audit phase** of the lyrebird-desktop adversarial pipeline.

The user invoked `/desktop-sweep $ARGUMENTS`.

## Behavior

If `$ARGUMENTS` is empty or `all`: dispatch ONE `area-auditor` subagent per slice (8 in parallel). Slices: `slice:client`, `slice:models`, `slice:state`, `slice:tests`, `slice:screens`, `slice:components`, `slice:audio`, `slice:scaffold`.

Otherwise `$ARGUMENTS` should match exactly one of the slice labels. Dispatch a single `area-auditor` against that slice.

## Pre-flight

1. `git branch --show-current` — confirm; the auditors are read-only but the dispatcher should know context.
2. Skip any slice that has an open issue with `triage:quiet-30d` filed within the last 30 days. Run `gh issue list --label "triage:quiet-30d" --search "<slice-name>"` to check.

## Dispatch

Launch all auditor agents in a SINGLE message with multiple Agent tool calls (parallelizes the audit, since auditors are read-only and never collide).

Each agent gets a prompt like:
```
You are auditing slice:<X>. Wave-budget remaining: <N> seconds.
Read CLAUDE.md and follow your agent-definition file (.claude/agents/area-auditor.md) exactly. Default to findings: [].
```

## After all auditors return

Aggregate the per-slice summaries:
- Total `candidates_found`.
- Total `issues_filed`.
- Slices with `auto_downgrade: true` (5+ findings — these need user attention).
- Slices reporting `M == 0` (quiet — increment cooldown counter for that slice).

If all 8 slices return `M == 0`, post-summary: "All 8 slices quiet. Pipeline reports: polished — no findings this sweep."

If any slice auto-downgraded, surface those candidates to the user without filing.

## Cooldown bookkeeping

For each slice that returned `M == 0` for a SECOND consecutive run (track via the existence of an open `triage:quiet-30d` tracking issue per slice — see Scripts/area-lock.sh pattern, or create a parallel mechanism):
```
gh issue create --title "triage: slice:<X> quiet (30d cooldown)" \
  --body "Two consecutive empty audits on $(date +%Y-%m-%d). Auditors skip this slice for 30 days." \
  --label "triage:quiet-30d"
```
Auto-close it after 30 days (or when an issue is filed against that slice manually).

## Final summary to the user

Print:
```
desktop-sweep complete
slices audited: <N>
issues filed: <M>
slices quiet: [...]
slices auto-downgraded: [...] (need manual review)
next: /desktop-fix <issue#>  or  /desktop-loop  to drive a full wave
```
