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

# 1. Already in the environment the launching session will inherit -> validate it.
# CRITICAL: a login-shell read (`zsh -lic`, "Restored session ..." banners, etc.) can
# prepend junk to the token -> a contaminated value that silently 401s/Disconnects.
# The real token is clean hex; reject contamination loudly instead of registering a bad one.
if [ -n "${DOMSHELL_TOKEN:-}" ]; then
  if printf '%s' "$DOMSHELL_TOKEN" | grep -qE '^[0-9a-fA-F]{32,}$'; then
    echo "ensure-domshell-token: DOMSHELL_TOKEN present in env (clean hex) — OK."
    exit 0
  fi
  rawlen=$(printf '%s' "$DOMSHELL_TOKEN" | wc -c | tr -d ' ')
  echo "ensure-domshell-token: DOMSHELL_TOKEN is set but is NOT clean hex (len=$rawlen) — likely login-shell banner contamination."
  echo "  Re-export just the hex portion (do NOT read it via a login shell / 'zsh -lic'):"
  echo "    export DOMSHELL_TOKEN=\$(printf '%s' \"\$DOMSHELL_TOKEN\" | grep -oE '[0-9a-fA-F]{32,}' | head -1)"
  echo "  then restart the session. (The token value is not printed here on purpose.)"
  exit 1
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
    echo "    export DOMSHELL_TOKEN=\$(grep '^DOMSHELL_TOKEN=' \"$found\" | cut -d= -f2- | tr -dc '0-9a-fA-F')"
  else
    echo "    export DOMSHELL_TOKEN=\$(tr -dc '0-9a-fA-F' < \"$found\")"
  fi
  echo "  (the trailing 'tr -dc' strips any banner/whitespace so only the hex token survives.)"
  exit 1
fi

# 2b. Last resort before asking — the live DOMShell proxy's own --token arg.
PROXY_TOK=$(ps -axo command 2>/dev/null | grep -oE 'domshell-proxy .*--token [0-9a-fA-F]{32,}' | grep -oE '[0-9a-fA-F]{32,}' | head -1)
if [ -n "$PROXY_TOK" ]; then
  echo "ensure-domshell-token: DOMSHELL_TOKEN not in env, but the running domshell-proxy is using a token."
  echo "  Export it from the live proxy (no login shell), then restart the session:"
  echo "    export DOMSHELL_TOKEN=\$(ps -axo command | grep -oE 'domshell-proxy .*--token [0-9a-fA-F]{32,}' | grep -oE '[0-9a-fA-F]{32,}' | head -1)"
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
