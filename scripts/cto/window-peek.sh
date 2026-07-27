#!/usr/bin/env bash
# Read the visible contents of a Terminal window (last N non-empty lines).
# Usage: window-peek.sh <window-id> [lines=15]
# Companion to /peek (which tails JSONL): this shows what's ON SCREEN — prompts,
# permission dialogs, queued input — which the JSONL cannot show.
set -euo pipefail
if [ "${1:-}" = "list" ]; then
  osascript -e 'tell application "Terminal"
    set out to ""
    repeat with w in windows
      set out to out & (id of w) & " | " & (name of w) & linefeed
    end repeat
    return out
  end tell' 2>/dev/null
  exit 0
fi
WIN="${1:?usage: window-peek.sh <window-id>|list [lines]}"
N="${2:-15}"
osascript -e "tell application \"Terminal\" to get contents of window id $WIN" 2>/dev/null \
  | grep -v '^[[:space:]]*$' | tail -n "$N"
