---
name: close-window
description: Close the Terminal window hosting a finished Phase 2 dev-team Claude Code session. Use at sprint wind-down after dev-report.md has landed and /sprint-accept has been run. Cleans up tab accumulation from multi-sprint sessions. CTO-autonomous (no claude -p / API — just osascript window close); the JSONL transcript stays on disk regardless, and the safety check refuses to close unless dev-report.md exists (or --force).
allowed-tools: Bash(*) Read
argument-hint: <repo-name> [--force]
---

# Close window for: $ARGUMENTS

Closes the Terminal window for the named repo's Phase 2 session — **hands-free** (it pre-kills the window's processes by tty so macOS never raises the "terminate running processes?" sheet, with a Terminate-click fallback). The claude process is terminated; its JSONL transcript at `~/.claude/projects/...` was flushed continuously and is preserved for later /peek or /resume-dev-team.

```!
set -uo pipefail
# CTO-HOME ANCHORING: the fleet registry lives in the CTO home, but `git rev-parse`
# returns whatever repo the SHELL sits in — a lingering cd into a project repo makes
# this skill read the wrong tree (or none). $CLAUDE_PROJECT_DIR is the session's project
# root regardless of cwd drift; git root is the fallback.
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || { echo "ERROR: cannot enter $ROOT"; exit 1; }
CTO_REGISTRY="$ROOT/.cto/projects.yaml"
if [ ! -f "$CTO_REGISTRY" ]; then
  echo "ERROR: fleet registry not found at $CTO_REGISTRY — run this from the CTO home."
  exit 1
fi
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
# Close strategy (revised 2026-06-22 — the prior "close then click Terminate" in ONE script
# DEADLOCKED: Terminal's `close` BLOCKS on the "terminate running processes?" sheet, so the
# click code that came AFTER it never ran — the agent had to click Terminate / type exit by
# hand. New strategy makes it deterministic and hands-free:
#   (1) PRE-KILL the window's processes by its tty (claude/node/uv/domshell-proxy/python) so
#       `close` finds nothing running and never raises the sheet at all. The JSONL transcript
#       is already flushed and dev-report.md is already on disk, so a hard kill loses nothing.
#   (2) Fire `close` in the BACKGROUND so that IF a residual sheet still appears it cannot
#       block this script.
#   (3) FOREGROUND loop clicks any lingering "Terminate" sheet (which also unblocks the bg
#       close) and verifies the window is gone.
# Use `(first window whose id is X)` — `window id X` raises -1728.
# Requires Accessibility permission for Terminal (System Settings → Privacy & Security →
# Accessibility) — same requirement as /send.

# (1) resolve the TARGET window's tty, then SIGTERM/SIGKILL its processes. Guard the tty
#     format so an empty/garbled value can never widen the kill.
TTY=$(osascript 2>/dev/null -e "tell application \"Terminal\" to get tty of selected tab of (first window whose id is $WIN_ID)" || true)
TTY=$(printf '%s' "$TTY" | tr -d '[:space:]')
if printf '%s' "$TTY" | grep -qE '^/dev/ttys[0-9]+$'; then
  TN=${TTY#/dev/}
  pkill -TERM -t "$TN" 2>/dev/null || true
  sleep 0.4
  pkill -KILL -t "$TN" 2>/dev/null || true
  echo "  terminated processes on $TTY (window cleared — no terminate sheet expected)"
else
  echo "  (could not resolve window tty: '$TTY'); relying on the Terminate-sheet click below"
fi

# (2) close in the BACKGROUND so a residual sheet can't block us.
osascript -e "tell application \"Terminal\" to close (first window whose id is $WIN_ID)" >/dev/null 2>&1 &

# (3) FOREGROUND: click any "Terminate" sheet (unblocks the bg close), then verify gone.
RESULT="WARNING: window id $WIN_ID may still be open — retry /close-window or click the red X"
for _i in 1 2 3 4 5 6; do
  sleep 0.4
  osascript >/dev/null 2>&1 <<'OSA' || true
tell application "System Events"
  if exists process "Terminal" then
    tell process "Terminal"
      repeat with w in windows
        if (exists sheet 1 of w) and (exists button "Terminate" of sheet 1 of w) then
          click button "Terminate" of sheet 1 of w
        end if
      end repeat
    end tell
  end if
end tell
OSA
  STILL=$(osascript -e "tell application \"Terminal\" to ((id of windows) contains $WIN_ID)" 2>/dev/null || echo "true")
  if [ "$STILL" = "false" ]; then RESULT="closed window id $WIN_ID (processes terminated, window closed)"; break; fi
done
echo "$RESULT"

# Clear the recorded window id so /send / /close-window don't try to use it again
rm -f "$WIN_ID_FILE"
echo "  cleared $WIN_ID_FILE"

echo "Done. JSONL transcript preserved at ~/.claude/projects/... for /peek + /resume-dev-team."
```

## Your task as CTO

Confirm to the CEO in one line: "Closed window id $WIN_ID for $REPO_NAME. Transcript preserved." If the safety check tripped, explain that dev-report.md wasn't found and offer the --force flag if they really want to abort.

Sign as: — CTO
