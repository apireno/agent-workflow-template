#!/usr/bin/env bash
# test-next-bug-id.sh — fleet bug-id allocator, offline fixture (scratch CTO home + two repos).
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/next-bug-id.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/bugid.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/.cto" "$W/a/docs/backlog/bugs" "$W/b/docs/sprints/s1"
printf 'projects:\n  - name: a\n    path: %s/a\n  - name: b\n    path: %s/b\n' "$W" "$W" > "$W/home/.cto/projects.yaml"
echo "# BUG-041 — x" > "$W/a/docs/backlog/bugs/BUG-041-x.md"
echo "Filed BUG-057 in the dev-report; also a date-ish token BUG-20260919." > "$W/b/docs/sprints/s1/dev-report.md"
echo "$W/home" > "$W/b/.cto-path"
export CTO_HOME="$W/home"
[ "$(bash "$X" --peek)" = "BUG-058" ] && ok "seeds above the highest id cited in any repo's docs (057), ignoring a date-shaped token" || fail "seed: $(bash "$X" --peek)"
[ "$(bash "$X" --peek)" = "BUG-058" ] && ok "--peek consumes nothing" || fail "peek consumed"
[ "$(bash "$X")" = "BUG-058" ] && [ "$(bash "$X")" = "BUG-059" ] && ok "consecutive calls issue 058 then 059" || fail "sequence"
[ "$(bash "$X" --n 3 | tr '\n' ' ')" = "BUG-060 BUG-061 BUG-062 " ] && ok "--n 3 issues a block" || fail "--n"
echo "see BUG-100" > "$W/a/docs/backlog/bugs/hand.md"
[ "$(bash "$X")" = "BUG-101" ] && ok "an id typed by hand elsewhere is never re-issued (jumps past 100)" || fail "hand-typed id"
for i in $(seq 1 10); do bash "$X" > "$W/p$i" & done; wait
[ "$(cat "$W"/p* | sort -u | wc -l | tr -d ' ')" = "10" ] && ok "10 parallel calls -> 10 distinct ids (lock holds)" || fail "parallel collision: $(cat "$W"/p* | sort | uniq -d | tr '\n' ' ')"
( unset CTO_HOME; cd "$W/b" && [ "$(bash "$X" --peek)" = "BUG-112" ] ) && ok "a dev repo finds the home through .cto-path" || fail ".cto-path lookup: $( unset CTO_HOME; cd "$W/b"; bash "$X" --peek 2>&1)"
( unset CTO_HOME; cd "$W" && HOME="$W/nohome" bash "$X" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "no CTO home -> exit 2, nothing guessed" || fail "no-home exit"
echo ""; echo "next-bug-id tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
