---
description: Drive a single GitHub issue through fix → adversarial review → auto-merge. Hard-rejects `kind:feat` issues. Claims hotspot locks for `client.rs` / `tests.rs` / `AppModel.swift` / `LyrebirdApp.swift`.
argument-hint: "<issue-number>"
---

You are running the **single-issue fix workflow** of the lyrebird-desktop adversarial pipeline.

The user invoked `/desktop-fix $ARGUMENTS`. `$ARGUMENTS` is one GitHub issue number.

## Pre-flight

1. `gh issue view $ARGUMENTS --json number,title,body,labels,state`. If `state != OPEN`, abort.
2. **Hard-reject `kind:feat`**: if the issue has `kind:feat`, abort with:
   > "fix workflow only handles `kind:bug|polish|chore|refactor`. Issue #$ARGUMENTS is `kind:feat`. Skipping."
3. **Hard-reject `priority:p3`**: not auto-flowed. Comment on the issue:
   > "fix workflow only handles `priority:p0|p1|p2`. Skipping; reopen via manual workflow if you want this fixed."
4. Determine slice from the issue's labels. If no `slice:*` label, abort and comment:
   > "auto-triage: issue lacks `slice:*` label. Add one and rerun."
5. Determine if the slice's hotspot lock is needed (slice:client → clientrs, slice:tests → testsrs, slice:scaffold → appmodel + lyrebirdapp).
6. `Scripts/area-lock.sh status` — record current lock state. If any required hotspot is locked, abort:
   > "hotspot <X> locked by #<N>. Wait for that PR to merge, then rerun."

## Dispatch the fixer

Spawn ONE `area-fixer` agent with prompt:
```
slice: <slice:X>
issues: [<#$ARGUMENTS>]
hotspots-required: [<hotspot>] | []
wave-budget: <Scripts/wave-budget.sh remaining>
```
Wait for it to return.

## On fixer success (PR opened)

Spawn ONE `adversarial-reviewer` against the new PR. Wait for outcome.

- `approve` → reviewer queues `gh pr merge --squash --auto --delete-branch`. Done.
- `request-changes` → spawn the fixer AGAIN with the reviewer's findings appended to the prompt. Cap iterations at 3. After 3 round-trips with no approval, abort and surface to user.
- `dispute-needs-opus` → spawn an Opus-model `adversarial-reviewer` (override the agent's default model to opus for this single invocation). Whichever way Opus rules is final. If Opus approves, queue auto-merge. If Opus also requests changes, abort and surface to user.

## On merge

If the PR claimed a hotspot, run:
```
Scripts/area-lock.sh release <hotspot>
```

## Output

```
issue: #$ARGUMENTS
result: merged-#<pr> | request-changes-after-3-rounds | aborted-<reason>
hotspot: <X> | none
review-rounds: <N>
```
