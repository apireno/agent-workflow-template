#!/bin/bash
# check-complete.sh — Per-repo Stop hook for Phase 2 dev-team sessions.
#
# Installed at .claude/hooks/check-complete.sh in each dev-team repo.
# Wired in .claude/settings.json under hooks.Stop (see settings.devteam.json.template).
#
# Fires at every turn end. Touches .claude/COMPLETE when THE ACTIVE SPRINT's
# dev-report.md has landed but the sprint is not yet accepted — so the CTO's
# /sprint-status detects completion within seconds.
#
# Sprint scope (fixes the repo-global false-positive): once a repo accumulates
# more than one sprint dir, a prior sprint's dev-report.md must NOT mark a NEW
# session COMPLETE. We scope to the active sprint recorded by auto-paste-brief.sh
# in .claude/current-sprint, and only treat a sprint as freshly-complete when it
# has dev-report.md but no cto-decision-*.md (done-but-not-yet-accepted).
#
# Idempotent. No-op if .claude/COMPLETE already exists.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLAUDE_DIR="$REPO_ROOT/.claude"

# Fast path: already marked COMPLETE — nothing to do
[ -f "$CLAUDE_DIR/COMPLETE" ] && exit 0

mkdir -p "$CLAUDE_DIR"

# Drain stdin (Stop hooks receive JSON; we don't need it but must consume it)
cat >/dev/null 2>&1 || true

# A sprint dir is "freshly complete" iff it has dev-report.md AND no cto-decision-*.md
sprint_ready() {
    [ -f "$1/dev-report.md" ] || return 1
    ls "$1"/cto-decision-*.md >/dev/null 2>&1 && return 1   # already accepted — not a fresh signal
    return 0
}

mark() {
    touch "$CLAUDE_DIR/COMPLETE"
    echo "marked COMPLETE via Stop hook (sprint=$(basename "$1")) ts=$(date -u +%FT%TZ)" >> "$CLAUDE_DIR/session.log"
}

SPRINT=""
[ -f "$CLAUDE_DIR/current-sprint" ] && SPRINT=$(tr -d '[:space:]' < "$CLAUDE_DIR/current-sprint")

if [ -n "$SPRINT" ] && [ -d "$REPO_ROOT/docs/sprints/$SPRINT" ]; then
    # Scoped to the active sprint — the robust path
    sprint_ready "$REPO_ROOT/docs/sprints/$SPRINT" && mark "$REPO_ROOT/docs/sprints/$SPRINT"
else
    # Fallback (current-sprint not recorded): any done-but-not-accepted sprint
    for d in "$REPO_ROOT"/docs/sprints/*/; do
        [ -d "$d" ] || continue
        if sprint_ready "$d"; then mark "$d"; break; fi
    done
fi

exit 0
