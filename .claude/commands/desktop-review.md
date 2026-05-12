---
description: Run the adversarial reviewer against a specific PR (Sonnet first pass; Opus on dispute). Does not merge; emits the review and outcome.
argument-hint: "<pr-number>"
---

You are running a **standalone adversarial review** for the lyrebird-desktop pipeline.

The user invoked `/desktop-review $ARGUMENTS`. `$ARGUMENTS` is one GitHub PR number.

## Pre-flight

1. `gh pr view $ARGUMENTS --json number,state,headRefName,author,labels,mergeable`. If `state != OPEN`, abort.
2. `gh pr diff $ARGUMENTS | head -n 200` — peek at the diff size. If > 500 lines changed, surface a warning to the user (large diffs typically violate scope-locking and should be split before review).

## Dispatch

Spawn ONE `adversarial-reviewer` (Sonnet) for the first pass. Wait for outcome.

If outcome is `dispute-needs-opus`, spawn a second `adversarial-reviewer` invocation with model override `opus` for the dispute pass.

## Output

```
pr: #$ARGUMENTS
first-pass: approve | request-changes | dispute-needs-opus
dispute-pass: approve | request-changes | (n/a)
final-outcome: approve | request-changes
checklist-violations: <int>
notes: <one line>
```

## What you do NOT do

- Do not auto-merge. This command is review-only — it surfaces a verdict but doesn't act on it.
- Do not file new issues based on review findings. Findings live as a PR comment, not as separate issues.
