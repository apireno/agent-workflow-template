---
name: sprint-verify
description: Objectively verify that each PRD/sprint-plan acceptance criterion was actually delivered as stated — the independent step BETWEEN the QA drive and /sprint-accept. Aggregates test-results + qa-report + demo-output and runs targeted gap-fill checks, marking every criterion MET / NOT-MET / UNVERIFIED with an evidence pointer. Writes conformance.md. Makes NO ship/no-ship decision (that is /sprint-accept). Run AFTER the dev-report + test re-run + QA drive land, BEFORE accepting. Auto-fire when the CEO asks to verify a sprint's deliverables, "did we build what the plan said", or before a sprint accept.
allowed-tools: Bash(*) Read Write
argument-hint: <sprint-dir>
---

# Sprint Verify: $ARGUMENTS

Maps each acceptance criterion to evidence and marks it MET / NOT-MET / UNVERIFIED. **Objective —
produces `conformance.md` (facts), never a ship decision.** Verify is the synthesizer; tests + the
QA drive + the demo are the evidence producers, so it runs AFTER them.

## Inventory evidence + seed the report

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt no_nomatch sh_word_split
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SPRINT_DIR="$ARGUMENTS"
SPRINT_DIR="${SPRINT_DIR%% *}"   # first token (ignore trailing flags)
[ -d "$SPRINT_DIR" ] || { echo "ERROR: sprint dir not found: $SPRINT_DIR"; echo "Usage: /sprint-verify <sprint-dir>"; exit 1; }

# Criteria source: prefer scope.md (VP-Product's acceptance criteria), else sprint-plan.md.
CRIT_SRC=""
for f in scope.md sprint-plan.md; do [ -f "$SPRINT_DIR/$f" ] && { CRIT_SRC="$SPRINT_DIR/$f"; break; }; done
[ -n "$CRIT_SRC" ] || { echo "ERROR: no scope.md or sprint-plan.md in $SPRINT_DIR — nothing to verify against."; exit 1; }
echo "criteria source : $CRIT_SRC"

# Evidence inventory — verify AGGREGATES these; it must run after they exist.
echo "evidence present:"
EV=0
for f in test-results.md qa-report.md demo-output.md flow-graph.json dev-report.md; do
  if [ -f "$SPRINT_DIR/$f" ]; then printf '  [present] %s\n' "$f"; EV=$((EV+1)); else printf '  [absent ] %s\n' "$f"; fi
done

# Ordering guard: verify runs AFTER tests + QA. Warn (don't block) if they're missing or stale,
# so the verifier knows un-covered criteria will land UNVERIFIED rather than MET.
[ -f "$SPRINT_DIR/test-results.md" ] || echo "  WARN: no test-results.md — re-run the suite BEFORE verify (it's the ground-truth of the dev-report's 'tests pass' claim); test-backed criteria will be UNVERIFIED."
if [ -f "$SPRINT_DIR/dev-report.md" ] && [ -f "$SPRINT_DIR/test-results.md" ] && [ "$SPRINT_DIR/dev-report.md" -nt "$SPRINT_DIR/test-results.md" ]; then
  echo "  WARN: test-results.md is OLDER than dev-report.md — may be stale; re-run tests before trusting test-backed rows."
fi
# QA drive only matters if a user-facing surface is in scope.
if grep -qiE 'browser|cli|mcp|ui|surface|qa-plan' "$CRIT_SRC" 2>/dev/null && [ ! -f "$SPRINT_DIR/qa-report.md" ]; then
  echo "  WARN: plan references a user-facing surface but no qa-report.md — run /qa-ux <dir> --mode drive BEFORE verify; UX criteria will be UNVERIFIED."
fi

# Seed conformance.md from the template (don't overwrite an existing one — verify may be re-run).
CONF="$SPRINT_DIR/conformance.md"
if [ ! -f "$CONF" ] && [ -f "$ROOT/docs/sprints/_templates/conformance.md" ]; then
  sed "s/<slug>/$(basename "$SPRINT_DIR")/; s/<short-sha>/$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)/" \
    "$ROOT/docs/sprints/_templates/conformance.md" > "$CONF"
  echo "seeded $CONF from template — fill it in per Your task."
else
  echo "conformance.md $( [ -f "$CONF" ] && echo 'exists — UPDATE it (re-verify), do not blank prior rows' || echo 'template missing — author from the structure in Your task' )"
fi

echo ""
echo "=== ACCEPTANCE CRITERIA (verify each of these) — from $CRIT_SRC ==="
grep -nE 'Acceptance:|Empirical signal:|Success Criteria|Requirement|Acceptance Criteria|HARD' "$CRIT_SRC" 2>/dev/null | head -60
echo ""
echo "NOTE: this is a grep hint only — read $CRIT_SRC IN FULL plus the PRD it cites; criteria may be prose."
```

## Your task as CTO (verifier — objective, no ship decision)

You are doing **objective conformance verification**, not accepting the sprint. Produce facts.

1. **Extract every acceptance criterion** from the criteria source (read it in full + the cited PRD). Include `scope.md` "Acceptance" / "Success Criteria", `sprint-plan.md` acceptance criteria, and `qa-plan.md` HARD signals if present. Each criterion ideally declares an **empirical signal** (a command+expected output, an exact string/`data-testid`/log line, or a named demo observation).

2. **For each criterion, gather evidence — aggregate first, then gap-fill:**
   - Look for the result in the existing artifacts: `test-results.md`, `qa-report.md`, `demo-output.md`, the flow-graph. Cite the specific line/section.
   - If nothing covers it, **run the criterion's empirical signal yourself** (the command / the check) and record the actual result. Use the real CLI/Bash; for browser-only signals that need DOMShell, note that they belong to the QA drive — if the QA drive didn't cover it, mark UNVERIFIED (do not re-drive the browser here).
   - **Do NOT trust the dev-report's prose as evidence.** "The dev-report says it works" is not a MET — find the empirical artifact or run the check. (This is the recurring claims-vs-reality failure this step exists to catch.)

3. **Mark each criterion:**
   - **MET** — concrete evidence shows it delivered as stated (cite it).
   - **NOT-MET** — evidence shows it was not delivered / behaves wrong (cite it).
   - **UNVERIFIED** — no evidence and no runnable signal (e.g. criterion had no empirical signal, or needs a surface no one drove). UNVERIFIED is never assumed MET.

4. **Write `conformance.md`** (template seeded above): the criteria table (criterion → declared signal → status → evidence pointer), the MET/NOT-MET/UNVERIFIED summary, and the plan-quality notes (criteria that arrived with no empirical signal, or whose signal was merely "tests pass" — feedback for VP Product). Sign `— CTO`.

5. **Present a 5-line summary to the CEO:** MET N/total, the NOT-MET list, the UNVERIFIED list, and the one-line recommendation for `/sprint-accept` (e.g. "3 NOT-MET — accept only if you're shipping those as known issues"). **State explicitly that this is verification, not acceptance** — the ship decision is `/sprint-accept`, which may accept with these as documented known-issues.

Sign as: — CTO
