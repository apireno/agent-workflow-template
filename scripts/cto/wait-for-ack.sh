#!/usr/bin/env bash
# wait-for-ack.sh — wait for a lane to reply "ACK <TAG>". One watcher per wait.
#
#   wait-for-ack.sh <repo-path|repo-name|window-id|transcript.jsonl> <TAG> [--timeout SECS] [--history]
#
# WHY (2026-10-19). Every CTO watcher one weekend was a hand-written loop grepping a lane's JSONL.
# Each one had to re-learn the same two traps: the CTO's own prompt ("reply ACK R17 when done") is in
# the transcript too, as a USER message; and lanes PROMISE acks in prose ("I'll send ACK R17 once the
# suite is green"). Both matched a naive grep, so watchers fired before the work was done.
#
# MATCH RULE. Only ASSISTANT messages; only text APPENDED after this watcher started (unless
# --history); and "ACK <TAG>" must stand on a line of its own (optionally followed by " — note").
# A promise inside a sentence never matches. Tags match exactly (R17 does not match R170).
#
# RESOLVE. A path: its .claude/current-session.id, else the session working there now
# (session-for-path.sh). A repo name: looked up in the CTO registry. A number: the window id is
# looked up in every registered repo's .claude/terminal-windows.tsv. A .jsonl: used as given.
#
# Run it in the background (or under Monitor): a skill or tool shell is killed after ~2 minutes.
# Exit: 0 acked (prints the line + time) · 3 timeout · 2 cannot resolve a transcript / usage
set -uo pipefail
TARGET="${1:-}"; TAG="${2:-}"; TIMEOUT=1800; HISTORY=0
[ $# -ge 2 ] && shift 2 || { echo "usage: wait-for-ack.sh <repo|name|window-id|file.jsonl> <TAG> [--timeout SECS] [--history]" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in --timeout) TIMEOUT="${2:?}"; shift ;; --timeout=*) TIMEOUT="${1#--timeout=}" ;; --history) HISTORY=1 ;;
        *) echo "wait-for-ack: unknown argument '$1'" >&2; exit 2 ;; esac; shift
done
case "$TAG" in ''|*[!A-Za-z0-9._:-]*) echo "wait-for-ack: TAG must be letters, digits, . _ : - (got '$TAG')" >&2; exit 2 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd -P)"
REG=""; for c in "${CTO_HOME:-}" "$(cd "$HERE/../.." && pwd)" "$(tr -d '[:space:]' < "$HOME/.cto/home" 2>/dev/null)"; do
    [ -n "$c" ] && [ -f "$c/.cto/projects.yaml" ] && ! grep -q '/Users/yourname/' "$c/.cto/projects.yaml" && { REG="$c/.cto/projects.yaml"; break; }; done
repo_paths() { [ -n "$REG" ] && python3 - "$REG" <<'PY'
import re,sys
for b in re.split(r'(?=- name:)', open(sys.argv[1]).read()):
    n=re.search(r'- name:\s*(\S+)',b); p=re.search(r'path:\s*(\S+)',b)
    if n and p: print(n.group(1)+"\t"+p.group(1))
PY
}
transcript_for_dir() {
    local d="$_DIR" sid t
    if [ -f "$d/.claude/current-session.id" ]; then
        sid="$(tr -d '[:space:]' < "$d/.claude/current-session.id")"
        t="$(ls -1 "$HOME/.claude/projects/"*/"$sid.jsonl" 2>/dev/null | head -1)"
        [ -n "$t" ] && { echo "$t"; return; }
    fi
    bash "$HERE/session-for-path.sh" "$d" 2>/dev/null
}
T=""
case "$TARGET" in
    *.jsonl) T="$TARGET" ;;
    *[!0-9]*)
        if [ -d "$TARGET" ]; then _DIR="$TARGET"; T="$(transcript_for_dir)"
        else _DIR="$(repo_paths | awk -F'\t' -v n="$TARGET" '$1==n{print $2}')"; [ -n "$_DIR" ] && T="$(transcript_for_dir)"; fi ;;
    *)  while IFS=$'\t' read -r _n _p; do
            [ -f "$_p/.claude/terminal-windows.tsv" ] && awk -F'\t' -v w="$TARGET" '$1==w||$2==w{f=1} END{exit !f}' "$_p/.claude/terminal-windows.tsv" && { _DIR="$_p"; T="$(transcript_for_dir)"; break; }
        done < <(repo_paths) ;;
esac
[ -n "$T" ] && [ -f "$T" ] || { echo "wait-for-ack: no transcript for '$TARGET' (no session id, no session working there, or unknown window)." >&2; exit 2; }
echo "wait-for-ack: watching $(basename "$T" .jsonl) for 'ACK $TAG' (timeout ${TIMEOUT}s$( [ "$HISTORY" = 1 ] && echo ', including history'))" >&2
START=0; [ "$HISTORY" = 1 ] || START=$(wc -c < "$T" | tr -d ' ')
python3 - "$T" "$TAG" "$START" "$TIMEOUT" <<'PY'
import json, re, sys, time
path, tag, off, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
pat = re.compile(r'^[ \t>*_`]*ACK[ \t]+' + re.escape(tag) + r'(?![A-Za-z0-9._:-])[^\n]*$', re.M)
deadline = time.time() + timeout; buf = ""
while True:
    with open(path, "r", errors="replace") as f:
        f.seek(off); chunk = f.read(); off = f.tell()
    buf += chunk
    lines = buf.split("\n"); buf = lines.pop()          # keep a partial last line for next round
    for line in lines:
        try: d = json.loads(line)
        except Exception: continue
        if d.get("type") != "assistant": continue
        for c in (d.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "text":
                m = pat.search(c.get("text", ""))
                if m:
                    print(f"ACK {tag} at {d.get('timestamp','?')}: {m.group(0).strip()}"); sys.exit(0)
    if time.time() >= deadline:
        print(f"wait-for-ack: no 'ACK {tag}' from the lane within {int(timeout)}s", file=sys.stderr); sys.exit(3)
    time.sleep(5)
PY
