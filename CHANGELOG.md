# Changelog — agent-workflow-template

Mechanism changes only. This repo is the single lane for workflow mechanism: fleet CTOs report
gaps (`docs/memos/`), the template team implements and syncs. See `docs/personas/cto.md`,
"Mechanism Is Not Yours to Edit".

Newest first.

## 2026-09-03 — dev tabs inherited a Fable default nobody set here

Reported from the field: several `/handoff` windows ran on Fable rather than the Opus default,
and the CTO agent had not instructed a model change. It hadn't, and neither had any script.

`/model` does two things under one keystroke: it changes the window you typed it in, **and** it
writes the choice as the machine-global default for every session started afterwards. A
selection made in the CTO-home window at 2026-09-02T01:43:54Z was inherited twenty minutes
later by all three tabs of a `/handoff` fan-out — proven at message #1 of each transcript, so
nothing switched mid-session; each tab was born on Fable. A fourth handoff four hours later did
the same. The picker's own wording has changed under us: transcripts from v2.1.145 record "for
this session", v2.1.156 onward record "and saved as your default for new sessions". The habit
outlived the semantics.

Nothing in this repo pins a model — no `--model`, no `ANTHROPIC_MODEL`, no `"model"` key in any
shipped settings file — and that is correct behaviour, not the bug. The bug is that the value
deciding the cost of every orchestrated session is held in state this repo cannot see, and a
tab on the wrong model still produces perfectly good work. Nothing fails; the quota reports it
days later without naming the sprint that spent it.

Fix is observation, not pinning — pinning would trade a silent wrong model for a silent stale
one. New `scripts/cto/check-fleet-model.sh`: `--audit` asserts no launch site pins a model
(the standing answer to "are the handoff scripts setting it?"), default mode reads the model
each session **actually ran on** out of its own JSONL and exits 3 on drift, because
configuration does not hold that answer and the transcript does. Wired into `preflight.sh` for
CTO homes only, and into `/handoff` as a post-launch check that prints the model each tab
started on before the CTO reports the handoff as done.

Operator note carried in both: a running session keeps the model it started on, so correcting
the global default does not move a live tab.

RCA: `docs/memos/2026-09-03-rca-handoff-model-inheritance.md`.

## 2026-09-01 — the CTO-home anchor never worked (skill argument rewriting)

Reported from the field: `/handoff` failing "no CTO home found" regardless of cwd and
regardless of the `~/.cto/home` anchor the error message recommends. The report was right on
root cause and evidence, and understated the impact.

The skill runtime rewrites argument placeholders in SKILL.md before the shell runs, and its
regex matches any dollar-digit token. Measured against a probe skill: it is document-wide with
no code-fence awareness (comments and prose included), there is no escape (a backslash renders
it **empty**), it beats the shell (a function's own positional is replaced before bash sees it,
so the caller's real argument is discarded), and with no arguments it substitutes nothing.

That last property is why this is not "broken when passed arguments" but **never worked**. The
anchor's first test renders as `[ -n "" ]`, so it fails for every candidate on every path —
env vars, the upward walk, the `~/.cto/home` fallback. Executed while standing in the CTO home,
the case that cannot fail, it still printed "no CTO home found". So for six weeks `/handoff`
was hard-down and the other eleven anchor-carrying skills fell back to the cwd repo 100% of the
time, saved only by the CEO usually standing in the right place. The block exists to stop
relying on exactly that luck. `dirname: illegal option -- -` was the same bug waving, read as
cosmetic noise for two weeks.

Introduced here, in `ed27f56`, by the fix for the *previous* anchoring defect. The block written
to replace a confident wrong answer about which repo we are in shipped as a confident wrong
answer about which repo we are in.

Fixed: no positional parameters in the anchor at all (named variables; brace-wrapped positionals
survive the rewrite and are deliberately not used, because the next person to write the bare form
reintroduces a silent bug). Lint **CHECK E** flags any dollar-digit token anywhere in a SKILL.md,
whole-document to match the runtime's own scope. That found four more offenders the report did not
reach: `awk '{print $6}'` in `digest` (awk field references are the same token class), functions
taking positionals in `lane-check` and `vp-review`, and `$0` written in prose meaning *zero
dollars*, rendered to the reader as argument text. Also `dirname --`, and a failure message that
no longer recommends the remedy you have already applied.

Verified by the property that matters: substituting argument text into all 18 SKILL.md files is
now a byte-for-byte no-op. Plus the anchor resolving from a drifted dev repo, CHECK E catching an
injected regression, and a live `/escalate-drain` with the exact failing argument shape.

The lesson: `/handoff` already carried a comment — written when the anchor was — saying not to use
awk field references *because the harness substitutes them*. Correct diagnosis of this exact
defect, forty lines from where the broken block was pasted in, recorded as a local quirk instead of
a rule about the rendering layer. A finding written down where it was found does not generalise.
CHECK E is that finding written down as a rule.

RCA: `docs/memos/2026-09-01-rca-skill-argument-rewriting.md`.

## 2026-08-27 — composer suggestions are not directives (authorship guards)

A watcher reported *stranded input* in a live dev-team session and, per standing doctrine,
tried to submit it. Twice. The text was Claude Code's own generated grey composer suggestion —
nobody had typed it. Only a busy composer stopped the submit.

Window reads carry no colour. Claude Code renders its generated suggestion through the same
input renderer as typed characters, in the same cells, differing only by a dim attribute that
`Terminal … get contents` strips — and the suggestion is persisted nowhere to compare against.
A suggestion and a human's unsubmitted draft are byte-identical to every watcher here. Because
a suggestion is generated from the session's own context, submitting one hands the session its
own last recommendation back **wearing its principal's authority**: not a fabricated result,
a fabricated authorization.

Root cause was one sentence in a header. `window-peek --input` called what it found "stray
input" and "the operator's draft" — an authorship claim the script had no way to make — and a
downstream doctrine reasonably read that as licence to submit. The mechanism never submitted
anything; the seam did.

Fixed at the source rather than by detection, because detection is impossible here and saying
so is part of the fix: every interactive launch path now exports
`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` (read by the vendor ahead of any feature gate or
setting), and `promptSuggestionEnabled: false` covers sessions started by hand in a dev repo.
Then the fences, because a session can still attach to a window we did not launch:
`window-peek --input` warns on every hit; `--authorship` proves the switch is set for a window
(0 = provably off, 3 = unknown — never "probably human"); `qa-send` refuses a whitespace-only
payload, whose only effect is to submit whatever is already in the box, unless a named human
attests to having typed it. Doctrine lives where the grant lives — `cto.md`, `CLAUDE.md`,
`scripts/cto/README.md`, `/send`.

The audit turned up a second instance of the same class: `/close-window` answered the macOS
"Terminate" sheet by clicking the button on *every* Terminal window, since System Events
cannot see Terminal's window ids. With two sheets up it could have killed a live sprint while
tidying a finished tab. It now refuses on ambiguity.

`scripts/cto/test-authorship-guards.sh` — 13 assertions. The launch-site scan is written as
"every `do script` that starts claude", so a path added later is covered without anyone
remembering; a negative control reconstructs the pre-fix script and confirms it *would* have
reached the keystroke path.

The durable rule: **a watcher may report what it observed, never who caused it.** Where the
second is needed and cannot be measured, remove the ambiguity at the source or ask a human.
RCA: `docs/memos/2026-08-27-rca-observed-text-is-not-attributed-text.md`.

## 2026-08-14 — duplicate-native-library detection (kgspin-core BUG-308)

`scripts/agentic/check-native-dupes.sh`, wired into `preflight.sh`. Detects two copies of one
C++ runtime inside a single Python environment — the condition behind an interpreter-teardown
SIGBUS that produced 41 crash dumps on one machine before anyone read one.

The template cannot fix a dev repo's dependency graph, but it can stop the condition recurring
silently. That is the whole contribution: **38 of 41 dumps were one signature**, and nothing in
the workflow was ever going to say so, because the crash happens at `exit()` — after the work
is done and the artifacts are written. It never failed a test. Every instance looked ignorable.

Two detectors: a hazard-list check for duplicate process-global runtimes (`libomp` ×3 here),
and a symbol-level check that catches the case filenames cannot — `_sentencepiece…so` and
`_spp…so` are unrelated names carrying the same vendored library.

Precision mattered more than coverage; the first draft reported 60+ benign vendored copies and
would have been switched off in a week. Nested interpreters are pruned (one package ships an
entire second Python), findings group by owning *package* rather than by file (pyarrow ships
four interlinked libraries — one copy, not four), and only runtimes holding process-global
state are reported. Cached and keyed on an environment fingerprint: ~10s cold, 0.8s warm,
refreshed in the background so a session start never waits for it.

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

### Field-confirmed 2026-08-14 (kgspin-cto)

Clipboard send path (864-char paste into a live session, clipboard restored, no leakage),
tri-state send verification against a live transcript, detached `/vp-review` including a correct
exit-3 rerun, and `/peek`. Four fixes confirmed by a session that was not the one that wrote
them — which is the only kind of confirmation that counts for the send path, whose failure mode
lands outside the terminal.

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
