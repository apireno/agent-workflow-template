#!/usr/bin/env bash
# record-approval.sh — the CTO records a CEO approval for a gate, quoting the CEO's words verbatim.
#
#   record-approval.sh <sprint-dir> <gate> --words "<the CEO's words, verbatim>" --scope "<scope confirmed back>"
#                      [--session <id>]     (default: $CLAUDE_CODE_SESSION_ID, this session)
#                      [--message <uuid>]   (pin the CEO message; default: the most recent one with the words)
#
# HOW THE CEO APPROVES (CEO ruling 2026-10-30). The CEO approves in the CTO conversation, in their own
# words. The CTO records those words: verbatim, dated, with the exact scope the CTO confirmed back
# to the CEO, recorded_by CTO, and the session id. The CEO never runs a command, opens a shell or
# retypes a token to approve anything. Proof of human presence is not the goal; a faithful, reviewable
# record is. So the CTO quotes the CEO exactly, never widens a "yes" into a broader scope, and asks
# when the scope is ambiguous ("for ratification you mean the possessive flag for offers?") before
# recording "ok approved".
#
# WHAT THIS CHECKS BEFORE WRITING. The session must be a CTO-home session (dev lanes do not record
# approvals), and --words must appear in a message the CEO typed in that session (exact after
# whitespace and quote normalization; a paraphrase is refused). Short approvals recur across a long
# session, so the MOST RECENT matching CEO message is used, and the output says when more than one
# matched; --message <uuid> pins a specific one. The date and message id are that message's.
#
# Appends to <sprint-dir>/CEO-AUTHORIZATION.md one section per gate; check-authorization.sh reads it.
# Exit: 0 recorded · 2 usage · 3 not a CTO-home session / no transcript · 4 words not found as said
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-}"; GATE="${2:-}"; shift 2 2>/dev/null || true
WORDS=""; SCOPE=""; MSG=""; SID="${CLAUDE_CODE_SESSION_ID:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --words) WORDS="${2:-}"; shift ;; --words=*) WORDS="${1#--words=}" ;;
        --scope) SCOPE="${2:-}"; shift ;; --scope=*) SCOPE="${1#--scope=}" ;;
        --session) SID="${2:-}"; shift ;; --session=*) SID="${1#--session=}" ;;
        --message) MSG="${2:-}"; shift ;; --message=*) MSG="${1#--message=}" ;;
        *) echo "record-approval: unknown argument '$1'" >&2; exit 2 ;;
    esac; shift
done
if [ -z "$DIR" ] || [ -z "$GATE" ] || [ -z "$WORDS" ] || [ -z "$SCOPE" ]; then
    echo "usage: record-approval.sh <sprint-dir> <gate> --words \"<CEO's words, verbatim>\" --scope \"<scope confirmed back>\" [--session <id>] [--message <uuid>]" >&2; exit 2
fi
[ -d "$DIR" ] || { echo "record-approval: not a directory: $DIR" >&2; exit 2; }
case "$GATE" in *[!A-Za-z0-9._-]*) echo "record-approval: gate name may use letters, digits, . _ - only" >&2; exit 2 ;; esac
[ -n "$SID" ] || { echo "record-approval: no session id (CLAUDE_CODE_SESSION_ID unset); pass --session <id>" >&2; exit 3; }
case "$SCOPE$WORDS" in *$'\n'*) echo "record-approval: --words and --scope are one line each" >&2; exit 2 ;; esac

V="$(python3 -I -B "$HERE/_approval_transcript.py" verify "$SID" "$WORDS" ${MSG:+"$MSG"})" || exit 2
field() { printf '%s' "$V" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }
if [ -z "$(field transcript)" ]; then
    echo "record-approval: no transcript for session $SID on this machine; cannot confirm the words were said." >&2; exit 3
fi
if [ "$(field cto_home)" != "True" ]; then
    echo "record-approval: session $SID runs in $(field cwd), which is not a CTO home. Only the CTO records approvals." >&2; exit 3
fi
if [ "$(field found)" != "True" ]; then
    if [ -n "$MSG" ]; then echo "record-approval: message $MSG is not a CEO message in this session containing those words." >&2
    else echo "record-approval: those words are not in any message the CEO typed in this session." >&2; fi
    echo "  Quote the CEO exactly. If the approval was paraphrased or the scope is unclear, ask the CEO again." >&2; exit 4
fi
DATE="$(field date)"; [ -n "$DATE" ] || DATE="$(date +%Y-%m-%d)"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
F="$DIR/CEO-AUTHORIZATION.md"
[ -f "$F" ] || printf '# CEO approvals\n\nThe CEO approves in the CTO conversation; the CTO records the words verbatim (scripts/agentic/record-approval.sh).\n' > "$F"
{
    printf '\n## %s\n' "$GATE"
    printf -- '- ceo_words: "%s"\n' "$(esc "$WORDS")"
    printf -- '- scope: %s\n' "$SCOPE"
    printf -- '- date: %s\n' "$DATE"
    printf -- '- recorded_by: CTO\n'
    printf -- '- session: %s\n' "$SID"
    printf -- '- message: %s\n' "$(field uuid)"
} >> "$F"
echo "recorded: $GATE -> $F (CEO, $DATE: \"$WORDS\", message $(field uuid))"
N="$(field matches)"; if [ -z "$MSG" ] && [ "${N:-1}" -gt 1 ]; then
    echo "  note: $N CEO messages in this session contain those words; recorded the most recent ($DATE)." >&2
    echo "  If that is not the approval you mean, remove this section and re-run with --message <uuid>." >&2
fi
