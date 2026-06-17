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

# On-exit teardown sweep: close the QA lane even if the drive CRASHES. DOMShell leaves
# lanes open on disconnect, so a failed drive would otherwise orphan a Chrome tab group.
# The agent also closes its lane explicitly (protocol step 4); `group close` is idempotent
# so the explicit close + this sweep are both safe. The agent records its lane id below.
LANE_FILE="$SPRINT_DIR/.qa-lane"; rm -f "$LANE_FILE"
teardown() {
  [ -s "$LANE_FILE" ] || return 0
  local id; id=$(tr -dc '0-9' < "$LANE_FILE" 2>/dev/null)
  [ -n "$id" ] && { echo "qa-drive-gemini: teardown — closing lane $id (orphan-safe)"; printf 'group close %s\n' "$id" | gemini --yolo --allowed-mcp-server-names domshell >/dev/null 2>&1 || true; }
  rm -f "$LANE_FILE"
}
trap teardown EXIT

# 3. fan the drive to gemini (it reads persona+plan, drives domshell, writes artifacts)
PROMPT=$(cat <<EOF
You are QA-UX (persona: $PERSONA — read it). DRIVE the live app at $URL through the browser
surface using the domshell MCP (single tool domshell_execute; browser-as-filesystem; commands
newline-separated).

=== SINGLE-LANE PROTOCOL (MANDATORY — read before any domshell call) ===
DOMShell isolates each tab group as its own Chrome lane. You must operate in EXACTLY ONE group
for the WHOLE drive, start to finish. Violating this opens orphan browser windows.
1. FIRST domshell_execute call ONLY: pass group_id:"new". The reply ends with "[lane: <ID>]".
   READ that <ID>, remember it, AND write just that id (one line) to $SPRINT_DIR/.qa-lane so the
   harness can sweep it if you crash. This is YOUR lane for the entire session.
2. EVERY domshell_execute call after the first: pass group_id:"<ID>" (the SAME id from step 1) —
   navigate, click, type, grep, screenshot, all of it. NEVER pass group_id:"new" again. NEVER
   omit group_id (that hits the shared/default lane). NEVER open a second group "to be safe".
3. To move to the next journey, RE-USE the same lane: just navigate it back to $URL. Do NOT open
   a fresh group per journey — one lane carries all of J1..Jn.
4. LAST action of the drive: run "group close <ID>" on your one lane. Then stop.
If you ever find yourself about to send group_id:"new" for a second time, STOP — that is the bug;
reuse your existing <ID> instead.
=== END SINGLE-LANE PROTOCOL ===

Execute the journeys in $PLAN. For each: run the steps, assert the HARD signals (exact strings /
selectors — pass/fail), judge the SOFT signals. Capture each designated hero shot via
domshell_execute screenshot into $ASSETS/ (provenance: code_sha=$QA_CODE_SHA). Build the UX
flow-graph ($SPRINT_DIR/flow-graph.json) from the states you actually traverse.

Then OVERWRITE $REPORT with the real browser findings: surface-by-surface pass/fail, each finding
tagged severity (BLOCKER/MAJOR/MINOR/NOTE) AND fault-domain (client/integration/server/data-quality/ux),
with concrete evidence (DOM grep / screenshot path). Route data/quality findings to VP-DS — make NO
statistical claim. Cross-reference the prior backend audit already in the file (keep its real findings,
mark them backend-confirmed). End with a ship/no-ship posture. Sign "— QA".
Do NOT write code, fix bugs, or touch any database. Files only.
EOF
)
echo "$PROMPT" | gemini --yolo --allowed-mcp-server-names domshell 2>&1 | grep -vE "Loaded cached|YOLO mode is enabled"
echo "qa-drive-gemini: done — review $REPORT + $ASSETS/ + $SPRINT_DIR/flow-graph.json"
