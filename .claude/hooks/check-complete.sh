#!/bin/bash
# check-complete.sh — Per-repo Stop hook for Phase 2 dev-team sessions.
#
# Installed at .claude/hooks/check-complete.sh in each acme-* repo.
# Wired in .claude/settings.json under hooks.Stop.
#
# Fires at every turn end. If a dev-report.md exists anywhere under docs/sprints/,
# touches .claude/COMPLETE so the CTO's /sprint-status detects completion within
# seconds — without waiting for the session to actually end.
#
# Idempotent. No-op if .claude/COMPLETE already exists or if no dev-report found.
# Stdout is NOT injected into Claude context for Stop hooks.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLAUDE_DIR="$REPO_ROOT/.claude"

# Fast path: already marked COMPLETE — nothing to do
[ -f "$CLAUDE_DIR/COMPLETE" ] && exit 0

mkdir -p "$CLAUDE_DIR"

# Drain stdin (Stop hooks receive JSON; we don't need anything from it but must consume it)
cat >/dev/null 2>&1 || true

# Scan for any dev-report.md under docs/sprints/
if find "$REPO_ROOT/docs/sprints" -name 'dev-report.md' -type f 2>/dev/null | head -1 | grep -q .; then
    touch "$CLAUDE_DIR/COMPLETE"
    TS=$(date -u +%FT%TZ)
    echo "marked COMPLETE via Stop hook (dev-report.md present) ts=$TS" >> "$CLAUDE_DIR/session.log"
fi

exit 0
