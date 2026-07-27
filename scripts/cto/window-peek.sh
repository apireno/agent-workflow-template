#!/usr/bin/env bash
# window-peek.sh — read what is ON SCREEN in a Terminal window (or list all windows).
#
#   window-peek.sh list              # every Terminal window: "<id> | <title>"
#   window-peek.sh <window-id> [N]   # last N (default 15) non-blank on-screen lines
#
# Companion to /peek, NOT a replacement. /peek tails the session JSONL — the model's
# thinking and tool calls. This shows the SCREEN: permission dialogs, queued-but-
# unsubmitted input, and shell output the JSONL never records. When a session looks
# hung, /peek shows the last thing it did; this shows what it is waiting on.
#
# macOS + Terminal.app only, like the rest of the window-orchestration layer
# (/handoff, /send, /close-window). Read-only: it never sends keystrokes.
#
# Requires Accessibility/Automation permission for Terminal (same grant /send needs).

set -uo pipefail

if [ "${1:-}" = "list" ]; then
    osascript -e 'tell application "Terminal"
        set out to ""
        repeat with w in windows
            set out to out & (id of w) & " | " & (name of w) & linefeed
        end repeat
        return out
    end tell' 2>/dev/null || { echo "window-peek: could not enumerate Terminal windows (is Terminal running? is Automation permission granted?)" >&2; exit 1; }
    exit 0
fi

WIN="${1:?usage: window-peek.sh list | window-peek.sh <window-id> [lines]}"
N="${2:-15}"

CONTENTS="$(osascript -e "tell application \"Terminal\" to get contents of window id $WIN" 2>/dev/null)"
if [ -z "$CONTENTS" ]; then
    echo "window-peek: no contents for window id $WIN (closed, or wrong id — try 'window-peek.sh list')" >&2
    exit 1
fi

# Drop blank lines, keep the tail. grep exiting 1 on an all-blank window is not an
# error here, so it must not take the script down (this ran under `set -e` once and
# turned an empty-but-live window into a hard failure).
printf '%s\n' "$CONTENTS" | grep -v '^[[:space:]]*$' | tail -n "$N" || true
