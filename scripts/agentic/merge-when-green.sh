#!/usr/bin/env bash
# merge-when-green.sh — merge a PR only when its head is CURRENT and its checks are green; never
# otherwise. The PR-based landing path (land-lane.sh is the fast-forward one).
#
#   merge-when-green.sh <repo-path> <pr-number> [--method squash|merge|rebase] [--max-min N]
#                       [--grace-min N] [--no-gate] [--dry-run]
#
# Steps, each refusing with its own exit code (fleet report 2026-11-04):
#   1 STATE     gh pr view: open, base, head branch + sha. CONFLICTING -> exit 4 (no CI runs on a
#               conflicting PR, so waiting would only time out).
#   2 CURRENT   in the local checkout that has the PR head checked out: derived-artifact-gate.sh
#               --head --bytes and the project layer's landing checks. Not CURRENT -> exit 6. No
#               local checkout at the head sha -> exit 6 naming the command (--no-gate skips, logged
#               in the output; the CTO's call).
#   3 CHECKS    wait up to --max-min (default 240) for every non-advisory check to finish.
#               RED (fail/cancel) -> exit 1 · still pending at the deadline -> exit 3 ·
#               NO RUN (zero checks AND no queued/running workflow run for the head after
#               --grace-min, default 5) -> exit 5 — distinct from red: a push that produced no run
#               is a CI wiring fault, not a passing PR. A run queued behind a busy self-hosted
#               runner reports no checks yet; it counts as pending.
#               Advisory checks: names matching $MWG_ADVISORY_RE (default: advisory).
#   4 MERGE     gh pr merge --<method> --delete-branch (default squash); prints the method; verifies
#               the merge commit is on origin/<base>.
#   5 MOVE ON   after a squash, the lane branch is done (its commits are not ancestors of the base,
#               so git will never call it merged). A CLEAN local checkout of it is switched to the
#               base and the local branch deleted; a DIRTY one is left alone and the exact command
#               printed. pre-commit refuses further commits on a landed branch either way.
# Exit: 0 merged · 1 red · 2 usage · 3 timeout · 4 conflicting/not open · 5 no run · 6 not current
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO=""; PR=""; METHOD=squash; MAX=240; GRACE=5; NOGATE=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --method) METHOD="${2:-}"; shift ;; --max-min) MAX="${2:-}"; shift ;; --grace-min) GRACE="${2:-}"; shift ;;
        --no-gate) NOGATE=1 ;; --dry-run) DRY=1 ;;
        -*) echo "merge-when-green: unknown flag '$1'" >&2; exit 2 ;;
        *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$PR" ]; then PR="$1"; else echo "merge-when-green: extra argument '$1'" >&2; exit 2; fi ;;
    esac; shift
done
case "$METHOD" in squash|merge|rebase) ;; *) echo "merge-when-green: --method squash|merge|rebase" >&2; exit 2 ;; esac
[ -n "$REPO" ] && [ -n "$PR" ] && [ -d "$REPO" ] || { echo "usage: merge-when-green.sh <repo-path> <pr-number> [--method squash|merge|rebase] [--max-min N] [--grace-min N] [--no-gate] [--dry-run]" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"; NAME="$(basename "$REPO")"
say(){ echo "merge-when-green: $NAME #$PR $*"; }
ghr(){ (cd "$REPO" && gh "$@"); }

# 1 STATE
J="$(ghr pr view "$PR" --json state,mergeable,baseRefName,headRefName,headRefOid 2>/dev/null)" || { say "cannot read the PR (gh pr view failed)"; exit 4; }
f(){ printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"; }
STATE="$(f state)"; MG="$(f mergeable)"; BASE="$(f baseRefName)"; HEAD_BR="$(f headRefName)"; HEAD_SHA="$(f headRefOid)"
[ "$STATE" = OPEN ] || { say "is $STATE, not OPEN — nothing to merge"; exit 4; }
[ "$MG" = CONFLICTING ] && { say "CONFLICTING with $BASE — NOT merged (no CI runs on a conflicting PR). Merge $BASE into $HEAD_BR first."; exit 4; }
say "head $HEAD_BR @ ${HEAD_SHA:0:12} -> $BASE · method $METHOD"

# 2 CURRENT — find the checkout that has the head sha
CO=""
while read -r line; do
    case "$line" in worktree\ *) wt="${line#worktree }" ;; HEAD\ *) [ "${line#HEAD }" = "$HEAD_SHA" ] && CO="$wt" ;; esac
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null)
if [ "$NOGATE" = 1 ]; then say "CURRENT check SKIPPED (--no-gate)"
elif [ -z "$CO" ]; then
    say "NOT CHECKED — no local checkout is at the PR head ${HEAD_SHA:0:12}. Check out $HEAD_BR (git -C $REPO fetch origin $HEAD_BR && git -C $REPO switch $HEAD_BR), or pass --no-gate deliberately."; exit 6
else
    if [ -f "$CO/.claude/derived-artifacts.yaml" ]; then
        GOUT="$(bash "$HERE/derived-artifact-gate.sh" --head --bytes --repo "$CO" 2>&1)" || { say "NOT CURRENT — governed derived artifacts at the head:"; printf '%s\n' "$GOUT" | tail -12 | sed 's/^/  /'; exit 6; }
        say "derived artifacts CURRENT at the head ✓"
    fi
    if [ -x "$HERE/project-layer.sh" ]; then
        POUT="$(bash "$HERE/project-layer.sh" landing --repo "$CO" 2>&1)"; prc=$?
        [ -n "$POUT" ] && printf '%s\n' "$POUT" | sed 's/^/  /'
        [ $prc -eq 0 ] || { say "NOT CURRENT — a project landing check refused (above)"; exit 6; }
    fi
fi

# 3 CHECKS
ADV="${MWG_ADVISORY_RE:-advisory}"
START=$(date +%s); END=$(( START + MAX*60 )); GEND=$(( START + GRACE*60 ))
while :; do
    C="$(ghr pr checks "$PR" --json name,bucket 2>/dev/null || echo '[]')"
    V="$(printf '%s' "$C" | python3 -c '
import json,re,sys
try: cs=json.load(sys.stdin)
except Exception: cs=[]
cs=[c for c in cs if not re.search(sys.argv[1], c.get("name",""), re.I)]
b=[c.get("bucket","") for c in cs]
if not cs: print("none")
elif any(x in ("fail","cancel") for x in b): print("red:"+",".join(c["name"] for c in cs if c.get("bucket") in ("fail","cancel"))[:200])
elif any(x=="pending" for x in b): print("pending")
else: print("green")' "$ADV")"
    case "$V" in
        green) say "checks GREEN"; break ;;
        red:*) say "RED — not merged (${V#red:})"; exit 1 ;;
        none)
            # `gh pr checks` reports nothing until a job STARTS. A run that is queued behind a busy
            # self-hosted runner is a pending run, not a wiring fault (false NO RUN, 2026-11-05):
            # look at the workflow runs for the current head sha before calling it NO RUN.
            CUR="$(ghr pr view "$PR" --json headRefOid -q .headRefOid 2>/dev/null || echo "$HEAD_SHA")"
            Q="$(ghr run list --commit "$CUR" --json status -q '[.[]|select(.status!="completed")]|length' 2>/dev/null || echo 0)"
            if [ "${Q:-0}" -gt 0 ]; then
                [ "$(date +%s)" -ge "$END" ] && { say "TIMEOUT after ${MAX} min with runs queued — NOT merged"; exit 3; }
            elif [ "$(date +%s)" -ge "$GEND" ]; then
                say "NO RUN — zero checks and no queued run for ${CUR:0:12} after ${GRACE} min. The push produced no CI run: a wiring fault (workflow triggers, path filters, a disabled workflow), not a green PR. Not merged."; exit 5
            fi ;;
        pending) [ "$(date +%s)" -ge "$END" ] && { say "TIMEOUT after ${MAX} min with checks pending — NOT merged"; exit 3; } ;;
    esac
    sleep "${MWG_POLL:-30}"
done

# 4 MERGE
if [ "$DRY" = 1 ]; then say "DRY RUN — would: gh pr merge $PR --$METHOD --delete-branch"; exit 0; fi
for try in 1 2; do ghr pr merge "$PR" --"$METHOD" --delete-branch >/dev/null 2>&1; sleep "${MWG_SETTLE:-5}"
    M="$(ghr pr view "$PR" --json state,mergeCommit -q '.state+" "+(.mergeCommit.oid // "")' 2>/dev/null)"; [ "${M%% *}" = MERGED ] && break; done
[ "${M%% *}" = MERGED ] || { say "NOT MERGED after two attempts: $M"; exit 1; }
MC="${M#* }"; git -C "$REPO" fetch -q --prune origin
git -C "$REPO" merge-base --is-ancestor "$MC" "origin/$BASE" 2>/dev/null || { say "merged per GitHub, but ${MC:0:12} is not on origin/$BASE locally yet — verify"; exit 1; }
say "MERGED (${METHOD}) as ${MC:0:12}, on origin/$BASE ✓"

# 5 MOVE ON
if [ "$METHOD" != merge ] && [ -n "$CO" ]; then
    if [ -z "$(git -C "$CO" status --porcelain --untracked-files=no)" ]; then
        git -C "$CO" switch -q --detach "origin/$BASE" 2>/dev/null && git -C "$CO" branch -D "$HEAD_BR" >/dev/null 2>&1
        if [ "$CO" = "$REPO" ]; then git -C "$CO" switch -q "$BASE" 2>/dev/null && git -C "$CO" merge -q --ff-only "origin/$BASE" 2>/dev/null; fi
        say "lane checkout $CO moved off the landed branch (now at origin/$BASE); start the next sprint with: git -C $CO switch -c <new-branch> origin/$BASE"
    else
        say "lane checkout $CO has uncommitted changes — left as is. The branch is landed; move the work with: git -C $CO switch -c <new-branch> origin/$BASE"
    fi
fi
exit 0
