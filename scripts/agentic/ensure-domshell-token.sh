#!/usr/bin/env bash
# ensure-domshell-token.sh — make DOMSHELL_TOKEN available before a DOMShell drive.
#
# DOMShell's MCP server/proxy authenticates with the DOMSHELL_TOKEN env var — the same
# path the server itself uses. A missing token surfaces only as an opaque 401 + "no
# domshell_execute tool" much later, so any CTO/repo agent setting DOMShell up for the
# FIRST time should run this: it checks the env, then known local token files, and if
# the token is missing everywhere it HALTS with a clear "provide the token" prompt
# (populate the env var, or write it to a gitignored local file the agent can reference).
#
# Reusable beyond QA-UX — call it from any DOMShell setup step.
#
# Usage:  ensure-domshell-token.sh [project-root]
# Exit 0  -> DOMSHELL_TOKEN is in the ENV the launching session will inherit (ready).
# Exit 1  -> not in env (the message explains exactly how to provide it). NEVER prints
#            the token value.

set -uo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TOKFILE_PROJECT="$ROOT/.claude/.domshell-token"          # gitignored, per-project
TOKFILE_HOME="$HOME/.domshell-token"                     # gitignored, per-user
DOMSHELL_ENV="${DOMSHELL_HOME:-$HOME/repos/DOMShell}/mcp-server/.env"

# 1. Already in the environment Claude Code will inherit -> ready.
if [ -n "${DOMSHELL_TOKEN:-}" ]; then
  echo "ensure-domshell-token: DOMSHELL_TOKEN present in env — OK."
  exit 0
fi

# 2. Not in env — look in known local files (do NOT print the value).
found=""
for f in "$TOKFILE_PROJECT" "$TOKFILE_HOME" "$DOMSHELL_ENV"; do
  [ -f "$f" ] || continue
  if [ "$(basename "$f")" = ".env" ]; then
    grep -q '^DOMSHELL_TOKEN=..*' "$f" 2>/dev/null && { found="$f"; break; }
  else
    [ -s "$f" ] && { found="$f"; break; }
  fi
done

if [ -n "$found" ]; then
  echo "ensure-domshell-token: DOMSHELL_TOKEN not in env, but found in $found."
  echo "  Export it in the shell that launches claude, then restart the session:"
  if [ "$(basename "$found")" = ".env" ]; then
    echo "    export DOMSHELL_TOKEN=\$(grep '^DOMSHELL_TOKEN=' \"$found\" | cut -d= -f2-)"
  else
    echo "    export DOMSHELL_TOKEN=\$(cat \"$found\")"
  fi
  exit 1
fi

# 3. Nowhere — first-time setup: ask for it.
echo "ensure-domshell-token: DOMSHELL_TOKEN is NOT set and no local token file was found."
echo "  DOMShell's server/proxy authenticates with this token. Provide it (first-time setup):"
echo "   1) get the token:  npx @apireno/domshell init   (or read it from your DOMShell mcp-server/.env)"
echo "   2) make it available to the launching session — EITHER:"
echo "        export DOMSHELL_TOKEN=<token>                       # in the shell that launches claude"
echo "      OR write it to a gitignored local file the agent can reference:"
echo "        printf '%s\\n' '<token>' > \"$TOKFILE_PROJECT\" && export DOMSHELL_TOKEN=\$(cat \"$TOKFILE_PROJECT\")"
echo "   3) restart the claude session so the env + MCP both load."
exit 1
