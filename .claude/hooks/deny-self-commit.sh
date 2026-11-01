#!/usr/bin/env bash
# deny-self-commit.sh — PreToolUse(Bash) guard for Phase-2 dev-team sessions.
#
# The dev team writes artifacts to disk; the CTO commits AFTER the independent Phase-3
# review. A session that can commit its own work can also close its own gate, which
# collapses the separation the whole sprint lifecycle depends on.
#
# Blocks `git commit` / `git push`. Read-only and staging git (status/diff/log/show/add)
# stays allowed — dev teams need to inspect and stage their own work.
#
# Exit 2 = block, with stderr fed back to the model so it understands why and continues
# instead of retrying. Wired by /handoff's self-heal as PreToolUse with matcher "Bash".

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

if printf '%s' "$CMD" | grep -qE '\bgit\b[^|;&]*\b(commit|push)\b'; then
    echo "BLOCKED (no-self-commit policy): the CTO commits after the independent Phase-3 review." >&2
    echo "Write artifacts to disk only (dev-report.md, demo-output.md, source, tests)." >&2
    echo "Do NOT git commit/push, and do NOT self-run Phase-3 VP reviews." >&2
    echo "CTO 2026-10-31: Phase-3 VP reviews are the CTO's independent gate; lanes do not self-run them." >&2
    echo "Leave no review files (not even empty ones); end dev-report.md with: Phase-3 reviews pending: CTO" >&2
    exit 2
fi

exit 0
