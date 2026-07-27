#!/usr/bin/env bash
# Demo-stack operations, one allowlisted entrypoint — NO custom bash in the CTO session.
# Usage:
#   demo-stack.sh health          # one-line status: demo "${STACK_APP_PORT:-8080}", surreal "${STACK_DB_PORT:-8011}", port owners
#   demo-stack.sh up              # detached bringup (nohup, logged) — idempotent
#   demo-stack.sh reset           # reset-for-test then detached bringup
#   demo-stack.sh wait [secs]     # block (default 900s) until demo "${STACK_APP_PORT:-8080}" answers or bringup dies;
#                                 # prints DEMO_UP or BRINGUP_DIED + log tail. Monitor-friendly.
#   demo-stack.sh log             # tail the current bringup log
set -uo pipefail
APP="${STACK_APP_ROOT:?set STACK_APP_ROOT to the app repo path}"
LOG="${STACK_LOG:-/tmp/app-stack-bringup.log}"
cmd="${1:-health}"
case "$cmd" in
  health)
    d=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${STACK_HEALTH_URL:-http://127.0.0.1"${STACK_APP_PORT:-8080}"/}" || true)
    s=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${STACK_DB_HEALTH_URL:-http://127.0.0.1"${STACK_DB_PORT:-8011}"/health}" || true)
    echo "demo"${STACK_APP_PORT:-8080}"=$d surreal"${STACK_DB_PORT:-8011}"=$s"
    lsof -i "${STACK_DB_PORT:-8011}" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print "8011 owner:", $1, $2}' || true
    lsof -i "${STACK_APP_PORT:-8080}" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print "8080 owner:", $1, $2}' || true
    ;;
  up)
    nohup bash "$APP/scripts/"${STACK_BRINGUP_SCRIPT:-scripts/bringup.sh}"" > "$LOG" 2>&1 < /dev/null &
    echo "bringup detached pid $! log $LOG"
    ;;
  reset)
    bash "$APP/scripts/"${STACK_RESET_SCRIPT:-scripts/reset-for-test.sh}"" > "$LOG" 2>&1 \
      && echo "reset+bringup OK" || { echo "RESET/BRINGUP FAILED — log tail:"; tail -5 "$LOG"; exit 1; }
    ;;
  wait)
    t="${2:-900}"; end=$(( $(date +%s) + t ))
    while [ "$(date +%s)" -lt "$end" ]; do
      if curl -s -o /dev/null --max-time 3 "${STACK_HEALTH_URL:-http://127.0.0.1"${STACK_APP_PORT:-8080}"/}"; then echo DEMO_UP; exit 0; fi
      pgrep -f bringup-demo-stack >/dev/null || { echo BRINGUP_DIED; tail -5 "$LOG" 2>/dev/null; exit 1; }
      sleep 20
    done
    echo WAIT_TIMEOUT; exit 2
    ;;
  down)
    pkill -f "bringup-demo-stack" 2>/dev/null
    [ -n "${STACK_SERVER_PATTERN:-}" ] && pkill -f "$STACK_SERVER_PATTERN" 2>/dev/null
    for p in $(lsof -t -i "${STACK_APP_PORT:-8080}" -sTCP:LISTEN 2>/dev/null) $(lsof -t -i "${STACK_DB_PORT:-8011}" -sTCP:LISTEN 2>/dev/null); do kill "$p" 2>/dev/null; done
    sleep 3
    echo "teardown done:"; "$0" health
    ;;
  log) tail -15 "$LOG" 2>/dev/null ;;
  *) echo "unknown cmd: $cmd" >&2; exit 1 ;;
esac
