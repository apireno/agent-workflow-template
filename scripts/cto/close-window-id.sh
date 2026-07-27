#!/usr/bin/env bash
# Close a Terminal window by ID — orphan-safe (handoff overwrites tracked ids, so
# completed-sprint windows lose their /close-window route; this is the id-direct path).
# Pre-kills the window's processes by tty so macOS never raises the terminate sheet.
# Usage: close-window-id.sh <window-id> [<window-id>...]
set -uo pipefail
for WIN in "$@"; do
  TTY=$(osascript -e "tell application \"Terminal\" to get tty of window id $WIN" 2>/dev/null || true)
  if [ -n "$TTY" ]; then
    for p in $(lsof -t "$TTY" 2>/dev/null); do kill "$p" 2>/dev/null; done
    sleep 1
    for p in $(lsof -t "$TTY" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  fi
  osascript -e "tell application \"Terminal\" to close window id $WIN" 2>/dev/null \
    && echo "closed $WIN" || echo "close FAILED for $WIN (already gone?)"
done
