#!/usr/bin/env bash
# supervise-worker.sh <pgrep-pattern> <restart-cmd-file> [interval] [max-restarts]
#
# Keep a long-running detached job ALIVE, and say so out loud when it isn't.
#
#   <pgrep-pattern>     matched with `pgrep -f`. Make it specific enough not to match
#                       this supervisor or your editor.
#   <restart-cmd-file>  a shell SCRIPT FILE to re-run when the pattern matches nothing.
#                       A file, never an inline string: no quoting reaches the scanned
#                       command line, and the restart's own preconditions (queue empty?
#                       lock held?) live in the file where they can be reviewed.
#   [interval]          poll seconds (default 120).
#   [max-restarts]      give up after this many real restarts (default 20, 0 = never).
#
# Emits one line per STATE CHANGE, so a Monitor watching this reports "worker died /
# restarted" instead of silence. Restart output goes to <restart-cmd-file>.log — a
# restart that fails silently is indistinguishable from one that never ran.
#
# A restart script may legitimately DECLINE to start (no work queued = a clean exit,
# not a crash). Declines are counted separately from restarts and reported every 10th,
# so an idle worker doesn't look like a crash loop and doesn't burn the restart budget.
#
# WHY: overnight runs have been lost by verifying that a job STARTED but never that it
# STAYED ALIVE, with watchers armed on output FILES rather than on process liveness.
# Liveness is the signal; the file is the lagging indicator.

set -uo pipefail

PATTERN="${1:?usage: supervise-worker.sh <pgrep-pattern> <restart-cmd-file> [interval] [max-restarts]}"
CMDFILE="${2:?need a restart command file (a script file, not an inline command)}"
INTERVAL="${3:-120}"
MAX_RESTARTS="${4:-20}"
[ -f "$CMDFILE" ] || { echo "ERROR: restart command file not found: $CMDFILE" >&2; exit 1; }
RESTART_LOG="${CMDFILE}.log"

restarts=0
declines=0
was_alive=""

while true; do
    if pgrep -f "$PATTERN" >/dev/null 2>&1; then
        [ "$was_alive" = "yes" ] || echo "EVENT worker-alive: $PATTERN"
        was_alive=yes
        declines=0
    else
        was_alive=no
        echo "EVENT worker-down: $PATTERN — restarting (log: $RESTART_LOG)"
        bash "$CMDFILE" >>"$RESTART_LOG" 2>&1 &
        sleep 15
        if pgrep -f "$PATTERN" >/dev/null 2>&1; then
            restarts=$((restarts + 1))
            echo "EVENT worker-restarted: $PATTERN — restart #$restarts"
            declines=0
            if [ "$MAX_RESTARTS" -gt 0 ] && [ "$restarts" -ge "$MAX_RESTARTS" ]; then
                echo "EVENT worker-crash-loop: $PATTERN restarted $restarts times — giving up."
                echo "  This is a crash loop, not a supervision problem. See $RESTART_LOG."
                exit 1
            fi
        else
            declines=$((declines + 1))
            if [ $((declines % 10)) -eq 1 ]; then
                echo "EVENT worker-idle: $PATTERN — restart declined x$declines (no work queued?). Tail: $RESTART_LOG"
            fi
        fi
    fi
    sleep "$INTERVAL"
done
