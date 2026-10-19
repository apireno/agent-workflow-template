#!/usr/bin/env bash
# pinned-worktree.sh — a read-only engine checkout at an exact commit, created once, found by name.
#
#   pinned-worktree.sh <repo> <sha> [--paths a,b,…]     -> prints the worktree path
#   pinned-worktree.sh --from-pins [<pins.yaml>]          -> ensures every pin listed (default ./.claude/pins.yaml)
#
# WHY. Projects measured a sibling engine at a fixed commit by hard-coding paths like
# `<repo>-wt-<sha>` in code and creating them by hand. Nobody could tell which were still needed:
# a census found 21 worktrees / 37 GB, and live ones were deleted by mistake. The convention now:
#   - every pin a project depends on is listed in ONE file, <project-repo>/.claude/pins.yaml:
#         - repo: acme-core            # registry name, or a path
#           sha: 466b5f694c…           # full or short
#           paths: src/acme_core, docs/contracts   # optional sparse checkout
#           why: the tuner measures this engine build
#   - code reads the path from there (or from this script's output), never a hard-coded string;
#   - reap-worktrees.sh refuses to remove anything a pins file names, and the hygiene report lists
#     `-wt-` worktrees no pins file names (retired pins, safe to reap).
#
# Behaviour: path = <repo-parent>/<repo-name>-wt-<short-sha>, DETACHED at <sha>. Same path at the same
# sha -> no-op (idempotent). Same path at a different commit -> refused (someone moved a pinned
# checkout; that is exactly the drift a pin exists to prevent). --paths -> sparse checkout of those.
# Exit: 0 ok · 2 usage · 3 refused (path exists at another commit / not a worktree of <repo>)
set -uo pipefail
resolve_repo(){ # _R in: name or path -> echo path
    if [ -d "$_R/.git" ] || [ -f "$_R/.git" ]; then (cd "$_R" && pwd -P); return; fi
    local home="${CTO_HOME:-}"; [ -z "$home" ] && [ -f "$HOME/.cto/home" ] && home="$(tr -d '[:space:]' < "$HOME/.cto/home")"
    if [ -n "$home" ] && [ -f "$home/.cto/projects.yaml" ]; then
        python3 - "$home/.cto/projects.yaml" "$_R" <<'PY'
import re,sys
for b in re.split(r'(?=- name:)', open(sys.argv[1]).read()):
    n=re.search(r'- name:\s*(\S+)',b); p=re.search(r'path:\s*(\S+)',b)
    if n and p and n.group(1)==sys.argv[2]: print(p.group(1)); break
PY
    fi
}
ensure(){ # in: _REPO _SHA _PATHS
    local repo full short wt cur
    _R="$_REPO"; repo="$(resolve_repo)"
    [ -n "$repo" ] && [ -d "$repo" ] || { echo "pinned-worktree: unknown repo '$_REPO' (not a path, not in the registry)" >&2; return 2; }
    full="$(git -C "$repo" rev-parse --verify --quiet "$_SHA^{commit}")" || { git -C "$repo" fetch -q origin "$_SHA" 2>/dev/null; full="$(git -C "$repo" rev-parse --verify --quiet "$_SHA^{commit}")"; } || { echo "pinned-worktree: $_SHA is not a commit in $repo" >&2; return 2; }
    short="${full:0:7}"; wt="$(dirname "$repo")/$(basename "$repo")-wt-$short"
    if [ -e "$wt" ]; then
        cur="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
        if [ "$cur" = "$full" ] && [ "$(cd "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)" = "$repo" ]; then
            echo "$wt"; echo "pinned-worktree: $wt already at ${full:0:12} (no-op)" >&2; return 0
        fi
        echo "pinned-worktree: REFUSED — $wt exists but is at ${cur:-<not a worktree of $repo>}, not the pinned ${full:0:12}." >&2
        echo "  A pinned checkout must not move. Find out who moved it before touching it (reap-worktrees.sh shows its references)." >&2
        return 3
    fi
    git -C "$repo" worktree add -q --detach --no-checkout "$wt" "$full" || return 2
    if [ -n "$_PATHS" ]; then
        git -C "$wt" sparse-checkout init --cone -q 2>/dev/null || git -C "$wt" sparse-checkout init --cone
        # shellcheck disable=SC2086
        git -C "$wt" sparse-checkout set $(printf '%s' "$_PATHS" | tr ',' ' ')
    fi
    git -C "$wt" checkout -q --detach "$full" || return 2
    echo "$wt"; echo "pinned-worktree: created $wt at ${full:0:12}$( [ -n "$_PATHS" ] && echo " (sparse: $_PATHS)")" >&2
}
if [ "${1:-}" = "--from-pins" ]; then
    F="${2:-.claude/pins.yaml}"; [ -f "$F" ] || { echo "pinned-worktree: no pins file at $F" >&2; exit 2; }
    RC=0
    while IFS=$'\t' read -r _REPO _SHA _PATHS; do
        [ -n "$_REPO" ] || continue
        ensure || RC=$?
    done < <(python3 - "$F" <<'PY'
import re,sys
cur={}; rows=[]
for raw in open(sys.argv[1]):
    line=raw.split("#",1)[0].rstrip()
    if not line.strip(): continue
    s=line.strip()
    if s.startswith("- "): cur={}; rows.append(cur); s=s[2:]
    if ":" in s and rows: k,v=s.split(":",1); cur[k.strip()]=v.strip().strip("'\"")
for r in rows:
    if r.get("repo") and r.get("sha"): print(f"{r['repo']}\t{r['sha']}\t{','.join(p.strip() for p in r.get('paths','').split(',') if p.strip())}")
PY
)
    exit $RC
fi
[ $# -ge 2 ] || { echo "usage: pinned-worktree.sh <repo> <sha> [--paths a,b] | --from-pins [<pins.yaml>]" >&2; exit 2; }
_REPO="$1"; _SHA="$2"; _PATHS=""; shift 2
while [ $# -gt 0 ]; do case "$1" in --paths) _PATHS="${2:-}"; shift ;; --paths=*) _PATHS="${1#--paths=}" ;; *) echo "pinned-worktree: unknown argument '$1'" >&2; exit 2 ;; esac; shift; done
ensure
