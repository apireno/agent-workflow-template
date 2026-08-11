#!/bin/bash
# inject-devteam-contract.sh — SessionStart hook for repos whose root CLAUDE.md
# belongs to somebody else (an upstream OSS project we clone but do not own).
#
# Normal dev repos get the contract AS their CLAUDE.md and this hook is inert.
# In a public/upstream clone, overwriting the tracked CLAUDE.md would show up in
# `git status` and leak into any PR sent upstream, so push-to-repos.sh --upstream
# installs the contract as CLAUDE.devteam.md (git-excluded) and this hook feeds it
# to the session as additionalContext instead.
#
# Self-disabling by design — safe to wire in every repo:
#   * no CLAUDE.devteam.md at the repo root            -> exit silently
#   * root CLAUDE.md IS our contract already           -> exit silently (no double-load)
#
# Wired in .claude/settings.json under hooks.SessionStart, BEFORE auto-paste-brief.sh
# so the role definition precedes the sprint brief.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONTRACT="$REPO_ROOT/CLAUDE.devteam.md"

# Drain stdin (hook input JSON) so the writer never blocks on a full pipe.
cat >/dev/null 2>&1 || true

[ -f "$CONTRACT" ] || exit 0

# If the root CLAUDE.md is already our dev-team contract, Claude Code has loaded
# it natively — emitting it again would just duplicate the whole thing.
OWN_MARKER='Your default role is \*\*Dev Team\*\*'
if [ -f "$REPO_ROOT/CLAUDE.md" ] && grep -qE "$OWN_MARKER" "$REPO_ROOT/CLAUDE.md" 2>/dev/null; then
    exit 0
fi

cat <<'PREAMBLE'
=== AGENT WORKFLOW CONTRACT (CLAUDE.devteam.md) ===

This repository is a clone of an upstream project that owns its own CLAUDE.md /
AGENTS.md — that file is the authority on how to BUILD, TEST and CONTRIBUTE here,
and it still applies. What follows is the separate agent-workflow contract that
governs your ROLE, review lifecycle and output boundaries. Both are in force; if
they ever conflict on repo mechanics (build commands, style, PR process), the
upstream file wins.

The workflow scaffolding in this repo (this contract, docs/personas/,
docs/sprints/, scripts/agentic/, .claude/) is LOCAL-ONLY and git-excluded via
.git/info/exclude. Never commit it, never add it to the tracked .gitignore, and
never include it in a PR sent upstream.

PREAMBLE
cat "$CONTRACT"
echo ""
echo "=== END AGENT WORKFLOW CONTRACT ==="

exit 0
