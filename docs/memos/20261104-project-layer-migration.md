# Memo — Moving a project onto the project layer

**To:** every project CTO · **From:** template CTO · **Date:** 2026-11-04 · **Answers:** a fleet CTO's
"template gaps" memo (12 asks) and the CEO's direction: *"give them a more formal way to isolate and
keep project/repo specific items in scope … standing orders to always check your project/repo checklists."*

## 1. The model

| Layer | Lives in | Owned by | Sync |
|---|---|---|---|
| template | everything synced in (`scripts/`, `.claude/skills|hooks|githooks`, personas, `docs/*/_templates`) | template team | copied in on every sync |
| project | `<cto-home>/.cto/project/` | the project CTO | never written by sync |
| repo | `<repo>/.claude/project/` | that repo's lane | never written by `push-to-repos.sh` |

Each project/repo layer holds `standing-orders.md`, `checklists/<moment>.md`, `checks/<moment>/*.sh` and
(project) `settings-overlay.json`; `scripts/agentic/project-layer.sh` runs them at preflight, kickoff,
handoff, landing and accept. Guide: `docs/project-layer/_templates/README.md`.

**The test for where something goes:** would a second, unrelated project need it? Yes → it is a
mechanism request to the template team. No → it goes in your layer.

## 2. Migration, in order (≈ 30–60 min)

1. **Commit the sync** (scoped adds as usual). Then seed: `bash scripts/agentic/project-layer.sh init .cto/project`.
2. **Inventory everything you wired up ad hoc** and move each item:

   | Where it lives today | Moves to |
   |---|---|
   | A section you added to your home's `CLAUDE.md` that states a rule | `standing-orders.md` (one `## SO-…` per rule; why / since / repeated) |
   | A standing rule inside a memo, ruling or ADR | `standing-orders.md`, citing the document |
   | A rule you keep in memory or repeat in conversation | `standing-orders.md` the same day |
   | A domain lint, coverage pre-flight, lexicon check, runner sanity check | `checks/<moment>/<name>.sh` (non-zero exit refuses) |
   | "Remember to … before landing / accepting" | `checklists/landing.md` / `checklists/accept.md` |
   | Project scripts you put in template-owned dirs (`scripts/cto/<yours>.sh`) | a project-owned dir (e.g. `ops/` or `.cto/project/bin/`); sync does not delete them, but they are mixed into mechanism |
   | Tools in a session scratchpad (`/tmp`) | the template now ships: `ci-watch.sh`, `lane-watch.sh`, `merge-when-green.sh`, `qa-send.sh` (waits for an idle keyboard) — delete the scratchpad copies and re-arm Monitors on the template ones |
   | `.cto/settings-overlay.json` | `.cto/project/settings-overlay.json` (old path still read) |
   | Seam kinds your scanner misses | a probe TSV (`kind<TAB>regex[<TAB>glob]`) + `seam_probes: <path>` in each repo's `.claude/derived-artifacts.yaml` |
   | A runner's pre-job lock wait | `ci_hook_max_wait_min: <min>` in each repo's `.claude/land.yaml`; then `ci-lint.sh <repo>` and fix what it names |
   | A per-repo branch limit | `max_live_branches: <n>` in that repo's `.claude/land.yaml` (default 2) |
   | The CEO's time zone | `.cto/timezone` (e.g. `America/New_York`) — `log-line.sh` reads it |

3. **Install the heartbeat** (`docs/ops/_templates/README.md`; `launchctl load` prompts once).
4. **Verify:** `project-layer.sh status` → ok · next session's preflight prints your orders ·
   `branch-census.sh <repo>` under the cap for each repo · `ci-lint.sh <repo>` clean ·
   `cto-heartbeat.sh check --dry-run --quiet-min 0` names your live lanes.

## 3. What the template now enforces (the 12 asks)

| Ask | Shipped |
|---|---|
| Bytes, not inputs | `derived-artifact-gate.sh --bytes` rebuilds, compares, restores; accept + both landing paths pass it; opt-out `bytes_check: off` + `bytes_reason` |
| No generator | NO-GENERATOR / BAD-ENTRY refuse in every mode |
| Graph currency at landing | `land-lane.sh` step `current` and `merge-when-green.sh` refuse a head that is not current or fails a project landing check |
| Scanner blindness | `seam_probes:` → BLIND finding |
| Wiring / statistics sections | plan `**Declares:**` line; `check-dev-report.sh` in `/sprint-accept` |
| Branch hygiene | `branch-census.sh` (squash-merge aware; `--reap`, `--archive-stale`, cap); `/handoff` refuses over the cap; pre-commit refuses a landed branch; pre-push refuses creating a foreign base; lint CHECK I (`cd … && git push`) |
| CI watched, long runs understood | `ci-watch.sh`, `ci-lint.sh`, `docs/ci/_templates/heavy-job.yml`, `merge-when-green.sh` NO RUN ≠ RED |
| Lane liveness + CTO heartbeat | `lane-watch.sh` (WAITING / IDLE / DIALOG), `cto-heartbeat.sh` + launchd template, preflight registers the window |
| No focus theft | `qa-send.sh` waits for ≥ 4 s keyboard/mouse idle, else NOT SENT (exit 8) |
| Times from the clock | `log-line.sh` |
| LLM-stage budgeting | plan `## LLM-Stage Budget`; persona rule |
| Zero graded items | `/sprint-verify`: UNVERIFIED, never MET; the sweep-specific coverage check is a project check |
| Standing reminders | the project layer's `standing-orders.md`, printed every session |

— CTO
