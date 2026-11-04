#!/usr/bin/env bash
# test-project-layer.sh — the project/repo layers (CEO 2026-11-04) and the accept-time sections:
# init never overwrites · status (missing / empty / ok) · standing orders + checklist printing with
# commented examples ignored · checks refuse / pass / not-executable · project + repo layer order ·
# sync-cto-home.sh and push-to-repos.sh never write either layer · check-dev-report.sh.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; P="$T/scripts/agentic/project-layer.sh"; C="$T/scripts/agentic/check-dev-report.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -8 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/layer.XXXXXX")"; W="$(cd "$W" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
H="$W/acme-cto"; R="$W/acme-service"; mkdir -p "$H/.git" "$R/.git"; printf '%s\n' "$H" > "$R/.cto-path"

echo "== init / status =="
OUT=$(bash "$P" status --repo "$H"); [ $? -eq 1 ] && echo "$OUT" | grep -q MISSING && ok "status: a CTO home with no layer is MISSING (exit 1)" || fail "missing" "$OUT"
bash "$P" init "$H/.cto/project" >/dev/null
OUT=$(bash "$P" status --repo "$H"); [ $? -eq 1 ] && echo "$OUT" | grep -q EMPTY && ok "status: the seeded skeleton is EMPTY — its examples are comments, not orders" || fail "empty" "$OUT"
printf '\n## SO-001 — Read times from the clock\n- why: drift\n' >> "$H/.cto/project/standing-orders.md"
echo "keep me" > "$H/.cto/project/checklists/kickoff.md"; bash "$P" init "$H/.cto/project" >/dev/null
[ "$(cat "$H/.cto/project/checklists/kickoff.md")" = "keep me" ] && ok "init never overwrites an existing file" || fail "init overwrote"
OUT=$(bash "$P" status --repo "$H"); [ $? -eq 0 ] && echo "$OUT" | grep -q "ok (1 standing orders" && ok "status: ok with one order" || fail "status ok" "$OUT"

echo "== moments =="
OUT=$(bash "$P" preflight --repo "$H"); echo "$OUT" | grep -q "SO-001 — Read times from the clock" && ! echo "$OUT" | grep -q "<the rule" && ok "preflight prints the orders, not the commented template text" || fail "preflight" "$OUT"
printf -- '- [ ] wiring table attached\n<!-- - [ ] commented example -->\n' > "$H/.cto/project/checklists/accept.md"
mkdir -p "$H/.cto/project/checks/accept"; printf '#!/bin/sh\necho "graded: 12"\n' > "$H/.cto/project/checks/accept/cov.sh"; chmod +x "$H/.cto/project/checks/accept/cov.sh"
OUT=$(bash "$P" accept --repo "$R"); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "wiring table attached" && ! echo "$OUT" | grep -q "commented example" && echo "$OUT" | grep -q "cov.sh\] ok — graded: 12" && ok "accept from a dev repo: finds the project layer via .cto-path, prints the checklist, runs the check" || fail "accept" "$OUT"
printf '#!/bin/sh\necho "graded: 0"; exit 1\n' > "$H/.cto/project/checks/accept/cov.sh"
OUT=$(bash "$P" accept --repo "$R"); [ $? -eq 3 ] && echo "$OUT" | grep -q "REFUSED" && echo "$OUT" | grep -q "graded: 0" && ok "a failing check refuses (exit 3) with its output" || fail "refuse" "$OUT"
printf '#!/bin/sh\nexit 0\n' > "$H/.cto/project/checks/accept/cov.sh"; chmod -x "$H/.cto/project/checks/accept/cov.sh"
OUT=$(bash "$P" accept --repo "$R"); [ $? -eq 3 ] && echo "$OUT" | grep -q "NOT EXECUTABLE" && ok "a non-executable check refuses — never skipped silently" || fail "noexec" "$OUT"
chmod +x "$H/.cto/project/checks/accept/cov.sh"
mkdir -p "$R/.claude/project"; printf '## RO-001 — Never edit vendored models\n' > "$R/.claude/project/standing-orders.md"
OUT=$(bash "$P" kickoff --repo "$R"); A=$(echo "$OUT" | grep -n "project layer" | head -1 | cut -d: -f1); B=$(echo "$OUT" | grep -n "repo layer" | head -1 | cut -d: -f1)
[ -n "$A" ] && [ -n "$B" ] && [ "$A" -lt "$B" ] && echo "$OUT" | grep -q "RO-001" && ok "kickoff in a dev repo prints the project layer, then the repo layer" || fail "order" "$OUT"
bash "$P" bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown moment -> usage (exit 2)" || fail "usage"

echo "== sync and push never write a layer =="
G="$W/acme2-cto"; mkdir -p "$G/.cto/project" "$G/.claude/project"; git init -q "$G"
echo "MINE" > "$G/.cto/project/standing-orders.md"; echo "MINE" > "$G/.claude/project/standing-orders.md"
bash "$T/scripts/cto/sync-cto-home.sh" "$G" --apply >/dev/null 2>&1
[ "$(cat "$G/.cto/project/standing-orders.md")" = MINE ] && [ ! -e "$G/.cto/project/checklists" ] && ok "sync-cto-home.sh leaves .cto/project untouched" || fail "sync wrote the project layer"
# push-to-repos.sh resolves a target next to its own home: run a copy beside a throwaway lane
B="$W/base"; mkdir -p "$B"; rsync -a --exclude .git --exclude .cto/projects.yaml "$T/" "$B/acme3-cto/"
D="$B/acme-lane"; git init -q "$D"; mkdir -p "$D/.claude/project"; echo "MINE" > "$D/.claude/project/standing-orders.md"
( cd "$B/acme3-cto" && zsh scripts/cto/push-to-repos.sh acme-lane >/dev/null 2>&1 )
[ -f "$D/.claude/settings.json" ] && ok "push-to-repos.sh ran against the throwaway lane" || fail "push did not run"
[ "$(cat "$D/.claude/project/standing-orders.md")" = MINE ] && ok "push-to-repos.sh leaves an existing .claude/project untouched" || fail "push wrote the repo layer"

echo "== check-dev-report.sh =="
S="$W/s1"; mkdir -p "$S"
printf '# Plan\n**Goal:** x\n' > "$S/sprint-plan.md"; printf '# Report\n' > "$S/dev-report.md"
OUT=$(bash "$C" "$S"); [ $? -eq 0 ] && echo "$OUT" | grep -q "no \*\*Declares:\*\* line" && ok "a pre-2026-11-04 plan (no Declares) is reported, not refused" || fail "legacy" "$OUT"
printf '# Plan\n**Declares:** new-mechanisms: yes · measurements: yes · llm-stages: no\n' > "$S/sprint-plan.md"
cp "$T/docs/sprints/_templates/dev-report.md" "$S/dev-report.md"
OUT=$(bash "$C" "$S"); [ $? -eq 1 ] && echo "$OUT" | grep -q "Wiring" && echo "$OUT" | grep -q "Statistical Risks" && ok "an unfilled template (placeholders only) fails both declared sections" || fail "unfilled" "$OUT"
python3 - "$S/dev-report.md" <<'PY'
import sys; p = sys.argv[1]; t = open(p).read()
t = t.replace("| {name} | {entry → … → mechanism, with file:line} | WIRED / UNWIRED |", "| run-service registry | cli.main → runner.start → registry.get (runner.py:41) | WIRED |\n| key rotation | — | UNWIRED |")
t = t.replace('{risks, or "None — no measurement"}', "n=40 passages, drawn by stratified sample; precision not measured against sampled gold.")
open(p, "w").write(t)
PY
OUT=$(bash "$C" "$S"); [ $? -eq 0 ] && echo "$OUT" | grep -q "1 mechanism(s) UNWIRED" && ok "filled sections pass; an UNWIRED row is surfaced for the decision" || fail "filled" "$OUT"
printf '# Plan\n**Declares:** new-mechanisms: no · measurements: no · llm-stages: yes\n' > "$S/sprint-plan.md"
OUT=$(bash "$C" "$S"); [ $? -eq 1 ] && echo "$OUT" | grep -q "LLM-Stage Budget" && ok "llm-stages: yes without a budget section refuses" || fail "llm" "$OUT"
echo ""; echo "project-layer tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
