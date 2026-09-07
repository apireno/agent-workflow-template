#!/bin/bash
# derived-artifact-reminder.sh — Per-repo Stop hook: the REMINDER for governed derived
# artifacts (ADR-002 §4, point 2). Installed at .claude/hooks/ in each dev-team repo and
# wired under hooks.Stop next to check-complete.sh.
#
# Fires at every turn end. Runs the gate in audit mode against the worktree. When a finding
# is NEW (its fingerprint differs from the last one the lane was told about) the hook returns
# `decision: block` with the gate's text as the reason, so the session SEES it once and can
# act. Every later turn with the same finding is a systemMessage only (visible to the human,
# not the model) — advisory, never a loop. `stop_hook_active` is honoured: a turn that is
# already a continuation from a Stop hook is never blocked again.
#
# INERT unless the repo has .claude/derived-artifacts.yaml and the synced gate script.

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLAUDE_DIR="$REPO_ROOT/.claude"
GATE="$REPO_ROOT/scripts/agentic/derived-artifact-gate.sh"
[ -f "$CLAUDE_DIR/derived-artifacts.yaml" ] || { cat >/dev/null; exit 0; }
[ -f "$GATE" ] || { cat >/dev/null; exit 0; }

INPUT="$(cat 2>/dev/null || true)"
ACTIVE="$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo False)"

OUT="$(bash "$GATE" --worktree --audit --repo "$REPO_ROOT" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && { rm -f "$CLAUDE_DIR/derived-artifact-reminded"; exit 0; }

FINDINGS="$(printf '%s\n' "$OUT" | grep -E '^  \S+ +(block|warn) +(STALE|LEAK|DEAD-ROOT|NO-GENERATOR|NO-STAMP|GEN-ERROR|BAD-ENTRY)' )"
FP="$(printf '%s' "$FINDINGS" | shasum -a 256 2>/dev/null | cut -c1-16)"
LAST=""; [ -f "$CLAUDE_DIR/derived-artifact-reminded" ] && LAST="$(cat "$CLAUDE_DIR/derived-artifact-reminded")"
echo "derived-artifact reminder rc=$RC fp=$FP ts=$(date -u +%FT%TZ)" >> "$CLAUDE_DIR/session.log"

MSG="REMINDER (ADR-002, governed derived artifacts): this repo's derived artifact(s) are not current with the code:
$FINDINGS

Regenerate through the generator as shown (or: bash scripts/agentic/derived-artifact-gate.sh --fix), never by hand, and list it in dev-report.md. /sprint-verify checks this as a conformance row; the CTO's commit is refused while it is stale. If the finding is wrong (a seam in a path that should be excluded, a root that should move), say so in dev-report.md under 'Mechanism gaps' and continue."

if [ "$FP" != "$LAST" ] && [ "$ACTIVE" != "True" ]; then
    printf '%s' "$FP" > "$CLAUDE_DIR/derived-artifact-reminded"
    python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))' <<<"$MSG"
else
    python3 -c 'import json,sys; print(json.dumps({"systemMessage":"derived artifact still stale — see the earlier reminder (bash scripts/agentic/derived-artifact-gate.sh)"}))'
fi
exit 0
