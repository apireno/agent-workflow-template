# RCA — `agy` review engine returned empty completions (2026-10-08 → 2026-10-12)

**Author:** CTO (template team) · **Date:** 2026-10-12 · **Status:** fixed (`agy-exec.sh`), verified live
**Reported by:** a fleet CTO. Every dev lane whose repo resolved to `agy` saw its Phase-3 self-reviews
come back empty; the fleet CTO re-ran ~20 reviews by hand on `kimi`.

## What happened

`vp-review.sh` → `agy-exec.sh` → `agy -p=<prompt>` returned exit 0 with **zero bytes** on stdout, and
on stderr:

```
warning: --mode plan has no effect while slash command expansion is disabled.
jetski: no output produced — a tool required the "read_file" permission that headless mode cannot
prompt for, so it was auto-denied.            (also seen: the "command" permission)
```

`agy-exec.sh` treated the empty answer as a failure (exit 3) and `vp-review.sh` published no file —
the fail-loud path worked. The lanes recorded the gap and escalated, as the contract says.

## Measured

From every `agy` call logged in the fleet between 2026-10-07 and 2026-10-12 (83 calls):

| prompt size | calls | ok | empty |
|---|---|---|---|
| 20–30 KB | 3 | 3 | 0 |
| 30–40 KB | 15 | 10 | 5 |
| 40–60 KB | 56 | 39 | 17 |
| > 60 KB | 9 | 8 | 1 |

~28% failed, at every size above 30 KB — **not a size threshold**. Lanes saw 3/3 retries fail on the
same prompt, so it is **prompt-dependent**, not random per call.

## Reproduction

The exact prompt `vp-review.sh vp-eng` builds for a dev-report whose lane had logged the failure
(63 KB; captured with a stub `agy`), sent twice through each configuration from an empty directory,
`agy` 1.3.3, `gemini-3.1-pro-high`:

| configuration | result |
|---|---|
| A. as shipped: `--mode plan --disable-slash-commands` | empty 2/2 (`read_file` auto-denied) |
| B. `--mode plan` alone (plan mode actually in effect) | empty 2/2 |
| C. default mode | empty 2/2 |
| D. as shipped + a one-paragraph no-tools instruction first in the prompt | **verdict 2/2** (13–15 KB) |

## Root cause

`agy` is an agent, not a chat completion. A review prompt *invites* tool use: the persona says "read
…", and the artifact quotes file paths. The model reaches for `read_file` or a shell `command`.
Headless print mode cannot ask for that permission, auto-denies it, and the denial **aborts the whole
turn** instead of returning to the model. The wrapper's guards could not prevent this, because:

1. **`--mode plan` was never a guard.** `agy` ignores it when slash commands are disabled — it says
   so in the warning above, and that warning was in every failing log. Plan mode would not have
   helped anyway (configuration B).
2. **The 2026-10-07 verification could not have caught it.** It used a prompt that invited no tool
   ("reply with exactly OK") and one plan review that happened not to call one. A smoke test that
   cannot reach the failure path is not evidence about it.

Not the cause: prompt size (table above); settings in the scratch directory (it is empty and created
fresh per call). Not isolated: the `agy` version — it auto-updated from 1.3.1 to 1.3.3 during the
period and was not tested as a variable; the reproduction and the fix are both on 1.3.3.

## Fix (`scripts/agentic/agy-exec.sh`)

- **No-tools preamble first in every prompt**: "Everything you need is in this message. Do not call
  any tools, do not run commands, do not read files. Reply with the review as plain markdown text
  only." It also guarantees no prompt can begin with `/`.
- **`--mode plan` removed** (it was a no-op) and the header no longer claims it as a guard.
- **The failure is named**: empty output with the auto-deny message exits 3 as `TOOL-DENIED` with the
  tool's name, so a lane's mechanism-gap entry says what happened rather than "empty".
- Unchanged: empty scratch cwd, `--disable-slash-commands`, tools never auto-approved, Gemini models
  only, empty answer = failure.

**Verified:** 6/6 through `vp-review.sh` on three other dev-reports whose lanes had logged the
failure (vp-eng and vp-prod each; 46–116 s; 6–15 KB verdicts; nothing written outside the scratch
dir). `scripts/agentic/test-agy-exec.sh` (15 assertions, offline, stub `agy`) holds the guards.

## Not done, deliberately

- **No retirement.** The fix holds on every prompt that failed; the resolver keeps `agy`.
- **No automatic fallback to another engine** — *amended 2026-10-19 by CEO ruling: "agy, but fall
  back to kimi with warnings."* A fallback now runs only where `.review-engine-fallback` is set, and
  never silently: a stderr warning, a stamp at the top of the verdict naming the engine that ran and
  why, a row in `.claude/engine-fallbacks.log`, and a count in the CTO preflight.
- **Lane procedure when an engine is down** is now written into `CLAUDE.devteam.md`, beside the Phase-3
  review rule: record
  the gap with the exact error, do not switch engines, finish Phase 3, close with
  `Phase-3 reviews pending: engine <name> down`.

## Residual risk

The preamble is an instruction, not a permission boundary: a model can still call a tool. If it does,
the turn aborts and the review fails loudly as `TOOL-DENIED` — it cannot produce a wrong review or
touch the repo. The rate after the fix is 0 of 8 live calls; watch the `agy-stderr.log` files for
`TOOL-DENIED` in the first week.

— CTO
