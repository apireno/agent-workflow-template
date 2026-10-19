# ADR-003: Land by fast-forward from /sprint-accept — repo hygiene in the mechanism, not in memory

**Status:** Accepted (CEO approval 2026-10-19) · **Author:** CTO (template) · **Created:** 2026-10-19
**Origin:** a fleet CTO's request after a DevOps + Eng review (project-local; summarized here).
**Plan + VP reviews:** the template's local sprint dir `sprint-repo-hygiene-mechanism-20261007`
(vp-eng, vp-devops, vp-security; decision REJECTED-FOR-REVISION → split → approved).

## RICE

| Factor | Value | Rationale |
|---|---|---|
| Reach | 9 | Every sprint in every repo lands through this. |
| Impact | 5 | Unpushed work is lost work; a worktree a live lane reads, deleted, stops the lane. |
| Confidence | 0.85 | Every step is fixture-tested against a bare origin; fast-forward-only is conservative. |
| Effort | M | |
| **RICE** | **8.0** | |

## Context

A fleet audit found ~2 months of work existing only on one laptop (2,000+ unpushed commits), 103
abandoned worktrees (74 GB), 300+ merged branches never deleted, a repo whose de-facto main was a
feature branch (a merge to `main` never reached it), and CI red with nobody aware because nothing
had been pushed for it to run on. A follow-up census found the CTO had removed a worktree a live lane
was reading, twice in one month. Every step that would have prevented this lived in a persona rule
or in someone's memory. `/sprint-accept` wrote a decision and stopped.

The org is on **GitHub Free**: no branch protection, rulesets or required checks on private repos.
Server-side enforcement is a paid-plan decision. Until then the gate lives in our scripts.

## Decision

1. **Accepting a sprint lands it.** After an APPROVED (or APPROVED-WITH-CONDITIONS) decision,
   `/sprint-accept` runs `scripts/agentic/land-lane.sh <sprint-dir>`: commit the sprint dir (scoped) →
   refuse a lane that lacks `origin/<base>` (missing commits named) → push the lane and wait for CI on
   its head sha (red/missing refuses; `--allow-red "<reason>"` records the CEO's reason in the decision
   and an out-of-repo log) → **fast-forward** `origin/<base>` (never `--force`) → annotated tag
   `sprint/<slug>` → delete the lane branch on origin → archive, verify and remove the lane worktree →
   delete the local branch. Any refusal stops and reports `landing: INCOMPLETE at <step>`;
   `/sprint-accept <dir> --land` re-runs only the landing. Base = whatever `origin/HEAD` names.
2. **Fast-forward only.** Because step 3 proves the lane contains the base, landing is a pointer move
   on the remote; nothing is merged on a laptop. The sprint's record is the tag and the decision file.
3. **Never delete unarchived work.** `archive-worktree.sh` copies every untracked file and the
   project's allowlisted ignored outputs (default `outputs/ data/`, `.claude/land.yaml`), withholds
   secret-shaped files (named in `EXCLUDED.txt`), sha256-verifies the copy, and only then removes the
   worktree. Archive dirs are mode 700, under `~/<project>-data/wt-archive/<date>/`.
4. **Never remove what a live lane uses.** `reap-worktrees.sh` refuses any worktree a process, an open
   window, a live Claude session, a pins file, a data manifest, or a live lane's sprint dir references,
   naming the reference. There is no `--force`. Default is report-only.
5. **No direct pushes to base.** `.claude/githooks/pre-push` refuses a push to the base branch unless
   `land-lane.sh` made it (`LAND_LANE=1`); `ALLOW_BASE_PUSH="<why>"` is a logged exception. It is
   client-side and says so; the daily hygiene report (Sprint B) flags untagged base commits.
6. **Pins are declared, not hard-coded.** `pinned-worktree.sh` creates `<repo>-wt-<short-sha>` detached
   (sparse optional), idempotently; each project lists its pins in `.claude/pins.yaml`.
7. **Derived artifacts rebuild at their pin** (amends ADR-002): `pin_lock`/`pin_key`/`pin_arg`/
   `external` in the manifest; `--fix` reproduces the pin, `repin <name> <sha>` moves it, an external
   artifact with no pin is refused.

## Deviations from the approved plan (recorded, not hidden)

- **Where the landing outcome is written.** The plan put `landing: complete|incomplete` in the decision
  file. But the decision is committed *before* the push (it must land with the work, and the worktree
  holding it is removed afterwards), so it cannot also record the push's outcome. The outcome goes to
  `<main-repo>/.claude/landings.log` and the tag message; `/sprint-accept` reports it.
- **Hooks path is absolute.** Found while testing: a relative `core.hooksPath` resolves per worktree, and
  lane worktrees have no untracked `.claude/`, so *no* hook had been running in lane worktrees. The
  installer now sets the main checkout's absolute `.claude/githooks`.
- **SESSION and LANE references** in the reap are verified against live transcripts, not in the
  offline fixture (a fixture cannot fake a running Claude session).

## Consequences

**Positive.** Nothing lands without containing the base and passing CI (or a named override); every
landing is a fast-forward with a tag; branches and worktrees stop accumulating; nothing unarchived or
live is ever deleted; a sibling's dirt can no longer leak into a pinned artifact.
**Negative.** Accept is slower when CI is slow (up to `--ci-wait`, default 20 min). A repo without
`origin/HEAD` set cannot land until it is (`git remote set-head origin --auto`). The pre-push hook will
refuse a fleet's habit of pushing straight to `main` the first time it fires — by design.
**Rollback** of a landed sprint is a revert commit landed through a new lane; force-push to base stays
forbidden, incidents included.

## Tests

`test-land-lane.sh` (18) · `test-archive-worktree.sh` (10) · `test-reap-worktrees.sh` (10) ·
`test-pinned-worktree.sh` (7) · `test-derived-artifact-pins.sh` (10); the earlier gate suite (35) still
passes. Live: `reap-worktrees.sh` on a real fleet repo kept two pinned engine worktrees (named in a pin
file, a data manifest and a lane's dev-report) and marked one 40-day-old merged worktree reapable.

— CTO
