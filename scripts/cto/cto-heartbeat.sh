#!/usr/bin/env bash
# cto-heartbeat.sh — wake the CTO when lanes are live and the CTO session has gone quiet.
#
#   cto-heartbeat.sh check [--quiet-min N] [--dry-run]   one pass (launchd runs this every 10 min)
#   cto-heartbeat.sh register                            record this session's Terminal window
#                                                        (preflight runs it in every CTO session)
#
# WHY (fleet report 2026-11-04): a 10-hour overnight gap — lanes finished and waited, nothing woke
# the CTO. A session cannot wake itself; this runs OUTSIDE it, from launchd
# (docs/ops/_templates/com.cto.heartbeat.plist).
#
# `check`: when ~/.cto/state/lanes-live (written by lane-watch.sh) or the fleet's transcripts show a
# lane active in the last 3 h AND the CTO home's newest transcript is older than --quiet-min
# (default 60), at most once per quiet period:
#   1. injects "[HEARTBEAT] …" into the CTO's registered window through qa-send.sh — the single
#      keystroke path, which waits until the operator has stopped typing (no focus theft) and
#      verifies submission. The woken CTO checks the lanes and pushes a one-line page to the CEO's
#      phone (PushNotification; Remote Control delivers it) — cto.md "Heartbeat".
#   2. posts a macOS notification, and drops a memo in ~/.cto/inbox, so a missed injection still
#      leaves a trace.
# Exit: 0 nothing to do / woke the CTO · 2 usage
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; HOME_CTO="${CTO_HOME:-$(cd "$HERE/../.." && pwd -P)}"
CMD="${1:-}"; shift || true
QUIET=60; DRY=0
while [ $# -gt 0 ]; do case "$1" in --quiet-min) QUIET="${2:-60}"; shift ;; --dry-run) DRY=1 ;; *) echo "cto-heartbeat: unknown argument '$1'" >&2; exit 2 ;; esac; shift; done
STATE="${CTO_HEARTBEAT_STATE:-$HOME/.cto/state}"; mkdir -p "$STATE"
PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

if [ "$CMD" = register ]; then
    # walk up from this process to the first ancestor with a tty: that tty is the CTO's tab
    p=$$; tty=""
    for _ in 1 2 3 4 5 6 7 8; do
        t="$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')"; case "$t" in ""|"??") ;; *) tty="/dev/$t"; break ;; esac
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; [ -n "$p" ] && [ "$p" != 1 ] || break
    done
    [ -n "$tty" ] || exit 0
    w="$(osascript -e "tell application \"Terminal\"
repeat with w in windows
repeat with t in tabs of w
if tty of t is \"$tty\" then return id of w
end repeat
end repeat
end tell" 2>/dev/null)"
    [ -n "$w" ] && printf '%s\t%s\n' "$w" "$HOME_CTO" > "$STATE/cto-window"
    exit 0
fi
[ "$CMD" = check ] || { echo "usage: cto-heartbeat.sh check [--quiet-min N] [--dry-run] | register" >&2; exit 2; }

enc(){ printf '%s' "$1" | sed 's#[/.]#-#g'; }
now=$(date +%s)
newest(){ ls -t "$1"/*.jsonl 2>/dev/null | head -1; }
mt(){ stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
# live lanes: lanes-live (lane-watch) if fresh, else transcripts touched in the last 3 h
LIVE=""
if [ -f "$STATE/lanes-live" ] && [ $((now - $(mt "$STATE/lanes-live"))) -lt 1800 ]; then LIVE="$(cat "$STATE/lanes-live")"
else
    for r in $(bash "$HERE/fleet-repos.sh" "$HOME_CTO"); do
        f="$(newest "$PROJ/$(enc "$r")")"; [ -n "$f" ] || continue
        [ $((now - $(mt "$f"))) -lt 10800 ] && [ ! -f "$r/.claude/COMPLETE" ] && LIVE="$LIVE$r"$'\n'
    done
fi
LIVE="$(printf '%s' "$LIVE" | sed '/^$/d')"
[ -n "$LIVE" ] || exit 0
cf="$(newest "$PROJ/$(enc "$HOME_CTO")")"
[ -n "$cf" ] || exit 0
quiet=$(( (now - $(mt "$cf")) / 60 ))
[ "$quiet" -ge "$QUIET" ] || exit 0
last=$(cat "$STATE/heartbeat-last" 2>/dev/null || echo 0)
[ $((now - last)) -ge $((QUIET * 60)) ] || exit 0
n=$(printf '%s\n' "$LIVE" | wc -l | tr -d ' ')
names="$(printf '%s\n' "$LIVE" | xargs -n1 basename | tr '\n' ' ')"
MSG="[HEARTBEAT] $(date '+%H:%M %Z') — the CTO session has been quiet ${quiet} min while ${n} lane(s) are live: ${names}. Check them (/sprint-status, lane-watch.sh --once), act on anything waiting, then page the CEO one line with PushNotification."
if [ "$DRY" = 1 ]; then echo "would wake: $MSG"; exit 0; fi
printf '%s' "$now" > "$STATE/heartbeat-last"
mkdir -p "$HOME/.cto/inbox"; printf '# Heartbeat %s\n\n%s\n' "$(date -u +%FT%TZ)" "$MSG" > "$HOME/.cto/inbox/heartbeat-$(date -u +%Y%m%dT%H%M%SZ).md"
osascript -e "display notification \"CTO quiet ${quiet} min; ${n} lane(s) live\" with title \"CTO heartbeat\"" >/dev/null 2>&1 || true
if [ -f "$STATE/cto-window" ]; then
    w="$(cut -f1 "$STATE/cto-window")"; mf="$(mktemp "${TMPDIR:-/tmp}/heartbeat.XXXXXX")"; printf '%s' "$MSG" > "$mf"
    bash "$HERE/qa-send.sh" "$w" "$mf" --verify-submit >/dev/null 2>&1; rc=$?
    rm -f "$mf"; echo "cto-heartbeat: woke window $w (qa-send exit $rc)"
else
    echo "cto-heartbeat: no registered CTO window (preflight registers it); notification + inbox memo only"
fi
exit 0
