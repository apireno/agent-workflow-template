#!/usr/bin/env bash
# qa-standup.sh — pre-drive standup + safety guard for the QA-UX accept-time gate.
#
# Guarantees the things the persona's Operating Constraints require before any driving:
#   1. PROD-ENDPOINT GUARD  — refuse to drive a production host (never test against prod).
#   2. Reachability         — the target app/server actually answers.
#   3. Provenance env       — export QA_CODE_SHA + QA_APP_VERSION for stamping artifacts.
#   4. Browser session      — (browser surface) check the DOMShell MCP bridge is up.
#
# Exits non-zero (aborting the drive) on prod-guard trip, unreachable target, or missing
# DOMShell bridge when the browser surface is in scope.
#
# Usage: qa-standup.sh --url <app-url> --sprint-dir <dir> [--surfaces browser,cli,mcp]
#
# NOTE — project-specific infra (intentionally TODO, per the VP acceptance criteria):
#   * Ephemeral/preview-env provisioning (per-branch isolated stack) is project-owned —
#     wire your deploy here, or point --url at an already-stood-up preview env.
#   * CI/headless: DOMShell drives a REAL Chrome; a headless CI runner needs a display
#     (containerized browser + Xvfb/VNC). Provide it in the CI job, not here.
#   * Test creds must be IAM/tenant-scoped to dummy data — endpoint check below is
#     defense-in-depth, NOT the only guard.

set -uo pipefail

URL=""; SPRINT_DIR=""; SURFACES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url)        URL="${2:-}"; shift 2 ;;
    --sprint-dir) SPRINT_DIR="${2:-}"; shift 2 ;;
    --surfaces)   SURFACES="${2:-}"; shift 2 ;;
    *)            shift ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# 1. PROD-ENDPOINT GUARD. Extend QA_PROD_HOSTS (comma-sep) per project.
PROD_RE="${QA_PROD_HOSTS:-prod|production|\\.com/api|api\\.|app\\.}"
if [ -n "$URL" ] && printf '%s' "$URL" | grep -Eiq "$PROD_RE"; then
  echo "qa-standup: PROD-GUARD TRIPPED — '$URL' looks like production. Refusing to drive."
  echo "  Point --url at a preview/ephemeral env. (Override pattern via QA_PROD_HOSTS only if you are certain.)"
  exit 1
fi

# 2. Reachability (skip if no URL — e.g. CLI/MCP-only sprint).
if [ -n "$URL" ]; then
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null || echo 000)"
    if [ "$code" = "000" ]; then
      echo "qa-standup: target UNREACHABLE at $URL (no response). Start the app/preview env first."
      exit 1
    fi
    echo "qa-standup: target reachable ($URL -> HTTP $code)"
  else
    echo "qa-standup: WARN curl absent — cannot verify reachability of $URL"
  fi
fi

# 3. Provenance env (stamp every artifact + asset with these).
export QA_CODE_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
export QA_APP_VERSION="${QA_APP_VERSION:-$( [ -f "$ROOT/VERSION" ] && cat "$ROOT/VERSION" 2>/dev/null || (command -v jq >/dev/null 2>&1 && [ -f "$ROOT/package.json" ] && jq -r '.version // "unknown"' "$ROOT/package.json" 2>/dev/null) || echo unknown )}"
echo "qa-standup: provenance  code_sha=$QA_CODE_SHA  app_version=$QA_APP_VERSION"

# 4. Browser surface -> DOMShell MCP bridge check (HTTP MCP default :3001).
if [ -z "$SURFACES" ] || printf '%s' "$SURFACES" | grep -q browser; then
  DS_PORT="${DOMSHELL_MCP_PORT:-3001}"
  if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null --max-time 4 "http://127.0.0.1:${DS_PORT}/mcp" 2>/dev/null; then
      echo "qa-standup: DOMShell MCP bridge responding on :${DS_PORT}"
    else
      echo "qa-standup: DOMShell MCP bridge NOT reachable on :${DS_PORT}."
      echo "  Start it (npx @apireno/domshell --allow-write), open the Chrome extension, and 'connect <token>'."
      echo "  (HITL: browser QA needs a live, connected DOMShell session — see persona Operating Constraints.)"
      exit 1
    fi
  fi
fi

echo "qa-standup: OK — clear to drive."
exit 0
