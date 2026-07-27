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

# 4. Browser surface -> DOMShell must be (a) REGISTERED in this repo's .mcp.json
#    so the agent actually has the domshell_execute tool, and (b) reachable.
if [ -z "$SURFACES" ] || printf '%s' "$SURFACES" | grep -q browser; then
  # 4a. SELF-PROVISION the DOMShell MCP registration into the UX/TARGET repo — the
  # one that owns the sprint dir (where the app under test + DOMShell live). A
  # project's CTO home and non-UX repos do NOT get a browser MCP; only UX-focused
  # repos do. The browser drive must then run from a session ROOTED IN that repo so
  # the tool actually loads (MCP loads at session start). Missing -> we ADD it
  # (idempotent, preserving existing servers), same self-heal pattern as /handoff.
  TARGET_ROOT="$ROOT"
  [ -n "$SPRINT_DIR" ] && TARGET_ROOT="$(git -C "$SPRINT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"
  MCP_JSON="$TARGET_ROOT/.mcp.json"
  REG=$(python3 - "$MCP_JSON" <<'PY' 2>/dev/null
import json, sys, os
p = sys.argv[1]; d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: d = {}
s = d.setdefault("mcpServers", {})
if "domshell" in s:
    # Only the proxy form is correct here. A direct http/sse entry (e.g.
    # url=:3001|:17854/mcp) 401s without the token; a `--allow-write` spawn
    # conflicts with the running server. Flag those as wrong so they get fixed.
    print("PRESENT" if "domshell-proxy" in json.dumps(s["domshell"]) else "PRESENT_WRONG")
else:
    # stdio PROXY that connects to the already-running DOMShell server on :3001
    # (the CONTAINER — Docker/ToolHive — is canonical; NEVER a native server
    # alongside it) and authenticates with $DOMSHELL_TOKEN. This does NOT start a
    # second server (no :3001/:9876 port conflict) — the spawn form
    # (`--allow-write`) starts a colliding second server. Token via env so it is
    # never written into the (committable) config file.
    s["domshell"] = {"command": "npx", "args": ["-y", "-p", "@apireno/domshell",
        "domshell-proxy", "--port", "3001", "--token", "${DOMSHELL_TOKEN}"]}
    json.dump(d, open(p, "w"), indent=2)
    print("ADDED")
PY
)
  # Ensure the proxy's auth token is available (env is the path the server uses).
  # First-time setup with no token gets a clear prompt instead of a later 401.
  TOK_HELPER="$(dirname "$0")/ensure-domshell-token.sh"
  if [ -x "$TOK_HELPER" ]; then
    "$TOK_HELPER" "$TARGET_ROOT" || { echo "qa-standup: DOMSHELL_TOKEN not ready (see above) — aborting browser drive."; exit 1; }
  elif [ -z "${DOMSHELL_TOKEN:-}" ]; then
    echo "qa-standup: WARNING — DOMSHELL_TOKEN not set and ensure-domshell-token.sh missing; the proxy will 401."
  fi
  if [ "$REG" = "ADDED" ]; then
    echo "qa-standup: self-provisioned DOMShell (stdio proxy -> :3001) into ${MCP_JSON} (UX/target repo; existing servers preserved)."
    echo "  It CONNECTS to the already-running DOMShell server — the CONTAINER (Docker/ToolHive) is canonical,"
    echo "  NEVER a native server alongside it — via \$DOMSHELL_TOKEN. It does NOT start a conflicting server."
    echo "  >>> Export DOMSHELL_TOKEN, then run the drive from a session ROOTED IN ${TARGET_ROOT} (open/restart claude there), connect the Chrome extension, and re-run --mode drive. <<<"
    exit 1
  elif [ "$REG" = "PRESENT_WRONG" ]; then
    echo "qa-standup: ${MCP_JSON} has a DOMShell entry that is NOT the proxy form — a direct http/sse url 401s without the token, and a server-spawn conflicts with the running server. Replace it with the proxy form below, then restart the session:"
    echo '    "domshell": { "command": "npx", "args": ["-y","-p","@apireno/domshell","domshell-proxy","--port","3001","--token","${DOMSHELL_TOKEN}"] }'
    exit 1
  elif [ "$REG" != "PRESENT" ]; then
    echo "qa-standup: could not auto-register DOMShell in ${MCP_JSON} (python3 unavailable?). Add manually + restart:"
    echo '    "domshell": { "command": "npx", "args": ["-y","-p","@apireno/domshell","domshell-proxy","--port","3001","--token","${DOMSHELL_TOKEN}"] }'
    exit 1
  fi
  DS_PORT="${DOMSHELL_MCP_PORT:-3001}"
  DS_EXT_PORT="${DOMSHELL_EXT_PORT:-9876}"
  DS_MIN_VERSION="${DOMSHELL_MIN_VERSION:-2.0.9}"

  # 4b. DUPLICATE-BRIDGE PREFLIGHT (RCA 2026-07 — the 9-day outage).
  # Two DOMShell SERVERS can coexist invisibly: a native `--allow-write` spawn binding
  # 127.0.0.1 and a container binding 0.0.0.0 inside its own netns. Whichever squatted the
  # host port wins, and EVERY proxy silently relays to it — the container looks "running"
  # the whole time. Refuse to drive on any duplicate signal; a wrong-instance drive
  # produces confidently wrong QA findings, which is worse than no drive.
  DUP=0
  if command -v lsof >/dev/null 2>&1; then
    for _p in "$DS_PORT" "$DS_EXT_PORT"; do
      _n=$(lsof -nP -iTCP:"$_p" -sTCP:LISTEN -t 2>/dev/null | sort -u | grep -c '[0-9]')
      if [ "${_n:-0}" -gt 1 ]; then
        echo "qa-standup: DUPLICATE BRIDGE — ${_n} distinct processes are LISTENING on :${_p}."
        lsof -nP -iTCP:"$_p" -sTCP:LISTEN 2>/dev/null | sed 's/^/    /' | head -6
        DUP=1
      fi
    done
  fi
  # A NATIVE server process alongside a DOMShell CONTAINER is the exact RCA'd collision.
  # Match ONLY a JS-runtime process (node/npx/bun/deno) running domshell — filtering on the
  # executable (comm), not the raw command line: a bare `grep -i domshell` over argv also
  # matches any shell/agent that merely MENTIONS domshell (e.g. an exported DOMSHELL_* var),
  # which false-fails the standup. `domshell-proxy` is excluded — the proxy is a CLIENT, not
  # a server, and is expected to be running. Containerized servers live in their own PID
  # namespace and correctly do NOT appear here.
  NATIVE_SRV=$(ps -axo pid,comm,command 2>/dev/null \
    | awk '{c=$2; sub(/.*\//,"",c); if (c ~ /^(node|npx|bun|deno)/) print}' \
    | grep -i 'domshell' | grep -v 'domshell-proxy' | cut -c1-160 | head -3)
  CONTAINER_UP=0
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qi domshell && CONTAINER_UP=1
  command -v thv    >/dev/null 2>&1 && thv list 2>/dev/null | grep -qi domshell && CONTAINER_UP=1
  if [ -n "$NATIVE_SRV" ] && [ "$CONTAINER_UP" -eq 1 ]; then
    echo "qa-standup: TWO DOMSHELL SERVERS — a native server process is running WHILE a DOMShell"
    echo "  container is up. They collide silently on :${DS_PORT}/:${DS_EXT_PORT}; proxies relay to"
    echo "  whichever squatted the port first (this caused a 9-day outage, RCA 2026-07)."
    echo "  Native process(es):"; printf '%s\n' "$NATIVE_SRV" | sed 's/^/    /'
    echo "  FIX: kill the native server (the container is canonical), then re-run the standup."
    DUP=1
  fi
  [ "$DUP" -eq 1 ] && { echo "qa-standup: refusing to drive until the duplicate bridge is resolved."; exit 1; }

  if command -v curl >/dev/null 2>&1; then
    # 4c. IDENTITY + VERSION assert (not just reachability). `initialize` answers
    # UNAUTHENTICATED with {"result":{"serverInfo":{"name":"domshell","version":"X.Y.Z"}}}
    # (SSE-framed: lines prefixed `data: `), so we can prove (a) it IS DOMShell, not a
    # foreign service squatting the port, and (b) WHICH instance — a stale/wrong server
    # reports an older version (pre-2.0.9 reported a hardcoded "1.0.0").
    BODY=$(curl -s --max-time 6 -X POST "http://127.0.0.1:${DS_PORT}/mcp" \
             -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
             -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa-standup","version":"1"}}}' 2>/dev/null)
    if [ -z "$BODY" ] && ! curl -s -o /dev/null --max-time 4 "http://127.0.0.1:${DS_PORT}/mcp" 2>/dev/null; then
      echo "qa-standup: nothing answering on :${DS_PORT}."
      echo "  Start the DOMShell server — the CONTAINER is the canonical form:"
      echo "      thv run domshell-mcp-server        # ToolHive"
      echo "      docker start domshell-mcp-server   # or the equivalent docker run"
      echo "  Then open the Chrome extension and 'connect <token>'. (HITL: browser QA needs a live session.)"
      echo "  Do NOT also run a native 'npx @apireno/domshell --allow-write' SERVER — a native server and"
      echo "  the container collide silently on :${DS_PORT}/:${DS_EXT_PORT} (RCA 2026-07, 9-day outage)."
      echo "  Native server ONLY as a last resort, and ONLY if ALL of: 'thv list' shows nothing AND no"
      echo "  DOMShell container is running AND nothing is listening on :${DS_EXT_PORT}. NEVER both."
      exit 1
    fi
    # Parse serverInfo out of the (possibly SSE-framed) body.
    DS_NAME=$(printf '%s' "$BODY" | grep -o '"serverInfo"[^}]*}' | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    DS_VER=$(printf  '%s' "$BODY" | grep -o '"serverInfo"[^}]*}' | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$DS_NAME" ]; then
      if printf '%s' "$BODY" | grep -q '"jsonrpc"'; then
        # Speaks JSON-RPC but wouldn't identify itself (e.g. a future build gating
        # `initialize` behind auth). Not proof of a wrong instance -> warn, don't block.
        echo "qa-standup: WARN — :${DS_PORT} speaks JSON-RPC but returned no serverInfo; cannot assert"
        echo "  identity/version. Proceeding, but verify you are driving the intended instance."
      else
        echo "qa-standup: PORT COLLISION — something is on :${DS_PORT} but it is NOT DOMShell"
        echo "  (no JSON-RPC/serverInfo on /mcp — a foreign service is squatting the port)."
        echo "  Free :${DS_PORT} (stop the squatter), or point DOMShell elsewhere and set DOMSHELL_MCP_PORT."
        echo "  Detected listener:"; lsof -nP -iTCP:${DS_PORT} -sTCP:LISTEN 2>/dev/null | sed 's/^/    /' | head -4
        exit 1
      fi
    elif ! printf '%s' "$DS_NAME" | grep -qi domshell; then
      echo "qa-standup: WRONG SERVER on :${DS_PORT} — it identifies as '${DS_NAME}', not DOMShell."
      echo "  Free the port or set DOMSHELL_MCP_PORT to where DOMShell actually listens."
      exit 1
    elif [ -n "$DS_VER" ] && [ "$(printf '%s\n%s\n' "$DS_MIN_VERSION" "$DS_VER" | sort -V | head -1)" != "$DS_MIN_VERSION" ]; then
      echo "qa-standup: STALE/WRONG DOMSHELL INSTANCE — :${DS_PORT} reports v${DS_VER}, below the"
      echo "  required v${DS_MIN_VERSION}. A stale instance squatting the port is the RCA'd failure mode"
      echo "  (pre-2.0.9 also reported a hardcoded '1.0.0', so an old squatter can masquerade)."
      echo "  Stop it, start the current CONTAINER, and re-run. (Override: DOMSHELL_MIN_VERSION=...)"
      echo "  Detected listener:"; lsof -nP -iTCP:${DS_PORT} -sTCP:LISTEN 2>/dev/null | sed 's/^/    /' | head -4
      exit 1
    else
      echo "qa-standup: DOMShell confirmed on :${DS_PORT} — name=${DS_NAME} version=${DS_VER:-unreported} (min ${DS_MIN_VERSION})."
    fi
  fi
fi

echo "qa-standup: OK — clear to drive."
exit 0
