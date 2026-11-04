#!/usr/bin/env bash
# test-branch-census.sh — classification (merged / squash-merged / protected / live / stale), reap,
# archive, and the live-branch cap, against a local bare origin.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/branch-census.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -12 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/census.XXXXXX")"; W="$(cd "$W" && pwd -P)"; trap 'rm -rf "$W"' EXIT
git init -q --bare "$W/origin.git"; git clone -q "$W/origin.git" "$W/r" 2>/dev/null; R="$W/r"
gr(){ git -C "$R" -c core.hooksPath=/dev/null "$@"; }
gr config user.email t@t; gr config user.name t
echo a > "$R/a"; gr add a; gr commit -qm init; gr push -q origin HEAD:main; gr remote set-head origin main >/dev/null; gr branch -q -M main
mk(){ gr switch -q -c "$1" main; echo "$1" > "$R/$1.txt"; gr add "$1.txt"; gr commit -qm "$1" ${2:+--date="$2"}; gr push -q origin "$1"; gr switch -q main; }
mk merged-ff; gr merge -q --ff-only merged-ff
mk squashed; gr merge -q --squash squashed >/dev/null; gr commit -qm "squash of squashed"
gr push -q origin main
mk live1; mk live2; mk pinned
GIT_COMMITTER_DATE="2026-01-01T00:00:00" mk old 2026-01-01T00:00:00
mkdir -p "$R/.claude"; printf 'engines:\n  - branch: pinned\n' > "$R/.claude/pins.yaml"
gr worktree add -q "$W/wt-live1" live1 2>/dev/null

OUT=$(bash "$X" "$R" --max-live 10 2>&1); RC=$?
row(){ printf '%s\n' "$OUT" | grep -E "^$1 +$2 +[0-9]+d +$3\$" >/dev/null; }
[ $RC -eq 0 ] && ok "census runs (exit 0 under the cap)" || fail "census rc=$RC" "$OUT"
row local merged merged-ff && ok "ff-merged branch -> merged" || fail "merged-ff" "$OUT"
row local squash-merged squashed && row origin squash-merged squashed && ok "squash-merged branch recognised (local and origin) — git alone calls it unmerged" || fail "squashed" "$OUT"
row local protected live1 && ok "a branch checked out in a worktree is protected" || fail "checked-out" "$OUT"
row local protected pinned && ok "a branch named in .claude/pins.yaml is protected" || fail "pinned" "$OUT"
row local live live2 && ok "recent unmerged -> live" || fail "live2" "$OUT"
row local stale old && ok "old unmerged -> stale" || fail "old" "$OUT"
OUT=$(bash "$X" "$R" --max-live 1 2>&1); [ $? -eq 3 ] && echo "$OUT" | grep -q "OVER CAP — 2 unmerged branches > 1" && ok "over the cap -> exit 3 (live + stale count once per name; protected excluded)" || fail "cap" "$OUT"
printf 'max_live_branches: 5\n' > "$R/.claude/land.yaml"; OUT=$(bash "$X" "$R" 2>&1); [ $? -eq 0 ] && echo "$OUT" | grep -q "(cap 5)" && ok "cap read from .claude/land.yaml" || fail "land.yaml cap" "$OUT"
OUT=$(bash "$X" "$R" --reap --archive-stale --dry-run 2>&1); gr rev-parse -q --verify squashed >/dev/null && echo "$OUT" | grep -q "would:" && ok "--dry-run deletes nothing" || fail "dry" "$OUT"
OUT=$(bash "$X" "$R" --reap --archive-stale 2>&1)
! gr rev-parse -q --verify squashed >/dev/null && ! gr ls-remote --exit-code --heads origin squashed >/dev/null 2>&1 && ! gr rev-parse -q --verify merged-ff >/dev/null && ok "--reap deletes merged + squash-merged, local and origin" || fail "reap" "$OUT"
gr ls-remote --tags origin | grep -q "refs/tags/archive/old" && ! gr rev-parse -q --verify old >/dev/null && ok "--archive-stale tags archive/<name> on origin, then deletes" || fail "archive" "$OUT"
gr rev-parse -q --verify live1 >/dev/null && gr rev-parse -q --verify pinned >/dev/null && gr rev-parse -q --verify live2 >/dev/null && ok "protected and live branches untouched" || fail "kept" "$OUT"
echo ""; echo "branch-census tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
