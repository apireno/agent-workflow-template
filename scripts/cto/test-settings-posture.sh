#!/usr/bin/env bash
# test-settings-posture.sh — settings-posture.sh --check/--apply, the posture in the shipped templates,
# and preflight's permission-mode report (CEO 2026-11-01: the conversation is the gate, the harness is
# lenient). Offline; works on a temp copy of the template.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; S="$T/scripts/cto/settings-posture.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/posture.XXXXXX")"; trap 'rm -rf "$W"' EXIT
H="$W/acme-cto"; mkdir -p "$H/.claude"; cp "$T/.claude/settings.cto.json.template" "$H/.claude/"
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2"; }

echo "== templates carry the posture =="
for f in .claude/settings.cto.json.template .claude/settings.devteam.json.template .claude/settings.permissive.json; do
    python3 -c '
import json,sys; p=json.load(open(sys.argv[1]))["permissions"]; a=p.get("allow",[]); k=p.get("ask",[])
assert "Bash" in a, "no blanket Bash"
assert "Bash(*)" not in a, "Bash(*) and Bash both present"
for r in ("Bash(git push --force*)","Bash(git branch -D *)","Bash(launchctl load *)","Bash(gh repo delete *)","Edit(.claude/settings.json)"): assert r in k, "ask lacks "+r
assert not set(a)&set(k), "rule in both ask and allow"
assert "Bash(gh pr merge *)" not in a' "$T/$f" && ok "$f: blanket Bash + never-uninvited ask list, nothing in both" || fail "$f posture"
done
grep -q '"Bash(gh pr merge \*)"' "$T/.claude/settings.devteam.json.template" && grep -q '"Bash(gh pr merge \*)"' "$T/.claude/settings.permissive.json" \
  && ! grep -q '"Bash(gh pr merge \*)"' "$T/.claude/settings.cto.json.template" && ok "lanes ask on PR merge; the CTO home does not (the CEO approves merges in the conversation)" || fail "merge placement"
bash "$T/scripts/cto/lint-skills.sh" >/dev/null 2>&1 && ok "lint-skills clean (CHECK H covers the templates)" || fail "lint-skills: $(bash "$T/scripts/cto/lint-skills.sh" 2>&1 | grep '^  H' | head -3)"

echo "== --check / --apply =="
bash "$S" >/dev/null 2>&1; [ $? -eq 2 ] && ok "usage without --check/--apply (exit 2)" || fail "usage"
OUT="$(bash "$S" --check "$H" 2>&1)"; r=$?
[ $r -eq 1 ] && echo "$OUT" | grep -q 'defaultMode' && echo "$OUT" | grep -q 'blanket Bash' && echo "$OUT" | grep -q 'never-uninvited' && echo "$OUT" | grep -q 'preflight' \
  && ok "no settings.json -> drifted (exit 1), each gap named" || fail "fresh check rc=$r: $OUT"
OUT="$(bash "$S" --apply "$H" 2>&1)"; r=$?
[ $r -eq 0 ] && [ -f "$H/.claude/settings.json" ] && bash "$S" --check "$H" >/dev/null 2>&1 && ok "apply on a fresh home -> check passes" || fail "fresh apply rc=$r: $OUT"
[ "$(j "$H/.claude/settings.json" 'd["defaultMode"]')" = acceptEdits ] && ! grep -q '_comment' "$H/.claude/settings.json" && ok "applied file: defaultMode acceptEdits, no _comment keys" || fail "applied content"
cat > "$H/.claude/settings.json" <<'EOF'
{
  "defaultMode": "acceptEdits",
  "permissions": {
    "allow": ["Bash(*)", "Edit", "mcp__acme-graph__query", "Bash(git push --force*)"],
    "additionalDirectories": ["/Users/someone/repos/acme-service"]
  },
  "enabledMcpjsonServers": ["acme-graph"],
  "hooks": {"SessionStart": [{"matcher": "*", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/agentic/preflight.sh"}]}],
            "Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "/opt/acme/own-hook.sh"}]}]}
}
EOF
OUT="$(bash "$S" --check "$H" 2>&1)"; r=$?
[ $r -eq 1 ] && echo "$OUT" | grep -q 'never-uninvited' && ! echo "$OUT" | grep -q 'blanket Bash' && ! echo "$OUT" | grep -q 'preflight' \
  && ok "existing home: Bash(*) counts as the blanket (docs: equivalent to Bash); only the ask list is missing" || fail "existing check rc=$r: $OUT"
bash "$S" --apply "$H" >/dev/null 2>&1
OUT="$(bash "$S" --check "$H" 2>&1)"; r=$?
[ $r -eq 1 ] && echo "$OUT" | grep -q 'both ask and allow' && ok "an ask rule that is also allowed is reported as dead (ask wins)" || fail "dead-allow report rc=$r: $OUT"
python3 - "$H/.claude/settings.json" <<'PY' && ok "apply is a merge: MCP grant, additionalDirectories, enabledMcpjsonServers and the home's own Stop hook kept; Bash not duplicated; ask added" || fail "merge semantics"
import json, sys; d = json.load(open(sys.argv[1])); p = d["permissions"]
assert "mcp__acme-graph__query" in p["allow"] and p["additionalDirectories"] == ["/Users/someone/repos/acme-service"]
assert d["enabledMcpjsonServers"] == ["acme-graph"] and d["hooks"]["Stop"][0]["hooks"][0]["command"] == "/opt/acme/own-hook.sh"
assert sum(1 for r in p["allow"] if r in ("Bash", "Bash(*)")) == 1 and len(d["hooks"]["SessionStart"]) == 1
assert "Bash(launchctl load *)" in p["ask"] and "Bash(git push --force*)" in p["ask"]
PY

echo "== preflight reports the mode =="
P="$T/scripts/agentic/preflight.sh"
OUT="$(printf '{"session_id":"t","permission_mode":"auto","hook_event_name":"SessionStart"}' | REPO_ROOT="$T" bash "$P" 2>&1)"
echo "$OUT" | grep -q 'AUTO mode' && echo "$OUT" | grep -qi 'not a prompt' && ok "auto: warns that the blanket Bash is dropped and a block is not a prompt" || fail "auto warning: $(echo "$OUT" | grep -i 'mode' | head -3)"
OUT="$(printf '{"permission_mode":"acceptEdits"}' | REPO_ROOT="$T" bash "$P" 2>&1)"
echo "$OUT" | grep -q '\[PERMISSIONS\] mode=acceptEdits' && ok "acceptEdits: reported on one line, no warning" || fail "acceptEdits line: $(echo "$OUT" | grep PERMISSIONS)"
OUT="$(printf '' | REPO_ROOT="$T" bash "$P" 2>&1)"; ! echo "$OUT" | grep -q '\[PERMISSIONS\]' && ok "no hook input -> no mode line, no hang" || fail "empty stdin"
echo ""; echo "settings-posture tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
