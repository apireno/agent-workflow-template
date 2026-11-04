#!/usr/bin/env bash
# test-merge-when-green.sh — the PR landing path against a local bare origin and a stub `gh`.
# Covers: conflicting refused · NO RUN distinct from red · red · advisory checks ignored · timeout ·
# not CURRENT (gate / project check / no checkout at the head) · green merge, method printed,
# clean lane checkout moved off the landed branch · dirty checkout left alone with the command.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/merge-when-green.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -6 | sed 's/^/       | /'; return 0; }
W0="$(mktemp -d "${TMPDIR:-/tmp}/mwg.XXXXXX")"; W0="$(cd "$W0" && pwd -P)"; trap 'rm -rf "$W0"' EXIT
export HOME="$W0/home"; mkdir -p "$HOME" "$W0/bin"
export MWG_POLL=0 MWG_SETTLE=0
cat > "$W0/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: pr view / pr checks / pr merge, driven by $STUB_DIR files
D="$STUB_DIR"
case "$1 $2" in
  "pr view")
    if printf '%s ' "$@" | grep -q -- '-q'; then cat "$D/merged" 2>/dev/null || echo "OPEN "; exit 0; fi
    printf '{"state":"%s","mergeable":"%s","baseRefName":"main","headRefName":"lane-s1","headRefOid":"%s"}\n' \
      "$(cat "$D/state" 2>/dev/null || echo OPEN)" "$(cat "$D/mergeable" 2>/dev/null || echo MERGEABLE)" "$(cat "$D/head")" ;;
  "pr checks") cat "$D/checks" 2>/dev/null || echo '[]' ;;
  "pr merge")
    ( cd "$STUB_REPO" && git -c core.hooksPath=/dev/null push -q origin "$(cat "$D/head"):refs/heads/main" ) >/dev/null 2>&1
    echo "MERGED $(cat "$D/head")" > "$D/merged" ;;
esac
STUB
chmod +x "$W0/bin/gh"; export PATH="$W0/bin:$PATH"
setup(){ # fresh origin + main checkout on a lane branch at the PR head
  W="$W0/$1"; mkdir -p "$W/stub"; git init -q --bare "$W/origin.git"; git clone -q "$W/origin.git" "$W/acme-x" 2>/dev/null
  R="$W/acme-x"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  echo a > "$R/a"; git -C "$R" add a; git -C "$R" commit -qm init; git -C "$R" push -q origin HEAD:main 2>/dev/null; git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" switch -q -c lane-s1; echo f > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm feature; git -C "$R" push -q -u origin lane-s1 2>/dev/null
  git -C "$R" rev-parse HEAD > "$W/stub/head"; export STUB_DIR="$W/stub" STUB_REPO="$R" CTO_HOME="$W0/nohome"
}
checks(){ printf '%s' "$1" > "$STUB_DIR/checks"; }

echo "== refusals before CI =="
setup conflict; echo CONFLICTING > "$STUB_DIR/mergeable"
OUT=$(bash "$X" "$R" 7 2>&1); [ $? -eq 4 ] && echo "$OUT" | grep -q CONFLICTING && ok "conflicting PR refused (exit 4) before waiting" || fail "conflict" "$OUT"
setup nocheckout; git -C "$R" switch -q main 2>/dev/null || git -C "$R" switch -q -c main origin/main
OUT=$(bash "$X" "$R" 7 2>&1); [ $? -eq 6 ] && echo "$OUT" | grep -q "no local checkout is at the PR head" && ok "no checkout at the head -> NOT CHECKED (exit 6), with the command" || fail "no checkout" "$OUT"
setup gate; mkdir -p "$R/.claude"; printf 'artifacts:\n  - name: g\n    path: docs/g/\n    generator: scripts/none.py\n' > "$R/.claude/derived-artifacts.yaml"
OUT=$(bash "$X" "$R" 7 2>&1); [ $? -eq 6 ] && echo "$OUT" | grep -q "NOT CURRENT" && echo "$OUT" | grep -q NO-GENERATOR && ok "stale/ungenerated artifacts at the head -> NOT CURRENT (exit 6)" || fail "gate" "$OUT"
setup proj; H="$W/acme-cto"; mkdir -p "$H/.git" "$H/.cto/project/checks/landing"
printf '#!/bin/sh\necho lexicon: 2 closed-lane terms; exit 1\n' > "$H/.cto/project/checks/landing/lex.sh"; chmod +x "$H/.cto/project/checks/landing/lex.sh"
OUT=$(CTO_HOME="$H" bash "$X" "$R" 7 2>&1); [ $? -eq 6 ] && echo "$OUT" | grep -q "lex.sh\] REFUSED" && ok "a failing project landing check -> NOT CURRENT (exit 6)" || fail "project check" "$OUT"

echo "== checks =="
setup norun; checks '[]'
OUT=$(bash "$X" "$R" 7 --grace-min 0 2>&1); [ $? -eq 5 ] && echo "$OUT" | grep -q "NO RUN" && ok "zero checks -> NO RUN (exit 5), distinct from red" || fail "no run" "$OUT"
setup red; checks '[{"name":"unit","bucket":"pass"},{"name":"lint","bucket":"fail"}]'
OUT=$(bash "$X" "$R" 7 2>&1); [ $? -eq 1 ] && echo "$OUT" | grep -q "RED.*lint" && ok "a failing check -> RED (exit 1), named" || fail "red" "$OUT"
setup adv; checks '[{"name":"unit","bucket":"pass"},{"name":"perf (advisory)","bucket":"fail"}]'
OUT=$(bash "$X" "$R" 7 --dry-run 2>&1); [ $? -eq 0 ] && echo "$OUT" | grep -q "checks GREEN" && ok "an advisory check's failure does not block" || fail "advisory" "$OUT"
setup slow; checks '[{"name":"unit","bucket":"pending"}]'
OUT=$(bash "$X" "$R" 7 --max-min 0 2>&1); [ $? -eq 3 ] && echo "$OUT" | grep -q TIMEOUT && ok "pending at the deadline -> TIMEOUT (exit 3), not merged" || fail "timeout" "$OUT"

echo "== merge and move on =="
setup green; checks '[{"name":"unit","bucket":"pass"}]'
OUT=$(bash "$X" "$R" 7 2>&1); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "MERGED (squash)" && ok "green -> merged, method printed, verified on origin/main" || fail "merge rc=$RC" "$OUT"
[ "$(git -C "$R" symbolic-ref --short HEAD 2>/dev/null)" = main ] && ! git -C "$R" rev-parse -q --verify lane-s1 >/dev/null && ok "clean lane checkout moved to main; landed branch deleted locally" || fail "move on: $(git -C "$R" status -sb | head -1)"
setup dirty; checks '[{"name":"unit","bucket":"pass"}]'; echo wip >> "$R/f"
OUT=$(bash "$X" "$R" 7 2>&1); [ $? -eq 0 ] && echo "$OUT" | grep -q "uncommitted changes — left as is" && [ "$(git -C "$R" symbolic-ref --short HEAD)" = lane-s1 ] && ok "dirty checkout left alone, exact command printed" || fail "dirty" "$OUT"
echo ""; echo "merge-when-green tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
