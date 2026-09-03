# RCA — dev-team tabs ran on Fable because `/model` writes a machine-global default

**Date:** 2026-09-03
**Class:** *inherited configuration with no local record* — the setting that decides
the cost of every orchestrated session is stored nowhere this repo can see, and is
written by a UI whose blast radius is larger than the window it is typed in.
**Impact:** four handoff sessions (2026-09-02) ran on Fable 5.1 instead of the Opus
default, consuming a large share of the week's quota.
**Severity:** high (cost), zero (correctness — the work itself was unaffected).

---

## 1. What happened

On 2026-09-02 at 01:43:54Z a `/model` selection was made in the CTO-home window:

```
<command-name>/model</command-name>
<local-command-stdout>Set model to `Fable 5.1` and saved as your default for new sessions</local-command-stdout>
```

Twenty minutes later `/handoff` opened three Terminal tabs. All three ran their
**first** assistant message on `claude-fable-5-1`. A fourth handoff four hours
later did the same:

| session (first message) | started | model at message #1 |
|---|---|---|
| dev-repo A | 2026-09-02T02:04:25Z | `claude-fable-5-1` |
| dev-repo B | 2026-09-02T02:04:25Z | `claude-fable-5-1` |
| dev-repo C | 2026-09-02T02:04:25Z | `claude-fable-5-1` |
| dev-repo D | 2026-09-02T06:04:51Z | `claude-fable-5-1` |

The three 02:04:25Z sessions share a launch second — one `/handoff` fan-out.
Message **#1**, not a later message, is the important part: nothing switched the
model mid-session. Each tab was born on Fable.

## 2. Root cause

Claude Code's `/model` picker does two things under one keystroke:

1. changes the model for **the window you typed it in**, and
2. writes that choice as the **machine-global default for every session started
   afterwards** — the picker says so in its own output ("and saved as your default
   for new sessions").

`/handoff` launches each dev tab with a bare `claude` invocation. It passes no
`--model`, sets no `ANTHROPIC_MODEL`, and ships no `"model"` key in any
`settings.json`. That is not an oversight to be fixed by adding one — it is the
correct default-inheriting behaviour. But it means the model of the entire fleet is
decided by whatever was last picked in *any* window, and there is no artifact in
this repo, in the sprint dir, or in the brief that records what that was.

**The CTO agent did not change the model, and no script did.** A human `/model`
selection in the CTO window propagated to every subsequently launched tab. The
fleet CTO's report that it never instructed a model change is accurate.

## 3. Why nothing caught it

Three separate reasons, each sufficient on its own:

- **No local record.** Grep proves the negative: zero `--model` flags, zero
  `ANTHROPIC_MODEL`, zero `"model"` keys across `scripts/` and `.claude/` in this
  repo and in the CTO home. There was nothing to audit, because the value lives in
  Claude Code's own state, not ours.
- **The picker's semantics changed under us.** Older sessions in the transcript
  record `Set model to Opus 4.7 **for this session**` (v2.1.145, 2026-05-28). From
  v2.1.156 onward the same command records `**and saved as your default for new
  sessions**`. The habit — "I'll switch the model in this window" — was formed when
  it meant one window and kept its meaning to the operator after it stopped meaning
  that.
- **A cost failure reports success.** Same shape as the other defects this repo has
  logged: a dead review engine's empty verdict reads as PASS, a `/send` that clears
  the composer reads as delivered. Here, a tab on the wrong model produces
  perfectly good sprint work. Nothing fails. The only signal is the quota, which
  arrives days later and does not name the sprint that spent it.

## 4. Fix

The failure class is *unobserved inheritance*, so the fix is observation, not
pinning. Pinning a model in the launch line would make `/handoff` ignore a
deliberate change too, trading a silent wrong model for a silent stale one.

- **`scripts/cto/check-fleet-model.sh`** (new)
  - `--audit` — static: asserts nothing in `scripts/` or `.claude/` pins a model
    (no `--model`, no model env var, no `"model"` key in a shipped settings file).
    This is the standing answer to "are the handoff scripts setting the model?"
  - default mode — observed: reads the model each recent session **actually ran
    on** out of its own JSONL transcript, first message and last, and exits 3 on
    any session not matching `CTO_EXPECTED_MODEL` (default `opus`). Configuration
    cannot be consulted here because configuration does not hold the answer; the
    transcript does.
- **`scripts/agentic/preflight.sh`** — CTO homes (`agent-workflow-template`, `*-cto`)
  run the check at SessionStart and surface drift as a `[WARN]` with the per-repo
  table. Dev repos skip it.
- **`.claude/skills/handoff/SKILL.md`** — after the tabs launch, polls each new
  session's transcript and prints the model each tab **actually started on**, with
  a loud warning if it is not the expected default. This closes the gap at the
  moment it opens, rather than at the next session start.

## 5. Operator note

A running session keeps the model it started on. Fixing the global default does
**not** retroactively move a live tab — `/model` must be run inside each affected
window, or the window closed and re-handed-off. The observed-mode table shows
first-message and last-message model side by side precisely so a window that was
corrected mid-flight is distinguishable from one that was not.

## 6. Audit table

| surface | sets a model? | evidence |
|---|---|---|
| `.claude/skills/handoff/SKILL.md` launch line | no | bare `claude "$KICKOFF"`; env exports are title + suggestion controls only |
| `.claude/skills/resume-dev-team/SKILL.md` | no | `claude --resume`, no model flag |
| `scripts/agentic/qa-drive-claude.sh` | no | grep clean |
| `scripts/cto/*` | no | grep clean |
| `.claude/settings*.json*` (all shipped variants) | no | no `"model"` key |
| dev repos' `.claude/settings.json` | no | fleet grep clean |
| `~/.zshrc` / `~/.zprofile` / `~/.zshenv` | no | no `ANTHROPIC_MODEL` |
| Claude Code `/model` picker | **YES — machine-global** | transcript, 2026-09-02T01:43:54Z |

The only writer is the one surface this repo does not own.
