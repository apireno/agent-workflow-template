#!/usr/bin/env bash
# land-lane.sh — land an ACCEPTED sprint: the hygiene steps that used to live in memory (ADR-003).
#
#   land-lane.sh <sprint-dir> [--dry-run] [--allow-red "<reason>"] [--ci-wait <min>] [--no-reap]
#
# WHY. A fleet audit found ~2 months of work never pushed, 103 abandoned worktrees, 300+ merged
# branches never deleted, a repo whose de-facto main was a feature branch, and CI red with nobody
# aware because nothing was pushed for it to run on. Every step below lived in a persona rule or in
# someone's head. On GitHub Free there is no server-side gate, so this script is the gate.
#
# Called by /sprint-accept after an APPROVED decision; safe to re-run (it resumes from what is
# already true). Any refusal stops before the next step and reports `landing: INCOMPLETE at <step>`.
#   1 RESOLVE   lane = branch checked out where the sprint dir lives; base = what origin/HEAD names.
#               Refuse: origin/HEAD unset · lane == base · detached HEAD · uncommitted tracked
#               changes outside the sprint dir.
#   2 COMMIT    the sprint dir's own artifacts (decision file included) — a scoped `git add` of that
#               dir only, so the decision lands WITH the work. Nothing else is ever added.
#   3 CONTAINS  `git fetch`; refuse unless origin/<base> is an ancestor of the lane; list what is missing.
#   4 CI        push the lane branch; if the repo has .github/workflows, wait (--ci-wait, default 20)
#               for the run on the lane's HEAD sha. Red / cancelled / missing / no `gh` -> refuse,
#               unless --allow-red "<reason>": the reason goes into the decision file (step 2 commits
#               it) and into <data-root>/land-overrides.log (outside the repo, mode 600).
#   5 LAND      fast-forward ONLY: `git push origin <sha>:refs/heads/<base>` (never --force),
#               with LAND_LANE=1 so the pre-push hook lets it through. Rejected -> INCOMPLETE.
#   6 TAG       annotated `sprint/<slug>` at the landed sha (message: decision file + verdict); pushed.
#   7 DELETE    the lane branch on origin, after ancestry confirms it landed.
#   8 REAP      a linked lane worktree: archive-worktree.sh (archive, sha256-verify, remove), then the
#               local branch. Skipped with --no-reap, or when the main checkout IS the lane.
# Every run appends one row to <main-repo>/.claude/landings.log.
# Exit: 0 landed (or nothing left to do) · 2 usage · 3 refused / incomplete
set -uo pipefail
DIR=""; DRY=0; ALLOW_RED=""; CI_WAIT=20; REAP=1
while [ $# -gt 0 ]; do
    case "$1" in --dry-run) DRY=1 ;; --allow-red) ALLOW_RED="${2:-}"; shift ;; --allow-red=*) ALLOW_RED="${1#--allow-red=}" ;;
        --ci-wait) CI_WAIT="${2:-20}"; shift ;; --no-reap) REAP=0 ;;
        -*) echo "land-lane: unknown flag '$1'" >&2; exit 2 ;; *) [ -z "$DIR" ] && DIR="$1" || { echo "land-lane: extra argument '$1'" >&2; exit 2; } ;; esac; shift
done
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: land-lane.sh <sprint-dir> [--dry-run] [--allow-red \"<reason>\"] [--ci-wait <min>] [--no-reap]" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd -P)"; HERE="$(cd "$(dirname "$0")" && pwd -P)"
TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || { echo "land-lane: $DIR is not in a git repo" >&2; exit 2; }
MAIN="$(cd "$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"
SLUG="$(basename "$DIR")"; SLUG="${SLUG#sprint-}"
REL="${DIR#"$TOP"/}"
HOME_CTO="${CTO_HOME:-}"; [ -z "$HOME_CTO" ] && [ -f "$MAIN/.cto-path" ] && HOME_CTO="$(tr -d '[:space:]' < "$MAIN/.cto-path")"
[ -z "$HOME_CTO" ] && [ -f "$HOME/.cto/home" ] && HOME_CTO="$(tr -d '[:space:]' < "$HOME/.cto/home")"
PROJECT="$(basename "${HOME_CTO:-$MAIN}")"; PROJECT="${PROJECT%-cto}"; DATA="${LAND_DATA_ROOT:-$HOME/$PROJECT-data}"
LOG="$MAIN/.claude/landings.log"; mkdir -p "$MAIN/.claude"
STEP="resolve"; LANE=""; BASE=""; SHA=""
say(){ echo "land-lane: $*"; }
stop(){ say "landing: INCOMPLETE at $STEP — $*"; [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\tINCOMPLETE\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SLUG" "$LANE" "$BASE" "${SHA:-}" "$STEP" "$*" >> "$LOG"; exit 3; }
run(){ if [ "$DRY" = 1 ]; then say "  would: $*"; else "$@"; fi; }
g(){ git -C "$TOP" "$@"; }

# 1 RESOLVE
BASE="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; BASE="${BASE#origin/}"
[ -n "$BASE" ] || stop "origin/HEAD is not set. Fix once with: git -C $TOP remote set-head origin --auto"
LANE="$(g symbolic-ref --quiet --short HEAD 2>/dev/null)" || stop "detached HEAD in $TOP — a lane is a branch"
[ "$LANE" != "$BASE" ] || stop "the sprint dir is on '$BASE' itself; there is no lane branch to land"
OUTSIDE="$(g status --porcelain --untracked-files=no | awk -v r="$REL" '{p=substr($0,4); if (index(p, r)!=1) print p}')"
[ -z "$OUTSIDE" ] || stop "uncommitted tracked changes outside the sprint dir — commit or discard them first: $(printf '%s ' $OUTSIDE | cut -c1-200)"
say "lane '$LANE' -> base '$BASE' · sprint $SLUG · repo $TOP$( [ "$TOP" != "$MAIN" ] && echo " (worktree of $MAIN)")"
[ "$DRY" = 1 ] && say "DRY RUN — nothing is pushed, committed, tagged, deleted or removed."

# 2 COMMIT the sprint dir (scoped) — the decision lands with the work
STEP="commit"
DEC="$(ls -t "$DIR"/cto-decision-*.md 2>/dev/null | head -1)"
[ -n "$DEC" ] || stop "no cto-decision-*.md in the sprint dir — /sprint-accept writes it before landing"
# The verdict LINE first ("Decision: X" / "Verdict: X", bold or not); only then the first verdict
# word anywhere — reasoning that mentions an earlier REJECTED must not be read as the verdict.
VERDICT="$(grep -m1 -iE '^[#>* _-]*(decision|verdict)[* _]*:' "$DEC" | grep -oE 'APPROVED(-WITH-CONDITIONS)?|REJECTED[-A-Z]*|ESCALATE[-A-Z]*' | head -1)"
[ -n "$VERDICT" ] || VERDICT="$(grep -m1 -oE 'APPROVED(-WITH-CONDITIONS)?|REJECTED[-A-Z]*|ESCALATE[-A-Z]*' "$DEC" || echo unknown)"
case "$VERDICT" in APPROVED|APPROVED-WITH-CONDITIONS) : ;; *) stop "the decision ($DEC) is '$VERDICT', not APPROVED — nothing lands" ;; esac
if [ -n "$ALLOW_RED" ] && ! grep -q "CI override:" "$DEC"; then
    run sh -c "printf '\n**CI override:** %s (land-lane --allow-red, %s)\n' \"\$1\" \"\$2\" >> \"\$3\"" _ "$ALLOW_RED" "$(date -u +%FT%TZ)" "$DEC"
fi
if [ -n "$(g status --porcelain -- "$REL")" ]; then
    run g add -- "$REL"
    run g -c core.hooksPath=/dev/null commit -q -m "sprint $SLUG: accepted ($VERDICT) — sprint artifacts" -- "$REL"
    say "committed the sprint dir's artifacts (scoped to $REL)"
fi
SHA="$(g rev-parse HEAD)"

# 3 CONTAINS BASE
STEP="contains-base"
run g fetch -q origin || stop "git fetch failed"
if ! g merge-base --is-ancestor "origin/$BASE" "$SHA" 2>/dev/null; then
    MISSING="$(g log --oneline "$SHA..origin/$BASE" | head -10)"
    stop "the lane does not contain origin/$BASE. Merge or rebase $BASE into '$LANE' first. Missing:
$MISSING"
fi
say "lane contains origin/$BASE ✓"

# 4 CI on the lane's HEAD sha
STEP="ci"
run env LAND_LANE=0 git -C "$TOP" push -q origin "$LANE" || stop "could not push the lane branch '$LANE'"
CI="no-ci"
if [ -n "$(g ls-tree --name-only "$SHA" .github/workflows/ 2>/dev/null)" ]; then
    if ! command -v gh >/dev/null 2>&1; then CI="unknown (gh not installed)"
    elif [ "$DRY" = 1 ]; then CI="(dry run: would wait up to ${CI_WAIT} min for the run on ${SHA:0:12})"
    else
        DEADLINE=$(( $(date +%s) + CI_WAIT*60 )); CI="missing"
        while :; do
            J="$(cd "$TOP" && gh run list --commit "$SHA" --limit 5 --json status,conclusion 2>/dev/null || echo '[]')"
            CI="$(printf '%s' "$J" | python3 -c '
import json,sys
r=json.load(sys.stdin)
if not r: print("missing")
elif any(x.get("status")!="completed" for x in r): print("running")
else: print("success" if all(x.get("conclusion") in ("success","skipped","neutral") for x in r) else "red:"+",".join(sorted({x.get("conclusion") or "?" for x in r})))')"
            # Any FINISHED result (success or red) ends the wait at once; only "running" (and a run that
            # has not appeared yet) keeps polling, until the deadline.
            case "$CI" in
                running|missing)
                    [ "$(date +%s)" -ge "$DEADLINE" ] && { CI="timed out after ${CI_WAIT} min (still $CI)"; break; }
                    sleep "${LAND_CI_POLL:-15}" ;;
                *) break ;;
            esac
        done
    fi
fi
case "$CI" in
    success|no-ci|"(dry run"*) say "CI: $CI" ;;
    *)  if [ -n "$ALLOW_RED" ]; then
            say "CI: $CI — OVERRIDDEN: $ALLOW_RED"
            if [ "$DRY" = 0 ]; then mkdir -p "$DATA"; printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SLUG" "$SHA" "$CI" "$ALLOW_RED" >> "$DATA/land-overrides.log"; chmod 600 "$DATA/land-overrides.log"; fi
        else stop "CI on ${SHA:0:12} is '$CI'. Fix it, or land deliberately with --allow-red \"<reason>\" (recorded in the decision and the override log)"; fi ;;
esac

# 5 LAND (fast-forward only)
STEP="land"
if g merge-base --is-ancestor "$SHA" "origin/$BASE" 2>/dev/null; then say "already landed: origin/$BASE contains ${SHA:0:12}"
else
    run env LAND_LANE=1 git -C "$TOP" push -q origin "$SHA:refs/heads/$BASE" || stop "push to '$BASE' was rejected (it moved since step 3?). Re-run /sprint-accept --land to re-check and retry. Branch and worktree are untouched."
    say "landed ${SHA:0:12} on origin/$BASE (fast-forward) ✓"
fi

# 6 TAG
STEP="tag"
TAG="sprint/$SLUG"
if g rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then say "tag $TAG exists"
else run g -c core.hooksPath=/dev/null tag -a "$TAG" "$SHA" -m "sprint $SLUG landed on $BASE — decision: ${DEC#"$TOP"/} ($VERDICT)$( [ -n "$ALLOW_RED" ] && echo "; CI override: $ALLOW_RED")"; fi
run env LAND_LANE=1 git -C "$TOP" push -q origin "refs/tags/$TAG" || stop "could not push tag $TAG"
say "tagged $TAG ✓"

# 7 DELETE the lane branch on origin
STEP="delete-branch"
[ "$DRY" = 1 ] || g fetch -q origin
if [ "$DRY" = 0 ] && ! g merge-base --is-ancestor "$SHA" "origin/$BASE"; then stop "origin/$BASE does not contain ${SHA:0:12} after landing — branch kept"; fi
if g ls-remote --exit-code --heads origin "$LANE" >/dev/null 2>&1; then run g push -q origin --delete "$LANE" || stop "could not delete origin/$LANE"; fi
say "deleted origin/$LANE ✓"

# 8 REAP the lane worktree, then the local branch
STEP="reap"
if [ "$TOP" != "$MAIN" ] && [ "$REAP" = 1 ]; then
    if [ "$DRY" = 1 ]; then bash "$HERE/archive-worktree.sh" "$TOP" --dest "$DATA/wt-archive" --dry-run | sed 's/^/  /'
    else
        cd "$MAIN" || true
        bash "$HERE/archive-worktree.sh" "$TOP" --dest "$DATA/wt-archive" --remove || stop "archive/verify failed — the worktree is KEPT"
        git -C "$MAIN" branch -D "$LANE" >/dev/null 2>&1 && say "deleted local branch $LANE ✓"
    fi
elif [ "$TOP" = "$MAIN" ]; then
    say "the lane is the main checkout — switching it back to $BASE"
    run g checkout -q "$BASE" && run g merge -q --ff-only "origin/$BASE" && run g branch -D "$LANE" >/dev/null
else say "worktree kept (--no-reap); local branch kept (it is checked out there)"; fi

[ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\tCOMPLETE\t-\t%s\n' "$(date -u +%FT%TZ)" "$SLUG" "$LANE" "$BASE" "$SHA" "CI=$CI" >> "$LOG"
say "landing: $( [ "$DRY" = 1 ] && echo 'DRY RUN OK' || echo COMPLETE) — sprint/$SLUG at ${SHA:0:12} on $BASE"
exit 0
