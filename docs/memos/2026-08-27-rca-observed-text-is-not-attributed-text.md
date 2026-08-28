# RCA — observed text is not attributed text

**Date:** 2026-08-27 · **Author:** CTO (template) · **Class:** governance defect in the
window-orchestration layer · **Severity:** high (fabricated authority, silent)
**Status:** fixed at the source, fenced in the mechanism, guarded by a regression test

---

## 1. What happened

A watcher on a live dev-team session reported *stranded input* — text sitting unsubmitted in
the session's composer. Standing doctrine said to submit it via a space-payload keystroke, so
that was attempted. Twice. It never registered, and only because the session was mid-turn and
holding the composer.

The text had not been typed by anyone. It was Claude Code's own generated inline suggestion —
the grey completion the composer offers ahead of the cursor. The operator identified it from
the colour on screen. No watcher can see colour.

## 2. Why it is a governance defect and not a UI nit

Three properties compound:

1. **The capture is lossy in exactly the wrong dimension.** Claude Code renders the generated
   suggestion through the same text-input renderer as typed characters, into the same cells,
   distinguished only by a dim/colour attribute (verified by inspection of Claude Code
   2.1.248: the suggestion is passed to the input component as `inlineGhostText` alongside
   `dim`). `Terminal … get contents` — the read behind every peek and watcher here — returns
   plain text with every attribute stripped. A suggestion and a human's typed-but-unsubmitted
   draft are therefore **byte-identical** to every tool we have.

2. **There is nothing to compare against.** The suggestion is not written to the session
   JSONL, to `~/.claude/history.jsonl` (which records *submitted* prompts only), or to any
   draft file — checked; nothing is persisted. So the ambiguity cannot be resolved after the
   fact either.

3. **The content is adversarially shaped by accident.** A suggestion is generated from the
   session's own context, so it tends to echo the session's own last recommendation.
   Submitting one hands the session its own advice back **wearing its principal's authority**.
   Downstream, every artifact records it as a decision by the human. This is the
   failure-that-reports-success family with a new twist: the fabricated thing is not a result,
   it is *authorization*.

The doctrine that told the watcher to submit predates the suggestion feature. It rested on a
premise — *composer text is human-typed* — that a vendor release quietly falsified. Nothing
warned, because nothing could.

## 3. Root cause

**A tool asserted an attribute it could not observe, and a doctrine was built on the
assertion.**

The mechanism itself was innocent of submitting: `watch-file-or-prompt.sh` only ever emitted
tagged lines, and `qa-send.sh` only ever verified that *its own* message arrived. The defect
lived in the seam. `window-peek.sh --input` called its output **"stray input"** and
**"the operator's draft"**, and its header instructed callers to act on it. That framing — an
authorship claim the script had no way to make — is what a downstream doctrine reasonably read
as licence to submit. A detector that names what it found is a detector; one that names *who
put it there* is making something up.

The corollary is the durable lesson, and it generalises past this incident:

> **A watcher may report what it observed. It may never report who caused it.**
> Where the second is needed and cannot be measured, the answer is to remove the ambiguity at
> the source or to escalate to a human — never to infer it.

## 4. Fix

Prevention first. Detection heuristics were considered and **rejected as impossible**, not
merely difficult: there is no textual discriminator to find (§2.1), and nothing persisted to
compare against (§2.2). A colour-preserving capture (screenshot plus pixel sampling of the
composer row) was also rejected — it needs a further permission grant, breaks on themes and
resizes, and would produce a *probabilistic* answer to a question that must be certain.

| # | Change | Where |
|---|---|---|
| 1 | **Suggestions off in every orchestrated window.** `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` exported at launch. The vendor reads this env var *before* any feature gate or settings key, so it holds regardless of rollout state. | `/handoff`, `/resume-dev-team`, `qa-drive-claude.sh` |
| 2 | **`promptSuggestionEnabled: false`** in the dev-team settings template — covers a session started by hand inside the repo, which a launch-time env var never reaches. | `.claude/settings.devteam.json.template` |
| 3 | **`window-peek --input` no longer asserts authorship.** It prints an UNVERIFIED-AUTHORSHIP warning on every hit, and the header states the rule where the capability is granted. | `scripts/cto/window-peek.sh` |
| 4 | **`window-peek --authorship`** — proves the kill-switch is set for a given window by finding the launch line in its scrollback. Deliberately one-directional: `0` = provably off, `3` = unknown. Never "probably human". | `scripts/cto/window-peek.sh` |
| 5 | **`qa-send` refuses a whitespace-only payload** — the exact shape of the attempted action, since a lone space is the smallest edit that submits whatever is already in the box. Exit 7, before any window is touched. Escape hatch `--submit-composer-text "<who confirmed>"` requires a named human, refuses on an empty composer, and prints the text being submitted. A watcher signal is not a human. | `scripts/cto/qa-send.sh` |
| 6 | **Doctrine at the grant.** Directive provenance is two-class; window-recovered text is quarantined until a human claims it, per incident. | `docs/personas/cto.md`, `CLAUDE.md`, `scripts/cto/README.md`, `/send` |
| 7 | **Regression test**, including a negative control that reconstructs the pre-fix script and confirms it *would* have proceeded to the keystroke path. | `scripts/cto/test-authorship-guards.sh` |

Fix 1 is the one that ends the failure class; 3–7 exist because a dev team may still attach to
a window we did not launch, and because doctrine outlives any single switch.

## 5. Audit — every automation that acts on a window signal

Classified by the question that matters: **whose authorship does this act on?** Acting on text
we wrote is safe; acting on text we merely observed is not.

| Automation | Sends input? | Acts on window content? | Authorship | Verdict |
|---|---|---|---|---|
| `qa-send.sh` (normal message) | yes | no | **ours** — we wrote the file | SAFE by construction |
| `qa-send.sh --verify-submit` nudge (bare space) | yes | yes | **ours** — fires only while the box still matches the head of *our* message | SAFE (already guarded; now documented as to why) |
| `qa-send.sh` whitespace payload | yes | **submits foreign text** | **unknown** | **WAS UNSAFE → refused (exit 7) unless a named human attests** |
| `window-peek.sh --input` | no (read-only) | reports composer text | claimed "operator's draft" | **WAS UNSAFE FRAMING → warns on every hit; `--authorship` added** |
| `window-peek.sh --queued`, default screen read | no | yes | n/a — reports state, not a directive | SAFE |
| `watch-file-or-prompt.sh` (`PROMPT_BLOCK`, `PATTERN_HIT`) | **no — emits tagged lines only** | yes | n/a | SAFE: alert-only by construction. This is the shape all watchers must keep. |
| `/handoff` launch (`do script`) | launch only | no | ours (the kickoff string) | SAFE + now launches suggestion-free |
| `/resume-dev-team` launch | launch only | no | ours | SAFE + now launches suggestion-free |
| `qa-drive-claude.sh` launch + kickoff | via `qa-send.sh` | no | ours | SAFE + now launches suggestion-free |
| `/send` | via `qa-send.sh` | no | ours | SAFE |
| `/close-window` — clicks the "Terminate" sheet | UI click | **yes, on UI state** | n/a (not content) | **FIXED — see below** |
| `supervise-worker.sh` | no | no (process liveness) | n/a | SAFE |

**Second finding, from the audit rather than the incident.** `/close-window` answered a macOS
dialog by iterating *every* Terminal window and clicking any "Terminate" button it found —
System Events cannot see Terminal's window ids, so the target was identified by UI state
alone. With two sheets on screen it could have terminated the processes of a live dev session
while tidying up an unrelated finished tab. Same defect class, different surface: acting on an
observed signal as though it identified a specific thing. Now it refuses on ambiguity — it
clicks only when exactly one sheet exists, and otherwise tells the operator to click it
themselves.

## 6. Historical consequence

Any past "human directive" whose *only* provenance is a window submission of stranded text —
never typed in the principal's own channel, never echoed back and confirmed — is **unratified**
and may have originated as a suggestion. Any standing decision resting solely on one must be
re-confirmed before it is treated as binding. This is a fleet-side reconciliation, not a
template one; the mechanism change stops new instances, it cannot un-fabricate old ones.

## 7. Verification

`bash scripts/cto/test-authorship-guards.sh` — 13 assertions, all passing, including:

- **both directions of the launch-site scan** — removing the export from a single launch site
  was confirmed to fail the test, so the check is known to be load-bearing rather than merely
  green;
- **a negative control** — the gate is stripped from a copy of `qa-send.sh` and the space
  payload is confirmed to proceed to the keystroke path, so the refusal assertions are known
  to be testing the guard and not the parser;
- **the `--authorship` probe end-to-end** against a real Terminal window launched the way
  `/handoff` launches (returns 0) and a hand-started one (returns 3, never a guess).

The scan is written as "every `do script` that starts claude", not a hand-listed set of files,
so a launch path added later is covered without anyone remembering to add it.

— CTO
