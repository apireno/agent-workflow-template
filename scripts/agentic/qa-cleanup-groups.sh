#!/usr/bin/env bash
# qa-cleanup-groups.sh — CTO janitor for orphan DOMShell tab groups (lanes).
#
# QA drives are supposed to use ONE named lane and close it. But a hard-killed / hung /
# crashed drive can leave its lane open. This is the manual cleanup the CTO runs when
# groups pile up: inspect first, then close specific lanes, the lanes a sprint recorded,
# or sweep all agent lanes.
#
# ENGINE: a DIRECT curl JSON-RPC client to the running DOMShell server's /mcp endpoint —
# NO gemini, NO claude -p. (gemini-CLI was deprecated by Google 2026-06-19, UNSUPPORTED_CLIENT;
# the old gemini-shelling janitor was dead. This talks to DOMShell over HTTP itself.)
# Auth: Bearer $DOMSHELL_TOKEN (the same token the proxy passes). The server is the one on
# :3001 (the CONTAINER — Docker/ToolHive — is canonical; never a native server alongside it); this never starts a second server.
#
# Safety: DEFAULTS TO LIST — it never closes anything unless you ask. `--all-agent` is
# deliberately separate + loud because it closes EVERY agent lane (other windows / Cowork too).
# `--sprint-dir <dir>` is the SAFEST close path: it closes only the lane ids THAT sprint
# recorded in <dir>/.qa-lanes, so a human's walked-away session is never touched.
#
# Usage:
#   qa-cleanup-groups.sh                       # LIST all DOMShell lanes (inspect first)
#   qa-cleanup-groups.sh --close 12,34         # close lanes 12 and 34 only
#   qa-cleanup-groups.sh --sprint-dir <dir>    # close exactly the ids in <dir>/.qa-lanes (+ qa-ux-* by name)
#   qa-cleanup-groups.sh --agent-default       # close ONLY generic unnamed `agent` lanes; SPARES named
#                                              #   (qa-ux-*) lanes — SAFE during an active drive. Interim
#                                              #   mitigation for the per-connection lane until ext >=1.3.2 (#53).
#   qa-cleanup-groups.sh --all-agent           # close EVERY agent lane (NOT shared/default) — loud

set -uo pipefail
ACTION="list"; IDS=""; SPRINT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)         ACTION=list; shift ;;
    --close)        ACTION=close; IDS="${2:-}"; shift 2 ;;
    --close=*)      ACTION=close; IDS="${1#--close=}"; shift ;;
    --all-agent)    ACTION=all; shift ;;
    --agent-default) ACTION=agentdefault; shift ;;
    --sprint-dir)   ACTION=registry; SPRINT_DIR="${2:-}"; shift 2 ;;
    --sprint-dir=*) ACTION=registry; SPRINT_DIR="${1#--sprint-dir=}"; shift ;;
    *)              echo "Unknown arg: $1 (use --list | --close <ids> | --sprint-dir <dir> | --all-agent)" >&2; shift ;;
  esac
done

command -v curl >/dev/null    || { echo "ERROR: curl not found."; exit 1; }
command -v python3 >/dev/null  || { echo "ERROR: python3 not found (used to build/parse JSON-RPC)."; exit 1; }

# Resolve the DOMShell auth token: env first, else the live proxy's --token arg.
TOK="${DOMSHELL_TOKEN:-}"
[ -n "$TOK" ] || TOK=$(ps -axo command 2>/dev/null | grep -oE 'domshell-proxy .*--token [^ ]+' | grep -oE -- '--token [^ ]+' | awk '{print $2}' | head -1)
[ -n "$TOK" ] || { echo "ERROR: DOMSHELL_TOKEN not resolvable (export it, or start the DOMShell proxy)."; exit 1; }

DS_URL="http://127.0.0.1:${DOMSHELL_MCP_PORT:-3001}/mcp"
ACCEPT='Accept: application/json, text/event-stream'

# --- minimal MCP-over-HTTP client (initialize -> session id -> tools/call) ---------------
SID=""
ds_init() {
  SID=$(curl -s -D - -o /dev/null --max-time 12 -X POST "$DS_URL" \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -H "$ACCEPT" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa-cleanup","version":"1"}}}' \
    2>/dev/null | grep -i '^mcp-session-id:' | awk '{print $2}' | tr -d '\r')
  [ -n "$SID" ] || { echo "ERROR: DOMShell did not return a session (server down on :${DOMSHELL_MCP_PORT:-3001}, or bad token)."; return 1; }
  # politeness: the initialized notification (server may require it before tools/call)
  curl -s -o /dev/null --max-time 8 -X POST "$DS_URL" \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -H "$ACCEPT" \
    -H "mcp-session-id: $SID" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null || true
}

# SSE response parser (inline -c so the curl pipe — not a heredoc — feeds python's stdin;
# `python3 - <<HEREDOC` would let the heredoc override the pipe and read no JSON).
DS_PARSE='import sys, json
text = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data:"):
        continue
    try:
        msg = json.loads(line[5:].strip())
    except Exception:
        continue
    for c in (msg.get("result", {}) or {}).get("content", []) or []:
        if isinstance(c, dict) and c.get("type") == "text":
            text.append(c.get("text", ""))
    if msg.get("error"):
        text.append("MCP error: " + json.dumps(msg["error"]))
print("\n".join(text).strip())'

# ds_exec "<command string>" "<group_id-or-empty>" -> prints the domshell text result.
# The payload builder uses `python3 - <<HEREDOC` with NO pipe in (it's $( ) capture), so the
# heredoc-as-program + argv-as-data form is correct there; only the parser needs the pipe.
ds_exec() {
  local cmd="$1" gid="${2:-}"
  local payload
  payload=$(python3 - "$cmd" "$gid" <<'PY'
import json, sys
cmd, gid = sys.argv[1], sys.argv[2]
args = {"command": cmd}
if gid:
    args["group_id"] = gid
print(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                  "params": {"name": "domshell_execute", "arguments": args}}))
PY
)
  curl -s --max-time 40 -X POST "$DS_URL" \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -H "$ACCEPT" \
    -H "mcp-session-id: $SID" --data "$payload" 2>/dev/null \
  | python3 -c "$DS_PARSE"
}

ds_init || exit 1

# SELF-REAP: pre-DOMShell-1.3.2, every MCP connection mints its own default `agent` lane on
# connect (NOTE-A), so this janitor's OWN connection leaks one lane per run. Close it on exit,
# REUSING THE SAME SID (same connection ⇒ no new lane is minted).
#
# POST-1.3.2 (DOMShell #53 — the team deleted the eager groupNew(["agent"]) in SESSION_START):
# there is NO connection-default lane, so the `group list` below finds nothing "(attached)" and
# this is a harmless no-op. Kept as belt-and-suspenders for operators still on older extensions;
# safe to delete once the fleet is fully on ext >=1.3.2 (per the DOMShell maintainers' memo).
# NOTE the read-only `group list` uses group_id "shared" — fine because it's READ-ONLY. After
# 1.3.2 "shared"/omitted means "the user's REAL browser, no isolation", so NEVER pair it with a
# write verb here; closes below use numeric lane ids (id-scoped), never "shared".
self_reap() {
  local attached
  attached=$(ds_exec "group list" "shared" 2>/dev/null | grep -i '(attached)' | grep -oE '[0-9]{4,}' | head -1)
  if [ -n "$attached" ]; then
    ds_exec "group close" "$attached" >/dev/null 2>&1 || true
  fi
}
trap self_reap EXIT

case "$ACTION" in
  list)
    echo "qa-cleanup: listing DOMShell lanes (read-only)..."
    ds_exec "group list" "shared"
    echo ""
    echo "Next: qa-cleanup-groups.sh --close <id>[,<id>...]   |   --sprint-dir <dir>   |   --all-agent"
    ;;

  close)
    [ -n "$IDS" ] || { echo "ERROR: --close needs ids, e.g. --close 12,34"; exit 1; }
    echo "qa-cleanup: closing lanes: $IDS"
    echo "$IDS" | tr ',' '\n' | while IFS= read -r id; do
      id=$(printf '%s' "$id" | tr -dc '0-9'); [ -n "$id" ] || continue
      echo "  close lane $id:"; ds_exec "group close" "$id" | sed 's/^/    /'
    done
    ;;

  registry)
    # PROVENANCE sweep — close exactly the ids THIS round recorded (safe: never touches a
    # group the drive didn't mint). Works even if the drive's own session died.
    REG="$SPRINT_DIR/.qa-lanes"
    if [ ! -s "$REG" ]; then echo "qa-cleanup: no recorded lanes at $REG (nothing to sweep)."; exit 0; fi
    echo "qa-cleanup: closing this round's recorded lanes from $REG:"
    while IFS= read -r id; do
      id=$(printf '%s' "$id" | tr -dc '0-9'); [ -n "$id" ] || continue
      echo "  close lane $id:"; ds_exec "group close" "$id" | sed 's/^/    /'
    done < "$REG"
    # Belt-and-suspenders: also close any lane whose name starts with qa-ux- (catches an
    # orphan whose drive died before recording its id). Needs DOMShell extension >=1.3.2
    # (older titles the group "agent"); harmless no-op otherwise.
    echo "  sweeping any remaining qa-ux-* named lanes:"
    LANES=$(ds_exec "group list" "shared")
    printf '%s\n' "$LANES" | grep -iE 'qa-ux-' | grep -oE '[0-9]+' | sort -u | while IFS= read -r id; do
      [ -n "$id" ] || continue; echo "    close qa-ux lane $id:"; ds_exec "group close" "$id" | sed 's/^/      /'
    done
    rm -f "$REG"
    ;;

  agentdefault)
    # SAFE interim sweep (pre-DOMShell-1.3.2): close ONLY the generic, unnamed `agent`
    # connection-default lanes — the ones every MCP connection mints until ext #53/1.3.2
    # ships. SPARES every NAMED lane (qa-ux-*, etc.), so it is safe to run DURING an active
    # drive: the drive works in its named lane, not the generic `agent` one. Once you install
    # ext >=1.3.2 these lanes stop being created and this mode becomes a no-op.
    LANES=$(ds_exec "group list" "shared")
    echo "qa-cleanup: lanes:"; printf '%s\n' "$LANES" | sed 's/^/  /'
    # Match lines whose lane NAME is exactly "agent" (name token immediately before "[id N]");
    # a named lane like "qa-ux-foo  [id N]" or "agent-x" does NOT match "agent  [id".
    IDS=$(printf '%s\n' "$LANES" | grep -E '(^|[[:space:]])agent[[:space:]]+\[id[[:space:]]+[0-9]+\]' | grep -oE '\[id[[:space:]]+[0-9]+\]' | grep -oE '[0-9]+')
    if [ -z "$IDS" ]; then echo "qa-cleanup: no generic 'agent' connection-default lanes to close."; else
      echo "$IDS" | while IFS= read -r id; do
        [ -n "$id" ] || continue; echo "  close generic agent lane $id:"; ds_exec "group close" "$id" | sed 's/^/    /'
      done
      echo "qa-cleanup: closed the generic 'agent' lanes; named (qa-ux-*) lanes left untouched."
    fi
    ;;
  all)
    echo "qa-cleanup: WARNING — sweeping ALL agent lanes."
    echo "  This closes EVERY DOMShell agent lane, including other Chrome windows and any Cowork session."
    echo "  Only do this when no other legitimate DOMShell session is active."
    LANES=$(ds_exec "group list" "shared")
    echo "  current lanes:"; printf '%s\n' "$LANES" | sed 's/^/    /'
    # Best-effort: close every numeric lane id we can see (the shared/default lane has no
    # closeable group, so a close on it is a harmless no-op).
    printf '%s\n' "$LANES" | grep -oE 'lane[s]?[^0-9]*[0-9]+|\b[0-9]{1,6}\b' | grep -oE '[0-9]+' | sort -u | while IFS= read -r id; do
      [ -n "$id" ] || continue; echo "  close lane $id:"; ds_exec "group close" "$id" | sed 's/^/    /'
    done
    ;;
esac
