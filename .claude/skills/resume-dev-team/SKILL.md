---
name: resume-dev-team
description: Recover a crashed per-repo Phase 2 session by reading its current-session.id and spawning a new Terminal tab running `claude --resume <session-id>`. Use when /sprint-status shows CRASHED for a repo or the CEO notices a dead session.
allowed-tools: Bash(*) Read
argument-hint: <repo-name>
---

# Resume Dev Team: $ARGUMENTS

```!
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || { echo "ERROR: not in a repo"; exit 1; }
REPO_NAME="$ARGUMENTS"

if [ -z "$REPO_NAME" ]; then
  echo "Usage: /resume-dev-team <repo-name>"
  exit 1
fi

# Resolve repo path
REPO_PATH=$(python3 - <<PYEOF
import re
with open('.cto/projects.yaml') as f:
    text = f.read()
for b in re.split(r'(?=- name:)', text):
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    if m and m.group(1) == "$REPO_NAME" and p:
        print(p.group(1))
        break
PYEOF
)

if [ -z "$REPO_PATH" ]; then
  echo "ERROR: repo '$REPO_NAME' not in .cto/projects.yaml"
  exit 1
fi

SESS_ID_FILE="$REPO_PATH/.claude/current-session.id"
if [ ! -f "$SESS_ID_FILE" ]; then
  echo "ERROR: no recorded session ID at $SESS_ID_FILE"
  echo "Either /handoff was never run for this repo, or the SessionStart hook didn't record the ID."
  echo "Recovery option: re-run /handoff <sprint-XX> --repos $REPO_NAME"
  exit 1
fi

SESSION_ID=$(cat "$SESS_ID_FILE" | tr -d '[:space:]')

# Verify the JSONL exists (sanity check before trying to resume)
JSONL=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
if [ -z "$JSONL" ]; then
  echo "ERROR: no JSONL found for session $SESSION_ID"
  echo "Session may have been deleted. Recovery option: re-run /handoff with --repos $REPO_NAME"
  exit 1
fi

echo "Resuming session $SESSION_ID for $REPO_NAME"
echo "JSONL: $JSONL"
echo "Last activity: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$JSONL")"
echo ""

# Open new Terminal tab running claude --resume
echo "Opening Terminal tab with claude --resume..."
osascript <<APPLESCRIPT 2>&1 | tail -1
tell application "Terminal"
    activate
    do script "cd $REPO_PATH && echo '[resume] resuming session $SESSION_ID for $REPO_NAME...' && claude --resume $SESSION_ID"
end tell
APPLESCRIPT

# Clear CRASHED flag if it exists
if [ -f "$REPO_PATH/.claude/CRASHED" ]; then
  rm "$REPO_PATH/.claude/CRASHED"
  echo "Cleared CRASHED flag."
fi
echo ""
echo "Resume tab launched. Watch the new Terminal window for the session to come back online."
```

## Your task as CTO

Confirm to the CEO:

1. **Session resumed** in a new Terminal tab
2. **CRASHED flag cleared** (if it was set)
3. **Recommend:** use `/peek $ARGUMENTS` to verify the resumed session is making progress

If the resume fails (e.g., session ID stale, JSONL missing), surface the error to the CEO and suggest re-running `/handoff` for that specific repo.

Sign as: — CTO
