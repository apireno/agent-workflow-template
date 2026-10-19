#!/usr/bin/env bash
# test-skill-flags.sh — the argument loops of the skills that take flags must accept `--x v` and
# `--x=v`, and must REFUSE an unknown flag or a stray extra word (2026-10-19: `/sprint-fanout …
# --repos a,b` printed "Unknown flag", dropped the list and fanned out to all 14 repos).
# Extracts each skill's own parse block from SKILL.md and runs it in bash AND zsh. Offline.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; return 0; }
block(){ # block <skill>: from the line declaring EXPECT (or the for-loop) through the EXPECT guard/done
  awk '/^EXPECT=""$/ && !s{s=1} /^for tok in \$ARGS; do$/ && !s{s=1} s{print} s && /^\[ -n "\$EXPECT" \]/{exit} s && /^done$/ && !e{e=1; d=NR} e && NR>d && !/^\[ -n "\$EXPECT" \]/{exit}' "$T/.claude/skills/$1/SKILL.md"
}
run(){ # run <shell> <skill> <args> <vars to print>
  local sh="$1" sk="$2" args="$3" vars="$4" body; body="$(block "$sk")"
  "$sh" -c "[ -n \"\${ZSH_VERSION:-}\" ] && setopt sh_word_split; ARGS='$args'; $body
for v in $vars; do eval \"printf '%s=%s;' \\\$v \\\"\\\${\$v:-}\\\"\"; done" 2>&1
}
for SH in bash zsh; do
  echo "== $SH =="
  o=$(run $SH sprint-fanout "goal.md --repos a,b --sprint 07" "PRD_PATH REPOS_FILTER SPRINT"); [ "$o" = "PRD_PATH=goal.md;REPOS_FILTER=a,b;SPRINT=07;" ] && ok "fanout: space form (the 10/19 failure)" || fail "fanout space form: $o"
  o=$(run $SH sprint-fanout "goal.md --repos=a,b --sprint=07" "PRD_PATH REPOS_FILTER SPRINT"); [ "$o" = "PRD_PATH=goal.md;REPOS_FILTER=a,b;SPRINT=07;" ] && ok "fanout: = form" || fail "fanout = form: $o"
  o=$(run $SH sprint-fanout "goal.md --repo a" "PRD_PATH"); echo "$o" | grep -q "unknown flag '--repo'" && ok "fanout: unknown flag refuses" || fail "fanout unknown flag: $o"
  o=$(run $SH sprint-fanout "goal.md a,b" "PRD_PATH"); echo "$o" | grep -q "unexpected extra argument 'a,b'" && ok "fanout: stray word refuses" || fail "fanout stray: $o"
  o=$(run $SH sprint-fanout "goal.md --repos" "PRD_PATH"); echo "$o" | grep -q "needs a value" && ok "fanout: dangling flag refuses" || fail "fanout dangling: $o"
  o=$(run $SH handoff "sprint-x --repos a,b --model opus --dry-run" "SPRINT REPOS_FILTER DEVTEAM_MODEL CLI_MODEL DRY_RUN"); [ "$o" = "SPRINT=sprint-x;REPOS_FILTER=a,b;DEVTEAM_MODEL=opus;CLI_MODEL=1;DRY_RUN=1;" ] && ok "handoff: space form incl. --model approval" || fail "handoff space: $o"
  o=$(run $SH handoff "sprint-x --repos=a --model=fable" "REPOS_FILTER DEVTEAM_MODEL CLI_MODEL"); [ "$o" = "REPOS_FILTER=a;DEVTEAM_MODEL=fable;CLI_MODEL=1;" ] && ok "handoff: = form" || fail "handoff = form: $o"
  o=$(run $SH handoff "sprint-x --repo a" "SPRINT"); echo "$o" | grep -q "unknown flag" && ok "handoff: unknown flag refuses (no all-repo fan-out)" || fail "handoff unknown: $o"
  o=$(run $SH vp-review "a.md --vps vp-eng,vp-devops --engine kimi" "ART VPS ENGINE_FLAG"); [ "$o" = "ART=a.md;VPS=vp-eng,vp-devops;ENGINE_FLAG=kimi;" ] && ok "vp-review: space form" || fail "vp-review space: $o"
  o=$(run $SH vp-review "a.md --vp=vp-eng" "ART"); echo "$o" | grep -q "unknown flag" && ok "vp-review: unknown flag refuses" || fail "vp-review unknown: $o"
  o=$(run $SH new-project "acme --repos a,b --org o --adopt" "PROJECT REPOS ORG ADOPT"); [ "$o" = "PROJECT=acme;REPOS=a,b;ORG=o;ADOPT=1;" ] && ok "new-project: space form" || fail "new-project: $o"
  o=$(run $SH close-window "acme --froce" "REPO_NAME"); echo "$o" | grep -q "unknown flag" && ok "close-window: a typo'd --force refuses" || fail "close-window: $o"
done
echo ""; echo "skill-flag tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
