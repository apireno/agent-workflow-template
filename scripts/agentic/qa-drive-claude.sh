#!/usr/bin/env bash
# qa-drive-claude.sh — the QA-UX browser drive (now the DEFAULT + ONLY engine).
#
# Launches an INTERACTIVE Claude session (subscription pool — never `claude -p`) in the UX
# repo to run the drive, reusing /handoff's machinery so the CTO NEVER hand-edits .claude/:
#   * the drive brief is a HANDOVER DOC in docs/  (briefs live in docs/, never .claude/);
#   * the skill writes the one-shot .claude/pending-prompt.md ITSELF (the SessionStart
#     auto-paste hook injects it as additionalContext — no positional prompt, no manual CR);
#   * the workspace + domshell MCP + tool/skill PERMISSIONS are pre-seeded so nothing prompts;
#   * the launched window id is RECORDED and a kickoff ("go") is AUTO-SENT — zero-touch.
#
# The former gemini engine (qa-drive-gemini.sh) is DEAD as of 2026-06-19: Google deprecated
# the gemini-CLI free tier (IneligibleTierError / UNSUPPORTED_CLIENT — migrate to Antigravity).
# This Claude engine is therefore the sole drive path. Bright-line preserved: this is an
# INTERACTIVE Claude session (subscription pool), NOT `claude -p`.
#
# Usage: qa-drive-claude.sh <sprint-dir> --url <non-prod-url> [--handover <path>]
#   --handover <path> : drive from an existing brief/handover doc. Default: synthesize
#                       docs/sprints/<sprint>/qa-drive-brief.md from the persona + qa-plan.
#
# ZERO-TOUCH: launch -> record window id -> auto-send "go" kickoff (the SessionStart hook's
# additionalContext needs a real user message to start; "go" is that message, sent for you).
# If auto-kickoff can't reach the tab (Accessibility perm not granted), the printed fallback
# tells the operator to type `go` + Enter once — a BARE Enter on an empty box submits nothing.

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
GROUP_NAME="qa-ux-$(basename "$ROOT")-$(basename "$SPRINT_DIR")"
if [ -z "$HANDOVER" ]; then
  {
    echo "# QA-UX browser-drive brief — $(basename "$SPRINT_DIR")"; echo
    echo "**YOU ARE ALREADY INSIDE THE DRIVE SESSION.** This session IS the QA-UX browser drive."
    echo "Adopt the QA-UX persona (\`$PERSONA\`) and drive the browser by calling the registered"
    echo "**\`domshell_execute\` tool DIRECTLY**. Do NOT invoke the \`/qa-ux\` skill, do NOT spawn another"
    echo "session, do NOT run any qa-drive script — that would recurse. Just call \`domshell_execute\`."
    echo "If \`domshell_execute\` is NOT in your tool list, the session wasn't restarted after standup"
    echo "registered the MCP; STOP and tell the CTO to restart this session — do not substitute API/DB"
    echo "inspection for a browser drive."
    echo
    echo "## Canonical FIRST call (one shot: mint + name + navigate + read)"
    echo '```'
    echo "domshell_execute(command=\"ls\", group_id=\"new\", group_name=\"$GROUP_NAME\", initial_url=\"$URL\")"
    echo '```'
    echo "- Capture the trailing \`[lane: <id>]\` from the reply. Append that id (one line) to \`$SPRINT_DIR/.qa-lanes\`."
    echo "- Pass \`group_id=\"<id>\"\` (the SAME id) on EVERY later call. Call \`group_id:\"new\"\` EXACTLY ONCE per drive."
    echo "- On a failed navigation, RETRY WITH THE SAME id and the \`open <url>\` verb (never \`cd <url>\`, never re-mint)."
    echo "- LAST action: \`domshell_execute(command=\"group close\", group_id=\"<id>\")\`."
    echo "- SAFETY: NEVER pass \`group_id:\"shared\"\` or omit \`group_id\` for any write (open/click/type/"
    echo "  select/submit/js/key). Per DOMShell #53 (ext >=1.3.2) those operate on the user's REAL browser,"
    echo "  not an isolated lane. Drive ONLY in your named \`$GROUP_NAME\` lane; \`shared\` is read-only-list only."
    echo "- NOTE: on older extensions a generic \`agent\` connection-lane may also appear; ignore it — your"
    echo "  named lane is the one you close. (Post-#53 that default lane is no longer created.)"
    echo
    echo "## The drive"
    echo "- WAIT for async/loading states to settle before asserting — never a mid-flight DOM (a still-loading panel is not empty)."
    echo "- Execute \`$PLAN\`; assert HARD signals (exact strings/selectors), judge SOFT signals."
    echo "- UPDATE (do not overwrite) \`$SPRINT_DIR/qa-report.md\`, preserving any prior backend audit verbatim."
    echo "- Capture hero shots to \`$SPRINT_DIR/assets/\` and verify each file exists; build \`$SPRINT_DIR/flow-graph.json\`."
    echo "- Files only, no database. Redact via \`scripts/agentic/qa-redact.sh\` before persisting. Sign \"— QA\"."
  } > "$BRIEF"
  echo "qa-drive-claude: wrote handover brief -> $BRIEF (docs/, not .claude/)"
else
  [ -f "$BRIEF" ] || { echo "ERROR: --handover doc not found: $BRIEF"; exit 1; }
  echo "qa-drive-claude: using handover brief -> $BRIEF"
fi

# 3. SKILL-owned one-shot pending-prompt.md (the SessionStart hook auto-pastes it). The skill
#    writes this — the CTO never touches .claude/. It points the new session at the docs brief
#    and makes explicit that THIS session is the drive (BUG-5: never re-invoke the /qa-ux skill).
mkdir -p "$ROOT/.claude"
printf 'Read %s in full and execute it NOW as QA-UX. You ARE the drive session: drive the browser by calling the registered domshell_execute tool DIRECTLY. Do NOT invoke the /qa-ux skill or spawn another session (that recurses). You are pre-approved; do not ask for permission.\n' "$BRIEF" > "$ROOT/.claude/pending-prompt.md"

# 4. pre-AUTHORIZE the launched session fully so NOTHING prompts: (a) trust + enable the
#    domshell MCP in ~/.claude.json, and (b) seed the repo's .claude/settings.json
#    permissions.allow with exactly what the drive needs — the domshell tool + the Bash
#    patterns it runs. Deliberately do NOT allow the qa-ux Skill: the drive must call
#    domshell_execute directly, and allowing the skill would let it recurse (BUG-5).
python3 - "$ROOT" <<'PY' 2>/dev/null || echo "qa-drive-claude: WARN could not pre-authorize (first run may prompt on trust/permission)"
import json, sys
from pathlib import Path
root = sys.argv[1]
# (a) ~/.claude.json — workspace trust + MCP enablement
cj = Path.home()/'.claude.json'
if cj.exists():
    d = json.loads(cj.read_text())
    proj = d.setdefault('projects', {}).setdefault(root, {})
    proj['hasTrustDialogAccepted'] = True
    proj['enableAllProjectMcpServers'] = True
    en = proj.setdefault('enabledMcpjsonServers', [])
    if 'domshell' not in en: en.append('domshell')
    cj.write_text(json.dumps(d, indent=2))
# (b) <repo>/.claude/settings.json — tool/skill permissions for the drive (NOT the qa-ux skill)
sp = Path(root)/'.claude'/'settings.json'
s = {}
if sp.exists():
    try: s = json.loads(sp.read_text())
    except Exception: s = {}
perms = s.setdefault('permissions', {})
allow = perms.setdefault('allow', [])
needed = [
    'mcp__domshell',                         # whole-server allow (covers domshell_execute)
    'mcp__domshell__domshell_execute',       # explicit tool allow
    'Read', 'Write',                         # writes qa-report / flow-graph / .qa-lanes
    'Bash(scripts/agentic/qa-redact.sh:*)',  # redaction before persisting
    'Bash(ls:*)', 'Bash(cat:*)', 'Bash(mkdir:*)',
]
for n in needed:
    if n not in allow: allow.append(n)
# DENY every OTHER browser driver. A drive session with a second browser MCP available
# has driven the operator's REAL browser despite a brief naming domshell_execute
# explicitly: instruction does not survive contact with tool availability. The wrong
# engine must be mechanically uncallable, not merely discouraged.
# Generalizes: a launcher-scoped session gets a deny-list for every tool class its
# persona forbids — QA-UX drives an isolated lane, never the human's browser.
deny = perms.setdefault('deny', [])
for n in ['mcp__claude-in-chrome']:
    if n not in deny: deny.append(n)
s.setdefault('enableAllProjectMcpServers', True)
# Anchor any repo-relative hook command already wired in this repo. A drive session
# launched into a repo stamped before the hook-path fix hits
#   "Stop hook error: .claude/hooks/check-complete.sh: No such file or directory"
# because hooks run from an arbitrary cwd. It fails silently (a broken Stop hook just
# logs), so the drive looks fine while its completion signal never fires.
for _ev, _groups in (s.get('hooks') or {}).items():
    if not isinstance(_groups, list): continue          # skip _comment_* string entries
    for _g in _groups:
        for _h in _g.get('hooks', []):
            _c = _h.get('command', '')
            if _c.startswith('.claude/') or _c.startswith('scripts/'):
                _h['command'] = '$CLAUDE_PROJECT_DIR/' + _c
sp.parent.mkdir(parents=True, exist_ok=True)
sp.write_text(json.dumps(s, indent=2))
print("qa-drive-claude: pre-authorized — trust + domshell MCP + drive permissions (qa-ux skill intentionally NOT allowed)")
PY

# 5. launch interactive claude in the UX repo (subscription pool; never claude -p) and
#    RECORD the window id (mirrors /handoff: the trailing bare `newTab` keeps
#    "tab N of window id NNNN" as the last osascript line so the parse below works).
echo "qa-drive-claude: launching interactive claude in $ROOT ..."
TAB_INFO=$(osascript 2>&1 <<APPLESCRIPT | tail -1
tell application "Terminal"
  activate
  set newTab to do script "cd $ROOT && export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 && claude"
  set custom title of newTab to "qa-ux · $(basename "$SPRINT_DIR")"
  newTab
end tell
APPLESCRIPT
)
echo "  $TAB_INFO"
WIN_ID=$(printf '%s' "$TAB_INFO" | grep -oE 'window id [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$WIN_ID" ]; then
  echo "$WIN_ID" > "$ROOT/.claude/terminal-window.id"
  echo "qa-drive-claude: recorded window id $WIN_ID -> $ROOT/.claude/terminal-window.id (for qa-send/peek/close)"
else
  echo "qa-drive-claude: WARN could not parse window id — auto-kickoff + qa-send unavailable; type 'go' + Enter in the tab yourself."
fi

# 6. AUTO-KICKOFF: the SessionStart hook injects the brief as additionalContext, which does
#    NOT start Claude — it needs a real user message. Send "go" for the operator (qa-send.sh
#    keystroke-injects from a file so the osascript braces never trip the obfuscation prompt).
#    A short settle lets the session reach its prompt before the keystroke lands.
QA_SEND="$ROOT/scripts/cto/qa-send.sh"
if [ -n "$WIN_ID" ] && [ -x "$QA_SEND" ]; then
  KICK=$(mktemp -t qa-kickoff); printf 'go' > "$KICK"
  # settle ~12s for claude to boot to its input prompt, then inject the kickoff.
  ( i=0; while [ $i -lt 12 ]; do sleep 1; i=$((i+1)); done; "$QA_SEND" "$WIN_ID" "$KICK" >/dev/null 2>&1; rm -f "$KICK" ) &
  echo "qa-drive-claude: auto-kickoff scheduled (sends 'go' to window $WIN_ID after a ~12s settle)."
  echo "  If the drive doesn't start (Accessibility perm not granted for Terminal), type 'go' + Enter in the tab."
else
  echo "qa-drive-claude: >>> type 'go' then Enter ONCE in the new tab to start (a BARE Enter submits nothing). <<<"
fi
echo ""
echo "qa-drive-claude: drive launching. It calls domshell_execute DIRECTLY and writes"
echo "  $SPRINT_DIR/qa-report.md + assets/ + flow-graph.json. Monitor with: /peek $(basename "$ROOT")"
