#!/usr/bin/env bash
# check-authorization.sh — has the CEO approved a gate? For gate scripts and preflights to call.
#
#   check-authorization.sh <sprint-dir> <gate>
#
# Satisfied by a section `## <gate>` in <sprint-dir>/CEO-AUTHORIZATION.md recorded by the CTO from
# the CEO's words in conversation (record-approval.sh; CEO ruling 2026-10-30). The section must carry
# ceo_words (quoted), scope, date, recorded_by: CTO and session. When that session's transcript is
# on this machine it must be a CTO-home session and contain the quoted words in a message the CEO
# typed; an entry from a dev lane's session, or one whose words were not said, does not count. An
# entry whose transcript is not on this machine (another host, rotated away) is judged on its
# fields and says so.
#
# Not satisfied: the CTO asks the CEO in the conversation and records the answer. Nothing here
# ever asks the CEO to run a command.
# Exit: 0 satisfied · 1 not satisfied · 2 usage
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-}"; GATE="${2:-}"
[ $# -eq 2 ] && [ -n "$DIR" ] && [ -n "$GATE" ] && [ -d "$DIR" ] || { echo "usage: check-authorization.sh <sprint-dir> <gate>" >&2; exit 2; }
F="$DIR/CEO-AUTHORIZATION.md"
if [ -f "$F" ]; then
    RES="$(python3 -I -B - "$F" "$GATE" "$HERE/_approval_transcript.py" <<'PY'
import importlib.util, re, sys
f, gate, helper = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("at", helper); at = importlib.util.module_from_spec(spec); spec.loader.exec_module(at)
for sec in re.split(r'\n(?=## )', open(f).read()):
    m = re.match(r'## (\S+)[ \t]*\n', sec)
    if not m or m.group(1) != gate: continue
    g = lambda k: (re.search(r'^- ' + k + r':[ \t]*(.*?)[ \t]*$', sec, re.M) or [None, None])[1]
    words, scope, date, by, sid, msg = g('ceo_words'), g('scope'), g('date'), g('recorded_by'), g('session'), g('message')
    missing = [k for k, v in (("ceo_words", words), ("scope", scope), ("date", date), ("recorded_by", by), ("session", sid)) if not v]
    if missing: print("BAD missing " + ",".join(missing)); continue
    if by != "CTO": print("BAD recorded_by " + by + " (only the CTO records approvals)"); continue
    if not (words.startswith('"') and words.endswith('"')): print("BAD ceo_words is not a quotation"); continue
    w = re.sub(r'\\(.)', r'\1', words[1:-1])
    v = at.verify(sid, w, msg or None)   # a recorded message id is checked as that exact message
    if v["transcript"]:
        if not v["cto_home"]: print("BAD session " + sid + " ran in " + str(v["cwd"]) + ", not a CTO home"); continue
        if not v["found"]: print("BAD the quoted words are not in " + ("CEO message " + msg if msg else "any message the CEO typed") + " in session " + sid); continue
        print("OK " + date + " " + w + " [scope: " + scope + "]"); continue
    print("OK " + date + " " + w + " [scope: " + scope + "] (session transcript not on this machine; fields only)")
PY
)"
    if printf '%s\n' "$RES" | grep -q '^OK '; then
        echo "authorized: CEO, $(printf '%s\n' "$RES" | grep '^OK ' | tail -1 | cut -d' ' -f2-)"; exit 0
    fi
    printf '%s\n' "$RES" | grep '^BAD ' | sed "s|^BAD |NOT authorized: '$GATE' entry in $F: |" >&2
fi
echo "NOT authorized: gate '$GATE' in $DIR. The CTO asks the CEO in the conversation, confirms the scope," >&2
echo "  and records the CEO's words verbatim with scripts/agentic/record-approval.sh." >&2
exit 1
