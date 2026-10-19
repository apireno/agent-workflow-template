#!/usr/bin/env bash
# session-for-path.sh — the transcript of the session currently working IN a directory.
#
#   session-for-path.sh <dir> [--hours N]   -> prints the .jsonl path (and the id on stderr)
#
# WHY (2026-10-19). A lane is often launched in a repo's main checkout and then moves into a linked
# worktree. The SessionStart hook records the session id where the session STARTED, so
# <worktree>/.claude/current-session.id never exists and qa-send --verify-submit could not tell a
# message read from one queued and dropped. A transcript records the cwd on every turn; the session
# whose MOST RECENT cwd is <dir> (or below it) is the one working there now.
#
# Searches transcripts modified in the last N hours (default 48), newest first, reading only each
# file's tail. Exit: 0 found · 1 none · 2 usage
set -uo pipefail
DIR="${1:-}"; HOURS=48
[ "${2:-}" = "--hours" ] && HOURS="${3:-48}"
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: session-for-path.sh <dir> [--hours N]" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd -P)"
python3 - "$DIR" "$HOURS" <<'PY'
import glob, json, os, sys, time
d=sys.argv[1]; cut=time.time()-float(sys.argv[2])*3600
fs=[f for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")) if os.path.getmtime(f)>=cut]
for f in sorted(fs, key=os.path.getmtime, reverse=True):
    with open(f,"rb") as fh:
        fh.seek(0,2); n=fh.tell(); fh.seek(max(0,n-262144)); tail=fh.read().decode("utf-8","replace").splitlines()
    for line in reversed(tail):
        if '"cwd"' not in line: continue
        try: cwd=os.path.realpath(json.loads(line).get("cwd",""))
        except Exception: continue
        if cwd==d or cwd.startswith(d+os.sep):
            print(f); print("session-for-path: "+os.path.basename(f)[:-6]+" (latest cwd "+cwd+")", file=sys.stderr); sys.exit(0)
        break   # this session's latest cwd is elsewhere — it is not working in d now
sys.exit(1)
PY
