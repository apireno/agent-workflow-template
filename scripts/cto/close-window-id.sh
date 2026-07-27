#!/usr/bin/env bash
# close-window-id.sh — close Terminal windows BY ID, for orphans /close-window can't reach.
#
#   close-window-id.sh <window-id> [<window-id>...]         # DRY RUN: show what would die
#   close-window-id.sh --yes <window-id> [<window-id>...]   # actually close
#
# WHY THIS EXISTS: /close-window resolves <repo> -> the id recorded in
# <repo>/.claude/terminal-window.id, and refuses to close unless dev-report.md exists.
# When two sprints run against the same repo, /handoff OVERWRITES that file, so the
# older window loses its route and /close-window can no longer address it. This is the
# id-direct escape hatch for exactly those orphans.
#
# WHY DRY-RUN BY DEFAULT: this pre-kills every process on the window's tty (so macOS
# never raises the "close anyway?" sheet) — it will terminate a live agent session
# without asking. /close-window has a dev-report safety gate; an id-direct close has no
# repo to check, so "show the target before destroying it" IS the gate. Look at the
# process list, then re-run with --yes.
#
# macOS + Terminal.app only. Requires Automation permission for Terminal.

set -uo pipefail

CONFIRM=0
case "${1:-}" in
    --yes|-y) CONFIRM=1; shift ;;
esac
[ $# -gt 0 ] || { echo "usage: close-window-id.sh [--yes] <window-id> [<window-id>...]" >&2; exit 1; }

for WIN in "$@"; do
    NAME=$(osascript -e "tell application \"Terminal\" to get name of window id $WIN" 2>/dev/null || true)
    TTY=$(osascript -e "tell application \"Terminal\" to get tty of window id $WIN" 2>/dev/null || true)
    if [ -z "$NAME" ] && [ -z "$TTY" ]; then
        echo "window $WIN: not found (already closed?)"
        continue
    fi

    echo "window $WIN: ${NAME:-<untitled>}   tty=${TTY:-<none>}"
    if [ -n "$TTY" ]; then
        PIDS=$(lsof -t "$TTY" 2>/dev/null | sort -u)
        if [ -n "$PIDS" ]; then
            echo "  processes that will be terminated:"
            # shellcheck disable=SC2086
            ps -o pid,comm,command -p $(printf '%s' "$PIDS" | tr '\n' ',' | sed 's/,$//') 2>/dev/null \
                | tail -n +2 | cut -c1-120 | sed 's/^/    /'
        fi
    fi

    if [ "$CONFIRM" -ne 1 ]; then
        echo "  DRY RUN — re-run with --yes to close this window."
        continue
    fi

    if [ -n "$TTY" ]; then
        for p in $(lsof -t "$TTY" 2>/dev/null); do kill "$p" 2>/dev/null; done
        sleep 1
        for p in $(lsof -t "$TTY" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    fi
    if osascript -e "tell application \"Terminal\" to close (first window whose id is $WIN)" 2>/dev/null; then
        echo "  closed $WIN"
    else
        echo "  close FAILED for $WIN — Terminal sometimes errors -1728 here; retry, or close it by hand."
    fi
done
