---
name: send
description: Send a message to a running Phase 2 dev-team Claude Code session by injecting it into the recorded Terminal window via osascript. Use when /peek shows the dev team asking a question, when VP review feedback needs to reach a running session, or when you want to pass a follow-up instruction without spawning a new tab. Auto-fire when the CEO says things like "tell the tuner team to X", "respond to the morphology dev team with Y", "ask the dev team to Z". Cheaper than /resume-dev-team because there is no new session, no conversation-history reload, no token cost.
allowed-tools: Bash(*) Read
argument-hint: <repo-name> <message>
---

# Send to dev team: $ARGUMENTS

Injects a message into the live Claude Code session running in the repo's recorded Terminal window. The dev team sees the message as if a human typed it at the prompt.

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

# Capture the skill arguments via a single-quoted heredoc so the message body
# may contain ANY character — double-quotes, $, backticks — without breaking
# shell parsing. A bare ARGS="$ARGUMENTS" breaks the moment the message has a ".
ARGS=$(cat <<'__CTO_SEND_ARGUMENTS_EOF__'
$ARGUMENTS
__CTO_SEND_ARGUMENTS_EOF__
)
REPO_NAME=""
MESSAGE=""

# First token is repo name; everything after is the message
read -r REPO_NAME MESSAGE <<< "$ARGS"

if [ -z "$REPO_NAME" ] || [ -z "$MESSAGE" ]; then
  echo "Usage: /send <repo-name> <message>"
  echo "Example: /send acme-service-a please switch to validating PRD-114 first"
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
  echo "Either the session was not launched via /handoff, or handoff predates the window-id tracking patch."
  echo "Manual fix: find the window id (e.g., from earlier handoff output) and write it to $WIN_ID_FILE"
  exit 1
fi
WIN_ID=$(cat "$WIN_ID_FILE" | tr -d '[:space:]')

# Write the message to a temp file so we don't have to shell-escape it through
# osascript. AppleScript will read the file content via `do shell script`.
MSG_FILE=$(mktemp /tmp/cto-send-msg-XXXXXX)
trap "rm -f '$MSG_FILE'" EXIT
printf '%s' "$MESSAGE" > "$MSG_FILE"

echo "Sending to $REPO_NAME (window id $WIN_ID):"
echo "  $MESSAGE" | head -c 200
echo ""

# Use System Events keystroke. `do script in window N` writes to the shell
# context, NOT to a TUI program's stdin — confirmed empirically 2026-05-18:
# message landed as empty `system` JSONL events, never reached claude's input.
# System Events keystroke writes to the active window's input event stream,
# which TUI apps DO see correctly. Requires Accessibility permission for
# Terminal (System Settings → Privacy & Security → Accessibility → enable
# Terminal). Granted once; persists.
osascript <<APPLESCRIPT 2>&1 | tail -5
set msgContent to do shell script "cat " & quoted form of "$MSG_FILE"

tell application "Terminal"
    activate
    set frontmost of window id $WIN_ID to true
end tell

delay 0.3

tell application "System Events"
    tell process "Terminal"
        keystroke msgContent
        -- Wait for the FULL keystroke stream to be ingested and the input box
        -- to settle BEFORE sending Return. A fixed 0.1s is far too short for a
        -- long message: the System Events keystroke call returns before the OS finishes
        -- delivering all events, so the Return arrives mid-paste and is
        -- absorbed as a literal newline in the input box — the message then
        -- sits UNSUBMITTED. Scale the wait to message length (~1.5s base +
        -- ~0.0015s/char): a 2000-char message waits ~4.5s, then Return submits.
        delay (1.5 + (count of characters of msgContent) * 0.0015)
        key code 36 -- Return (submit)
    end tell
end tell

return "sent " & (length of msgContent) & " chars to window id $WIN_ID"
APPLESCRIPT

echo ""
echo "Message injected into $REPO_NAME (window id $WIN_ID)."
echo "NOTE: the trailing Return does NOT reliably submit — when the dev team is mid-task"
echo "the keystrokes buffer and the Return replays as a newline, not a submit. If the"
echo "message is sitting unsent in the input box, press Enter in that Terminal window."
echo "Then /peek $REPO_NAME to see the response."
```

## Your task as CTO

The message has been injected into the dev-team session. Tell the CEO:

1. **Confirmation:** "Injected N chars into $REPO_NAME (window id $WIN_ID)."
2. **Submit caveat — state this EVERY time:** the auto-submit Return is unreliable. If the
   message is sitting unsubmitted in the dev team's input box, the CEO must press Enter in
   that Terminal window. This is a known `/send` limitation, not a one-off — do not claim
   the message "sent" or "delivered" as if it auto-submitted.
3. **Next step:** once submitted, `/peek $REPO_NAME` to see the response.

Sign as: — CTO
