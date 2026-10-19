#!/usr/bin/env bash
# test-reap-worktrees.sh — reap only merged, clean, unreferenced worktrees; refuse every live
# reference by name. Offline fixture with a local bare "origin". (LANE and SESSION are exercised
# against live transcripts by the operator; a fixture cannot fake a running Claude session.)
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/reap-worktrees.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -8 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/reap.XXXXXX")"; W="$(cd "$W" && pwd -P)"; SLP=""
trap '[ -n "$SLP" ] && kill $SLP 2>/dev/null; rm -rf "$W"' EXIT
M="$W/acme-x"; git init -q --bare "$W/origin.git"; git clone -q "$W/origin.git" "$M" 2>/dev/null
git -C "$M" config user.email t@t; git -C "$M" config user.name t
echo a > "$M/a"; git -C "$M" add -A; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main 2>/dev/null
git -C "$M" remote set-head origin main >/dev/null 2>&1
wt(){ git -C "$M" worktree add -q "$W/acme-x-wt-$1" -b "wt-$1" >/dev/null 2>&1; }
wt done; wt busy; wt pinned; wt manifest; wt unmerged; wt dirty
echo b > "$W/acme-x-wt-unmerged/b"; git -C "$W/acme-x-wt-unmerged" add -A; git -C "$W/acme-x-wt-unmerged" commit -qm b
echo edit >> "$W/acme-x-wt-dirty/a"
mkdir -p "$M/.claude" "$W/data/run1"; printf -- '- repo: acme-x\n  sha: abc\n  path: %s/acme-x-wt-pinned\n' "$W" > "$M/.claude/pins.yaml"
printf '{"engine_path": "%s/acme-x-wt-manifest"}\n' "$W" > "$W/data/run1/records.json"
( cd "$W/acme-x-wt-busy" && exec sleep 60 ) & SLP=$!
sleep 1
OUT=$(CTO_HOME= HOME="$W/h" bash "$X" "$M" --data-root "$W/data" --archive-root "$W/arch" 2>&1)
row(){ printf '%s\n' "$OUT" | grep "acme-x-wt-$1 "; }
row done | grep -q '^REAPABLE' && ok "merged + clean + unreferenced -> REAPABLE" || fail "done" "$OUT"
row busy | grep -q 'KEEP.*PROCESS cwd' && ok "a process cwd'd into it -> KEEP (PROCESS)" || fail "busy" "$OUT"
row pinned | grep -q 'KEEP.*PIN .*pins.yaml' && ok "named in .claude/pins.yaml -> KEEP (PIN)" || fail "pinned" "$OUT"
row manifest | grep -q 'KEEP.*MANIFEST .*records.json' && ok "named in a data manifest -> KEEP (MANIFEST)" || fail "manifest" "$OUT"
row unmerged | grep -q 'KEEP.*not merged' && ok "unmerged -> KEEP" || fail "unmerged" "$OUT"
row dirty | grep -q 'KEEP.*1 uncommitted edit' && ok "uncommitted edit -> KEEP" || fail "dirty" "$OUT"
[ -d "$W/acme-x-wt-done" ] && ok "report-only removes nothing" || fail "report removed something"
CTO_HOME= HOME="$W/h" bash "$X" "$M" --worktree "$W/acme-x-wt-busy" --data-root "$W/data" >/dev/null 2>&1; [ $? -eq 3 ] && ok "--worktree on a live one exits 3" || fail "--worktree exit"
OUT=$(CTO_HOME= HOME="$W/h" bash "$X" "$M" --reap --data-root "$W/data" --archive-root "$W/arch" 2>&1)
[ ! -d "$W/acme-x-wt-done" ] && ls "$W"/arch/*/acme-x-wt-done/MANIFEST.sha256 >/dev/null 2>&1 && ok "--reap archived and removed ONLY the reapable one" || fail "reap" "$OUT"
for k in busy pinned manifest unmerged dirty; do [ -d "$W/acme-x-wt-$k" ] || fail "--reap removed a KEEP worktree ($k)"; done; ok "every KEEP worktree is still there"
echo ""; echo "reap-worktrees tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
