# Polish targets — definition of done for the agentic pipeline

This file is the user-authored gate. The pipeline (`/desktop-loop`) reads this list at the start of each wave. When every target below is verifiably true, the pipeline exits with status **"polished — pipeline idle"** and stops auditing the affected slices.

If you (skalthoff) leave this file empty, the pipeline runs indefinitely, bounded only by stop-conditions inside `desktop-loop` (drain ceilings, quiet-area cooldowns, time budgets).

## How to add a target

Each target must be **measurable** by a shell command or a `grep`/`gh`-style check. If a target needs human judgment, it doesn't belong here — it's just commentary.

Format:
```
- [ ] <human-readable description>
      check: <one-line shell command that exits 0 when target is met>
      slices: <comma-separated slice labels affected>
```

The pipeline runs each `check:` line as a sanity gate. A target is satisfied iff the command exits 0.

## Initial targets (placeholder — replace with your real ones)

- [ ] No `print(... not yet wired ...)` stubs anywhere in `macos/Sources/`
      check: ! grep -r 'not yet wired' macos/Sources/ --include='*.swift' -l | grep -q .
      slices: slice:scaffold, slice:screens, slice:components

- [ ] No synchronous `try core.X(...)` calls inside `@MainActor` tight loops
      check: # add a real shell check here once the pattern is grep-able
      slices: slice:scaffold, slice:screens

- [ ] Real-server smoke test passes for: login, library page 1, search, queue add, playback start/stop
      check: Scripts/smoke-test.sh
      slices: slice:client, slice:state

- [ ] All `priority:p0` issues are either resolved or downgraded with rationale
      check: test "$(gh issue list --label 'priority:p0' --state open --json number -q 'length')" -eq 0
      slices: all

- [ ] Zero `<<<<<<< HEAD` or other rebase markers anywhere in the repo
      check: ! git grep -nE '^(<<<<<<< |=======$|>>>>>>> )' -- '*.swift' '*.rs' '*.toml' | grep -q .
      slices: all

## When the pipeline reports "polished"

Either:
- Retire targets that are stable and no longer at risk of regression.
- Add new targets that reflect the next round of polish.
- Or accept that the pipeline is idle and let it stay idle until something breaks.

The point of this file: **the agents don't get to invent the bar.** You do.
