---
name: close-window
description: Close the Terminal window hosting a finished Phase 2 dev-team Claude Code session. Use at sprint wind-down after dev-report.md has landed and /sprint-accept has been run. Cleans up tab accumulation from multi-sprint sessions. CTO-autonomous (no claude -p / API — just osascript window close); the JSONL transcript stays on disk regardless, and the safety check refuses to close unless dev-report.md exists (or --force).
allowed-tools: Bash(*) Read
argument-hint: <repo-name> [--force]
---

# Close window for: $ARGUMENTS

Closes the Terminal window for the named repo's Phase 2 session. The underlying claude process exits cleanly; the JSONL transcript at `~/.claude/projects/...` is preserved for later /peek or /resume-dev-team.

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

ARGS="$ARGUMENTS"
REPO_NAME=""
FORCE=0
for tok in $ARGS; do
  case "$tok" in
    --force) FORCE=1 ;;
    --*)     echo "Unknown flag: $tok" >&2 ;;
    *)       [ -z "$REPO_NAME" ] && REPO_NAME="$tok" ;;
  esac
done

if [ -z "$REPO_NAME" ]; then
  echo "Usage: /close-window <repo-name> [--force]"
  echo "  --force   skip the dev-report.md presence check"
  exit 1
fi

# Resolve repo path. Accepts exact name OR suffix alias ("tuner" -> "acme-service-a").
REPO_PATH=$(python3 - <<PYEOF
import re, sys
with open('/Users/apireno/repos/agent-workflow-template/.cto/projects.yaml') as f:
    text = f.read()
arg = "$REPO_NAME"
for b in re.split(r'(?=- name:)', text):
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    if m and m.group(1) == arg and p:
        print(p.group(1)); break
else:
    candidates = []
    for b in re.split(r'(?=- name:)', text):
        m = re.search(r'- name:\s*(\S+)', b)
        p = re.search(r'path:\s*(\S+)', b)
        if not m or not p: continue
        if m.group(1) == f"acme-{arg}" or m.group(1).endswith(f"-{arg}"):
            candidates.append((m.group(1), p.group(1)))
    if len(candidates) == 1: print(candidates[0][1])
    elif len(candidates) > 1: print(f"ERROR: ambiguous alias '{arg}' matches: {[c[0] for c in candidates]}", file=sys.stderr)
PYEOF
)

if [ -z "$REPO_PATH" ]; then
  echo "ERROR: repo '$REPO_NAME' not found in .cto/projects.yaml (tried exact + suffix-alias match)"
  exit 1
fi

WIN_ID_FILE="$REPO_PATH/.claude/terminal-window.id"
if [ ! -f "$WIN_ID_FILE" ]; then
  echo "ERROR: no recorded window id for $REPO_NAME at $WIN_ID_FILE"
  echo "Nothing to close (or window was launched before window-id tracking was in place)."
  exit 1
fi
WIN_ID=$(cat "$WIN_ID_FILE" | tr -d '[:space:]')

# Safety: refuse to close if dev-report.md doesn't exist (sprint not complete) — unless --force
if [ "$FORCE" -ne 1 ]; then
  # NB: no `find | head | grep` pipeline here — under pipefail, head's early exit
  # SIGPIPEs find and fails the pipeline even when a match exists (false REFUSE).
  if [ -z "$(find "$REPO_PATH/docs/sprints" -name 'dev-report.md' -type f -print -quit 2>/dev/null)" ]; then
    echo "REFUSING to close window id $WIN_ID for $REPO_NAME:"
    echo "  no dev-report.md found anywhere under $REPO_PATH/docs/sprints/"
    echo "  this suggests the sprint is still in progress."
    echo ""
    echo "If you really want to close anyway (e.g., aborting a sprint), re-run with --force:"
    echo "  /close-window $REPO_NAME --force"
    exit 1
  fi
fi

echo "Closing Terminal window id $WIN_ID for $REPO_NAME..."
# Close strategy (revised 2026-05-29 — see memory feedback-close-window-terminal-flaky):
#   We do NOT rely on getting claude to exit first. The inner claude TUI
#   intercepts keystrokes, so an `/exit`+Return keystroke often does not reach
#   or submit (same flaky keystroke channel as /send). claude keeps running and
#   `close` then raises macOS's sheet:
#     "Do you want to terminate running processes in this window?  [Cancel] [Terminate]"
#   `saving no` does NOT suppress that sheet (it suppresses the *save* dialog, a
#   different prompt). If left unhandled, the sheet sits there blocking forever.
#   So: fire `close`, then deterministically click the "Terminate" button on the
#   sheet via System Events accessibility — that needs no keystroke into claude.
#   Also: use `(first window whose id is X)` — `window id X` raises -1728.
#
# Requires Accessibility permission for Terminal (System Settings → Privacy &
# Security → Accessibility) — same requirement as /send.
osascript <<APPLESCRIPT 2>&1 | tail -5
tell application "Terminal"
    try
        set targetWin to (first window whose id is $WIN_ID)
        set frontmost of targetWin to true
    end try
end tell

delay 0.3

-- close raises the "terminate running processes?" sheet because claude is running
tell application "Terminal"
    try
        close (first window whose id is $WIN_ID)
    end try
end tell

delay 0.7

-- confirm the terminate sheet if it appeared (deterministic; no keystroke into claude)
tell application "System Events"
    tell process "Terminal"
        set frontmost to true
        repeat with w in windows
            if (exists sheet 1 of w) and (exists button "Terminate" of sheet 1 of w) then
                click button "Terminate" of sheet 1 of w
            end if
        end repeat
    end tell
end tell

-- verify
tell application "Terminal"
    if (id of windows) contains $WIN_ID then
        return "WARNING: window id $WIN_ID still open — retry /close-window or click the red X"
    else
        return "closed window id $WIN_ID (claude terminated)"
    end if
end tell
APPLESCRIPT

# Clear the recorded window id so /send / /close-window don't try to use it again
rm -f "$WIN_ID_FILE"
echo "  cleared $WIN_ID_FILE"

echo "Done. JSONL transcript preserved at ~/.claude/projects/... for /peek + /resume-dev-team."
```

## Your task as CTO

Confirm to the CEO in one line: "Closed window id $WIN_ID for $REPO_NAME. Transcript preserved." If the safety check tripped, explain that dev-report.md wasn't found and offer the --force flag if they really want to abort.

Sign as: — CTO
