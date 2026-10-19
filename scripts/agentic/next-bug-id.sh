#!/usr/bin/env bash
# next-bug-id.sh — ONE bug-id sequence for the whole fleet.
#
# WHY (2026-10-19). Each repo numbered its own bugs, so ids collided across the fleet in one week:
# BUG-613..624 in one repo, 616..636 in another, 625..642 in a third. A bug id is cited across
# repos (sprint plans, RCAs, commit subjects); two bugs with one id is two bugs nobody can name.
#
# HOW. The counter lives in the CTO home at .cto/bug-counter (one integer). Each call takes a lock
# (mkdir, atomic), reads the counter, and issues max(counter, highest BUG-N already present in any
# registered repo's docs/) + 1 — so the first run seeds itself above every existing id, and
# an id typed by hand elsewhere can never be re-issued. "Present" means cited anywhere under a
# registered repo's docs/ (or the CTO home's), not only in a backlog file. The lock makes parallel lanes safe.
#
# CTO home: $CTO_HOME > nearest .cto-path walking up from the repo > ~/.cto/home.
#
# USAGE: next-bug-id.sh            -> prints e.g. BUG-651 and consumes it
#        next-bug-id.sh --peek     -> prints the id the next call would issue; consumes nothing
#        next-bug-id.sh --n 3      -> issues three consecutive ids, one per line
# Exit: 0 ok · 2 no CTO home / no registry · 3 could not take the lock within 30 s
set -uo pipefail
PEEK=0; N=1
while [ $# -gt 0 ]; do
    case "$1" in
        --peek) PEEK=1 ;;
        --n) N="${2:?--n needs a number}"; shift ;;
        --n=*) N="${1#--n=}" ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "next-bug-id: unknown argument '$1'" >&2; exit 2 ;;
    esac; shift
done
case "$N" in ''|*[!0-9]*|0) echo "next-bug-id: --n must be a positive integer" >&2; exit 2 ;; esac

HOME_DIR="${CTO_HOME:-}"
if [ -z "$HOME_DIR" ]; then
    d="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -f "$d/.cto/projects.yaml" ] && { HOME_DIR="$d"; break; }
        [ -f "$d/.cto-path" ] && { HOME_DIR="$(tr -d '[:space:]' < "$d/.cto-path")"; break; }
        d="$(dirname -- "$d")"
    done
fi
[ -z "$HOME_DIR" ] && [ -f "$HOME/.cto/home" ] && HOME_DIR="$(tr -d '[:space:]' < "$HOME/.cto/home")"
REG="$HOME_DIR/.cto/projects.yaml"
[ -n "$HOME_DIR" ] && [ -f "$REG" ] || { echo "next-bug-id: no CTO home found (set CTO_HOME, or a .cto-path / ~/.cto/home). The fleet counter lives there." >&2; exit 2; }

COUNTER="$HOME_DIR/.cto/bug-counter"; LOCK="$HOME_DIR/.cto/bug-counter.lock"
if [ "$PEEK" -eq 0 ]; then
    for _ in $(seq 1 60); do mkdir "$LOCK" 2>/dev/null && break; sleep 0.5; done
    [ -d "$LOCK" ] || { echo "next-bug-id: could not take $LOCK within 30 s (stale? remove it if no other call is running)." >&2; exit 3; }
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
fi

SEEN="$(python3 - "$REG" "$HOME_DIR" <<'PY'
import re, sys, os, glob
t=open(sys.argv[1]).read(); paths=[sys.argv[2]]
for b in re.split(r'(?=- name:)', t):
    p=re.search(r'path:\s*(\S+)', b)
    if p: paths.append(p.group(1))
hi=0
import subprocess
# Every id IN USE counts, not only filed ones: bugs are cited in sprint plans, dev-reports and
# RCAs before (or without) a backlog file. \b + {1,6}: a date-shaped token such as BUG-20260919
# (seen in a fleet doc) must not jump the counter to twenty million.
for root in paths:
    d=os.path.join(root, "docs")
    if not os.path.isdir(d): continue
    # -I skips binaries ("Binary file … matches" is not an id); markdown only — ids are written in
    # prose, and scanning generated data under docs/ made one call take 30 s.
    r=subprocess.run(["grep","-rhoIE","--include=*.md",r"\bBUG-[0-9]{1,6}\b",d],capture_output=True,text=True)
    for tok in re.findall(r"BUG-(\d{1,6})", r.stdout):
        hi=max(hi,int(tok))
print(hi)
PY
)"
CUR=0; [ -f "$COUNTER" ] && CUR="$(tr -dc '0-9' < "$COUNTER")"; CUR="${CUR:-0}"
BASE=$(( CUR > SEEN ? CUR : SEEN ))
# At least three digits (BUG-041), the fleet's existing style; wider numbers print as they are.
i=1; while [ "$i" -le "$N" ]; do printf 'BUG-%03d\n' "$(( BASE + i ))"; i=$((i+1)); done
[ "$PEEK" -eq 1 ] && exit 0
printf '%s\n' "$(( BASE + N ))" > "$COUNTER.tmp" && mv "$COUNTER.tmp" "$COUNTER"
