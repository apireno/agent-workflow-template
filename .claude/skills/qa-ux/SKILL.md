---
name: qa-ux
description: Drive the live product as a skeptical end-user across browser (DOMShell MCP), CLI, and MCP surfaces, then produce a defect report + a derived UX flow-graph + provenance-stamped hero assets. Two modes — `--mode plan` authors qa-plan.md at sprint-planning time (HARD vs SOFT assertions, hero shots, in-scope surfaces); `--mode drive` (default) is the accept-time gate that exercises the running app against qa-plan.md before /sprint-accept. Use when a user-facing sprint needs UX/output-quality verification, or to author a QA test plan up front. Implements docs/personas/qa-ux.md.
allowed-tools: Bash(*) Read Write
argument-hint: <sprint-dir> [--mode plan|drive] [--surfaces browser,cli,mcp] [--url <app-url>] [--engine gemini|claude]
---

# QA-UX: $ARGUMENTS

Runs the QA-UX persona (`docs/personas/qa-ux.md`) against a sprint. **plan** mode authors the
test plan before code; **drive** mode is the accept-time gate that drives the live app.

## Setup + standup

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || { echo "ERROR: not in a repo"; exit 1; }

ARGS="$ARGUMENTS"
SPRINT_DIR=""; MODE="drive"; SURFACES=""; URL=""; ENGINE="gemini"
for tok in $ARGS; do
  case "$tok" in
    --mode=*)     MODE="${tok#--mode=}" ;;
    --surfaces=*) SURFACES="${tok#--surfaces=}" ;;
    --url=*)      URL="${tok#--url=}" ;;
    --engine=*)   ENGINE="${tok#--engine=}" ;;
    --*)          echo "Unknown flag: $tok" >&2 ;;
    *)            [ -z "$SPRINT_DIR" ] && SPRINT_DIR="$tok" ;;
  esac
done

if [ -z "$SPRINT_DIR" ]; then
  echo "Usage: /qa-ux <sprint-dir> [--mode plan|drive] [--surfaces browser,cli,mcp] [--url <app-url>] [--engine gemini|claude]"
  exit 1
fi
[ -d "$SPRINT_DIR" ] || { echo "ERROR: sprint dir not found: $SPRINT_DIR"; exit 1; }

PERSONA="$ROOT/docs/personas/qa-ux.md"
QA_PLAN="$SPRINT_DIR/qa-plan.md"
QA_REPORT="$SPRINT_DIR/qa-report.md"
ASSETS="$SPRINT_DIR/assets"
[ -f "$PERSONA" ] || echo "WARN: persona not found at $PERSONA (sync it from the template)"

echo "persona   : $PERSONA"
echo "sprint    : $SPRINT_DIR"
echo "mode      : $MODE"
echo "surfaces  : ${SURFACES:-<read from qa-plan / auto>}"
echo "engine    : $ENGINE   (bright-line: gemini-CLI or interactive Claude — NEVER claude -p)"
echo ""

if [ "$MODE" = "plan" ]; then
  if [ ! -f "$QA_PLAN" ] && [ -f "$ROOT/docs/sprints/_templates/qa-plan.md" ]; then
    cp "$ROOT/docs/sprints/_templates/qa-plan.md" "$QA_PLAN"
    echo "seeded $QA_PLAN from template — author it (HARD/SOFT assertions, surfaces, hero shots)."
  else
    echo "qa-plan : ${QA_PLAN} ($( [ -f "$QA_PLAN" ] && echo exists || echo MISSING template ))"
  fi
  echo "PLAN MODE — author/refine the qa-plan; no live driving."
  exit 0
fi

# ---- drive mode: standup guard before any driving ----
[ -f "$QA_PLAN" ] || { echo "ERROR: $QA_PLAN missing — run '/qa-ux $SPRINT_DIR --mode plan' first (shift-left: the plan precedes the drive)."; exit 1; }
mkdir -p "$ASSETS"

if [ -x "$ROOT/scripts/agentic/qa-standup.sh" ]; then
  "$ROOT/scripts/agentic/qa-standup.sh" --url "$URL" --sprint-dir "$SPRINT_DIR" || { echo "STANDUP FAILED — aborting drive (target unreachable / prod-guard tripped / DOMShell session absent)."; exit 1; }
else
  echo "WARN: scripts/agentic/qa-standup.sh missing — cannot verify standup/prod-guard. Proceed only on a known non-prod target."
fi
echo ""
echo "DRIVE MODE — standup OK. Provenance: CODE_SHA=${QA_CODE_SHA:-<unset>} APP_VERSION=${QA_APP_VERSION:-<unset>}"
echo "Artifacts to produce: $QA_REPORT , $SPRINT_DIR/flow-graph.json(+.md) , $ASSETS/"
```

## Your task as QA-UX

**Adopt the persona:** read `docs/personas/qa-ux.md` in full and operate as **QA-UX** (review/adversarial; you drive and report, you never fix). Then execute the selected mode.

### If `--mode plan`
Author/refine `qa-plan.md` (template seeded above):
1. Declare the **in-scope surfaces** (browser / CLI / MCP) this sprint exposes.
2. For each journey, write the acceptance signals split into **HARD** (exact string/pattern/`data-testid`/selector — deterministic, will graduate to `tests/e2e/`) and **SOFT** (semantic judgment).
3. Name the **hero shots** (critical delivered features to capture) and the **fault-domain routing** expectations.
4. Link each journey back to the PRD requirement / RICE it verifies.
Stop after writing the plan — no live driving. Sign `— QA`.

### If `--mode drive` (accept-time gate)
1. **Drive each in-scope surface** against `qa-plan.md`:
   - **browser** → DOMShell MCP (`domshell_execute`): `ls`/`cd`/`cat`/`text`/`grep`/`extract_table` to assert HARD signals; judge SOFT signals; `screenshot` each hero feature.
   - **CLI** → Bash: invoke the real CLI, capture stdout/stderr + exit codes, assert HARD, judge SOFT.
   - **MCP** → call the repo's own MCP server as an agent would; check tool-description fidelity, round-trips/token cost, error recovery.
2. **Build the UX flow-graph** as a byproduct (`$SPRINT_DIR/flow-graph.json` + Mermaid `flow-graph.md`): nodes = UI states (route + HARD landmarks, transient DOM stripped), edges = actions (+ the API calls they fire + any defect). `diff` against the prior sprint's if present.
3. **Tag every finding** by severity (`BLOCKER/MAJOR/MINOR/NOTE`) AND fault-domain (`client/integration/server/data-quality/ux/unverified`), each with concrete evidence. Route `data/quality` to VP-DS — do NOT make statistical claims.
4. **Redact before persisting:** run every transcript / report / captured log through `scripts/agentic/qa-redact.sh --in-place <file>` BEFORE it lands in `assets/`. Screenshots rely on UI-level masking at capture. No credential/token/PII leaves the QA lane.
5. **Write `qa-report.md`** (template: `docs/sprints/_templates/qa-report.md`): surface-by-surface pass/fail, findings, flow-graph diff summary, hero-asset index, and a recommended **ship / no-ship** posture.

### Then, as CTO
Summarize for the CEO: surfaces driven, BLOCKER/MAJOR counts by fault-domain, hero assets captured, flow-graph delta, and the ship/no-ship recommendation. **Gate semantics:** the report must exist and be reviewed before `/sprint-accept`; shipping with known defects is a CTO/CEO call, documented in the `cto-decision`. Sign `— CTO`.
