#!/usr/bin/env bash
# test-archive-worktree.sh — archive, verify, then remove; never remove on a failed archive. Offline.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/archive-worktree.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -4 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/aw.XXXXXX")"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
M="$W/main"; mkdir -p "$M"; git -C "$M" init -q; git -C "$M" config user.email t@t; git -C "$M" config user.name t
printf 'outputs/\ndata/\n.venv/\n.env\n' > "$M/.gitignore"; echo a > "$M/a.txt"; git -C "$M" add -A; git -C "$M" commit -qm init
mk(){ git -C "$M" worktree add -q "$W/$1" -b "$1" >/dev/null 2>&1; mkdir -p "$W/$1/outputs/run1" "$W/$1/.venv/lib"
  echo "result" > "$W/$1/outputs/run1/r.json"; echo "my notes" > "$W/$1/NOTES.md"; echo "SECRET=1" > "$W/$1/.env"; echo "-----BEGIN KEY" > "$W/$1/outputs/run1/client.pem"; echo "pkg" > "$W/$1/.venv/lib/x.py"; echo "edit" >> "$W/$1/a.txt"; }
mk wt1
OUT=$(bash "$X" "$M/../wt1" --dest "$W/arch" --dry-run 2>&1)
echo "$OUT" | grep -q "copy 2 file" && [ -d "$W/wt1" ] && [ ! -d "$W/arch" ] && ok "--dry-run plans 2 files and touches nothing" || fail "dry run" "$OUT"
OUT=$(bash "$X" "$W/wt1" --dest "$W/arch" --remove 2>&1); RC=$?
A=$(ls -d "$W"/arch/*/wt1 2>/dev/null)
[ $RC -eq 0 ] && [ ! -d "$W/wt1" ] && ok "archived, verified, then removed" || fail "rc=$RC" "$OUT"
[ -f "$A/files/NOTES.md" ] && [ -f "$A/files/outputs/run1/r.json" ] && ok "untracked note and allowlisted ignored output are in the archive" || fail "archive contents: $(find "$A" -type f | head)"
[ ! -e "$A/files/.env" ] && ok ".env (ignored, outside the allowlist) is not copied" || fail ".env copied"
[ ! -e "$A/files/outputs/run1/client.pem" ] && grep -qx "outputs/run1/client.pem" "$A/EXCLUDED.txt" && ok "a secret-shaped file INSIDE the allowlist is withheld and named in EXCLUDED.txt" || fail "pem: $(cat "$A/EXCLUDED.txt")"
[ ! -e "$A/files/.venv" ] && ok "an ignored venv outside the allowlist is not copied" || fail "venv copied"
grep -q "+edit" "$A/diff-HEAD.patch" && ok "uncommitted tracked change kept as diff-HEAD.patch" || fail "diff missing"
[ "$(stat -f %Lp "$A")" = "700" ] && ok "archive dir is owner-only (700)" || fail "perms $(stat -f %Lp "$A")"
mk wt2; mkdir -p "$W/ro"; chmod 500 "$W/ro"
OUT=$(bash "$X" "$W/wt2" --dest "$W/ro" --remove 2>&1); RC=$?
[ $RC -eq 4 ] && [ -d "$W/wt2" ] && ok "archive fails (read-only dest) -> exit 4, worktree KEPT" || fail "rc=$RC wt2 exists=$([ -d "$W/wt2" ] && echo y)" "$OUT"
OUT=$(bash "$X" "$M" --dest "$W/arch" --remove 2>&1); [ $? -eq 3 ] && [ -d "$M/.git" ] && ok "refuses the MAIN checkout" || fail "main checkout" "$OUT"
echo ""; echo "archive-worktree tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
