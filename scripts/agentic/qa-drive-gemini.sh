#!/usr/bin/env bash
# qa-drive-gemini.sh — CTO-orchestrated QA-UX browser drive via gemini-CLI ($0, no osascript).
#
# This is the SELF-ORCHESTRATING engine the /qa-ux skill's drive mode is missing: instead of
# assuming you opened an interactive MCP-enabled session, it (1) ensures DOMShell is registered
# for *gemini* (the proxy form + token, --trust), (2) runs the standup guard, then (3) fans the
# QA-UX persona + qa-plan to `gemini --yolo --allowed-mcp-server-names domshell`, which drives the
# live browser via domshell_execute and writes the artifacts. Bright-line clean: gemini, never claude -p.
#
# Usage: qa-drive-gemini.sh <sprint-dir> --url <non-prod-url>
# Prereqs: DOMShell server running (Docker/ToolHive/native) + Chrome extension connected;
#          DOMSHELL_TOKEN resolvable (env, or the running proxy's --token arg).

set -uo pipefail
SPRINT_DIR=""; URL=""
while [ $# -gt 0 ]; do case "$1" in
  --url) URL="${2:-}"; shift 2 ;;
  *) [ -z "$SPRINT_DIR" ] && SPRINT_DIR="$1"; shift ;;
esac; done
[ -d "$SPRINT_DIR" ] || { echo "ERROR: sprint dir not found: $SPRINT_DIR"; exit 1; }
ROOT="$(git -C "$SPRINT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAN="$SPRINT_DIR/qa-plan.md"; REPORT="$SPRINT_DIR/qa-report.md"; ASSETS="$SPRINT_DIR/assets"
PERSONA="$ROOT/docs/personas/qa-ux.md"
[ -f "$PLAN" ] || { echo "ERROR: $PLAN missing — run '/qa-ux $SPRINT_DIR --mode plan' first."; exit 1; }
mkdir -p "$ASSETS"
command -v gemini >/dev/null || { echo "ERROR: gemini-CLI not found (bright-line: gemini or interactive claude, never claude -p)."; exit 1; }

# 1. standup guard (prod-guard + reachability + provenance)
if [ -x "$ROOT/scripts/agentic/qa-standup.sh" ]; then
  "$ROOT/scripts/agentic/qa-standup.sh" --url "$URL" --sprint-dir "$SPRINT_DIR" --surfaces cli >/dev/null 2>&1 || true
fi
[ -n "$URL" ] && { code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null); [ "$code" = "000" ] && { echo "ERROR: target $URL unreachable"; exit 1; }; }

# 2. ensure DOMShell registered for GEMINI (proxy form + token, --trust). Token: env, else the running proxy's arg.
TOK="${DOMSHELL_TOKEN:-}"
[ -z "$TOK" ] && TOK=$(ps -axo command 2>/dev/null | grep -oE 'domshell-proxy --port 3001 --token [a-f0-9]{40,}' | head -1 | grep -oE '[a-f0-9]{40,}')
[ -z "$TOK" ] && { echo "ERROR: DOMSHELL_TOKEN not resolvable (export it, or start the DOMShell proxy)."; exit 1; }
# Idempotent register. NOTE: do NOT gate on `gemini mcp list` — it re-spawns+reconnects every
# server per call, so its status is slow/non-deterministic (observed: 3 rapid calls dropped the
# domshell line entirely while a standalone call showed Connected). gemini connects at drive-time.
gemini mcp add --scope user --trust domshell npx -- -y -p @apireno/domshell domshell-proxy --port 3001 --token "$TOK" >/dev/null 2>&1 || true
echo "qa-drive-gemini: domshell registered for gemini (--trust); connection verified at drive-time, not via the flaky 'mcp list'."

export QA_CODE_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "qa-drive-gemini: domshell Connected · target $URL · code_sha $QA_CODE_SHA · driving via gemini --yolo"

# PROVENANCE-based cleanup (NO server GC). The drive names its group by a hard convention and
# records EVERY lane id it mints; on ANY exit (success / crash / timeout / kill / 403) the trap
# closes exactly those ids — never a guessed "garbage" group, never the user's tabs. group close
# is group-scoped + idempotent, so this + the agent's own close + the invoker's post-round sweep
# are all safe. DOMShell @apireno/domshell 2.0.5 contract: group_id:"new" + initial_url + group_name
# in ONE call. (Chrome titles the group with group_name on extension >=1.3.2; the lane id is the
# load-bearing handle today — the sweep matches ids, the name is the forward-compat bonus.)
GROUP_NAME="qa-ux-$(basename "$ROOT")-$(basename "$SPRINT_DIR")"
LANE_FILE="$SPRINT_DIR/.qa-lanes"; : > "$LANE_FILE"
teardown() {
  if [ -s "$LANE_FILE" ]; then
    while IFS= read -r id; do
      id=$(printf '%s' "$id" | tr -dc '0-9'); [ -n "$id" ] || continue
      echo "qa-drive-gemini: teardown — closing lane $id"
      printf 'group close %s\n' "$id" | gemini --yolo --allowed-mcp-server-names domshell >/dev/null 2>&1 || true
    done < "$LANE_FILE"
    rm -f "$LANE_FILE"
  fi
  # Reap the registration so per-connection proxies don't accumulate across drives.
  gemini mcp remove domshell >/dev/null 2>&1 || true
}
trap teardown EXIT INT TERM

# 3. fan the drive to gemini (it reads persona+plan, drives domshell, writes artifacts)
PROMPT=$(cat <<EOF
You are QA-UX (persona: $PERSONA — read it). DRIVE the live app at $URL through the browser
surface using the domshell MCP (single tool domshell_execute; browser-as-filesystem; commands
newline-separated).

=== SINGLE-LANE PROTOCOL (MANDATORY — read before any domshell call) ===
DOMShell drives the real Chrome; isolation is by GROUP (a lane). group close <id> is group-scoped
— it closes only the tabs in that lane, never any other tabs. You operate in EXACTLY ONE named
group for the WHOLE drive.
1. FIRST domshell_execute call ONLY — mint + name + navigate in ONE call:
     { "command": "text main", "group_id": "new", "initial_url": "$URL", "group_name": "$GROUP_NAME" }
   This opens \$URL at creation (no separate nav to fail) and tags the group. The reply ends with
   "[lane: <ID>]". READ that <ID>, remember it, AND append just that id (one line) to
   $SPRINT_DIR/.qa-lanes so the harness/invoker can sweep it if you crash. This is YOUR lane.
2. EVERY later call: pass group_id:"<ID>" (the SAME id) — navigate (open <url>), click, grep,
   screenshot, all of it. Call group_id:"new" EXACTLY ONCE per drive — NEVER again. NEVER omit
   group_id. If a navigation is REJECTED, RETRY WITH THE SAME <ID> and the correct verb
   (use "open <url>", not "cd <url>") — do NOT re-mint a new group (re-minting is the leak bug).
3. Next journey: reuse the same lane — "open <url>" it back to $URL. One lane carries all of J1..Jn.
4. LAST action of the drive: run "group close <ID>". Then stop.
If you are ever about to send group_id:"new" a second time, STOP — that is the bug; reuse your <ID>.
=== END SINGLE-LANE PROTOCOL ===

Execute the journeys in $PLAN. For each: run the steps, assert the HARD signals (exact strings /
selectors — pass/fail), judge the SOFT signals.

CRITICAL — WAIT FOR ASYNC STATES BEFORE ASSERTING. Never assert on a mid-flight DOM. After any
action that triggers loading (search, navigate, fetch), WAIT for the loading/searching indicator
to disappear and the result region to settle (poll the DOM, or use a wait) BEFORE you read/assert.
A still-loading panel is NOT an empty panel; "0 results" mid-fetch is NOT "search is broken". If
unsure whether a state settled, wait and re-read rather than file a defect.

Capture each designated hero shot via domshell_execute screenshot into $ASSETS/ (provenance:
code_sha=$QA_CODE_SHA). Only report a hero shot as captured if the file ACTUALLY EXISTS (verify
with ls $ASSETS/) — never claim a phantom asset. Build the UX flow-graph
($SPRINT_DIR/flow-graph.json) from the states you actually traverse.

Then UPDATE $REPORT — do NOT blindly overwrite it. First READ the existing $REPORT and PRESERVE its
prior backend/data audit findings verbatim (mark them "backend-confirmed"); only ADD or correct the
BROWSER findings from this drive. Losing the prior audit is a regression. Each finding: severity
(BLOCKER/MAJOR/MINOR/NOTE) AND fault-domain (client/integration/server/data-quality/ux), with concrete
evidence (DOM grep / screenshot path). Route data/quality findings to VP-DS — make NO statistical
claim. End with a ship/no-ship posture. Sign "— QA".

Do NOT write code, fix bugs, or touch any database. Files only. Before you finish, VERIFY your work
landed: $REPORT was actually written and the claimed hero-shot files exist in $ASSETS/. Do not report
success for artifacts that were not actually produced.
EOF
)
echo "$PROMPT" | gemini --yolo --allowed-mcp-server-names domshell 2>&1 | grep -vE "Loaded cached|YOLO mode is enabled"
echo "qa-drive-gemini: done — review $REPORT + $ASSETS/ + $SPRINT_DIR/flow-graph.json"
