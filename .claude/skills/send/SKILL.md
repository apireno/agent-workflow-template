---
name: send
description: Send a message to a running Phase 2 dev-team Claude Code session by injecting it into the recorded Terminal window via osascript. Use when /peek shows the dev team asking a question, when VP review feedback needs to reach a running session, or when you want to pass a follow-up instruction without spawning a new tab. Auto-fire when the CEO says things like "tell the tuner team to X", "respond to the morphology dev team with Y", "ask the dev team to Z". Cheaper than /resume-dev-team because there is no new session, no conversation-history reload, no token cost. A bare NUMERIC first argument is treated as a Terminal window id and addressed directly — use that for windows the repo registry cannot name: a second sprint on the same repo (handoff overwrites the single recorded id slot), a QA drive window, or another orchestration session with no repo binding.
allowed-tools: Bash(*) Read
argument-hint: <repo-name|window-id> <message>
---

# Send to dev team: $ARGUMENTS

Injects a message into the live Claude Code session running in the repo's recorded Terminal window. The dev team sees the message as if a human typed it at the prompt.

```!
set -uo pipefail
# CTO-HOME ANCHORING. These skills read the fleet registry, which lives in the CTO home
# — but `git rev-parse` returns whatever repo the SHELL happens to sit in. A lingering cd
# into a project repo made /handoff report "no target repos found" and made vp-review
# resolve personas against the wrong tree. $CLAUDE_PROJECT_DIR is the session's project
# root regardless of cwd drift, so it is the correct anchor; git root is the fallback.
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || { echo "ERROR: cannot enter $ROOT"; exit 1; }
CTO_REGISTRY="$ROOT/.cto/projects.yaml"
if [ ! -f "$CTO_REGISTRY" ]; then
  echo "ERROR: fleet registry not found at $CTO_REGISTRY"
  echo "  This skill must run from the CTO home (the repo holding .cto/projects.yaml)."
  echo "  If you are in a project repo, the session project dir is wrong — reopen in the CTO home."
  exit 1
fi
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
  echo "       /send <window-id>  <message>      # id-direct, see below"
  echo "Example: /send acme-service-a please switch to validating PRD-114 first"
  exit 1
fi

# ID-DIRECT ADDRESSING. A repo's terminal-window.id is a SINGLE SLOT that /handoff
# overwrites, so a second sprint against the same repo silently steals the first
# window's address — and some windows (a QA drive, another CTO session) have no repo
# binding at all. A bare numeric first token addresses that window directly, skipping
# registry + slot resolution entirely. `window-peek.sh list` enumerates ids.
case "$REPO_NAME" in
  ''|*[!0-9]*) ID_DIRECT=0 ;;
  *)           ID_DIRECT=1 ;;
esac

if [ "$ID_DIRECT" -eq 1 ]; then
  WIN_ID="$REPO_NAME"
  REPO_NAME="window $WIN_ID"
else
# Resolve repo path. Accepts exact name OR suffix alias ("tuner" -> "acme-service-a").
REPO_PATH=$(python3 - <<PYEOF
import re, sys
with open('$CTO_REGISTRY') as f:
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
  echo "ERROR: repo '$REPO_NAME' not found in $CTO_REGISTRY (tried exact + suffix-alias match)"
  exit 1
fi

WIN_ID_FILE="$REPO_PATH/.claude/terminal-window.id"
if [ ! -f "$WIN_ID_FILE" ]; then
  echo "ERROR: no recorded window id for $REPO_NAME at $WIN_ID_FILE"
  echo "Either the session was not launched via /handoff, or handoff predates the window-id tracking patch."
  echo "Fix: run  bash scripts/cto/window-peek.sh list  and send id-direct:  /send <window-id> <message>"
  exit 1
fi
WIN_ID=$(cat "$WIN_ID_FILE" | tr -d '[:space:]')
fi

# Write the message to a temp file — qa-send.sh reads it from there so neither the
# message text nor any osascript braces land on the scanned command line.
MSG_FILE=$(mktemp /tmp/cto-send-msg-XXXXXX)
trap "rm -f '$MSG_FILE'" EXIT
printf '%s' "$MESSAGE" > "$MSG_FILE"

echo "Sending to $REPO_NAME (window id $WIN_ID):"
echo "  $MESSAGE" | head -c 200
echo ""

# DELEGATE to the single keystroke path. This skill used to carry its own copy of the
# osascript, and that copy had no FOCUS GUARD: `set frontmost of window id N to true` can
# fail (-10006 observed live) and the keystroke fired anyway — into whatever app was
# focused. A downstream incident had an orchestration message land in the operator's
# personal messaging app that way. qa-send.sh verifies Terminal is frontmost AND its front
# window is the target id before typing a single character, and aborts sending NOTHING
# otherwise. Do not reinstate an inline osascript here.
bash "$ROOT/scripts/cto/qa-send.sh" "$WIN_ID" "$MSG_FILE"
SEND_RC=$?

echo ""
if [ "$SEND_RC" -ne 0 ]; then
  echo "NOT SENT to $REPO_NAME (window id $WIN_ID) — see the FOCUS-GUARD reason above."
  echo "Nothing was typed anywhere. Common causes: the machine is in use by the operator,"
  echo "the window id is stale (run: bash scripts/cto/window-peek.sh list), or Accessibility"
  echo "permission is not granted to Terminal."
  exit "$SEND_RC"
fi
echo "Message injected into $REPO_NAME (window id $WIN_ID)."
echo "NOTE: the trailing Return does NOT reliably submit — when the dev team is mid-task"
echo "the keystrokes buffer and the Return replays as a newline, not a submit. If the"
echo "message is sitting unsent in the input box, press Enter in that Terminal window."
echo "Then /peek $REPO_NAME to see the response."
```

## Your task as CTO

The message has been injected into the dev-team session. Tell the CEO:

1. **Confirmation:** "Injected N chars into $REPO_NAME (window id $WIN_ID)." **If the script
   aborted with a FOCUS-GUARD error, say NOTHING WAS SENT** — do not describe the message as
   delivered, and relay the guard's reason (machine in use / stale window id / missing
   Accessibility permission) so the CEO knows what to fix before a retry.
2. **Submit caveat — state this EVERY time:** the auto-submit Return is unreliable. If the
   message is sitting unsubmitted in the dev team's input box, the CEO must press Enter in
   that Terminal window. This is a known `/send` limitation, not a one-off — do not claim
   the message "sent" or "delivered" as if it auto-submitted.
3. **Next step:** once submitted, `/peek $REPO_NAME` to see the response (id-direct sends have no repo to peek — use `bash scripts/cto/window-peek.sh <id>` instead).

Sign as: — CTO
