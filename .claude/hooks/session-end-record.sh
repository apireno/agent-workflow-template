#!/bin/bash
# session-end-record.sh — Per-repo SessionEnd hook for Phase 2 dev-team sessions.
#
# Records session end + sets CRASHED flag on unclean exit.
# Records COMPLETE flag if a dev-report.md exists in any sprint dir (indicates
# the dev team finished the assigned work).
#
# Stdout of SessionEnd hooks is NOT injected into Claude context (session is
# already ending). All output is for logging only.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLAUDE_DIR="$REPO_ROOT/.claude"
mkdir -p "$CLAUDE_DIR"

# Read hook input JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
EXIT_REASON=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reason', d.get('exit_reason', 'unknown')))" 2>/dev/null || echo "unknown")

TS=$(date -u +%FT%TZ)
echo "session_id=$SESSION_ID reason=$EXIT_REASON ts=$TS ended" >> "$CLAUDE_DIR/session.log"

# Detect unclean exit
case "$EXIT_REASON" in
    "clear"|"compact"|"quit"|"exit"|"logout")
        # clean exit — no CRASHED flag
        ;;
    *)
        # Treat anything not in the clean list as crashed for safety
        touch "$CLAUDE_DIR/CRASHED"
        echo "marked CRASHED (reason=$EXIT_REASON)" >> "$CLAUDE_DIR/session.log"
        ;;
esac

# Check for completion: any dev-report.md in any sprint dir indicates the dev team finished
if find "$REPO_ROOT/docs/sprints" -name 'dev-report.md' -type f 2>/dev/null | head -1 | grep -q .; then
    touch "$CLAUDE_DIR/COMPLETE"
    echo "marked COMPLETE (dev-report.md present)" >> "$CLAUDE_DIR/session.log"
fi

exit 0
