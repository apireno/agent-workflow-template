#!/bin/bash
# auto-paste-brief.sh — Per-repo SessionStart hook for Phase 2 dev-team sessions.
#
# Installed at .claude/hooks/auto-paste-brief.sh in each acme-* repo.
# Wired in .claude/settings.json under hooks.SessionStart.
#
# Two responsibilities:
#   1. Record the session_id (so /peek and /resume-dev-team can find this session)
#   2. If .claude/pending-prompt.md exists, emit it as additionalContext via stdout —
#      the SessionStart hook contract treats stdout as context injected into Claude.
#
# After successful auto-paste, the pending-prompt.md is moved to .claude/used-prompts/
# so it doesn't fire again on session restart.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLAUDE_DIR="$REPO_ROOT/.claude"
mkdir -p "$CLAUDE_DIR"

# Read hook input JSON from stdin to capture session_id + source
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
SOURCE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('source',''))" 2>/dev/null || echo "")

# Record session metadata
TS=$(date -u +%FT%TZ)
echo "$SESSION_ID" > "$CLAUDE_DIR/current-session.id"
echo "session_id=$SESSION_ID source=$SOURCE ts=$TS started" >> "$CLAUDE_DIR/session.log"

# Clear stale CRASHED + COMPLETE flags — this session is starting clean. A
# leftover COMPLETE (from a prior accepted sprint in this repo) would otherwise
# make /sprint-status report this fresh session as already done.
[ -f "$CLAUDE_DIR/CRASHED" ] && rm "$CLAUDE_DIR/CRASHED"
[ -f "$CLAUDE_DIR/COMPLETE" ] && rm "$CLAUDE_DIR/COMPLETE"

# Auto-paste the brief if present.
#
# IMPORTANT: SessionStart hook stdout is injected as `additionalContext` — that
# is system-side context, NOT a user message. Claude Code requires an actual
# user message before it will respond. The session will be IDLE until the
# operator types something in the Terminal tab.
#
# To minimize friction on the operator's side, we wrap the brief with explicit
# self-starting instructions so that even a one-character message ("go", "."
# etc.) is enough to kick off Phase 2 execution — Claude knows from this
# preamble that the user's first message is authorization to proceed.
BRIEF="$CLAUDE_DIR/pending-prompt.md"
if [ -f "$BRIEF" ] && [ "$SOURCE" = "startup" ]; then
    # Record the active sprint dir so the completion hooks scope to THIS sprint
    # (fallback — /handoff also writes .claude/current-sprint authoritatively).
    if [ ! -f "$CLAUDE_DIR/current-sprint" ]; then
        ACTIVE_SPRINT=$(grep -oE 'docs/sprints/sprint-[^/[:space:]]+' "$BRIEF" 2>/dev/null | sed 's#docs/sprints/##' | head -1)
        [ -n "$ACTIVE_SPRINT" ] && echo "$ACTIVE_SPRINT" > "$CLAUDE_DIR/current-sprint"
    fi
    cat <<'PREAMBLE'
=== CTO MISSION BRIEF — SELF-STARTING ON FIRST USER MESSAGE ===

The CTO has approved a sprint plan for you (below). This brief was injected
as additionalContext by the SessionStart hook, NOT as a user message — that
is why you are currently idle.

**When the operator sends their FIRST message in this session — even if it
is just a kickoff like "go", "begin", "start", or "."** — immediately begin
executing the sprint plan below. Do NOT ask for permission, clarification,
or confirmation: the CTO and 5 VP personas have already reviewed and
approved this plan (see the cto-decision-*.md file in the sprint dir for
the audit trail). Treat the operator's first message as authorization to
proceed, unless it explicitly redirects you to something else.

Your first action should be: (1) acknowledge the brief in one sentence,
(2) announce the starting task, (3) begin work.

=== END SELF-STARTING NOTE ===

PREAMBLE
    cat "$BRIEF"
    # Move brief to used-prompts so it doesn't re-fire on /resume
    mkdir -p "$CLAUDE_DIR/used-prompts"
    mv "$BRIEF" "$CLAUDE_DIR/used-prompts/$(date +%Y%m%d-%H%M%S)-prompt.md"
fi

exit 0
