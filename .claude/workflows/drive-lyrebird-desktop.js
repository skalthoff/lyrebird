export const meta = {
	name: 'drive-lyrebird-desktop',
	description:
		'Aggressively drive lyrebird-desktop toward shippable: each wave resolves open agent PRs, drains the real open backlog (bugs p0→p2, then M3 features), periodically audits for regressions, then builds → adversarial-reviews (2 refix rounds) → auto-merges. Loops until the backlog drains / POLISH_TARGETS passes / token budget / wave cap.',
	whenToUse:
		'When the owner wants the app driven hard end-to-end: clears stalled PRs, fixes the open bug backlog, implements M3 features, and keeps the audit safety-net running. Hotspot-safe, worktree-isolated, auto-merge on approval.',
	phases: [
		{ title: 'Preflight', detail: 'POLISH gate + open-work census + open agent-PR list' },
		{ title: 'Resolve PRs', detail: 'review → refix(≤2) → merge/flag every open agent PR' },
		{ title: 'Audit', detail: '8 auditors on wave 1 + every Nth wave (regression net)' },
		{ title: 'Triage', detail: 'fresh audit findings → bug manifest' },
		{ title: 'Backlog', detail: 'select prioritized open issues without a PR (bugs then M3 feats)' },
		{ title: 'Build', detail: 'area-fixer (bugs) + feature-builder (feats), worktree-isolated, ≤1/hotspot' },
		{ title: 'Review', detail: 'adversarial-reviewer per PR; Opus on dispute; 2 refix rounds; auto-merge' },
		{ title: 'Release gate', detail: 'M4 release-readiness verification (no live signing)' },
		{ title: 'Report', detail: 'final polish-gate + run summary' },
	],
}

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------
const cfg = {
	autoMerge: args && args.autoMerge != null ? args.autoMerge : true,
	maxWaves: args && args.maxWaves != null ? args.maxWaves : null,
	auditEvery: args && args.auditEvery != null ? args.auditEvery : 4, // audit on wave 1 and every Nth wave
	backlogBatch: args && args.backlogBatch != null ? args.backlogBatch : 16, // candidate items pulled per wave
	buildCeiling: args && args.buildCeiling != null ? args.buildCeiling : 10, // max PRs opened per wave (runtime caps concurrency at min(16,cores-2))
	refixRounds: args && args.refixRounds != null ? args.refixRounds : 2, // in-wave request-changes retries
	featMilestone: args && args.featMilestone ? args.featMilestone : 'M3 — macOS polish',
	includeDist: args && args.includeDist != null ? args.includeDist : true,
	// Model for code-authoring agents (builders + in-place PR refixers). Default opus for max code quality.
	builderModel: args && args.builderModel ? args.builderModel : 'opus',
	// Escalate the adversarial first-pass reviewer to this model too (default sonnet — anti-anchoring + opus-on-dispute is intentional).
	reviewModel: args && args.reviewModel ? args.reviewModel : 'sonnet',
	// HYPER / CI-gated mode: builders SKIP the slow CPU-bound local cargo/swift compile and
	// rely on GitHub Actions (runs fmt/clippy/test/swift-build on every PR) as the authoritative
	// build gate. Auto-merge only lands on green CI, so correctness is preserved while the local
	// box stops being the bottleneck. They still do FAST local sanity (fmt --check, grep) before push.
	ciGated: args && args.ciGated != null ? args.ciGated : false,
}

const WAVE_TOKEN_COST = 1300000 // observed ~1.27M/wave on the first full run
const DRAIN_CEILING = cfg.ciGated ? 24 : 10 // CI-gated mode tolerates a much deeper open-PR queue (cloud runners gate, not the local box)

const MAX_WAVES =
	cfg.maxWaves != null
		? cfg.maxWaves
		: budget.total
			? Math.max(1, Math.min(12, Math.floor(budget.total / WAVE_TOKEN_COST)))
			: 6

// ---------------------------------------------------------------------------
// SCHEMAS
// ---------------------------------------------------------------------------
const PREFLIGHT_SCHEMA = {
	type: 'object',
	properties: {
		polished: { type: 'boolean' },
		polishChecks: {
			type: 'array',
			items: {
				type: 'object',
				properties: { name: { type: 'string' }, pass: { type: 'boolean' }, detail: { type: 'string' } },
				required: ['name', 'pass'],
			},
		},
		openP0: { type: 'integer' },
		openBugs: { type: 'integer' },
		openFeatM3: { type: 'integer' },
		openAgentPRs: {
			type: 'array',
			items: {
				type: 'object',
				properties: {
					number: { type: 'integer' },
					head: { type: 'string' },
					title: { type: 'string' },
					isDraft: { type: 'boolean' },
				},
				required: ['number'],
			},
		},
		openFixPRs: { type: 'integer' },
		notes: { type: 'string' },
	},
	required: ['polished', 'openP0', 'notes'],
	additionalProperties: true,
}

const AUDIT_SCHEMA = {
	type: 'object',
	properties: {
		slice: { type: 'string' },
		candidatesFound: { type: 'integer' },
		issuesFiled: { type: 'integer' },
		issueNumbers: { type: 'array', items: { type: 'integer' } },
		autoDowngrade: { type: 'boolean' },
		notes: { type: 'string' },
	},
	required: ['slice', 'issuesFiled', 'notes'],
	additionalProperties: true,
}

const TRIAGE_SCHEMA = {
	type: 'object',
	properties: {
		manifest: {
			type: 'array',
			items: {
				type: 'object',
				properties: {
					issue: { type: 'integer' },
					slice: { type: 'string' },
					hotspot: { type: 'string' },
					priority: { type: 'string' },
					effort: { type: 'string' },
				},
				required: ['issue', 'hotspot'],
			},
		},
		rejected: { type: 'array', items: { type: 'object', properties: { issue: { type: 'integer' }, reason: { type: 'string' } } } },
		notes: { type: 'string' },
	},
	required: ['manifest'],
	additionalProperties: true,
}

const SELECT_SCHEMA = {
	type: 'object',
	properties: {
		items: {
			type: 'array',
			items: {
				type: 'object',
				properties: {
					issue: { type: 'integer' },
					slice: { type: 'string' },
					hotspot: { type: 'string' },
					title: { type: 'string' },
					kind: { type: 'string' },
					builder: { type: 'string' },
				},
				required: ['issue', 'hotspot', 'builder'],
			},
		},
		notes: { type: 'string' },
	},
	required: ['items'],
	additionalProperties: true,
}

const BUILD_SCHEMA = {
	type: 'object',
	properties: {
		issue: { type: 'integer' },
		prOpened: { type: ['integer', 'null'] },
		branch: { type: 'string' },
		hotspotsClaimed: { type: 'array', items: { type: 'string' } },
		buildGate: { type: 'string', enum: ['pass', 'fail', 'skipped'] },
		resolved: { type: 'boolean' },
		notes: { type: 'string' },
	},
	required: ['issue', 'prOpened', 'buildGate', 'resolved', 'notes'],
	additionalProperties: true,
}

const REVIEW_SCHEMA = {
	type: 'object',
	properties: {
		pr: { type: ['integer', 'null'] },
		outcome: { type: 'string', enum: ['approve', 'request-changes', 'dispute-needs-opus', 'close', 'no-pr', 'error'] },
		checklistViolations: { type: 'integer' },
		merged: { type: 'boolean' },
		hotspotReleased: { type: ['string', 'null'] },
		notes: { type: 'string' },
	},
	required: ['outcome', 'notes'],
	additionalProperties: true,
}

const RELEASE_GATE_SCHEMA = {
	type: 'object',
	properties: {
		checks: {
			type: 'array',
			items: {
				type: 'object',
				properties: { name: { type: 'string' }, pass: { type: 'boolean' }, detail: { type: 'string' } },
				required: ['name', 'pass'],
			},
		},
		releaseReady: { type: 'boolean' },
		blockers: { type: 'array', items: { type: 'string' } },
		notes: { type: 'string' },
	},
	required: ['releaseReady', 'notes'],
	additionalProperties: true,
}

// ---------------------------------------------------------------------------
// SLICES + helpers
// ---------------------------------------------------------------------------
const SLICES = [
	'slice:client',
	'slice:models',
	'slice:state',
	'slice:tests',
	'slice:screens',
	'slice:components',
	'slice:audio',
	'slice:scaffold',
]

function hotspotOf(item) {
	const h = (item && item.hotspot ? String(item.hotspot) : '').toLowerCase()
	if (h.includes('client')) return 'client'
	if (h.includes('test')) return 'tests'
	if (h.includes('appmodel') || h.includes('scaffold') || h.includes('lyrebirdapp')) return 'appmodel'
	if (h && h !== 'none') return 'none'
	const s = (item && item.slice ? String(item.slice) : '').toLowerCase()
	if (s.includes('client')) return 'client'
	if (s.includes('tests')) return 'tests'
	if (s.includes('scaffold')) return 'appmodel'
	return 'none'
}

function pickWork(allItems, ceiling) {
	const seen = new Set()
	const selected = []
	const deferred = []
	const seenIssue = new Set()
	for (const it of allItems) {
		if (seenIssue.has(it.issue)) continue // de-dup same issue from multiple sources
		seenIssue.add(it.issue)
		const h = hotspotOf(it)
		if (selected.length >= ceiling) {
			deferred.push(it)
			continue
		}
		if (h !== 'none' && seen.has(h)) {
			deferred.push(it)
			continue
		}
		if (h !== 'none') seen.add(h)
		selected.push({ ...it, _hotspot: h })
	}
	return { selected, deferred }
}

function builderAgentType(item) {
	return item.builder === 'area-fixer' ? 'area-fixer' : 'claude'
}

// Build-gate directive — swapped by cfg.ciGated. In CI-gated (HYPER) mode the local box does
// NOT run the slow CPU-bound cargo clippy/test + swift build (those serialize and are the real
// bottleneck on this 10-core machine); GitHub Actions runs the full gate on every PR in the cloud,
// and auto-merge only lands on green CI. Builders still run FAST local checks so they don't push
// obviously-broken diffs and waste a CI cycle.
const BUILD_GATE_DIRECTIVE = cfg.ciGated
	? `BUILD GATE — CI-GATED (HYPER) MODE: Do NOT run the slow local build (\`cargo clippy\`/\`cargo test\`/\`swift build\`) — GitHub Actions CI is the authoritative gate and runs fmt+clippy+test+swift-build on your PR in the cloud; auto-merge only lands on green CI. DO run these FAST local checks before pushing so you don't burn a CI cycle on a trivial error: (a) \`cargo fmt --all\` (auto-format, then \`--check\` clean) for Rust; (b) \`swift format\`/visual scan + confirm braces/imports balance for Swift; (c) re-read your full \`git diff\` for syntax. For FFI-adjacent changes (core/src/lib.rs or uniffi Record/Enum in models.rs) you MUST still regenerate the xcframework + lyrebird_core.swift bindings locally and commit them in the SAME commit (CI consumes the committed xcframework; stale bindings = red CI). After you push and open the PR, you MAY return immediately — do not block locally waiting for CI; the reviewer checks the CI result. Never \`--no-verify\`/\`--no-gpg-sign\`. Ignore Scripts/wave-budget.sh.`
	: `BUILD GATE: Run the full gates before pushing — Rust → \`cargo fmt --all -- --check\` + \`cargo clippy --workspace --all-targets --all-features -- -D warnings\` + \`cargo test --workspace --exclude lyrebird-desktop --all-features --no-fail-fast\`; Swift → \`cd macos && swift build\` (FFI-adjacent: \`rm -rf macos/.build && swift build --package-path macos\`, and regenerate xcframework + bindings in the SAME commit). Never \`--no-verify\`/\`--no-gpg-sign\`. Ignore Scripts/wave-budget.sh.`

// ---------------------------------------------------------------------------
// PROMPTS
// ---------------------------------------------------------------------------
function preflightPrompt(w) {
	return `Preflight for wave ${w} of the lyrebird-desktop DRIVE pipeline. Read-only — do NOT file issues, open PRs, or change code. Run and report:

1. POLISH gate: read POLISH_TARGETS.md; for every target whose \`check:\` line is a real shell command (not a placeholder comment), RUN it. A target passes iff exit 0. Report {name, pass, detail} each. \`polished\` = every runnable check passed.
2. Census via \`gh\`: openP0 (open priority:p0), openBugs (open kind:bug), openFeatM3 (open kind:feat in milestone "${cfg.featMilestone}").
3. Open agent PRs: \`gh pr list --state open --json number,headRefName,title,isDraft\`. Return openAgentPRs = those whose head branch starts with \`fix/\` or \`feat/\` (EXCLUDE dependabot/* and any human branch). Also openFixPRs = count of head:fix/.

Do NOT use Scripts/wave-budget.sh — the orchestrator governs the budget. Return the structured PREFLIGHT object.`
}

function auditPrompt(slice, w) {
	return `You are auditing ${slice}. Wave ${w} of the lyrebird-desktop DRIVE pipeline (regression net). Read CLAUDE.md fully and follow .claude/agents/area-auditor.md EXACTLY. Default verdict: findings: []. De-dup against ALL open issues with \`gh issue list --state open --search "<keyword>"\` before filing — most real bugs are already tracked; do not refile them. Honor the five-part falsifiability gate and auto-downgrade rule. Ignore Scripts/wave-budget.sh. File only genuinely NEW confirmed defects with \`gh issue create\` (+ \`source:auto-audit\`). Return the structured AUDIT summary.`
}

function triagePrompt(w, filedNumbers) {
	return `You are the problem-triager for wave ${w}. Follow .claude/agents/problem-triager.md EXACTLY. Do NOT write code or open PRs. Ignore Scripts/wave-budget.sh — treat budget as ample; never emit an empty manifest due to budget.

Issues filed by auditors this wave: ${filedNumbers.length ? filedNumbers.map((n) => '#' + n).join(', ') : '(none)'}. Reject kind:feat, re-check falsifiability, reconcile priority/effort labels, tag hotspots (client.rs / tests.rs / AppModel.swift+LyrebirdApp.swift). Build the ordered fix manifest (priority desc, effort asc, non-hotspot first, ≤1/hotspot, cap 6). Return the structured TRIAGE object.`
}

function backlogPrompt(w, n, milestone, excludeNote) {
	return `You are the BACKLOG SELECTOR for wave ${w}. Read-only + \`gh\`. Do NOT write code. Pick up to ${n} of the highest-value OPEN issues to drive next.

Be AMBITIOUS — fill the entire batch (${n} items) if that much real work exists. The orchestrator runs up to 10 builders in parallel, so favor a DIVERSE SPREAD across the 8 slices and keep at most ONE item per hotspot (client.rs / tests.rs / AppModel.swift+LyrebirdApp.swift) so the batch parallelizes without collisions.

Priority order:
1. Open \`kind:bug\` — priority p0 > p1 > p2 (confirmed defects; fix first).
2. Open \`kind:feat\` in milestone "${milestone}" — priority p0 > p1 > p2, then effort S > M > L. INCLUDE effort:L features when they are well-scoped and self-contained (do not skip a feature just for being L), and INCLUDE p0 features. Aim high — these features are the actual product.
3. Open \`area:dist\` / M4 work that needs NO Apple credentials (CI yaml, entitlements plist, packaging/appcast scripts).

HARD requirements for every pick:
- SKIP any issue that already has an OPEN PR (search \`gh pr list --state open\` and match by "Closes #n" in bodies or by topic). ${excludeNote || ''}
- SKIP kind:feat blocked on unlanded core FFI (read CLAUDE.md "Deferred / known-open work").
- SKIP issues that are already implemented (verify by reading the cited code) — a no-op PR wastes a review cycle.
- For each pick set: \`slice\` (one of the 8 slice labels, infer from area/topic), \`hotspot\` (client | tests | appmodel | none — appmodel = touches AppModel.swift/LyrebirdApp.swift), \`builder\` ("area-fixer" for kind:bug/chore/polish, "feature-builder" for kind:feat), \`kind\`, \`title\`.

Return the structured SELECT object. If nothing actionable remains, return items: [].`
}

function fixerPrompt(item, w) {
	const hs = item._hotspot === 'none' ? '[]' : `[${item._hotspot}]`
	return `slice: ${item.slice || '(infer from issue labels)'}
issues: [#${item.issue}]
hotspots-required: ${hs}
wave: ${w}

Follow .claude/agents/area-fixer.md EXACTLY — EXCEPT do NOT abort on the wave-budget gate (ignore Scripts/wave-budget.sh; the orchestrator governs budget; treat remaining as ample). Pre-flight: \`git branch --show-current\`; if on main/claude/*, create \`fix/${item.issue}-<slug>\` off \`origin/main\`. Make the MINIMAL change that closes #${item.issue} — nothing else. If a required hotspot is already locked by another agent, abort cleanly (prOpened:null).

${BUILD_GATE_DIRECTIVE}

No AI attribution, no banned comments. Open a PR with \`Closes #${item.issue}\` + the \`pipeline:\` block; the PR TITLE must be a single conventional-commit line (e.g. \`fix(macos): <what>\`) — never internal notes, questions, or monologue. ESCAPE \`@\` IN PROSE: backtick Swift property wrappers/attributes (\`@State\`, \`@Environment\`, \`@MainActor\`, \`@escaping\`, …) in the PR/commit body so GitHub doesn't render them as @username mentions; in the TITLE drop the @ entirely (write "State", not "@State"). Return the structured BUILD object.`
}

function featureBuilderPrompt(item, w) {
	const hs = item._hotspot === 'none' ? 'none' : item._hotspot
	return `You implement ONE feature for lyrebird-desktop — a NATIVE desktop Jellyfin client (Rust \`core/\` via UniFFI; \`macos/\` SwiftUI app consuming LyrebirdCore). Wave ${w}. You OWN the design quality: match the Apple Music / Spotify / Doppler bar in ROADMAP.md.

Issue: #${item.issue} — "${item.title || ''}" (${item.slice || 'unknown'}, kind:${item.kind || 'feat'}). Hotspot: ${hs}.

Discipline:
1. \`git branch --show-current\`; if on main/claude/*, create \`feat/${item.issue}-<slug>\` off \`origin/main\`.
2. Read the issue (\`gh issue view ${item.issue}\`) and the cited code. Read CLAUDE.md "Runtime gaps — common patterns" (sync FFI on MainActor, paged-cache-only resolution, optimistic-UI-without-echo, tuple-destructure awaits) and the build-gate section. VERIFY the feature isn't already implemented — if it is, abort (prOpened:null, resolved:false) rather than ship a no-op.
3. If hotspot != none, claim it: \`Scripts/area-lock.sh claim ${hs} pending feature-builder-${item.issue}\`; if LOCKED, abort cleanly (no waiting).
4. Implement the smallest CORRECT version that satisfies the issue's acceptance criteria, following existing patterns (resolveArtist/resolveAlbum cache-miss fallback, Log.app.notice over print, errorMessage + rollback for mutations). No speculative scope. If a missing core FFI is in scope, add it in \`core/\` and regenerate the xcframework + \`lyrebird_core.swift\` bindings in the SAME commit (\`./macos/Scripts/build-core.sh --arm64-only\`; then \`cd macos && rm -rf .build && swift build\`).
5. ${BUILD_GATE_DIRECTIVE}
6. Add a focused test only if it directly verifies new behavior. No AI attribution anywhere (commits/PR/comments); author as the user.
7. Open a PR: TITLE must be a single conventional-commit line (e.g. \`macos: <what>\`) — never internal notes/questions/monologue. ESCAPE \`@\` IN PROSE: backtick Swift property wrappers/attributes (\`@State\`, \`@Environment\`, \`@MainActor\`, …) in the body so GitHub doesn't make them @username mentions; in the TITLE drop the @ (write "State", not "@State"). Body = one-sentence WHY, \`Closes #${item.issue}\`, \`pipeline:\` block (fixer-session, slice, hotspots-claimed, build-gate, diff-stat). Name any claimed hotspot for release on merge.

Return the structured BUILD object (prOpened = PR number, or null if aborted).`
}

function reviewPrompt(pr, w) {
	const mergeLine = cfg.autoMerge
		? 'On `approve`: `gh pr review --approve` THEN `gh pr merge ' + pr + ' --squash --auto --delete-branch`. Release any claimed hotspot lock after queuing the merge.'
		: 'On `approve`: `gh pr review --approve` only. Do NOT merge.'
	const ciLine = cfg.ciGated
		? '\n\nCI-GATED MODE: builders did NOT compile locally — GitHub Actions is the build gate. Check the PR\'s CI status with `gh pr checks ' + pr + '` (or `gh pr view ' + pr + ' --json statusCheckRollup`). If CI is still pending, that is fine — `--squash --auto` waits for green before merging, so you may approve a code-correct PR while CI runs. If CI has already FAILED, do NOT approve: return `request-changes` citing the failing job (fmt/clippy/test/swift-build) so the builder fixes it. A PR is only mergeable when the diff is correct AND CI is (or will go) green.'
		: ''
	return `Review PR #${pr}. Wave ${w}. NOTE: .claude/agents/adversarial-reviewer.md says "approving is the exception" and "emit one finding per category" — for THIS feature-drive pipeline that calibration is OVERRIDDEN by the rules below (it caused 7/7 false rejections of correct PRs). Use the def's 8 risk categories only as a LENS, not as a quota. Anti-anchoring: read the DIFF and its callers BEFORE the PR description/issue (error-swallowing, MainActor-blocking FFI, paged-cache-only resolution, optimistic-UI-without-echo, hotspot growth, missing test for changed behavior, speculative scope, banned comments).

CALIBRATION — this is the important part. Your job is to catch REAL defects, NOT to manufacture findings. You are NOT required to emit a finding per category; a clean diff legitimately has zero. **APPROVE when ALL of these hold:** (1) the diff correctly does what the linked issue asks, (2) scope is locked to that issue (no unrelated churn), (3) CI is green or pending (\`gh pr checks ${pr}\`), and (4) you cannot name a CONCRETE defect — a specific line that swallows a real error, blocks the MainActor in a hot path, resolves from a paged cache without FFI fallback, mutates UI without server echo, leaves a banned comment, or adds genuinely out-of-scope code. A small, correct, scope-locked PR (even a 2-line fix) is an APPROVE, not a request-changes. Do not reject for "could add a test" on a trivial/UI change, for style, or for hypotheticals you cannot tie to a specific line.

**request-changes ONLY when you can cite a concrete defect** (file:line + why it breaks for a real user). When you do, list every such finding so the builder can fix them in one pass. **close** only if the PR is a literal no-op / duplicate of already-merged work / re-implements something already present.

If CI has already FAILED (not pending), return \`request-changes\` naming the failing job.${ciLine}

${mergeLine}

Return the structured REVIEW object.`
}

function disputePrompt(pr, w) {
	return `OPUS DISPUTE PASS for PR #${pr} (wave ${w}). The Sonnet pass returned \`dispute-needs-opus\`. Follow the "Opus dispute pass" section of .claude/agents/adversarial-reviewer.md. You MAY read the PR description/issue now. Re-run the 8-category checklist; check Sonnet's findings were grounded AND any fixer pushback wasn't a deflection. You have final say. ${cfg.autoMerge ? 'If you approve: `gh pr review --approve` then `gh pr merge ' + pr + ' --squash --auto --delete-branch`, release any hotspot lock.' : 'If you approve: `gh pr review --approve` only.'} Return the structured REVIEW object.`
}

function refixPrompt(item, build, reviewNotes, w) {
	return `The adversarial reviewer requested changes on PR #${build.prOpened} (wave ${w}, issue #${item.issue}). Address EVERY finding below on the SAME branch (${build.branch || 'the existing branch'}), scope locked to the issue. ${BUILD_GATE_DIRECTIVE} Push to the same branch (the PR updates). Do NOT open a new PR. No AI attribution.

Reviewer findings:
${reviewNotes || '(see the PR review comment)'}

Return the structured BUILD object (prOpened = same PR number).`
}

function resolvePRBuilderPrompt(pr, head, reviewNotes, w) {
	const isFeat = (head || '').startsWith('feat/')
	return `Address the adversarial reviewer's change-requests on the EXISTING open PR #${pr} (head: ${head || '?'}, wave ${w}). ${isFeat ? 'This is a FEATURE PR.' : 'This is a bug-fix PR.'}

1. \`git fetch origin && git checkout ${head}\` (or the PR's head). Read the PR diff and the reviewer's comments.
2. Address EVERY reviewer finding with scope locked to the linked issue. Follow CLAUDE.md runtime-gap patterns. ${isFeat ? 'Hold the Apple Music / Spotify / Doppler quality bar.' : 'Make the minimal correct change.'}
3. ${BUILD_GATE_DIRECTIVE}
4. Push to the SAME branch (the PR updates). No new PR. No AI attribution.

Reviewer findings:
${reviewNotes || '(read the latest CHANGES_REQUESTED / COMMENTED review on the PR)'}

Return the structured BUILD object (issue = the issue this PR closes, prOpened = ${pr}).`
}

function releaseGatePrompt(w) {
	return `M4 release-readiness gate, wave ${w}. Read-only — do NOT sign/notarize/upload (needs the user's Apple credentials). Verify {name, pass, detail} each: (1) macos/Scripts/{sign,notarize,make-dmg,make-bundle,generate-appcast}.sh exist and are real implementations; (2) a release CI workflow under .github/workflows wires build→sign→notarize→staple→DMG→appcast; (3) hardened-runtime entitlements + Developer ID config present; (4) POLISH_TARGETS.md runnable checks; (5) Sparkle EdDSA appcast tooling present. Set \`releaseReady\` only if the user could produce a signed/notarized/stapled DMG just by supplying credentials. List \`blockers\`. Return the structured RELEASE_GATE object.`
}

function finalGatePrompt() {
	return `Final gate for the lyrebird-desktop DRIVE run. Read POLISH_TARGETS.md and run every runnable \`check:\` line. Report: open priority:p0 count, open kind:bug count, open kind:feat count in milestone "${cfg.featMilestone}", open agent PR count (head fix/* or feat/*). \`polished\` = all runnable checks pass. Return the structured PREFLIGHT object.`
}

// ---------------------------------------------------------------------------
// REVIEW HELPERS
// ---------------------------------------------------------------------------
const giveUpPRs = new Set() // PRs that exhausted refix rounds — left for the human

async function reviewPR(pr, w) {
	if (!pr) return { pr: null, outcome: 'no-pr', notes: 'no PR' }
	let rev = await agent(reviewPrompt(pr, w), {
		agentType: 'adversarial-reviewer',
		model: cfg.reviewModel,
		isolation: 'worktree',
		phase: 'Review',
		schema: REVIEW_SCHEMA,
		label: `review:#${pr}`,
	})
	if (rev && rev.outcome === 'dispute-needs-opus') {
		rev = await agent(disputePrompt(pr, w), {
			agentType: 'adversarial-reviewer',
			model: 'opus',
			isolation: 'worktree',
			phase: 'Review',
			schema: REVIEW_SCHEMA,
			label: `dispute:#${pr}`,
		})
	}
	if (!rev) return { pr, outcome: 'error', notes: 'reviewer returned null' }
	// REVIEW_SCHEMA doesn't require `pr`, so the agent's object often omits it.
	// Always stamp the known pr so downstream accounting (run.merged / run.unresolvedPRs)
	// never pushes `undefined`.
	return { ...rev, pr: rev.pr ?? pr }
}

// Newly-built item: review, then up to refixRounds in-wave retries on request-changes.
async function reviewAndRefix(build, item, w) {
	if (!build) return { item, build: null, review: { outcome: 'error', notes: 'builder threw' } }
	if (!build.prOpened) return { item, build, review: { outcome: 'no-pr', notes: build.notes || 'no PR opened' } }
	let review = await reviewPR(build.prOpened, w)
	let cur = build
	let rounds = 0
	while (review && review.outcome === 'request-changes' && rounds < cfg.refixRounds) {
		rounds++
		const refixed = await agent(refixPrompt(item, cur, review.notes, w), {
			agentType: builderAgentType(item),
			model: cfg.builderModel,
			isolation: 'worktree',
			phase: 'Build',
			schema: BUILD_SCHEMA,
			label: `refix${rounds}:#${item.issue}`,
		})
		if (!refixed || !refixed.prOpened) break
		cur = refixed
		review = await reviewPR(cur.prOpened, w)
	}
	if (review && review.outcome === 'request-changes') giveUpPRs.add(cur.prOpened)
	return { item, build: cur, review }
}

// Pre-existing open PR: review, refix in place up to refixRounds, merge/close/flag.
async function resolveOpenPR(pr, w) {
	if (giveUpPRs.has(pr.number)) return { pr: pr.number, outcome: 'skipped-giveup', notes: 'exhausted prior rounds' }
	let review = await reviewPR(pr.number, w)
	let rounds = 0
	while (review && review.outcome === 'request-changes' && rounds < cfg.refixRounds) {
		rounds++
		const refixed = await agent(resolvePRBuilderPrompt(pr.number, pr.head, review.notes, w), {
			agentType: (pr.head || '').startsWith('feat/') ? 'claude' : 'area-fixer',
			model: cfg.builderModel,
			isolation: 'worktree',
			phase: 'Build',
			schema: BUILD_SCHEMA,
			label: `pr-refix${rounds}:#${pr.number}`,
		})
		if (!refixed) break
		review = await reviewPR(pr.number, w)
	}
	if (review && review.outcome === 'close') {
		await agent(`Close PR #${pr.number} as not-mergeable (no-op / duplicate of already-merged work / superseded). Run exactly: \`gh pr close ${pr.number} --comment "Closing: superseded or no-op per adversarial review; the linked issue stays open to be rebuilt clean."\` Do NOT interpolate any other text into that shell command. Do not delete the linked issue.`, {
			phase: 'Review',
			label: `close:#${pr.number}`,
		})
	} else if (review && review.outcome === 'request-changes') {
		giveUpPRs.add(pr.number)
	}
	return { pr: pr.number, outcome: review ? review.outcome : 'error', notes: review ? review.notes : '' }
}

// ---------------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------------
log(
	`drive-lyrebird-desktop${cfg.ciGated ? ' [HYPER/CI-gated]' : ''} | builders: ${cfg.builderModel} | autoMerge: ${cfg.autoMerge} | wave cap: ${MAX_WAVES}${
		budget.total ? ` (budget ${Math.round(budget.total / 1000)}k tok)` : ' (no budget directive — capped; pass args.maxWaves or +Ntok to extend)'
	} | buildCeiling ${cfg.buildCeiling} | drainCeiling ${DRAIN_CEILING} | audit every ${cfg.auditEvery} waves | ${cfg.refixRounds} refix rounds`,
)

const run = {
	waves: [],
	issuesFiled: [],
	prsOpened: [],
	merged: [],
	closed: [],
	unresolvedPRs: [],
	stoppedBecause: 'wave-cap',
}
let dryWaves = 0

for (let w = 1; w <= MAX_WAVES; w++) {
	if (budget.total && budget.remaining() < WAVE_TOKEN_COST / 2) {
		run.stoppedBecause = 'budget-exhausted'
		log(`stopping before wave ${w}: ~${Math.round(budget.remaining() / 1000)}k tokens left.`)
		break
	}

	phase('Preflight')
	log(`── wave ${w}/${MAX_WAVES} ──`)
	const pre = await agent(preflightPrompt(w), { phase: 'Preflight', schema: PREFLIGHT_SCHEMA, label: `preflight:w${w}` })

	let workedThisWave = 0

	// ---- 1. Resolve open agent PRs (clear stalled work first) ----
	const openPRs = (pre.openAgentPRs || []).filter((p) => p && p.number && !p.isDraft && !giveUpPRs.has(p.number))
	if (openPRs.length) {
		phase('Resolve PRs')
		log(`wave ${w}: resolving ${openPRs.length} open agent PR(s): ${openPRs.map((p) => '#' + p.number).join(', ')}`)
		const resolved = await parallel(openPRs.map((p) => () => resolveOpenPR(p, w)))
		resolved.filter(Boolean).forEach((r) => {
			workedThisWave++
			if (r.outcome === 'approve') run.merged.push(r.pr)
			else if (r.outcome === 'close') run.closed.push(r.pr)
			else run.unresolvedPRs.push(r.pr)
		})
	}

	// ---- 2. Audit (wave 1 + every Nth) ----
	let freshBugs = []
	const doAudit = cfg.auditEvery > 0 && (w === 1 || w % cfg.auditEvery === 0)
	if (doAudit) {
		phase('Audit')
		const audits = (
			await parallel(SLICES.map((s) => () => agent(auditPrompt(s, w), { agentType: 'area-auditor', phase: 'Audit', schema: AUDIT_SCHEMA, label: `audit:${s.replace('slice:', '')}:w${w}` })))
		).filter(Boolean)
		const filed = audits.flatMap((a) => a.issueNumbers || [])
		const totalFiled = audits.reduce((n, a) => n + (a.issuesFiled || 0), 0)
		run.issuesFiled.push(...filed)
		log(`wave ${w} audit: ${totalFiled} new issue(s) filed.`)
		if (totalFiled > 0 && totalFiled <= 10 && filed.length) {
			phase('Triage')
			const triage = await agent(triagePrompt(w, filed), { agentType: 'problem-triager', phase: 'Triage', schema: TRIAGE_SCHEMA, label: `triage:w${w}` })
			freshBugs = (triage.manifest || []).map((m) => ({ issue: m.issue, slice: m.slice, hotspot: m.hotspot, kind: 'bug', builder: 'area-fixer', title: '' }))
		} else if (totalFiled > 10) {
			log(`wave ${w}: audit produced ${totalFiled} findings (>10) — leaving them filed for human review, not auto-fixing this wave.`)
		}
	}

	// ---- 3. Backlog selection (real open issues without a PR) ----
	phase('Backlog')
	const throttle = (pre.openFixPRs || 0) >= DRAIN_CEILING
	const backlogSel = await agent(backlogPrompt(w, cfg.backlogBatch, cfg.featMilestone, throttle ? 'NOTE: open fix/* PR count is high — bias this batch toward kind:feat (feat/* branches) over new kind:bug fixes.' : ''), {
		phase: 'Backlog',
		schema: SELECT_SCHEMA,
		label: `backlog:w${w}`,
	})
	const backlogItems = (backlogSel.items || []).map((it) => ({ ...it, builder: it.builder === 'area-fixer' ? 'area-fixer' : 'claude' }))

	// Combine fresh-audit bugs (highest signal) + backlog; enforce ≤1/hotspot + ceiling.
	const combined = [...freshBugs, ...backlogItems]
	const { selected: workItems, deferred } = pickWork(combined, cfg.buildCeiling)
	log(`wave ${w} build set: ${workItems.length} [${workItems.map((i) => '#' + i.issue + '/' + (i.builder === 'area-fixer' ? 'bug' : 'feat')).join(', ') || 'none'}]${deferred.length ? `; deferred ${deferred.length}` : ''}.`)

	// ---- 4. Build → review(≤refixRounds) → merge ----
	if (workItems.length) {
		phase('Build')
		const results = await pipeline(
			workItems,
			(item) =>
				agent(item.builder === 'area-fixer' ? fixerPrompt(item, w) : featureBuilderPrompt(item, w), {
					agentType: builderAgentType(item),
					model: cfg.builderModel,
					isolation: 'worktree',
					phase: 'Build',
					schema: BUILD_SCHEMA,
					label: `build:#${item.issue}/${item.builder === 'area-fixer' ? 'bug' : 'feat'}`,
				}),
			(build, item) => reviewAndRefix(build, item, w),
		)
		results.filter(Boolean).forEach((r) => {
			if (r.build && r.build.prOpened) {
				workedThisWave++
				run.prsOpened.push(r.build.prOpened)
				const o = r.review && r.review.outcome
				if (o === 'approve') run.merged.push(r.build.prOpened)
				else run.unresolvedPRs.push(r.build.prOpened)
			}
		})
	}

	// ---- 5. Release gate ----
	let releaseGate = null
	if (cfg.includeDist && (w === 1 || w === MAX_WAVES || w % cfg.auditEvery === 0)) {
		phase('Release gate')
		releaseGate = await agent(releaseGatePrompt(w), { phase: 'Release gate', schema: RELEASE_GATE_SCHEMA, label: `release-gate:w${w}` })
		log(`wave ${w} release gate: releaseReady=${releaseGate.releaseReady}.`)
	}

	run.waves.push({ wave: w, openPRsResolved: openPRs.map((p) => p.number), built: workItems.map((i) => i.issue), releaseGate })

	// ---- Loop control ----
	const nothingActionable = pre.polished && (pre.openBugs || 0) === 0 && (pre.openFeatM3 || 0) === 0 && openPRs.length === 0
	if (nothingActionable) {
		run.stoppedBecause = 'polished'
		log(`wave ${w}: polished + no open bugs/feats/PRs. Done.`)
		break
	}
	if (workedThisWave === 0) {
		dryWaves++
		if (dryWaves >= 2) {
			run.stoppedBecause = 'idle'
			log(`wave ${w}: two consecutive waves with no work landed. Remaining backlog needs human input. Stopping.`)
			break
		}
	} else dryWaves = 0
}

// ---------------------------------------------------------------------------
// FINAL REPORT
// ---------------------------------------------------------------------------
phase('Report')
const finalGate = await agent(finalGatePrompt(), { phase: 'Report', schema: PREFLIGHT_SCHEMA, label: 'final-gate' })

const dedupe = (a) => Array.from(new Set(a))
const mergedSet = new Set(run.merged)
const summary = {
	stoppedBecause: run.stoppedBecause,
	wavesRun: run.waves.length,
	issuesFiled: dedupe(run.issuesFiled),
	prsOpened: dedupe(run.prsOpened),
	mergedOrQueued: dedupe(run.merged),
	closed: dedupe(run.closed),
	unresolvedPRs: dedupe(run.unresolvedPRs).filter((p) => !mergedSet.has(p)),
	gaveUpPRs: Array.from(giveUpPRs),
	finalPolished: finalGate.polished,
	finalPolishChecks: finalGate.polishChecks || [],
	openP0: finalGate.openP0,
	openBugs: finalGate.openBugs,
	openFeatM3: finalGate.openFeatM3,
}
log(
	`DONE — stopped: ${summary.stoppedBecause} | waves: ${summary.wavesRun} | merged/queued: ${summary.mergedOrQueued.length} | closed: ${summary.closed.length} | unresolved: ${summary.unresolvedPRs.length} | filed: ${summary.issuesFiled.length} | polished: ${summary.finalPolished}`,
)
return summary
