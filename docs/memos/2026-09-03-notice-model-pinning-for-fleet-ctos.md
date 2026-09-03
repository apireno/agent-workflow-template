# NOTICE to fleet CTOs — orchestrated windows now pin their model

**Date:** 2026-09-03
**Applies to:** every CTO home running this mechanism
**Action required:** yes — three items, §4. One of them is a session restart.

---

## 1. What you are being told

You reported that several `/handoff` windows ran on Fable without instructing a model
change. **You were right on both counts: you did not change it, and no script did.**
Nothing in this mechanism has ever set a model. That was the defect, not the innocence.

Claude Code's `/model` picker does two things under one keystroke: it changes the
window you type it in, **and** it saves that choice as the machine-global default for
every session started afterwards. A launcher that passes no model inherits it.

Evidence, from the transcripts rather than from anyone's memory:

- `2026-09-02T01:43:54Z`, CTO-home window: `Set model to `Fable 5.1` and saved as your
  default for new sessions`.
- `02:04:25Z` — three handoff tabs, same launch second, all three on `claude-fable-5-1`
  at **message #1**. Not a mid-session switch. Each tab was born on Fable.
- `06:04:51Z` — a fourth handoff, same.

Aggravating detail worth knowing, because it explains why the habit was safe and then
wasn't: transcripts from Claude Code v2.1.145 record `Set model to X **for this
session**`. From v2.1.156 onward the same command records `**and saved as your default
for new sessions**`. The semantics changed under us; the operator's mental model did not.

This is the same shape as the other defects in this repo's log — **a failure that
reports success.** A tab on the wrong model produces perfectly good sprint work.
Nothing fails. The only signal is the quota, days later, not naming the sprint that
spent it.

## 2. What changed

`claude --model X` is scoped to the session it launches ("Model for the current
session", per its own `--help`) and writes nothing back to the saved default. So the
two decisions separate: **your picker is yours, the fleet's model is policy.**

- **`scripts/cto/resolve-devteam-model.sh`** — single source of truth for an
  orchestrated window's model, same shape as `resolve-review-engine.sh` you already
  use. Precedence: `DEVTEAM_MODEL` env > `.cto/devteam-model` > built-in `opus`.
- **`/handoff`** resolves and passes the pin **per repo**, and accepts
  `--model=<alias|full|inherit>` for a one-off. It also prints, after launch, the model
  each tab **actually started on** — read from the new transcripts, because no config
  records it.
- **`/resume-dev-team`** resolves identically. Without that, a crash recovery would
  quietly return a repo to the global default halfway through a sprint.
- **`scripts/agentic/qa-drive-claude.sh`** likewise.
- **`scripts/cto/check-fleet-model.sh`** — `--audit` for the static question ("is
  anything hardcoding a model?"), default mode for the real one ("what did each session
  actually run on?"), exit 3 on drift. Wired into `preflight.sh` for CTO homes, so
  drift greets you at SessionStart.

Configure with `.cto/devteam-model` (see `.cto/devteam-model.example`):

```
opus                    # fleet default — first bare line wins
acme-tuner=fable        # optional per-repo override
```

`inherit` is a supported value. It restores the old behaviour deliberately and on the
record, which is the only acceptable way to have it.

## 3. Three things that will bite you if you don't know them

1. **A running session keeps the model it started on.** Fixing the default does not
   move a live tab. `/model` must be run *inside* each affected window, or the window
   closed and re-handed-off. This is why `check-fleet-model.sh` prints first-message
   and last-message model side by side — a window corrected mid-flight looks different
   from one that was never corrected.
2. **The pin reaches launcher-spawned tabs only.** A window you open by hand still
   inherits whatever `/model` last saved, from any window. That is by design; just
   don't read a green audit as covering hand-opened sessions.
3. **The default is an alias (`opus`), not a full model name.** An alias tracks the
   latest model of its family; a pinned full name silently ages into a retired one with
   nobody editing the line. Use a full name only for a variant an alias does not select
   — the 1M-context build being the case that matters for long sprints. If you want
   that, it is one line, and it needs revisiting each model release.

Also note the **audit's meaning changed**: pinning is now correct, so `--audit` fails
on a *hardcoded* model at a launch site, not on the presence of a pin. Don't "fix" a
pin you find in `/handoff` — that is the mechanism working.

## 4. Action required

1. **Restart your session.** Skill bodies are cached at first load, so your running
   window is still executing the OLD `/handoff`. Until you restart, nothing above
   applies to a handoff you fire.
2. **Stage the synced mechanism files.** They landed in your working tree via
   `sync-cto-home.sh` and are uncommitted alongside your own in-flight IP. Scoped add
   only — `git add .claude scripts docs/personas CLAUDE.devteam.md` — never `-A`.
3. **Clear the live drift.** As of writing, two windows were still running Fable from
   Tuesday's handoff. Run `bash scripts/cto/check-fleet-model.sh`, then `/model` inside
   each window it flags, or `/close-window` them.

Optionally: decide whether `opus` (alias, auto-tracking) or `claude-opus-5[1m]` (1M
context, needs revisiting per release) is right for your sprint lengths, and write it
to `.cto/devteam-model`. With no file you get `opus`.

## 5. Reference

- RCA with the full evidence and audit table:
  `docs/memos/2026-09-03-rca-handoff-model-inheritance.md`
- CHANGELOG entries: `2026-09-03` (both — the observation fix and the pinning amendment)
- Commits: `6dcf450` (detection), `b49f1db` (pinning)
