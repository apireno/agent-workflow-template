#!/bin/bash
# session-end-record.sh — Per-repo SessionEnd hook for Phase 2 dev-team sessions.
#
# Records session end + sets CRASHED flag on unclean exit.
# Records COMPLETE flag if THE ACTIVE SPRINT's dev-report.md exists but the sprint
# is not yet accepted (done-but-not-yet-accepted) — same sprint-scoped logic as
# check-complete.sh, to avoid a prior sprint's dev-report falsely marking COMPLETE.
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

# Completion: scope to the active sprint (.claude/current-sprint); a sprint is
# freshly-complete iff it has dev-report.md but no cto-decision-*.md yet.
sprint_ready() {
    [ -f "$1/dev-report.md" ] || return 1
    ls "$1"/cto-decision-*.md >/dev/null 2>&1 && return 1
    return 0
}
mark() {
    touch "$CLAUDE_DIR/COMPLETE"
    echo "marked COMPLETE (sprint=$(basename "$1"))" >> "$CLAUDE_DIR/session.log"
}

if [ ! -f "$CLAUDE_DIR/COMPLETE" ]; then
    SPRINT=""
    [ -f "$CLAUDE_DIR/current-sprint" ] && SPRINT=$(tr -d '[:space:]' < "$CLAUDE_DIR/current-sprint")
    if [ -n "$SPRINT" ] && [ -d "$REPO_ROOT/docs/sprints/$SPRINT" ]; then
        sprint_ready "$REPO_ROOT/docs/sprints/$SPRINT" && mark "$REPO_ROOT/docs/sprints/$SPRINT"
    else
        for d in "$REPO_ROOT"/docs/sprints/*/; do
            [ -d "$d" ] || continue
            if sprint_ready "$d"; then mark "$d"; break; fi
        done
    fi
fi

exit 0
