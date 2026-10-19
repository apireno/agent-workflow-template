#!/usr/bin/env bash
# test-pinned-worktree.sh — idempotent, sparse, refuses a moved pin, --from-pins. Offline.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/pinned-worktree.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -4 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/pin.XXXXXX")"; W="$(cd "$W" && pwd -P)"; trap 'rm -rf "$W"' EXIT
R="$W/acme-core"; mkdir -p "$R/src/eng" "$R/docs" "$R/big"; git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo e > "$R/src/eng/e.py"; echo d > "$R/docs/d.md"; echo b > "$R/big/blob"; git -C "$R" add -A; git -C "$R" commit -qm one; S1=$(git -C "$R" rev-parse HEAD)
echo e2 > "$R/src/eng/e.py"; git -C "$R" commit -qam two; S2=$(git -C "$R" rev-parse HEAD)
P=$(bash "$X" "$R" "${S1:0:9}" --paths src 2>/dev/null); RC=$?
[ $RC -eq 0 ] && [ "$P" = "$W/acme-core-wt-${S1:0:7}" ] && ok "created <repo>-wt-<short-sha>" || fail "create rc=$RC path=$P"
[ "$(git -C "$P" rev-parse HEAD)" = "$S1" ] && git -C "$P" symbolic-ref -q HEAD >/dev/null; [ $? -ne 0 ] && ok "detached at the pinned sha" || fail "not detached at S1"
[ -f "$P/src/eng/e.py" ] && [ ! -e "$P/big/blob" ] && ok "sparse: only the listed path checked out" || fail "sparse: $(ls "$P")"
OUT=$(bash "$X" "$R" "$S1" --paths src 2>&1 >/dev/null); [ $? -eq 0 ] && echo "$OUT" | grep -q "no-op" && ok "same pin again -> no-op" || fail "idempotent" "$OUT"
git -C "$P" checkout -q --detach "$S2" 2>/dev/null
OUT=$(bash "$X" "$R" "$S1" 2>&1 >/dev/null); [ $? -eq 3 ] && echo "$OUT" | grep -q "REFUSED" && ok "a moved pinned checkout is refused, not 'fixed'" || fail "moved" "$OUT"
mkdir -p "$W/proj/.claude"; printf -- '- repo: %s\n  sha: %s\n  paths: docs\n  why: test\n' "$R" "$S2" > "$W/proj/.claude/pins.yaml"
OUT=$(cd "$W/proj" && bash "$X" --from-pins 2>&1); [ $? -eq 0 ] && [ -f "$W/acme-core-wt-${S2:0:7}/docs/d.md" ] && [ ! -e "$W/acme-core-wt-${S2:0:7}/src" ] && ok "--from-pins creates every listed pin (sparse)" || fail "from-pins" "$OUT"
bash "$X" "$R" deadbeef >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown sha -> exit 2" || fail "bad sha"
echo ""; echo "pinned-worktree tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
