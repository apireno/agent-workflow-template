#!/usr/bin/env bash
# test-land-lane.sh — the landing gate end to end against a local bare "origin" and a stub `gh`.
# Covers: dry run touches nothing · lane missing base -> refused with the commits named · red CI
# refused, --allow-red lands it and records the reason · clean path (ff push, tag, remote branch
# deleted, worktree archived+removed, local branch deleted, log row) · base moving mid-landing ->
# INCOMPLETE with branch + worktree intact · non-APPROVED decision refused · pre-push hook.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; L="$T/scripts/agentic/land-lane.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -6 | sed 's/^/       | /'; return 0; }
W0="$(mktemp -d "${TMPDIR:-/tmp}/land.XXXXXX")"; W0="$(cd "$W0" && pwd -P)"; trap 'rm -rf "$W0"' EXIT
mkdir -p "$W0/bin"; cat > "$W0/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub: `gh run list --commit SHA ...` -> JSON per $STUB_CI; optional side effect to move base
[ -n "${STUB_MOVE_BASE:-}" ] && ( cd "$STUB_MOVE_BASE" && echo moved >> moved.txt && git add -A && git -c core.hooksPath=/dev/null commit -qm moved && git -c core.hooksPath=/dev/null push -q origin HEAD:main ) >/dev/null 2>&1
case "${STUB_CI:-success}" in
  success) echo '[{"status":"completed","conclusion":"success"}]' ;;
  failure) echo '[{"status":"completed","conclusion":"failure"}]' ;;
  none)    echo '[]' ;;
esac
STUB
chmod +x "$W0/bin/gh"; export PATH="$W0/bin:$PATH"
setup(){ # setup <name> [ci]: fresh origin + main clone + lane worktree with an APPROVED decision
  W="$W0/$1"; mkdir -p "$W"; git init -q --bare "$W/origin.git"; git clone -q "$W/origin.git" "$W/acme-x" 2>/dev/null
  M="$W/acme-x"; git -C "$M" config user.email t@t; git -C "$M" config user.name t
  mkdir -p "$M/.claude/githooks"; cp "$T/.claude/githooks/pre-push" "$M/.claude/githooks/"; git -C "$M" config core.hooksPath "$M/.claude/githooks"
  printf 'outputs/\n.claude/\n' > "$M/.gitignore"; echo a > "$M/a"
  [ "${2:-}" = ci ] && { mkdir -p "$M/.github/workflows"; echo "on: push" > "$M/.github/workflows/ci.yml"; }
  git -C "$M" add -A; git -C "$M" commit -qm init; git -C "$M" -c core.hooksPath=/dev/null push -q origin HEAD:main 2>/dev/null; git -C "$M" remote set-head origin main >/dev/null
  git -C "$M" worktree add -q "$W/acme-x-wt-lane" -b lane-s1 >/dev/null 2>&1; LN="$W/acme-x-wt-lane"
  echo feature > "$LN/f.txt"; git -C "$LN" add f.txt; git -C "$LN" commit -qm feature
  S="$LN/docs/sprints/sprint-s1"; mkdir -p "$S" "$LN/outputs"; echo "result" > "$LN/outputs/r.json"
  printf '# CTO decision\n\nDecision: APPROVED\n' > "$S/cto-decision-20261019.md"
  export LAND_DATA_ROOT="$W/data" CTO_HOME=
}
echo "== 1. dry run =="
setup dry; B0=$(git -C "$M" ls-remote origin refs/heads/main | cut -f1)
OUT=$(bash "$L" "$S" --dry-run 2>&1); RC=$?
[ $RC -eq 0 ] && [ "$(git -C "$M" ls-remote origin refs/heads/main | cut -f1)" = "$B0" ] && [ -d "$LN" ] && [ -n "$(git -C "$LN" status --porcelain -- docs)" ] && ok "dry run: origin, worktree and sprint dir untouched" || fail "dry rc=$RC" "$OUT"
echo "== 2. lane missing base =="
setup behind; ( cd "$M" && echo x > x && git add x && git commit -qm "base moved: fix X" && git -c core.hooksPath=/dev/null push -q origin HEAD:main ) 2>/dev/null
OUT=$(bash "$L" "$S" 2>&1); RC=$?
[ $RC -eq 3 ] && echo "$OUT" | grep -q "does not contain origin/main" && echo "$OUT" | grep -q "base moved: fix X" && ok "refused, naming the missing commit" || fail "behind rc=$RC" "$OUT"
grep -q $'\tINCOMPLETE\tcontains-base\t' "$M/.claude/landings.log" && ok "INCOMPLETE row logged" || fail "log row"
echo "== 3. red CI under ci: strict, then --allow-red =="
setup red ci; printf 'ci: strict\n' > "$M/.claude/land.yaml"
OUT=$(STUB_CI=failure bash "$L" "$S" 2>&1); RC=$?
[ $RC -eq 3 ] && echo "$OUT" | grep -q "CI on .* is 'red:failure'" && ok "red CI refused" || fail "red rc=$RC" "$OUT"
OUT=$(STUB_CI=failure bash "$L" "$S" --allow-red "flaky upstream test, tracked as BUG-1" 2>&1); RC=$?
[ $RC -eq 0 ] && git -C "$M" show "origin/main:docs/sprints/sprint-s1/cto-decision-20261019.md" 2>/dev/null | grep -q "CI override:.*flaky upstream" && ok "--allow-red lands; the reason is in the LANDED decision file" || fail "allow-red rc=$RC" "$OUT"
grep -q "flaky upstream" "$W/data/land-overrides.log" && [ "$(stat -f %Lp "$W/data/land-overrides.log")" = 600 ] && ok "override logged outside the repo, mode 600" || fail "override log"
echo "== 3b. ci: auto (default) — warns until the repo's first green, then blocks =="
setup auto ci
OUT=$(STUB_CI=failure bash "$L" "$S" 2>&1); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "WARNING ONLY" && echo "$OUT" | grep -q "landing: COMPLETE" && ok "first red landing (no green yet): warns and lands" || fail "auto first rc=$RC" "$OUT"
[ ! -f "$M/.claude/ci-green-seen" ] && ok "a red landing does not mark the repo green" || fail "green marker after red"
# second lane, green CI -> records the first green
git -C "$M" fetch -q origin; git -C "$M" worktree add -q "$W/lane2" -b lane-s2 origin/main >/dev/null 2>&1
echo two > "$W/lane2/two.txt"; git -C "$W/lane2" add two.txt; git -C "$W/lane2" commit -qm two
mkdir -p "$W/lane2/docs/sprints/sprint-s2"; printf 'Decision: APPROVED\n' > "$W/lane2/docs/sprints/sprint-s2/cto-decision-1.md"
OUT=$(STUB_CI=success bash "$L" "$W/lane2/docs/sprints/sprint-s2" 2>&1); RC=$?
[ $RC -eq 0 ] && [ -f "$M/.claude/ci-green-seen" ] && ok "first green landing recorded (.claude/ci-green-seen)" || fail "green record rc=$RC" "$OUT"
git -C "$M" fetch -q origin; git -C "$M" worktree add -q "$W/lane3" -b lane-s3 origin/main >/dev/null 2>&1
echo three > "$W/lane3/three.txt"; git -C "$W/lane3" add three.txt; git -C "$W/lane3" commit -qm three
mkdir -p "$W/lane3/docs/sprints/sprint-s3"; printf 'Decision: APPROVED\n' > "$W/lane3/docs/sprints/sprint-s3/cto-decision-1.md"
OUT=$(STUB_CI=failure bash "$L" "$W/lane3/docs/sprints/sprint-s3" 2>&1); RC=$?
[ $RC -eq 3 ] && echo "$OUT" | grep -q "INCOMPLETE at ci" && ok "after the first green, red CI is REFUSED" || fail "auto strict rc=$RC" "$OUT"
printf 'ci: advisory\n' > "$M/.claude/land.yaml"
OUT=$(STUB_CI=failure bash "$L" "$W/lane3/docs/sprints/sprint-s3" 2>&1); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "WARNING ONLY" && ok "ci: advisory overrides — red warns and lands" || fail "advisory rc=$RC" "$OUT"

echo "== 4. clean landing =="
setup clean ci
OUT=$(bash "$L" "$S" 2>&1); RC=$?
LSHA=$(git -C "$M" rev-parse lane-s1 2>/dev/null || true); RMAIN=$(git -C "$M" ls-remote origin refs/heads/main | cut -f1)
[ $RC -eq 0 ] && echo "$OUT" | grep -q "landing: COMPLETE" && ok "landing COMPLETE" || fail "clean rc=$RC" "$OUT"
git -C "$M" fetch -q origin; git -C "$M" show origin/main:f.txt >/dev/null 2>&1 && git -C "$M" show origin/main:docs/sprints/sprint-s1/cto-decision-20261019.md >/dev/null 2>&1 && ok "origin/main has the work AND the decision" || fail "content not landed"
git -C "$M" ls-remote --tags origin | grep -q "refs/tags/sprint/s1" && ok "annotated tag sprint/s1 on origin" || fail "tag"
git -C "$M" ls-remote --heads origin lane-s1 | grep -q . && fail "remote lane branch still there" || ok "origin/lane-s1 deleted"
[ ! -d "$LN" ] && ls "$W"/data/wt-archive/*/acme-x-wt-lane/files/outputs/r.json >/dev/null 2>&1 && ok "worktree archived (outputs kept) and removed" || fail "reap"
git -C "$M" rev-parse -q --verify lane-s1 >/dev/null && fail "local branch kept" || ok "local branch deleted"
grep -q $'\tCOMPLETE\t' "$M/.claude/landings.log" && ok "COMPLETE row logged" || fail "log"
echo "== 5. base moves between the check and the push =="
setup race ci
OUT=$(STUB_MOVE_BASE="$M" bash "$L" "$S" 2>&1); RC=$?
[ $RC -eq 3 ] && echo "$OUT" | grep -q "INCOMPLETE at land" && [ -d "$LN" ] && git -C "$M" ls-remote --heads origin lane-s1 | grep -q . && ok "push rejected -> INCOMPLETE; lane branch and worktree intact" || fail "race rc=$RC" "$OUT"
echo "== 6. decision not APPROVED =="
setup rejected; printf '# CTO decision\n\nDecision: REJECTED-FOR-REVISION\n' > "$S/cto-decision-20261019.md"
OUT=$(bash "$L" "$S" 2>&1); [ $? -eq 3 ] && echo "$OUT" | grep -q "not APPROVED" && ok "non-APPROVED decision refused" || fail "rejected" "$OUT"
echo "== 7. pre-push hook =="
setup hook; ( cd "$M" && echo y > y && git add y && git commit -qm y ) >/dev/null
OUT=$(cd "$M" && git push origin HEAD:main 2>&1); [ $? -ne 0 ] && echo "$OUT" | grep -q "REFUSED" && ok "direct push to main refused" || fail "hook allowed a direct push" "$OUT"
OUT=$(cd "$M" && ALLOW_BASE_PUSH="hotfix X" git push -q origin HEAD:main 2>&1); [ $? -eq 0 ] && grep -q "hotfix X" "$M/.claude/land-overrides.log" && ok "ALLOW_BASE_PUSH lets it through and logs the reason" || fail "allow" "$OUT"
OUT=$(cd "$M" && git push -q origin HEAD:other-branch 2>&1); [ $? -eq 0 ] && ok "pushing a non-base branch is unaffected" || fail "other branch" "$OUT"
echo ""; echo "land-lane tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
