# Changelog — agent-workflow-template

Mechanism changes only. This repo is the single lane for workflow mechanism: fleet CTOs report
gaps (`docs/memos/`), the template team implements and syncs. See `docs/personas/cto.md`,
"Mechanism Is Not Yours to Edit".

Newest first.

## 2026-08-14 — seven field defects from the kgspin fleet

From `template-gap-report-20260814` (kgspin-cto), filed after a real orchestration session.
Every item was worked around session-locally and left unpatched upstream, so all seven were
still live here. Full mapping in `docs/memos/2026-08-14-remediation-seven-defects.md`.

The unifying shape, again: **a failure that reports success.** A skill that dies on every
invocation, an empty file that reads as a clean review, a message that clears the input box
and is never read, a resolver that confidently returns the wrong fleet.

### Fixed

- **`/sprint-status` and `/peek` were dead on every invocation.** A single-quoted heredoc
  (`<<'PYEOF'`) with `open('$CTO_REGISTRY')` inside: no expansion, so python got the literal
  string. `/peek` carried the same bug undiagnosed. Registry paths now pass as `argv`.
- **`/vp-review` killed its own reviews.** The skill body fired reviews and `wait`ed inside a
  ~2-minute shell budget; long kimi reviews were SIGTERMed. New `vp-review-detach.sh` launches
  them immune to the group kill (`trap "" TERM` survives `exec`), `vp-review-wait.sh` polls
  from the main loop where the budget is minutes.
- **Zero-byte verdicts.** `vp-review.sh` redirected the engine straight at `<vp>.md`, which
  creates the file before the first byte — a kill left an empty verdict that read downstream as
  a completed review with nothing to say. The engine now writes to a temp file and the final
  path is created only by an atomic rename, so no abnormal exit can publish an empty one.
- **CTO-home anchoring.** `$CLAUDE_PROJECT_DIR` was empty in skill shells and the git-root
  fallback resolved to whatever repo the shell sat in. One canonical anchor block
  (`scripts/cto/_cto-home-anchor.sh`) in 10 skills tries `$CTO_HOME` → `$CTO_REPO` →
  `$CLAUDE_PROJECT_DIR` → walk-up → `.cto-path` → `~/.cto/home`, **validates** each candidate,
  and fails naming the actual cause. It also rejects the public template's placeholder registry,
  which otherwise resolves cleanly and reports a fleet of repos that do not exist.
- **Focus-guard leaks.** Two incidents typed message fragments into the operator's WhatsApp and
  Chrome mid-injection. `qa-send.sh` now pastes via the clipboard (one event, not seconds of
  keystrokes) and **re-verifies focus between the paste and the Return**, so a steal in between
  aborts before anything can be submitted in the wrong app. Clipboard is saved and restored.
  `--type` restores the old mode.
- **Swallowed sends.** `--verify-submit` treated a cleared input box as delivered; a queued
  ruling was dropped at turn end with the box clear. Verification now has a second stage
  against the session transcript on disk (`--repo` / `--transcript`), and reports
  `PROCESSED` / `DELIVERED` / `SUBMITTED BUT NOT PROCESSED` (exit 6) distinctly. Without a
  transcript it says so rather than claiming delivery.
- **Phase-3 lane.** `CLAUDE.devteam.md` now names the two review files the dev lane owns and
  states that `phase3-review-*`, `cto-decision-*` and `conformance.md` are CTO-lane — with the
  reason (an accept-gate a team commissions for itself is not independent of it).
- **Single window slot.** `/handoff` overwrote `.claude/terminal-window.id`, orphaning
  long-lived sessions. New append-only `scripts/cto/window-registry.sh`; `/send` and
  `/close-window` resolve through it, check liveness against Terminal, and **refuse to guess**
  when a repo has two live windows.

### Guards added (they fail against the pre-fix code — verified)

- `scripts/cto/lint-skills.sh` — quoted-heredoc interpolation, anchor drift, and `!` blocks
  that use `$ROOT`/`$CTO_REGISTRY` without re-anchoring (each block is a separate shell).
  `--apply` syncs the canonical anchor.
- `scripts/agentic/test-vp-review-guards.sh` — 7 assertions on the verdict-output contract,
  including SIGTERM and SIGKILL mid-review, plus a negative control that reproduces the
  pre-fix code and confirms it *does* leave a zero-byte file.

### Item 8 — `sync-cto-home.sh` resolved its SOURCE tree from the caller's cwd

Reported by kgspin-cto while adopting the above. `TEMPLATE="$(git rev-parse --show-toplevel)"`
answers "which repo is the shell standing in" — but TEMPLATE is the tree we copy *from*. Run
from the CTO home (which the fleet-sync instructions require), TEMPLATE resolved to TARGET and
the script refused with "target is the template itself": an error naming the wrong cause. Now
resolved from `${BASH_SOURCE[0]}`, and the refusal prints both paths and where each came from.

Swept all 15 `git rev-parse --show-toplevel` sites in `scripts/`. **Fourteen are correct** —
they mean "the repo this script operates on", almost all in the `${VAR:-$(git …)}`
caller-overridable form. One was the bug. New **CHECK D** in `lint-skills.sh` encodes the
distinction: a cwd-resolved variable used as a copy *source* is flagged; the subject-repo idiom
is not. Verified precise — clean on the fixed tree, one finding when the bug is reintroduced.

### Also found while fixing (not in the report)

- `/peek` carried the same fatal heredoc bug as `/sprint-status`.
- `/sprint-accept` had a second `!` block using `$ROOT` from a previous block — always empty.
- Four kgspin dev repos still point `.cto-path` at the public template, so escalations route
  to the wrong home. `push-to-repos.sh` now rewrites `.cto-path` on every sync.
- `settings.devteam.json.template` wired five hooks; `push-to-repos.sh` installed three.

## 2026-08-14 — upstream mode for repos we don't own

`push-to-repos.sh --upstream` (auto-detected) installs the mechanism into a public OSS clone
without touching a single tracked file: contract to `CLAUDE.devteam.md` loaded by a SessionStart
hook, scaffolding excluded via `.git/info/exclude`, paths the upstream project tracks left
alone. Acceptance test is `git status --porcelain` being empty afterwards.

## 2026-08-11 — review engine is a project-start choice

`set-review-engine.sh` (validated writer), `gemini` quarantined to `subagent` with a warning,
engine asked once at `/setup` and `/new-project`, seeded and healed fleet-wide from the CTO
home's own `.review-engine`.
