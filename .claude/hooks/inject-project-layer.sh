#!/bin/bash
# inject-project-layer.sh — SessionStart hook for dev lanes: print the project's and this repo's
# standing orders (and kickoff checklist) into the session's context (CEO 2026-11-04).
#
# The project layer lives in the CTO home (<cto-home>/.cto/project/, found via .cto-path or
# ~/.cto/home); the repo layer in <repo>/.claude/project/. Both are binding at the level of the
# dev-team contract. Inert when neither exists. Never fails the session start.
set -uo pipefail
cat >/dev/null 2>&1 || true
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PL="$ROOT/scripts/agentic/project-layer.sh"
[ -x "$PL" ] || exit 0
OUT="$(bash "$PL" kickoff --repo "$ROOT" --quiet 2>/dev/null)"
[ -n "$OUT" ] || exit 0
echo "=== PROJECT / REPO STANDING ORDERS (binding, same level as CLAUDE.md) ==="
printf '%s\n' "$OUT"
exit 0
