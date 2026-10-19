#!/bin/bash
# deny-authorization-forge.sh — PreToolUse guard (Edit|Write|NotebookEdit and Bash), in dev repos
# AND the CTO home. A session must never write a CEO authorization, for itself or for anyone.
#
# CEO-AUTHORIZATION.md records the CEO's own words for a human-only gate; only the CEO writes it,
# with scripts/agentic/ceo-authorize.sh in a real terminal (see its header). This hook closes the
# obvious agent paths to that file: a direct Edit/Write, a shell redirect/tee/sed -i/cp/mv into it,
# and running the recorder at all (which an agent could otherwise drive through a faked pty).
# Reading the file and running check-authorization.sh stay free. Fired on 2026-10-19's request that
# the CTO "record the CEO's word" — the classifier had refused the forged token four times; a file
# the CTO writes would have been the same act under a new name.
set -uo pipefail
INPUT="$(cat)"
read -r TOOL TARGET CMD < <(printf '%s' "$INPUT" | python3 -c '
import sys, json, shlex
d=json.load(sys.stdin); ti=d.get("tool_input",{}) or {}
print(d.get("tool_name",""), (ti.get("file_path") or ti.get("notebook_path") or "-").replace(" ","\\ "), json.dumps(ti.get("command","")))' 2>/dev/null)
CMD="$(printf '%s' "${CMD:-\"\"}" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read() or "\"\""))' 2>/dev/null)"
block() {
    echo "BLOCKED (CEO authorization): $1" >&2
    echo "Only the CEO records an authorization, in their own words, by running in Terminal:" >&2
    echo "  scripts/agentic/ceo-authorize.sh <sprint-dir> <gate> \"<the CEO's words>\"" >&2
    echo "Hand the CEO that command. Never write the record or a sign-off token on anyone's behalf." >&2
    exit 2
}
case "$(basename -- "${TARGET:--}")" in
    CEO-AUTHORIZATION.md) block "sessions do not write CEO-AUTHORIZATION.md." ;;
esac
if [ -n "$CMD" ]; then
    printf '%s' "$CMD" | grep -q 'ceo-authorize\.sh' && block "sessions do not run ceo-authorize.sh; it is the CEO's own command."
    if printf '%s' "$CMD" | grep -q 'CEO-AUTHORIZATION\.md'; then
        printf '%s' "$CMD" | grep -qE '>|\btee\b|sed[^|;&]*-i|\b(cp|mv|rm|truncate|install|ln)\b|open\(|write_text|\.write\(' \
            && block "that command would write CEO-AUTHORIZATION.md."
    fi
fi
exit 0
