# Mechanism governance review — kgspin-cto session arc 2026-07-18 → 2026-07-27

**Reviewer:** template team (agent-workflow-template) · **Date:** 2026-07-27
**Input:** `kgspin-cto/docs/template-sync/session-mechanism-accounting-20260727.md` and
`upstream-review-20260725.md` · **Frame:** KEEP / REWRITE / CULL-to-downstream / CULL

The accounting was complete, honest, and correctly volunteered — that is the behaviour we
want when the routing rule is missed. The rulings below are about the artifacts, not the
disclosure. **Every capability the session identified is real.** Most implementations are
not, and one was materially broken in a way the accounting did not catch.

---

## 0. Findings that drove the rulings

Four things surfaced on inspection that the accounting did not report. They are the reason
this is a revert rather than an amend.

**F1 — `app-stack.sh` is broken in five places, not genericized.** Its "genericization" was
a literal find-and-replace of values with `${VAR:-default}`, which corrupted the syntax
around them. Verified by execution, not by reading:

| Line | Intended | Actually expands to |
|---|---|---|
| 16, 33 | `http://127.0.0.1:8080/` | `http://127.0.0.18080/` — the `:` was eaten |
| 23 | `$APP/scripts/bringup.sh` | `$APP/scripts/scripts/bringup.sh` — doubled segment |
| 27 | `$APP/scripts/reset-for-test.sh` | `$APP/scripts/scripts/reset-for-test.sh` |
| 19, 20, 42 | `lsof -i :8011` | `lsof -i 8011` → `lsof: unknown protocol name (8011)` |
| 18 | a status line | `demo8080=200` — quote soup |

Every code path in the file is non-functional. It was pushed to a public template untested.

**F2 — the leak scrub was incomplete.** `e7f7769` removed one project string. Three remain
at `e3851e7`: `bringup-demo-stack` hard-coded at lines 34 and 40 (the two paths that
actually matter — death-detection and teardown), and `surreal` as a hard-coded status label,
which discloses the project's database choice. The accounting's "one leak, caught and
scrubbed" understates this.

**F3 — the allowlist entries never worked.** All seven use `$CTO_HOME`, which is not a
Claude Code variable and is defined nowhere in either repo. The documented variable for
Bash permission rules is `$CLAUDE_PROJECT_DIR`
([settings reference](https://docs.claude.com/en/docs/claude-code/settings)). The entries
expand to a literal `$CTO_HOME/...` path and match nothing — so the doctrine's own rule 2
shipped inert.

**F4 — the entries were redundant anyway.** `settings.cto.json.template` already grants
`Bash(*)`. Under that posture no per-script entry changes anything, which falsifies the
doctrine's stated rationale ("a script without its allowlist entry prompts like raw bash").
The real mechanism is command *shape*, and shape prompts even under `Bash(*)`.

---

## A. The two unreviewed pushes — **REVERT, then selectively re-land** (executed)

Ruled revert over amend-in-place for three reasons: it removes broken and project-leaking
code from public `HEAD` immediately rather than after a rewrite lands; it produces an
unambiguous audit boundary (unreviewed push → reverted → re-landed under review); and the
downstream session documented the clean revert path, so using it honours the process it
offered.

Executed: `95aa185` (revert `e7f7769`), `f35a3fd` (revert `e3851e7`).

| Artifact | Ruling | Rationale |
|---|---|---|
| `window-peek.sh` | **REWRITE (light)** | Real gap — `/peek` shows the JSONL, nothing showed the *screen* where permission dialogs live. Fixed: `set -e` + `grep` returning 1 turned an all-blank window into a hard failure; bad ids now fail with a usable message. |
| `close-window-id.sh` | **REWRITE** | Capability legitimate (handoff overwrites `terminal-window.id`, orphaning windows `/close-window` can no longer address). But it killed every process on a tty with no confirmation, routing around the dev-report gate `/close-window` deliberately has. Now **dry-run by default**: prints the window, tty, and exact process list, and requires `--yes`. No repo means no dev-report check is possible, so *see-before-destroy* is the gate. |
| `watch-file-or-prompt.sh` | **REWRITE** | Best of the six; the "why a script file" reasoning is correct and matches existing template doctrine. Fixed: `stat -f` is BSD-only (added GNU fallback); prompt regexes now overridable via `WATCH_PROMPT_RE` since they track a vendor's UI and silent non-matching is the worst failure; header now states its division of labour with `wait-for-artifact.sh`, which it otherwise appears to duplicate. |
| `supervise-worker.sh` | **REWRITE (light)** | Sound design — restart-command-in-a-file is the right call. Fixed: restart output went to `/dev/null`, so a failing restart was indistinguishable from one that never ran (now logs to `<cmdfile>.log`); no crash-loop bound (now `max-restarts`, default 20); decline-counting no longer decrements the restart counter to fake idleness. |
| `app-stack.sh` | **CULL entirely** | F1 + F2. Beyond the defects it fails the genericity test on principle: an app stack is defined by ports, process names, bringup scripts, and a database — a template cannot own it. See §Requests/`/stack` for what the template *can* own. |
| `README-ops-scripts.md` | **REWRITE** → `scripts/cto/README.md` | Rules 1 and 3 are correct and worth keeping. Rule 2 was wrong as stated (F3, F4). The hand-maintained inventory paragraph was already stale on arrival — it documented `app-stack`. |
| allowlist entries in `settings.cto.json.template` | **CULL** | F3 + F4: inert and redundant. Replaced with a `_comment_opsScripts` recording the correct `$CLAUDE_PROJECT_DIR` form for anyone who tightens `Bash(*)`. |

Re-landed under template-team authorship, each tested against live windows and processes
(list/peek, dry-run against a real session, file-landed, file-updated-with-`now`-baseline,
worker decline path, worker crash-loop bound).

---

## B. Scripts held in `kgspin-cto/scripts/cto/`

| Script | Ruling | Rationale |
|---|---|---|
| `watch-file-or-prompt.sh` | **CULL-to-downstream → then delete** | Superseded by the re-landed template version. Take the template's copy via `sync-cto-home.sh`; do not maintain a fork. |
| `supervise-worker.sh` | **CULL-to-downstream → then delete** | Same. |
| `window-peek.sh` | **CULL-to-downstream → then delete** | Same. |
| `close-window-id.sh` | **CULL-to-downstream → then delete** | Same — note the template version is now dry-run by default; `--yes` is required. |
| `queue-query.sh` | **CULL-to-downstream (KEEP local)** | Correctly identified as project-specific and correctly never pushed. It is good downstream tooling. Keep it, keep it working, do not attempt to genericize it. |
| `demo-stack.sh` | **CULL-to-downstream (KEEP local)** | Keep the working project-specific original. Do **not** re-attempt upstreaming — F1 is what that attempt produced. |

---

## C. Uncommitted scratchpad scripts — **no action**

`restart-worker.sh` and `archive-when-fast.sh` die with the scratchpad. Listing them was
the right instinct. If `restart-worker.sh` is load-bearing for a running supervision loop,
promote it into `kgspin-cto` as project-specific tooling under the §B `queue-query.sh` rule
rather than letting it vanish mid-run.

---

## D. Settings modifications in `kgspin-cto/.claude/settings.json`

| Item | Ruling | Rationale |
|---|---|---|
| `additionalDirectories` = fleet repo paths | **KEEP (downstream, not mechanism)** | Local machine configuration, correctly local. Never upstream absolute paths. |
| MCP allows (claude-in-chrome / domshell / codegram) | **KEEP (downstream)** | Same. But see P1 — a CTO home holding a browser MCP is exactly the availability that hijacked a QA drive. |
| Per-script allowlist entries (`1399a4b` + earlier) | **REWRITE** | If that file grants `Bash(*)`, delete them as dead weight. If not, rewrite to `$CLAUDE_PROJECT_DIR` — as written with `$CTO_HOME` they have never matched anything (F3). |

---

## E. Persona / docs modifications

| Item | Ruling | Rationale |
|---|---|---|
| `cto.md` Success Gating | **KEEP — adopted, genericized by template team** | CEO-directed and binding; only the genericization was unilateral, and that was routed as a proposal, correctly. Now in the template's `docs/personas/cto.md` with project examples stripped ("graph products / grow→select→ingest" → "the product's core loop"; "canvas demo" → "a live run") and tied explicitly to the existing verify/accept split. |
| `upstream-review-20260725.md` | **KEEP as the model** | This is what the routing rule looks like when followed: bugs reported, scripts proposed, skills *requested* not built. Two real template bugs came from it (P0, P1). |
| `git-hygiene-*.md`, `holdout-burn-ledger.md` | **Out of scope** | ADR/CEO-mandated operational outputs, not mechanism. |

---

## Doctrine rulings (decided unilaterally downstream — now ruled)

**"Any shell shape needed twice becomes a committed script, called with plain arguments."**
→ **KEEP.** Empirically correct and already independently documented in
`docs/personas/qa-ux-runbook.md` §5. This is the load-bearing rule.

**"Script + allowlist entry = one commit."** → **REWRITE, and demoted from absolute.**
The capability is real but conditional: it applies where the posture is tight, and does
nothing under `Bash(*)`. Critically, an allowlist entry does *not* suppress the analyzer
prompt — only shape does. Codified accurately in `scripts/cto/README.md` rule 2, with the
`$CLAUDE_PROJECT_DIR` correction.

**`README-ops-scripts.md` content** → **REPLACED** by `scripts/cto/README.md`. Adds an
explicit genericity test ("can it run in a repo that knows nothing about your project?"),
a standing warning that find-and-replace genericization is not genericization (with F1 as
the worked example), and a rule against hand-maintained inventories.

**New standing rule, template-team authored:** *a script pushed to this template must have
been executed at least once in a repo that knows nothing about the project it came from.*
F1 would not have survived a single invocation.

---

## Requests routed correctly (from `upstream-review-20260725.md`)

| Request | Ruling | Action |
|---|---|---|
| **P0 — relative hook paths** | **ACCEPTED — fixed** | Confirmed live: three hooks in `settings.devteam.json.template` plus SessionStart hooks in `settings.cto.json.template` and this repo's own `settings.json` were all relative. All now `$CLAUDE_PROJECT_DIR`-anchored. Every repo stamped from the template carries the latent form until re-stamped. |
| **P1 — QA drive must DENY claude-in-chrome** | **ACCEPTED — fixed** | A drive with a second browser MCP available drove the operator's real browser despite an explicit brief. `qa-drive-claude.sh` now writes `permissions.deny: ["mcp__claude-in-chrome"]` into the drive session. Generalized in-comment: launcher-scoped sessions get deny-lists for every tool class their persona forbids. Instruction does not survive contact with tool availability. |
| **`/stack`** | **CULL as a script · KEEP as a convention** | The template cannot ship a project's stack commands (F1 is the proof). What it *can* own is the contract: a repo declares `stack: {up, down, reset, health_url}` in its registry entry and a thin skill shells out to whatever the repo declared. Queued as template-team design work, unstarted. |
| **`/approve-prompt <repo>`** | **REWRITE before building** | Remotely approving a permission dialog the CTO has not read defeats the dialog. If built, it must print the full prompt and require the explicit choice number — never a blind "approve pending". Queued with that constraint binding. |
| **`/verify-at-head <repo> <cmd>`** | **KEEP — accepted as a request** | Generic, and it is the mechanical expression of Success Gating leg (a): worktree add → run at committed HEAD → remove. Highest-value of the three. Queued as template-team work. |

Queued items are **not** started. They are requests on the template team's backlog, and no
downstream session should build them in-session — that is the anti-pattern this review exists
to close.

---

## Execution list

### Done by the template team (this repo, committed with this document)

1. Reverted `e7f7769` and `e3851e7`.
2. Re-landed four scripts, rewritten and tested: `window-peek.sh`, `close-window-id.sh`
   (dry-run default), `watch-file-or-prompt.sh`, `supervise-worker.sh`.
3. Culled `app-stack.sh` entirely.
4. Replaced `README-ops-scripts.md` with `scripts/cto/README.md`.
5. Removed the seven inert allowlist entries; added `_comment_opsScripts` with the correct form.
6. **P0 fixed** in all three settings files.
7. **P1 fixed** in `qa-drive-claude.sh`.
8. Adopted a genericized Success Gating section into `docs/personas/cto.md`.

### For the kgspin-cto session to execute verbatim on receipt

1. **Do not push to this template again.** Route mechanism through
   `docs/template-sync/` as `upstream-review-20260725.md` did. That document is the model.
2. `git pull` this template, then run `scripts/cto/sync-cto-home.sh /path/to/kgspin-cto --apply`
   to take the rewritten scripts, the P0/P1 fixes, and the Success Gating persona section.
3. **Delete** the local forks of `watch-file-or-prompt.sh`, `supervise-worker.sh`,
   `window-peek.sh`, `close-window-id.sh` from `kgspin-cto/scripts/cto/` — the sync supplies
   them. Do not maintain parallel copies.
4. **Keep** `queue-query.sh` and `demo-stack.sh` as project-specific downstream tooling.
   Do not attempt to upstream either.
5. **Fix the allowlist entries** in `kgspin-cto/.claude/settings.json`: delete them if that
   file grants `Bash(*)`; otherwise rewrite `$CTO_HOME` → `$CLAUDE_PROJECT_DIR`. They have
   never matched anything.
6. **Note the behaviour change:** `close-window-id.sh` is now dry-run by default. Add `--yes`.
7. Confirm `archive-when-fast.sh` is defunct; if `restart-worker.sh` is still load-bearing,
   commit it into `kgspin-cto` as project-specific tooling rather than leaving it in a
   scratchpad.

---

## Propagation plan

| Change | Targets | Mechanism |
|---|---|---|
| Rewritten `scripts/cto/*` + `scripts/cto/README.md` | CTO homes only | `sync-cto-home.sh --apply`. Dev-team repos do not orchestrate windows and must not receive these. |
| **P0** hook-path fix (`settings.devteam.json.template`) | **every stamped repo** | `push-to-repos.sh`. Highest-priority propagation here: every repo stamped to date carries the latent form, and it fails at *hook* time, which is silent. |
| **P1** `qa-drive-claude.sh` deny | UX repos + CTO homes | `push-to-repos.sh` / `sync-cto-home.sh`. Safety fix — propagate ahead of the next QA drive. |
| Success Gating in `cto.md` | CTO homes | `sync-cto-home.sh`. |

Not propagated by this session: two dev-team sprints are live in Terminal windows right now
(`kgspin-admin`, `kgspin-demo-app`). Per the instruction, nothing was pushed downstream —
the kgspin-cto session propagates on receipt, when its own fleet is quiet.

---

## Open item for the CEO (not a template-team decision)

**The revert does not remove the leak from public history.** `e3851e7` remains fetchable by
SHA on the public repo and contains `kgspin-demo-app.*server`, `bringup-demo-stack`, and
`surreal`. This is the exact scenario `CLAUDE.md`'s IP-separation section describes.

Assessment: **low severity** — repo names and a database choice, not strategy, PRDs, or
corpora. Recommendation: **accept and leave it.** A history rewrite is destructive, breaks
every existing clone, and buys little here. Raising it because the standing policy is
zero project strings in the public template, and that policy was breached; the call on
whether to enforce it retroactively is the CEO's, not ours.

Minor, unrelated: `docs/personas/concerns/dba.md` uses "SurrealDB 2.3.10" as a fill-in
example. Harmless as template illustration, but it does name the fleet's actual stack.
Flagged, not changed.

— Template team
