# Remediation: the seven defects from `template-gap-report-20260814`

**From:** the template team · **To:** kgspin-cto (CEO relaying) · **Template HEAD:** see git log
**Source report:** `kgspin-cto/docs/template-reports/template-gap-report-20260814.md`
**Method:** kgspin repos treated as READ-ONLY evidence. Nothing was written into any of them.

## Verdict table

| # | Item | Verdict | Guard |
|---|---|---|---|
| 1 | `/sprint-status` heredoc quoting | **FIXED** — and `/peek` had it too | `lint-skills.sh` CHECK A |
| 2 | `/vp-review` skill-shell timeout + 0-byte files | **FIXED — FIELD-CONFIRMED 2026-08-14** | guards + a live detached run incl. a correct exit-3 rerun |
| 3 | Skill CTO-home anchoring | **FIXED** — one validated resolver, loud accurate failure | `lint-skills.sh` CHECK B + C |
| 4 | `qa-send --verify-submit` swallowed send | **FIXED — FIELD-CONFIRMED 2026-08-14** | processing verified from a live session transcript |
| 5 | Focus-guard mid-typing leak | **FIXED — FIELD-CONFIRMED 2026-08-14** | 864-char paste into a live session; clipboard restored, no leakage |
| 6 | Dev-team Phase-3 lane ambiguity | **FIXED** — lane table + named filenames + reason | none (prose) |
| 7 | `/handoff` single window slot | **FIXED** — append-only registry, refuses to guess | tested against live window ids |
| 8 | `sync-cto-home.sh` cwd-resolved TEMPLATE (filed during adoption) | **FIXED** — resolves from `BASH_SOURCE`; sweep found 1 real site of 15 | `lint-skills.sh` CHECK D |

All eight fixed. **Four are now field-confirmed** by kgspin-cto on 2026-08-14 — see
"Field confirmation" at the end, which retires both caveats this memo originally carried.

---

## 1. `/sprint-status` — dead on every invocation

**Reproduced.** `python3 - <<'PYEOF'` with `open('$CTO_REGISTRY')` inside. The quotes suppress
expansion, so python receives the literal 13 characters `$CTO_REGISTRY`.

**Fixed** by passing the path as `argv` — `python3 - "$CTO_REGISTRY" <<'PYEOF'` + `sys.argv[1]`,
the same form `push-to-repos.sh` already used.

**The audit you asked for found two more.** `/peek` carried the identical bug (undiagnosed —
it fires only on the no-argument usage path). `/sprint-accept` had a *different* instance of the
same family: a second ```` ```! ```` block referencing `$ROOT` set in the first block. **Each
block is a separate shell**, so that value was always empty. Three real sites, one of which the
field report could not have seen.

Three sites in the audit are deliberate literals and are allowlisted by name in the linter:
`$CLAUDE_PROJECT_DIR` written into a settings.json hook command, `$ARGUMENTS` (substituted by
the skill harness before the shell runs — the quoted heredoc is what makes it injection-safe),
and `${DOMSHELL_TOKEN}` written into an MCP config.

**Verified live:** `/sprint-status`'s blocks now run from `kgspin-cto` and print all 12 repos
with real session states.

## 2. `/vp-review` — the timeout, and the empty files it left

Two separate defects wearing one symptom.

**The timeout.** The skill fired reviews and `wait`ed inside a ~2-minute shell budget. Reviews
are minutes-long work; tying their lifetime to a seconds-long caller is the bug.
`scripts/agentic/vp-review-detach.sh` launches them **detached** — `trap "" TERM HUP INT` then
`exec`, and an ignored disposition survives `exec`, so a kill aimed at the launching shell's
process group no longer reaches them. `scripts/agentic/vp-review-wait.sh` polls from the main
loop, where the budget is minutes. **Exit 3 means "still running", not failure** — re-run it.

**The 0-byte files, which were not caused by the timeout.** The engine's stdout was redirected
straight at `<vp>.md`. Shell redirection *creates that file before the CLI writes a byte*, so
any kill left a zero-length verdict — which downstream reads as a review that ran and had
nothing to say. `vp-review.sh` now writes to a temp file and the final path is only ever
created by an **atomic rename** after the body passes inspection. No exit path, trapped or
untrappable, can publish an empty verdict.

**You asked the skill to refuse to leave a 0-byte output on any exit path. It now cannot
produce one at all**, which is the stronger property.

**Guard:** `scripts/agentic/test-vp-review-guards.sh` — 7 assertions, no network, no API spend
(uses `VP_REVIEW_DRY_RUN`), covering empty response, rate-limited response, good response,
SIGTERM mid-review, leftover temp files, and SIGKILL mid-review. The seventh is a **negative
control**: it reconstructs the pre-fix script and asserts it *does* leave a zero-byte file. A
guard that cannot fail proves nothing.

**One more silent failure found while fixing this.** The first version of the rewritten skill
printed `DISPATCH=detached` even when the launcher failed to start — sending the CTO off to
poll for reviews that never existed. It now branches on the launcher's exit code and the
presence of `.status` files, and prints `DISPATCH=failed` with the likely cause. Both paths
tested.

## 3. CTO-home anchoring

**Reproduced exactly**, and the root cause is worse than reported. From a shell sitting in
`kgspin-tuner` with `$CLAUDE_PROJECT_DIR` empty, `/sprint-status` did not merely fail — it
**succeeded against the wrong fleet**: `kgspin-tuner/.cto-path` points at the *public template*,
whose `.cto/projects.yaml` is a placeholder listing `my-project` and `my-frontend` at
`/Users/yourname/…`. A confident answer naming repos that do not exist.

**Fixed** with one canonical anchor block (`scripts/cto/_cto-home-anchor.sh`), applied verbatim
to 10 skills. It tries `$CTO_HOME` → `$CTO_REPO` → `$CLAUDE_PROJECT_DIR` → walk up from `$PWD`
→ `.cto-path` at each level → `~/.cto/home`, **validates every candidate** (must hold a
`.cto/projects.yaml` that is not the shipped placeholder), and on failure prints what it tried,
what it walked, and which candidates it rejected and why. Skills that read the fleet registry
set `CTO_HOME_REQUIRED=1` so a miss is fatal rather than a silent fallback to the current repo.

Live output from the reported failure position, now:

```
ERROR: no CTO home found — no directory containing .cto/projects.yaml.
  $CTO_HOME=''  $CTO_REPO=''  $CLAUDE_PROJECT_DIR=''
  walked up from: /Users/apireno/repos/kgspin-tuner
  rejected candidates:
    /Users/apireno/repos/agent-workflow-template (placeholder registry — the unconfigured template)
  This is an ANCHORING failure, not a missing registry. Run the skill from the CTO
  home, or fix it permanently:  echo /path/to/<project>-cto > ~/.cto/home
```

**Two things for your side.** (a) `kgspin-admin`, `kgspin-core`, `kgspin-loom` and
`kgspin-tuner` still have `.cto-path` pointing at the template — which also means
`escalate-to-cto.sh` has been routing their escalations to the wrong home. `push-to-repos.sh`
now rewrites `.cto-path` on every sync, so the next sync heals them; I did not touch them.
(b) Run `mkdir -p ~/.cto && echo /Users/apireno/repos/kgspin-cto > ~/.cto/home` once — it is
the last-resort anchor and makes cwd drift a non-event. `/setup` now writes it for new homes.

**Guards:** `lint-skills.sh` CHECK B (anchor drift from the canonical copy) and CHECK C (a `!`
block using `$ROOT`/`$CTO_REGISTRY` without re-anchoring). `--apply` re-syncs.

## 4. The swallowed send

**Not reproducible on demand** — it needs a live session queueing at a turn boundary — so this
was fixed by reasoning about the signal rather than by reproduction, and the reasoning is worth
stating: **box-cleared is a proxy, and it was measuring the wrong event.** Delivery, submission
and processing are three events; the old check confirmed the second and reported the third.

`--verify-submit` now runs in two stages. Stage 1 is the box check (submission). Stage 2 checks
the **session transcript on disk** — `--repo <path>` resolves `.claude/current-session.id` to
its JSONL and waits for the message to appear. Outcomes are now distinct:

- `PROCESSED` — in the transcript. The only one that means read.
- `DELIVERED` — left the box, processing not checkable (no transcript given). Says so.
- `SUBMITTED BUT NOT PROCESSED` — exit **6**, the failure you hit, now named.

`/send` passes `--repo` automatically and its report text no longer says "injected" as if that
meant read.

The `Press up to edit queued messages` hint is handled two ways: stripped from `--input`'s
pending-text extraction (it was making a clear box look occupied), and used as **evidence** by
the new `window-peek.sh --queued`, since its presence is exactly the queued-but-unread state.

**Caveat:** stage 2 greps the transcript for the head of the message's first line. A message
whose opening 24 characters duplicate an earlier one could false-positive. Acceptable for
rulings and STOP orders; worth knowing.

## 5. Focus-guard leaks — the one with blast radius outside the terminal

**Fixed by removing the exposure window rather than watching it more closely.** Per-character
typing holds the keyboard for seconds; a check before typing cannot help once focus moves
mid-stream. `qa-send.sh` now **pastes via the clipboard** — one `⌘V` event instead of thousands
of keystrokes — and the operator's clipboard is saved and restored.

The second half matters as much: **focus is re-verified between the paste and the Return.** If
it moved, the Return is *not* sent, the script aborts with exit 4, and it names the app that
took focus so the operator knows where to look. In a messaging app the Return is what turns a
stray paste into a sent message; that is the keystroke worth withholding.

`--type` / `AGENTIC_SEND_MODE=type` restores keystroke mode. Abort-loud behaviour is unchanged
and now applies to nudges too, which route through the same primitive.

**Caveat RETIRED 2026-08-14.** When written, only the *abort* path had been verified live —
the guard fired, refused to type, and named Chrome as the thief. The happy path was untested
because exercising it meant stealing focus from the operator mid-session. kgspin-cto has since
run it for real: an 864-character ruling injected by paste into a live session, clipboard saved
and restored, no leakage and no fragments. Clean on first use.

## 6. Dev-team Phase-3 lane

`CLAUDE.devteam.md` now carries a lane table naming the two files the dev lane owns
(`product-review.md`, `test-eval.md`) and stating that `phase3-review-*.md`, `cto-decision-*.md`
and `conformance.md` are CTO-lane — **with the reason**, because a rule without one gets
re-derived away: the CTO's Phase-3 review exists to be independent of the dev team, and a copy
a team commissions for itself cannot serve that purpose.

It also now says: if a review command fails, delete the empty output and record the failure in
`dev-report.md`. "The vp-prod review failed, engine error in the log" is a complete Phase-3
outcome. An empty file is not. Two new entries in COMMON MISTAKES.

## 7. The single window slot

`scripts/cto/window-registry.sh` — append-only TSV at `<repo>/.claude/terminal-windows.tsv`,
one row per window with a sprint label. `/handoff` appends (and still writes the legacy single
slot, which now means "most recent", not "the one"). `/send` and `/close-window` resolve
through it.

Two properties worth naming. **Liveness is never inferred from the file** — every resolve
checks the id against Terminal, because a row claiming `open` for a window the operator closed
is the same confident-wrong-answer failure as everything else in this report. And **ambiguity
refuses**: a repo with two live windows prints both with their labels and exits non-zero rather
than addressing the newest. For `/close-window` that is not a nicety — closing the wrong window
kills a live session.

Verified against your real window ids: two live windows → refusal with choices; label →
resolves; dead id → `GONE`; after close → the survivor resolves cleanly.

---

## 8. `sync-cto-home.sh` resolved TEMPLATE from cwd — FIXED

Filed by you during adoption, and correctly classed: same anchoring family as item 3, in a
script my item-3 fix did not reach because it fixes skills, not scripts.

**(1) Fixed.** `TEMPLATE` now comes from `${BASH_SOURCE[0]}`, so the script runs from any cwd —
including the CTO home, which is the cwd the fleet-sync instructions ask for. Confirmed against
your exact failing invocation.

**(2) Swept — and the honest result is one bug, not a class-wide rot.** There are 15
`git rev-parse --show-toplevel` sites under `scripts/`. **Fourteen are correct**: they mean
"the repo this script operates on" (`resolve-review-engine.sh` reading *that repo's*
`.review-engine`, `escalate-to-cto.sh`, `preflight.sh`, `vp-review.sh`'s project-specific
concerns/context), and nearly all use the `${VAR:-$(git …)}` caller-overridable idiom. The
`qa-drive-*` scripts anchor with `git -C "$SPRINT_DIR"`, which is explicit and right. Yours was
the only site where a cwd-resolved path meant *the tree we copy from*.

**(3) The refusal now self-diagnoses**, as requested:

```
ERROR: target and source are the same directory — nothing to sync.
  TARGET   : /Users/apireno/repos/kgspin-cto   (from argument 1)
  TEMPLATE : /Users/apireno/repos/agent-workflow-template (from this script's own path: …)
```

**Guarded — `lint-skills.sh` CHECK D.** The rule encodes the distinction rather than banning
`git rev-parse`, which would flag fourteen correct lines and be switched off within a week: a
cwd-resolved variable used in a copy *source* position is a finding; the subject-repo idiom is
not. It also matches the wrapper-function form (`sync_one "$TEMPLATE/x" "$TARGET/x"`), which is
how this bug hid from a naive `rsync|cp` scan. Verified both directions: clean on the fixed
tree, exactly one finding when the old line is restored.

**On your last paragraph — yes, keep sending those.** "The `/close-window` tty pre-kill worked
hands-free on its first live use" is worth as much as a bug report: it is the only evidence
that path works outside my own testing. Noted that the clipboard send path is still unexercised;
that is the one I most want a real report on, because its failure mode lands outside the
terminal.

## Sync

Everything above is in the template. `scripts/cto/sync-cto-home.sh <kgspin-cto> --apply` copies
`.claude/skills`, `.claude/hooks` and `scripts/` wholesale, so all of it lands in one pass;
`push-to-repos.sh` carries the dev-repo half (`CLAUDE.devteam.md`, `.cto-path`, hooks,
`scripts/agentic`). **Run both from `kgspin-cto`, not from the template** — `--fleet-default`
resolves from the repo the script lives in, and the template is deliberately engine-neutral.

Two things to do by hand after syncing: `echo /Users/apireno/repos/kgspin-cto > ~/.cto/home`,
and restart any long-lived sessions so they pick up the corrected mechanism.

**Keep filing these.** Four of the seven were things no amount of reading the template would
have surfaced — they only appear when a real session runs into them.

— CTO


---

# Field confirmation — 2026-08-14 (kgspin-cto)

Four of these fixes have now been exercised by a real session rather than by my tests:

- **Item 5, the clipboard send path.** An 864-char ruling injected with `mode=paste` into a
  live session. Clipboard saved and restored; no leakage, no fragments. This was the single
  most important one to confirm, because it is the only fix whose failure mode lands *outside*
  the terminal — in the operator's own applications. Clean on first use.
- **Item 4, tri-state verification.** Delivery confirmed, then processing verified from the
  session transcript. The distinction the fix exists to make held in the field.
- **Item 2, detached reviews.** A live `/vp-review` detach + `WAIT_CMD`, **including a correct
  exit-3 rerun on a long review** — which is the behaviour most likely to be misread as failure,
  so confirming it is worth more than confirming the happy path.
- **Item 1, `/peek`** — the bug the original report could not have seen.

This is the evidence my own testing could not produce, and it is why gap reports and
confirmations are equally worth filing. A fix verified only by the person who wrote it is a
hypothesis with good manners.

**Still unexercised:** the window registry's ambiguity refusal under a genuine two-live-sprint
repo (tested against real window ids, not against a real second sprint), and CHECK D as a
pre-commit gate rather than a manual run.
