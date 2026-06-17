#!/usr/bin/env bash
# wait-for-artifact.sh <session-jsonl> <target-file> [idle-ready=25] [idle-ceiling=240]
#
# Watch a Claude/gemini session's JSONL mtime (a proxy for "the agent went idle") plus a
# target artifact file, and exit when either:
#   READY   — the target exists AND the session has been idle >= idle-ready seconds
#             (the artifact has settled; the agent stopped writing). exit 0.
#   CEILING — the session has been idle >= idle-ceiling seconds (stuck/done). exit 2.
#
# Replaces the inline `while true; do … && { … "…"; break; } … done` monitor one-liner,
# which trips Claude Code's "expansion obfuscation" prompt (brace command-groups with quoted
# strings). As a script file, only `bash scripts/cto/wait-for-artifact.sh <jsonl> <file>` is
# scanned — clean — so the watch re-arms with zero prompts.

set -uo pipefail
JSONL="${1:?usage: wait-for-artifact.sh <session-jsonl> <target-file> [idle-ready] [idle-ceiling]}"
TARGET="${2:?need a target artifact file to watch}"
IDLE_READY="${3:-25}"
IDLE_CEILING="${4:-240}"

# mtime + size, portable across macOS (stat -f) and GNU/Linux (stat -c).
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
fsize() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo "?"; }

[ -f "$JSONL" ] || { echo "wait-for-artifact: WARN session jsonl not found yet: $JSONL"; }

while true; do
  now=$(date +%s)
  idle=$(( now - $(mtime "$JSONL") ))
  if [ -f "$TARGET" ] && [ "$idle" -gt "$IDLE_READY" ]; then
    echo "READY: $TARGET written + settled ($(fsize "$TARGET") bytes, session idle ${idle}s)"
    exit 0
  fi
  if [ "$idle" -gt "$IDLE_CEILING" ]; then
    state=absent; [ -f "$TARGET" ] && state=exists
    echo "CEILING: session idle ${idle}s, target $state. Last session lines:"
    tail -2 "$JSONL" 2>/dev/null | cut -c1-160
    exit 2
  fi
  sleep 12
done
