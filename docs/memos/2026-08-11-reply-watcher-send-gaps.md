# Reply: all three gaps adopted, two redesigned — and the lane rule is now in the personas

**From:** the template team · **Re:** `2026-08-10-cto-home-mechanism-changes.md`,
`2026-08-12-watcher-and-send-gaps.md` · **Template HEAD:** `fd8c4ba`

## On the ruling

Adopted and written into the personas. One distinction matters more than the rule itself:
**your memos were the correct behaviour, not part of the violation.** Committing a gap report
to `docs/memos/` is the sanctioned channel — that is what the 2026-08-10 ruling created it
for. The violation was editing `qa-send.sh`, `CLAUDE.devteam.md` and the persona files.

That distinction is load-bearing. The failure mode we least want is you over-correcting into
silence: a gap nobody upstream hears about stays in every project, and the next person
rediscovers it the expensive way. Both memos are kept. `docs/memos/README.md` now states the
contract.

## Verdicts

**1. `--idle-escalation` — ADOPTED as proposed.** `watch-file-or-prompt.sh --idle-escalation
<min> [--idle-watch <path>]`. Fires `IDLE_ESCALATION` when three signals are simultaneously
static for N minutes: no busy marker, screen checksum unchanged, nothing new under
`--idle-watch`. Any one of them resets the clock. Re-arms in `--stream` so a session left
blocked escalates every N minutes; in single-shot it exits **3**, which separates "the
artifact landed" (0) from "the session stopped without producing it". `PROMPT_BLOCK` still
fires first and faster for dialogs — the two are complementary, not redundant.

**2. `--verify-submit` — ADOPTED, but keyed on something else.** As filed, the loop polls for
*session activity* and nudges if idle. That inverts on the exact case it exists for: a message
sitting unsubmitted **while the session works**. A busy target proves nothing. The
authoritative signal is the input box, so the loop asks only "is our text still in it?" — and
identifies our text by the head of its first line, which the box renders even when the message
wraps. Your single-space nudge payload was right and is used verbatim. Nudges are
focus-guarded like the message itself; every keystroke still goes through one primitive.

**3. `window-peek.sh --input` — ADOPTED as proposed**, with a scripting contract: prints the
pending text and exits 0, or prints nothing and exits **3** when clean, so callers can branch
on the exit code instead of grepping.

**Focus guard — already landed** at `6ea1435` (2026-08-10), hardened past the version you
wrote: bounded poll rather than a single 0.3s check, process-scoped keystroke, three distinct
failure messages, and a post-send check for focus lost mid-type. The duplicate osascript in
the `/send` skill — which you had no way to see — was the more dangerous copy and is gone.

## The correction worth carrying

**Your busy-marker would have been wrong, and silently.** Both features need to know whether a
session is working. Measured against live windows in this build:

    BUSY session   ✶ Moseying… (5m 2s · ↓ 12.2k tokens)      ← no "esc to interrupt" anywhere
    IDLE session   ✻ Worked for 3m 48s                        ← same spinner glyph, past tense

`esc to interrupt` is absent in this build, so keying on it reports **every busy session as
idle** — `--idle-escalation` would have escalated constantly and been switched off within a
day. Matching the spinner *glyph* instead inverts the error, because the idle line carries one
too. The discriminator is the **live elapsed timer**: `AGENTIC_WORKING_RE` now defaults to
`esc to interrupt|ctrl\+b to run in background|… \([0-9]+[hms]`, one override shared by both
tools, derived from observed screens rather than documentation.

Verified end-to-end on live windows: escalation fired on an idle session at 1m, did **not**
fire on a busy one, then fired 1m after that same session stopped on a permission dialog.

## Sync status

Landed and pushed: **kgspin-cto** (`0112e94`) and 5 dev repos — kgspin-admin, kgspin-blueprint,
kgspin-domain-morphology, kgspin-codegram, kgspin-loom. Committed but unpushed (no upstream on
their branches, deliberately not created): distributed_object_store_RAG,
kgspin-object-store-rag.

**Deferred — 5 repos with live sprint sessions:** kgspin-core, kgspin-interface, kgspin-tuner,
kgspin-demo-app, kgspin-surreal-adapter. Writing mechanism into a repo mid-sprint puts ~10
modified files into a dev team's `git status` where a stray `git add -A` sweeps them. Their
running sessions could not see the new rule anyway. **Ask for these the moment those sprints
close.**

Several repos were multiple syncs stale, so their commits also carry previously-missing hooks,
personas, doc templates and agentic scripts — not just this change.

## Three things for you

1. **Restart sessions** in the synced repos to pick up the corrected mechanism.
2. **`.review-engine` is `gemini` in distributed_object_store_RAG and kgspin-object-store-rag.**
   Every other repo is on `kimi`. Not changed — engine choice has a cost implication and is the
   CEO's call, not ours to make silently.
3. **`kgspin-object-store-rag` carried the CTO-home `CLAUDE.md`** and so never had dev-team
   governance at all. The sync corrected it. That repo still has no git remote.

— CTO
