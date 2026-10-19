#!/usr/bin/env bash
# test-authorization-forge-guard.sh — the guard blocks what a command DOES to the CEO authorization
# record or recorder, never what its text merely MENTIONS. Offline; feeds hook JSON directly.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; H="$T/.claude/hooks/deny-authorization-forge.sh"
PASS=0; FAIL=0
t(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]} if sys.argv[1]=="Bash" else {"file_path":sys.argv[2],"content":"x"}}))' "$2" "$3" | bash "$H" >/dev/null 2>&1; r=$?
   if [ $r -eq "$1" ]; then PASS=$((PASS+1)); echo "  ok   $4"; else FAIL=$((FAIL+1)); echo "  FAIL (want $1 got $r) $4"; fi; }
echo "== must BLOCK =="
t 2 Write "/r/docs/sprints/s/CEO-AUTHORIZATION.md" "Write tool on the record"
t 2 Bash 'echo "- words: go" >> docs/sprints/s/CEO-AUTHORIZATION.md' "shell append"
t 2 Bash 'sed -i.bak s/B/C/ docs/sprints/s/CEO-AUTHORIZATION.md' "sed -i"
t 2 Bash 'cp /tmp/x docs/sprints/s/CEO-AUTHORIZATION.md' "cp over it"
t 2 Bash 'bash scripts/agentic/ceo-authorize.sh d g "go"' "bash runs the recorder"
t 2 Bash 'printf "g\n" | script -q /dev/null bash scripts/agentic/ceo-authorize.sh d g go' "recorder driven through a faked pty"
t 2 Bash 'cd x && FOO=1 scripts/agentic/ceo-authorize.sh d g go' "recorder after && with an env assignment"
t 2 Bash $'bash <<\'EOF\'\nscripts/agentic/ceo-authorize.sh d g go\nEOF' "recorder inside a heredoc fed to bash"
t 2 Bash $'python3 - <<\'PY\'\nopen("docs/s/CEO-AUTHORIZATION.md","a").write("x")\nPY' "python heredoc appending to the record"
t 2 Bash $'cat > docs/s/CEO-AUTHORIZATION.md <<\'EOF\'\nwords\nEOF' "cat heredoc redirected into the record"
echo "== must ALLOW =="
t 0 Bash $'cat > memo.md <<\'EOF\'\nCEO: run  bash scripts/agentic/ceo-authorize.sh <dir> <gate> "<words>"  in Terminal.\nEOF' "memo heredoc naming the recorder (fleet-reported false positive)"
t 0 Bash 'echo "hand the CEO: bash scripts/agentic/ceo-authorize.sh d g w"' "echo of the command as text"
t 0 Bash 'grep -n "ceo-authorize.sh" docs/personas/cto.md' "grep for the name"
t 0 Bash 'cat docs/sprints/s/CEO-AUTHORIZATION.md' "reading the record"
t 0 Bash 'bash scripts/agentic/check-authorization.sh docs/sprints/s fill-B' "running the check"
t 0 Bash 'bash scripts/agentic/test-ceo-authorization.sh' "running the test suite"
t 0 Write "/r/docs/sprints/s/dev-report.md" "an ordinary write"
echo ""; echo "forge-guard tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
