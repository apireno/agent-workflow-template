#!/usr/bin/env bash
# vp-review-wait.sh <out-dir> [--timeout SEC] [--quiet] [--no-reap]
#
# Poll the detached reviews launched by vp-review-detach.sh until every one has finished or
# the timeout expires, then print a status table.
#
# Run this from the MAIN LOOP (a Bash tool call), not from a skill body — the main loop's
# budget is minutes, the skill body's is ~2. That split is the whole point: the skill launches
# and returns, this waits.
#
# Safe to re-run: it is a poll, not a consumer. If it times out, call it again.
#
# Exit: 0 every review produced a verdict
#       1 at least one FAILED (verdict absent — check <vp>.log)
#       2 usage
#       3 still running when the timeout expired (not a failure — poll again)

set -uo pipefail
OUTDIR="${1:?usage: vp-review-wait.sh <out-dir> [--timeout SEC] [--quiet]}"
shift
TIMEOUT=480; QUIET=0; REAP=1
# REAP (fleet RCA 2026-10-28): a review subtree runs with TERM/HUP/INT ignored, so a hung engine
# outlived its review by days. When this wait gives up, any row still "running" for longer than
# REAP_AFTER seconds (default: agy's timeout + grace + 120 = 780) — and any FAILED row whose engine
# is still alive — gets its recorded process group and wrapper SIGKILLed, and the row is marked
# "failed: hard-timeout (reaped)". A failed or stale row must never leave a live engine behind.
REAP_AFTER="${VP_REVIEW_REAP_AFTER:-$(( ${AGY_TIMEOUT:-600} + ${AGY_HARD_GRACE:-60} + 120 ))}"
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
        --quiet) QUIET=1; shift ;;
        --no-reap) REAP=0; shift ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[ -d "$OUTDIR" ] || { echo "ERROR: no such directory: $OUTDIR" >&2; exit 2; }

STATUSES="$(ls "$OUTDIR"/*.status 2>/dev/null)"
[ -n "$STATUSES" ] || { echo "ERROR: no .status files in $OUTDIR — was vp-review-detach.sh run?" >&2; exit 2; }

START=$(date +%s)
while :; do
    RUNNING=0
    for s in $STATUSES; do
        [ "$(cat "$s" 2>/dev/null)" = "running" ] && RUNNING=$((RUNNING + 1))
    done
    [ "$RUNNING" -eq 0 ] && break
    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "$TIMEOUT" ]; then break; fi
    [ "$QUIET" -eq 1 ] || printf 'vp-review-wait: %s still running (%ss elapsed)\n' "$RUNNING" "$((NOW - START))" >&2
    sleep 10
done

descendants() { # print the pid and every descendant of _PID (ps-based; works under launchd reparenting)
    local all; all="$(ps -axo pid=,ppid= 2>/dev/null)"
    printf '%s\n' "$all" | awk -v root="$_PID" '{ kids[$2]=kids[$2]" "$1 } END { q=root; while (q!="") { split(q,a," "); q=""; for (i in a) { p=a[i]; if (p=="") continue; print p; q=q" "kids[p] } } }'
}
reap_row() { # _VP: SIGKILL its engine process group and its wrapper subtree; mark the row
    local vp="$_VP" pg wp
    pg="$(tr -dc '0-9' < "$OUTDIR/${vp}.agy.pid" 2>/dev/null)"
    wp="$(tr -dc '0-9' < "$OUTDIR/${vp}.pid" 2>/dev/null)"
    [ -n "$pg" ] && kill -9 -- "-$pg" 2>/dev/null
    if [ -n "$wp" ]; then _PID="$wp"; for p in $(descendants); do kill -9 "$p" 2>/dev/null; done; fi
    rm -f "$OUTDIR/${vp}.agy.pid"
    printf 'failed: hard-timeout (reaped)\n' > "$OUTDIR/${vp}.status"
    echo "vp-review-wait: REAPED $vp (engine group ${pg:-?}, wrapper ${wp:-?}) — SIGKILL; no verdict." >&2
}
if [ "$REAP" -eq 1 ]; then
    NOW=$(date +%s)
    for s in $STATUSES; do
        vp="$(basename "$s" .status)"; st="$(cat "$s" 2>/dev/null)"
        age=$(( NOW - $(stat -f %m "$s" 2>/dev/null || echo "$NOW") ))
        pg="$(tr -dc '0-9' < "$OUTDIR/${vp}.agy.pid" 2>/dev/null)"
        if [ "$st" = running ] && [ "$age" -ge "$REAP_AFTER" ]; then _VP="$vp"; reap_row
        elif [ "$st" != running ] && [ -n "$pg" ] && kill -0 -- "-$pg" 2>/dev/null; then _VP="$vp"; reap_row
        fi
    done
fi

OK=0; FAILED=0; RUNNING=0
printf '%-18s %-10s %-10s %s\n' "VP" "STATUS" "BYTES" "NOTE"
printf -- '---------------------------------------------------------------\n'
for s in $STATUSES; do
    vp="$(basename "$s" .status)"
    st="$(cat "$s" 2>/dev/null)"
    md="$OUTDIR/${vp}.md"
    bytes=0; [ -f "$md" ] && bytes=$(wc -c < "$md" | tr -d ' ')
    note=""
    case "$st" in
        ok)
            # The verdict file is only ever created WITH a body (vp-review.sh publishes by
            # rename), so "ok but no file" means something removed it — say so, don't assume.
            if [ "$bytes" -gt 0 ]; then OK=$((OK + 1)); else st="failed"; note="status=ok but no verdict on disk"; FAILED=$((FAILED + 1)); fi ;;
        failed)  FAILED=$((FAILED + 1)); note="see ${vp}.log" ;;
        "failed: hard-timeout (reaped)") FAILED=$((FAILED + 1)); note="engine hung past its hard clock; killed. Re-run on another engine (--engine kimi)" ;;
        running) RUNNING=$((RUNNING + 1)); note="still running — poll again" ;;
        *)       FAILED=$((FAILED + 1)); note="unknown status '$st'" ;;
    esac
    printf '%-18s %-10s %-10s %s\n' "$vp" "${st%% *}" "$bytes" "$( [ "${st#failed: }" != "$st" ] && printf '%s — ' "${st#failed: }")$note"
done
printf -- '---------------------------------------------------------------\n'
echo "OK=$OK FAILED=$FAILED RUNNING=$RUNNING"

[ "$RUNNING" -gt 0 ] && { echo "TIMED OUT after ${TIMEOUT}s with $RUNNING still running — re-run this command to keep waiting." >&2; exit 3; }
[ "$FAILED" -gt 0 ] && exit 1
exit 0
