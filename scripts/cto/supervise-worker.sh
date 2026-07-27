#!/usr/bin/env bash
# supervise-worker.sh <pattern> <restart-cmd-file> [interval=120]
#
# Keep a long-running detached job ALIVE. Polls for a process matching <pattern>;
# if none is running, re-runs the command in <restart-cmd-file> (a shell script
# file — never an inline string, so no quoting reaches the scanned command line)
# and logs the restart. Emits one line per state change, so a Monitor watching
# it reports "worker died / restarted" instead of silence.
#
# WHY: two overnight runs were lost (2026-07-20/21) because the CTO verified a
# job STARTED but never that it STAYED ALIVE, and the watchers were armed on
# output FILES rather than on process liveness. Liveness is the signal.

set -uo pipefail
PATTERN="${1:?usage: supervise-worker.sh <pgrep-pattern> <restart-cmd-file> [interval]}"
CMDFILE="${2:?need a restart command file}"
INTERVAL="${3:-120}"
[ -f "$CMDFILE" ] || { echo "ERROR: restart command file not found: $CMDFILE"; exit 1; }

restarts=0
idle=0
was_alive=""
while true; do
  if pgrep -f "$PATTERN" >/dev/null 2>&1; then
    [ "$was_alive" = "yes" ] || echo "EVENT worker-alive: $PATTERN"
    was_alive=yes
  else
    was_alive=no
    restarts=$((restarts + 1))
    echo "EVENT worker-down: $PATTERN — restart #$restarts"
    bash "$CMDFILE" >/dev/null 2>&1 &
    sleep 15
    if pgrep -f "$PATTERN" >/dev/null 2>&1; then
      echo "EVENT worker-restarted: $PATTERN"
    else
      # The restart script may legitimately decline to start (e.g. no work in the
      # queue — a clean exit, not a crash). Keep supervising rather than dying;
      # only a repeated decline is worth a human, so report every 10th.
      idle=$((idle + 1))
      [ $((idle % 10)) -eq 1 ] && echo "EVENT worker-idle: $PATTERN — restart declined (no work?) x$idle"
      restarts=$((restarts - 1))
    fi
  fi
  sleep "$INTERVAL"
done
