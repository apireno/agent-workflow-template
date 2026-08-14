#!/usr/bin/env bash
# vp-review-wait.sh <out-dir> [--timeout SEC] [--quiet]
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
TIMEOUT=480; QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
        --quiet) QUIET=1; shift ;;
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
        running) RUNNING=$((RUNNING + 1)); note="still running — poll again" ;;
        *)       FAILED=$((FAILED + 1)); note="unknown status '$st'" ;;
    esac
    printf '%-18s %-10s %-10s %s\n' "$vp" "$st" "$bytes" "$note"
done
printf -- '---------------------------------------------------------------\n'
echo "OK=$OK FAILED=$FAILED RUNNING=$RUNNING"

[ "$RUNNING" -gt 0 ] && { echo "TIMED OUT after ${TIMEOUT}s with $RUNNING still running — re-run this command to keep waiting." >&2; exit 3; }
[ "$FAILED" -gt 0 ] && exit 1
exit 0
