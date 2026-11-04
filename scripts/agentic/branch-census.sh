#!/usr/bin/env bash
# branch-census.sh — every branch in a repo, classified; reap what is done; cap what is live.
#
#   branch-census.sh <repo-path> [--reap] [--archive-stale] [--max-live N] [--stale-days N] [--dry-run]
#
# WHY (fleet report 2026-11-04): 151 branches across six repos, 115 of them PR branches already
# squash-merged. Git never calls a squash-merged branch merged — its commits are not ancestors of the
# base — so they looked open and nobody saw them as done. A lane that kept committing on one opened a
# PR that conflicted with its own squashed copy.
#
# Classes (local branches and origin/* branches, base excluded):
#   merged          the branch tip is an ancestor of origin/<base>
#   squash-merged   merging it into origin/<base> changes nothing (merge-tree result == base tree):
#                   its content is already on the base, however it got there
#   protected       checked out in a worktree, named in .claude/pins.yaml, or listed in
#                   .claude/keep-branches (one name per line) — never reaped (pinned worktrees are
#                   measurement provenance; reaping them breaks replays)
#   live            unmerged, last commit within --stale-days (default 21)
#   stale           unmerged, older than that
#
#   --reap            delete merged + squash-merged branches, local and on origin (never protected)
#   --archive-stale   for stale ones: tag archive/<name> at the tip (pushed), then delete the branch
#   --max-live N      exit 3 when live + stale branches exceed N (default: .claude/land.yaml
#                     `max_live_branches:`, else 2). /handoff runs this before opening a new lane.
# Exit: 0 ok · 2 usage · 3 over the cap
set -uo pipefail
REPO=""; REAP=0; ARCH=0; MAXLIVE=""; STALE_DAYS=21; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in --reap) REAP=1 ;; --archive-stale) ARCH=1 ;; --max-live) MAXLIVE="${2:-}"; shift ;;
        --stale-days) STALE_DAYS="${2:-21}"; shift ;; --dry-run) DRY=1 ;;
        -*) echo "branch-census: unknown flag '$1'" >&2; exit 2 ;; *) REPO="$1" ;; esac; shift
done
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "usage: branch-census.sh <repo-path> [--reap] [--archive-stale] [--max-live N] [--stale-days N] [--dry-run]" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"; g(){ git -C "$REPO" "$@"; }
g fetch -q --prune origin 2>/dev/null || true
BASE="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; BASE="${BASE#origin/}"
[ -n "$BASE" ] || { echo "branch-census: origin/HEAD unset in $REPO (git -C $REPO remote set-head origin --auto)" >&2; exit 2; }
if [ -z "$MAXLIVE" ]; then MAXLIVE="$(sed -n 's/^max_live_branches:[[:space:]]*\([0-9]*\).*/\1/p' "$REPO/.claude/land.yaml" 2>/dev/null | head -1)"; MAXLIVE="${MAXLIVE:-2}"; fi
BT="$(g rev-parse "origin/$BASE^{tree}")"; NOW=$(date +%s)
CHECKED="$(g worktree list --porcelain | sed -n 's#^branch refs/heads/##p')"
PINS="$(cat "$REPO/.claude/pins.yaml" "$REPO/.claude/keep-branches" 2>/dev/null)"
run(){ if [ "$DRY" = 1 ]; then echo "    would: $*"; else "$@"; fi; }

classify(){ # <ref> <name>
    local ref="$1" name="$2" t age
    if printf '%s\n' "$CHECKED" | grep -qxF "$name" || { [ -n "$PINS" ] && printf '%s' "$PINS" | grep -qwF -- "$name"; }; then echo protected; return; fi
    if g merge-base --is-ancestor "$ref" "origin/$BASE" 2>/dev/null; then echo merged; return; fi
    t="$(g merge-tree --write-tree "origin/$BASE" "$ref" 2>/dev/null | head -1)"
    [ "$t" = "$BT" ] && { echo squash-merged; return; }
    age=$(( (NOW - $(g log -1 --format=%ct "$ref")) / 86400 ))
    [ "$age" -gt "$STALE_DAYS" ] && echo stale || echo live
}
printf '%-8s %-14s %-5s %s\n' WHERE CLASS AGE BRANCH
LIVE=0; declare -a TODO
seen=""
for spec in $(g for-each-ref --format='%(refname)' refs/heads refs/remotes/origin); do
    case "$spec" in refs/heads/*) where=local; name="${spec#refs/heads/}" ;; *) where=origin; name="${spec#refs/remotes/origin/}" ;; esac
    [ "$name" = "$BASE" ] || [ "$name" = HEAD ] && continue
    cls="$(classify "$spec" "$name")"; age=$(( (NOW - $(g log -1 --format=%ct "$spec")) / 86400 ))
    printf '%-8s %-14s %-5s %s\n' "$where" "$cls" "${age}d" "$name"
    case "$cls" in live|stale) case " $seen " in *" $name "*) ;; *) LIVE=$((LIVE+1)); seen="$seen $name" ;; esac ;; esac
    TODO+=("$where|$cls|$name")
done
echo "branch-census: $(basename "$REPO") — base $BASE · $LIVE unmerged branch(es) (cap $MAXLIVE)"
if [ "$REAP" = 1 ] || [ "$ARCH" = 1 ]; then
    for e in "${TODO[@]:-}"; do
        [ -n "$e" ] || continue
        where="${e%%|*}"; rest="${e#*|}"; cls="${rest%%|*}"; name="${rest#*|}"
        case "$cls" in
            merged|squash-merged) [ "$REAP" = 1 ] || continue
                if [ "$where" = local ]; then run g branch -D "$name" >/dev/null && echo "  reaped local $name ($cls)"
                else run env LAND_LANE=1 git -C "$REPO" push -q origin --delete "$name" && echo "  reaped origin/$name ($cls)"; fi ;;
            stale) [ "$ARCH" = 1 ] || continue
                ref="$name"; [ "$where" = origin ] && ref="origin/$name"
                if ! g rev-parse -q --verify "refs/tags/archive/$name" >/dev/null; then
                    run g tag "archive/$name" "$ref" && run env LAND_LANE=1 git -C "$REPO" push -q origin "refs/tags/archive/$name"
                fi
                if [ "$where" = local ]; then run g branch -D "$name" >/dev/null; else run env LAND_LANE=1 git -C "$REPO" push -q origin --delete "$name"; fi
                echo "  archived $where $name -> tag archive/$name" ;;
        esac
    done
fi
if [ "$LIVE" -gt "$MAXLIVE" ]; then
    echo "branch-census: OVER CAP — $LIVE unmerged branches > $MAXLIVE. Land, reap (--reap), archive (--archive-stale) or keep deliberately (.claude/keep-branches) before opening another lane."
    exit 3
fi
exit 0
