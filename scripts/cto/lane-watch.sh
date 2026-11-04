#!/usr/bin/env bash
# lane-watch.sh — what every live lane is waiting on, as one line per event.
#
#   lane-watch.sh [--once] [--interval SEC] [--idle-min N] [--repos "a b"]
#
# WHY (fleet report 2026-11-04): a lane sat idle 90 min after a report; a report that ends
# "I continue" is not work; an overnight gap went unnoticed for 10 h. Lanes are watched, not polled
# by memory. Built to be wrapped by the harness's Monitor tool: each printed line wakes the CTO.
#
# Lanes: the active repos in <cto-home>/.cto/projects.yaml (or --repos). Each lane's transcript is
# the session working in that repo now (session-for-path.sh). Per lane, per pass:
#   WAITING  the session ended its turn with a message not yet reported — printed once, with the
#            first 170 chars. This is the turn-end the CTO must answer.
#   IDLE     no tool use for >= --idle-min (default 30) and the repo is not marked idle-by-design
#            (`touch <repo>/.claude/idle-by-design` while a lane legitimately waits) — once an hour.
#   DIALOG   a permission prompt is on screen in the lane's window (window-registry / terminal-window.id).
# State: ~/.cto/state/lane-watch/. Also writes ~/.cto/state/lanes-live (one live repo per line) for
# cto-heartbeat.sh. The first pass seeds silently.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; HOME_CTO="${CTO_HOME:-$(cd "$HERE/../.." && pwd -P)}"
ONCE=0; INTERVAL=60; IDLE_MIN=30; REPOS=""
while [ $# -gt 0 ]; do
    case "$1" in --once) ONCE=1 ;; --interval) INTERVAL="${2:-60}"; shift ;; --idle-min) IDLE_MIN="${2:-30}"; shift ;;
        --repos) REPOS="${2:-}"; shift ;; *) echo "lane-watch: unknown argument '$1'" >&2; exit 2 ;; esac; shift
done
ST="${LANE_WATCH_STATE:-$HOME/.cto/state/lane-watch}"; mkdir -p "$ST"
paths(){
    if [ -n "$REPOS" ]; then for r in $REPOS; do [ -d "$r" ] && echo "$r" || echo "$HOME/repos/$r"; done; return; fi
    bash "$HERE/fleet-repos.sh" "$HOME_CTO"
}
win_of(){ local r="$1" w=""
    [ -x "$HERE/window-registry.sh" ] && w="$(bash "$HERE/window-registry.sh" resolve "$r" 2>/dev/null | head -1)"
    [ -z "$w" ] && [ -f "$r/.claude/terminal-window.id" ] && w="$(tr -d '[:space:]' < "$r/.claude/terminal-window.id")"
    printf '%s' "$w"; }
while :; do
    now=$(date +%s); : > "$ST/.live.tmp"
    for r in $(paths); do
        [ -d "$r" ] || continue; k="$(basename "$r")"
        f="$(bash "$HERE/session-for-path.sh" "$r" --hours 12 2>/dev/null)" || continue
        [ -f "$f" ] || continue
        out="$(tail -c 400000 "$f" | python3 -c '
import sys, json, datetime
last = None; tool = None
for l in sys.stdin:
    try: d = json.loads(l)
    except Exception: continue
    if d.get("type") == "assistant":
        last = d
        for c in (d.get("message") or {}).get("content", []) or []:
            if isinstance(c, dict) and c.get("type") == "tool_use": tool = d.get("timestamp")
age = -1
if tool:
    try:
        t = datetime.datetime.strptime(tool[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        age = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 60)
    except Exception: pass
m = (last or {}).get("message") or {}
if last and m.get("stop_reason") == "end_turn":
    t = " ".join(c.get("text", "") for c in m.get("content", []) if isinstance(c, dict) and c.get("type") == "text").strip()
    print((last.get("uuid") or "none") + "\t" + t[:170].replace("\n", " ").replace("\t", " ") + "\t" + str(age))
else:
    print("none\t\t" + str(age))')"
        [ -n "$out" ] || continue
        id="$(printf '%s' "$out" | cut -f1)"; age="$(printf '%s' "$out" | cut -f3)"
        mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f"); [ $((now - mtime)) -lt 10800 ] && [ ! -f "$r/.claude/COMPLETE" ] && echo "$r" >> "$ST/.live.tmp"
        if [ "$id" != none ] && [ "$(cat "$ST/$k.turn" 2>/dev/null)" != "$id" ]; then
            [ -f "$ST/.seeded" ] && echo "$k WAITING: $(printf '%s' "$out" | cut -f2)"
            printf '%s' "$id" > "$ST/$k.turn"
        fi
        if [ ! -f "$r/.claude/idle-by-design" ] && [ ! -f "$r/.claude/COMPLETE" ] && [ "$age" -ge "$IDLE_MIN" ] 2>/dev/null; then
            last=$(cat "$ST/$k.idle" 2>/dev/null || echo 0)
            if [ $((now - last)) -ge 3600 ]; then
                [ -f "$ST/.seeded" ] && echo "$k IDLE: no tool use for ${age} min, not marked idle-by-design (touch $r/.claude/idle-by-design if it is waiting on purpose)"
                printf '%s' "$now" > "$ST/$k.idle"
            fi
        fi
        w="$(win_of "$r")"
        if [ -n "$w" ] && bash "$HERE/window-peek.sh" "$w" 2>/dev/null | tail -12 | grep -q "Do you want to proceed"; then
            [ "$(cat "$ST/$k.dialog" 2>/dev/null)" = "$id" ] || { echo "$k DIALOG: a permission prompt is open in window $w"; printf '%s' "$id" > "$ST/$k.dialog"; }
        fi
    done
    mv "$ST/.live.tmp" "$HOME/.cto/state/lanes-live" 2>/dev/null || { mkdir -p "$HOME/.cto/state"; mv "$ST/.live.tmp" "$HOME/.cto/state/lanes-live"; }
    touch "$ST/.seeded"
    [ "$ONCE" = 1 ] && exit 0
    sleep "$INTERVAL"
done
