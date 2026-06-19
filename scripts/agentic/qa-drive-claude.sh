#!/usr/bin/env bash
# qa-drive-claude.sh — the `--engine claude` QA-UX browser drive.
#
# Launches an INTERACTIVE Claude session (subscription pool — never `claude -p`) in the UX
# repo to run the drive, reusing /handoff's machinery so the CTO NEVER hand-edits .claude/
# or scripts keystrokes:
#   * the drive brief is a HANDOVER DOC in docs/  (briefs live in docs/, never .claude/);
#   * the skill writes the one-shot .claude/pending-prompt.md ITSELF (the SessionStart
#     auto-paste hook injects it as additionalContext — no positional prompt, no manual CR);
#   * the workspace + domshell MCP are pre-trusted so no startup prompt blocks input.
#
# gemini (qa-drive-gemini.sh) is the PROVEN $0 default and avoids the one limitation below —
# prefer it unless you specifically need the Claude engine.
#
# Usage: qa-drive-claude.sh <sprint-dir> --url <non-prod-url> [--handover <path>]
#   --handover <path> : drive from an existing brief/handover doc. Default: synthesize
#                       docs/sprints/<sprint>/qa-drive-brief.md from the persona + qa-plan.
#
# KNOWN CLAUDE-CODE LIMITATION: a launched interactive session shows the brief but does not
# auto-SUBMIT (positional prompt pre-fills without CR; additionalContext needs a user message).
# The operator presses Enter ONCE in the new tab to start. No .claude/ hand-editing, no
# keystroke scripting, no touching the protected folder. gemini has no such step.

set -uo pipefail
SPRINT_DIR=""; URL=""; HANDOVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --handover) HANDOVER="${2:-}"; shift 2 ;;
    --handover=*) HANDOVER="${1#--handover=}"; shift ;;
    *) [ -z "$SPRINT_DIR" ] && SPRINT_DIR="$1"; shift ;;
  esac
done
[ -d "$SPRINT_DIR" ] || { echo "ERROR: sprint dir not found: $SPRINT_DIR"; exit 1; }
ROOT="$(git -C "$SPRINT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAN="$SPRINT_DIR/qa-plan.md"; PERSONA="$ROOT/docs/personas/qa-ux.md"
[ -f "$PLAN" ] || { echo "ERROR: $PLAN missing — run '/qa-ux $SPRINT_DIR --mode plan' first."; exit 1; }

# 1. standup: provisions the domshell PROXY entry into the UX repo's .mcp.json + token guard.
"$ROOT/scripts/agentic/qa-standup.sh" --url "$URL" --sprint-dir "$SPRINT_DIR" --surfaces browser || { echo "qa-drive-claude: standup failed — aborting."; exit 1; }

# 2. HANDOVER DOC in docs/ (never .claude/). Default: synthesize from persona + qa-plan.
BRIEF="${HANDOVER:-$SPRINT_DIR/qa-drive-brief.md}"
if [ -z "$HANDOVER" ]; then
  {
    echo "# QA-UX browser-drive brief — $(basename "$SPRINT_DIR")"; echo
    echo "Adopt the QA-UX persona (\`$PERSONA\`). DRIVE the browser surface at $URL via the domshell MCP."
    echo "- ONE NAMED LANE: first domshell call passes group_id:\"new\" + initial_url + group_name=qa-ux-<repo>-<sprint> (DOMShell 2.0.5); capture the [lane: id], reuse it EVERY call (group_id:new exactly once — never re-mint on a failed nav; use open not cd); group close it at the end. Record minted ids to <sprint-dir>/.qa-lanes."
    echo "- WAIT for async/loading states to settle before asserting — never a mid-flight DOM (a still-loading panel is not empty)."
    echo "- Execute \`$PLAN\`; UPDATE (do not overwrite) \`$SPRINT_DIR/qa-report.md\`, preserving the prior backend audit."
    echo "- Capture hero shots to \`$SPRINT_DIR/assets/\` and verify each file exists; build \`$SPRINT_DIR/flow-graph.json\`."
    echo "- Files only, no database. Redact via qa-redact.sh before persisting. Sign \"— QA\"."
  } > "$BRIEF"
  echo "qa-drive-claude: wrote handover brief -> $BRIEF (docs/, not .claude/)"
else
  [ -f "$BRIEF" ] || { echo "ERROR: --handover doc not found: $BRIEF"; exit 1; }
  echo "qa-drive-claude: using handover brief -> $BRIEF"
fi

# 3. SKILL-owned one-shot pending-prompt.md (the SessionStart hook auto-pastes it). The skill
#    writes this — the CTO never touches .claude/. It points the new session at the docs brief.
mkdir -p "$ROOT/.claude"
printf 'Read %s in full and execute it now as QA-UX. You are pre-approved; do not ask for permission.\n' "$BRIEF" > "$ROOT/.claude/pending-prompt.md"

# 4. pre-trust the workspace (+ domshell MCP) so no startup prompt blocks input.
python3 - "$ROOT" <<'PY' 2>/dev/null || echo "qa-drive-claude: WARN could not pre-trust ~/.claude.json (first run may show a trust prompt)"
import json, sys
from pathlib import Path
root = sys.argv[1]; cj = Path.home()/'.claude.json'
if cj.exists():
    d = json.loads(cj.read_text())
    proj = d.setdefault('projects', {}).setdefault(root, {})
    proj['hasTrustDialogAccepted'] = True
    en = proj.setdefault('enabledMcpjsonServers', [])
    if 'domshell' not in en: en.append('domshell')
    cj.write_text(json.dumps(d, indent=2)); print("qa-drive-claude: pre-trusted workspace + domshell MCP")
PY

# 5. launch interactive claude in the UX repo (subscription pool; never claude -p).
echo "qa-drive-claude: launching interactive claude in $ROOT ..."
osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "  (osascript unavailable — open a terminal yourself: cd $ROOT && claude)"
tell application "Terminal"
  activate
  do script "cd $ROOT && claude"
end tell
APPLESCRIPT
echo ""
echo "qa-drive-claude: tab launched. The brief auto-pastes via the SessionStart hook —"
echo "  >>> PRESS ENTER ONCE in the new tab to start the drive. <<<  (Claude-Code limitation; gemini avoids it.)"
echo "  Then it drives the browser and writes $SPRINT_DIR/qa-report.md + assets/ + flow-graph.json."
