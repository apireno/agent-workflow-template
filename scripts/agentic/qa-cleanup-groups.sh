#!/usr/bin/env bash
# qa-cleanup-groups.sh — CTO janitor for orphan DOMShell tab groups.
#
# QA drives are supposed to use ONE lane and close it (single-lane protocol + on-exit
# sweep in qa-drive-gemini.sh). But an LLM driver can still spawn extra groups, and a
# hard-killed/hung drive can leave its lane open. This is the manual cleanup the CTO
# runs when groups pile up: inspect first, then close specific lanes or sweep all.
#
# Safety: it is timeout-guarded (won't itself hang), and DEFAULTS TO LIST — it never
# closes anything unless you ask. `--all-agent` is deliberately separate + loud because
# it closes EVERY agent lane, including other windows / a Cowork session.
#
# Usage:
#   qa-cleanup-groups.sh                  # LIST all DOMShell lanes (inspect first)
#   qa-cleanup-groups.sh --close 12,34    # close lanes 12 and 34 only
#   qa-cleanup-groups.sh --all-agent      # close EVERY agent lane (NOT shared/default) — loud warning
#
# $0 / bright-line clean: gemini + domshell, never claude -p.

set -uo pipefail
ACTION="list"; IDS=""; SPRINT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)         ACTION=list; shift ;;
    --close)        ACTION=close; IDS="${2:-}"; shift 2 ;;
    --close=*)      ACTION=close; IDS="${1#--close=}"; shift ;;
    --all-agent)    ACTION=all; shift ;;
    --sprint-dir)   ACTION=registry; SPRINT_DIR="${2:-}"; shift 2 ;;
    --sprint-dir=*) ACTION=registry; SPRINT_DIR="${1#--sprint-dir=}"; shift ;;
    *)              echo "Unknown arg: $1 (use --list | --close <ids> | --sprint-dir <dir> | --all-agent)" >&2; shift ;;
  esac
done

command -v gemini >/dev/null || { echo "ERROR: gemini-CLI not found."; exit 1; }

# Resolve token (env, else the live proxy's --token arg) + register domshell for gemini.
TOK="${DOMSHELL_TOKEN:-}"
if ! printf '%s' "$TOK" | grep -qE '^[0-9a-fA-F]{32,}$'; then
  TOK=$(ps -axo command 2>/dev/null | grep -oE 'domshell-proxy .*--token [0-9a-fA-F]{32,}' | grep -oE '[0-9a-fA-F]{32,}' | head -1)
fi
[ -n "$TOK" ] || { echo "ERROR: DOMSHELL_TOKEN not resolvable (export it, or start the DOMShell proxy)."; exit 1; }
gemini mcp add --scope user --trust domshell npx -- -y -p @apireno/domshell domshell-proxy --port 3001 --token "$TOK" >/dev/null 2>&1 || true

# Portable timeout (macOS lacks `timeout`; coreutils ships `gtimeout`).
TO=$(command -v timeout || command -v gtimeout || true)
run() { if [ -n "$TO" ]; then "$TO" 90 gemini --yolo --allowed-mcp-server-names domshell 2>&1; else gemini --yolo --allowed-mcp-server-names domshell 2>&1; fi | grep -vE "Loaded cached|YOLO mode is enabled" ; }

case "$ACTION" in
  list)
    echo "qa-cleanup: listing DOMShell lanes (read-only)..."
    printf 'Run the domshell command "group list" and print its output verbatim. Do nothing else — do not close anything.\n' | run
    echo ""
    echo "Next: qa-cleanup-groups.sh --close <id>[,<id>...]   (targeted)   |   --all-agent   (sweep every agent lane)"
    ;;
  close)
    [ -n "$IDS" ] || { echo "ERROR: --close needs ids, e.g. --close 12,34"; exit 1; }
    CMDS=$(echo "$IDS" | tr ',' '\n' | while IFS= read -r id; do [ -n "$id" ] && printf 'group close %s\n' "$id"; done)
    echo "qa-cleanup: closing lanes: $IDS"
    printf 'Run these domshell commands, one per line, then report each result. Do nothing else:\n%s\n' "$CMDS" | run
    ;;
  registry)
    # PROVENANCE sweep — close exactly the lane ids THIS round recorded (safe: never touches a
    # group the drive didn't mint, so a human's walked-away session is untouched). This is the
    # invoker's post-round cleanup; it works even if the drive's own engine 403'd/died.
    REG="$SPRINT_DIR/.qa-lanes"
    if [ ! -s "$REG" ]; then echo "qa-cleanup: no recorded lanes at $REG (nothing to sweep)."; exit 0; fi
    CMDS=$(while IFS= read -r id; do id=$(printf '%s' "$id" | tr -dc '0-9'); [ -n "$id" ] && printf 'group close %s\n' "$id"; done < "$REG")
    echo "qa-cleanup: closing this round's recorded lanes from $REG:"; printf '%s\n' "$CMDS" | sed 's/^/  /'
    printf 'Run these domshell commands, one per line, then report each result. Do nothing else:\n%s\n' "$CMDS" | run
    # On DOMShell extension >=1.3.2, also sweep any group named qa-ux-* (catches orphans whose
    # drive died before recording its id). Pre-1.3.2 the title is "agent", so this is a no-op then.
    printf 'Run domshell "group list". For EVERY lane whose name/title starts with "qa-ux-", run "group close <id>". Report what you closed. Do nothing else.\n' | run
    rm -f "$REG"
    ;;
  all)
    echo "qa-cleanup: WARNING — sweeping ALL agent lanes."
    echo "  This closes EVERY DOMShell agent lane, including other Chrome windows and any Cowork session."
    echo "  Only do this when no other legitimate DOMShell session is active."
    printf 'Run domshell "group list". Then for EVERY lane that is NOT the shared/default lane, run "group close <id>" using its numeric id. Report every id you closed. Do nothing else.\n' | run
    ;;
esac
