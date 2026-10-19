#!/usr/bin/env bash
# check-authorization.sh — is a human-only gate satisfied? For gate scripts and preflights to call.
#
#   check-authorization.sh <sprint-dir> <gate> [--token "<literal sign-off line>"]
#
# Satisfied by EITHER (a) the literal token line, if given, in any .md in the sprint dir — the
# existing convention — OR (b) a sealed section for <gate> in <sprint-dir>/CEO-AUTHORIZATION.md,
# written by the CEO with ceo-authorize.sh. A section whose seal does not match its own gate, words
# and time was edited after recording and does NOT count. Prints what satisfied it, or the exact
# command the CEO runs (in Terminal) to authorize.
# Exit: 0 satisfied · 1 not satisfied · 2 usage
set -uo pipefail
DIR="${1:-}"; GATE="${2:-}"; shift 2 2>/dev/null || true; TOKEN=""
while [ $# -gt 0 ]; do
    case "$1" in --token) TOKEN="${2:-}"; shift ;; --token=*) TOKEN="${1#--token=}" ;; *) echo "check-authorization: unknown argument '$1'" >&2; exit 2 ;; esac; shift
done
[ -n "$DIR" ] && [ -n "$GATE" ] && [ -d "$DIR" ] || { echo "usage: check-authorization.sh <sprint-dir> <gate> [--token \"<line>\"]" >&2; exit 2; }
if [ -n "$TOKEN" ]; then
    HIT="$(grep -rlF --include='*.md' -- "$TOKEN" "$DIR" 2>/dev/null | grep -v '/CEO-AUTHORIZATION.md$' | head -1)"
    [ -n "$HIT" ] && { echo "authorized: token line in $HIT"; exit 0; }
fi
F="$DIR/CEO-AUTHORIZATION.md"
if [ -f "$F" ]; then
    RES="$(python3 - "$F" "$GATE" <<'PY'
import re, sys, hashlib
t=open(sys.argv[1]).read(); gate=sys.argv[2]
for sec in re.split(r'\n(?=## )', t):
    m=re.match(r'## (\S+)\n', sec)
    if not m or m.group(1)!=gate: continue
    g=lambda k: (re.search(r'^- '+k+r': (.*)$', sec, re.M) or [None,None])[1]
    words=g('words'); ts=g('recorded_at'); seal=g('seal'); via=g('recorded_via') or ''
    if not (words and ts and seal and via.startswith('ceo-authorize.sh')): print('BAD malformed'); continue
    w=words[1:-1].replace('\\"','"') if words.startswith('"') and words.endswith('"') else words
    want=hashlib.sha256(f"{gate}|{w}|{ts}".encode()).hexdigest()
    print(('OK '+ts+' '+w) if want==seal else 'BAD seal-mismatch')
PY
)"
    if printf '%s\n' "$RES" | grep -q '^OK '; then
        echo "authorized: CEO, $(printf '%s\n' "$RES" | grep '^OK ' | tail -1 | cut -d' ' -f2-)"; exit 0
    fi
    printf '%s\n' "$RES" | grep -q 'seal-mismatch' && echo "NOT authorized: the '$GATE' section in $F was edited after it was recorded (seal mismatch)." >&2
fi
echo "NOT authorized: gate '$GATE' in $DIR. The CEO authorizes it by running, in Terminal:" >&2
echo "  $(cd "$(dirname "$0")" && pwd)/ceo-authorize.sh '$DIR' $GATE \"<the CEO's words>\"" >&2
exit 1
