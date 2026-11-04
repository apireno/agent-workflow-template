#!/usr/bin/env bash
# ci-watch.sh — one line per NEW failed / cancelled / timed-out GitHub Actions run across the fleet.
#
#   ci-watch.sh [--once] [--interval SEC] [--repos "a b"] [--state FILE]
#
# WHY (fleet report 2026-11-04): CI failure emails went unread until the CEO asked; "cancelled"
# runs (a job timeout shorter than a runner lock wait) read as noise. CI is watched, not remembered.
#
# Repos: the active entries of <cto-home>/.cto/projects.yaml (or --repos), each resolved to its
# GitHub owner/name from `git remote get-url origin`. The first pass SEEDS silently (no flood of old
# failures), then each new bad run prints once:
#   CI <conclusion>: <repo> / <workflow> / <branch> (<sha8>) run <id> at <created>
# Built to be wrapped by the harness's Monitor tool (each line wakes the CTO), or run with --once
# from a loop. State: ~/.cto/state/ci-watch-seen (survives reboots; a /tmp scratchpad does not).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; HOME_CTO="${CTO_HOME:-$(cd "$HERE/../.." && pwd -P)}"
ONCE=0; INTERVAL=180; REPOS=""; STATE="${CI_WATCH_STATE:-$HOME/.cto/state/ci-watch-seen}"
while [ $# -gt 0 ]; do
    case "$1" in --once) ONCE=1 ;; --interval) INTERVAL="${2:-180}"; shift ;; --repos) REPOS="${2:-}"; shift ;;
        --state) STATE="${2:-}"; shift ;; *) echo "ci-watch: unknown argument '$1'" >&2; exit 2 ;; esac; shift
done
command -v gh >/dev/null || { echo "ci-watch: gh not installed" >&2; exit 2; }
mkdir -p "$(dirname "$STATE")"; touch "$STATE"
paths(){
    if [ -n "$REPOS" ]; then for r in $REPOS; do [ -d "$r" ] && echo "$r" || echo "$HOME/repos/$r"; done; return; fi
    bash "$HERE/fleet-repos.sh" "$HOME_CTO"
}
slug(){ git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##'; }
SEEDED=0; [ -s "$STATE" ] && SEEDED=1
while :; do
    for p in $(paths); do
        s="$(slug "$p")"; [ -n "$s" ] || continue
        gh run list -R "$s" --limit 20 --json databaseId,workflowName,conclusion,headBranch,headSha,createdAt \
            -q '.[] | select(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out" or .conclusion=="startup_failure") | "\(.databaseId)\t\(.workflowName)\t\(.conclusion)\t\(.headBranch)\t\(.headSha[0:8])\t\(.createdAt)"' 2>/dev/null |
        while IFS=$'\t' read -r id wf concl br sha at; do
            [ -n "$id" ] || continue
            grep -qx "$s#$id" "$STATE" && continue
            echo "$s#$id" >> "$STATE"
            [ "$SEEDED" = 1 ] && echo "CI $concl: $(basename "$p") / $wf / $br ($sha) run $id at $at"
        done
    done
    SEEDED=1
    [ "$ONCE" = 1 ] && exit 0
    sleep "$INTERVAL"
done
