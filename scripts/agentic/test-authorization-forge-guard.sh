#!/usr/bin/env bash
# test-authorization-forge-guard.sh — in a dev lane the guard blocks what a command DOES to the CEO
# approval record, never what its text merely MENTIONS; in a CTO home it allows the write (CEO ruling
# 2026-10-30: the CTO records the CEO's words). Offline; feeds hook JSON directly.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; H="$T/.claude/hooks/deny-authorization-forge.sh"
PASS=0; FAIL=0; W="$(mktemp -d "${TMPDIR:-/tmp}/forge.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/acme-service/.git" "$W/acme-cto/.git"; export CLAUDE_PROJECT_DIR="$W/acme-service"
t(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]} if sys.argv[1]=="Bash" else {"file_path":sys.argv[2],"content":"x"}}))' "$2" "$3" | bash "$H" >/dev/null 2>&1; r=$?
   if [ $r -eq "$1" ]; then PASS=$((PASS+1)); echo "  ok   $4"; else FAIL=$((FAIL+1)); echo "  FAIL (want $1 got $r) $4"; fi; }
echo "== dev lane: must BLOCK =="
t 2 Write "/r/docs/sprints/s/CEO-AUTHORIZATION.md" "Write tool on the record"
t 2 Bash 'echo "- words: go" >> docs/sprints/s/CEO-AUTHORIZATION.md' "shell append"
t 2 Bash 'sed -i.bak s/B/C/ docs/sprints/s/CEO-AUTHORIZATION.md' "sed -i"
t 2 Bash 'cp /tmp/x docs/sprints/s/CEO-AUTHORIZATION.md' "cp over it"
t 2 Bash $'python3 - <<\'PY\'\nopen("docs/s/CEO-AUTHORIZATION.md","a").write("x")\nPY' "python heredoc appending to the record"
t 2 Bash $'cat > docs/s/CEO-AUTHORIZATION.md <<\'EOF\'\nwords\nEOF' "cat heredoc redirected into the record"
t 2 Bash $'bash <<\'EOF\'\necho "- ceo_words: go" >> docs/s/CEO-AUTHORIZATION.md\nEOF' "append inside a heredoc fed to bash"
t 2 Bash 'echo x | tee -a docs/s/CEO-AUTHORIZATION.md' "tee -a into it"
echo "== dev lane: must ALLOW =="
t 0 Bash $'cat > memo.md <<\'EOF\'\nThe CTO records approvals in CEO-AUTHORIZATION.md.\nEOF' "memo heredoc naming the file (data, not a write)"
t 0 Bash 'grep -n "CEO-AUTHORIZATION.md" docs/personas/cto.md' "grep for the name"
t 0 Bash 'cat docs/sprints/s/CEO-AUTHORIZATION.md' "reading the record"
t 0 Bash 'bash scripts/agentic/check-authorization.sh docs/sprints/s fill-B' "running the check"
t 0 Bash 'bash scripts/agentic/test-approval-record.sh' "running the test suite"
t 0 Write "/r/docs/sprints/s/dev-report.md" "an ordinary write"
echo "== CTO home: must ALLOW =="
export CLAUDE_PROJECT_DIR="$W/acme-cto"
t 0 Write "/r/docs/sprints/s/CEO-AUTHORIZATION.md" "CTO session writes the record"
t 0 Bash 'bash scripts/agentic/record-approval.sh docs/s g --words "ok approved" --scope "x"' "CTO runs the recorder"
t 0 Bash 'echo "- ceo_words: go" >> docs/sprints/s/CEO-AUTHORIZATION.md' "CTO shell append"
mkdir -p "$W/plain/.git" "$W/plain/.cto"; : > "$W/plain/.cto/projects.yaml"; export CLAUDE_PROJECT_DIR="$W/plain"
t 0 Write "/r/docs/sprints/s/CEO-AUTHORIZATION.md" "a CTO home detected by .cto/projects.yaml"
echo ""; echo "forge-guard tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
