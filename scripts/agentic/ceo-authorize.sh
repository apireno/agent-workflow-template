#!/usr/bin/env bash
# ceo-authorize.sh — the CEO records an authorization for a human-only gate, in the CEO's own words.
#
#   scripts/agentic/ceo-authorize.sh <sprint-dir> <gate> "<your words, verbatim>"
#
# WHY (2026-10-19). Some gates require a human sign-off (e.g. a security fill gate that wants a
# literal "VP-SECURITY-SIGN-OFF: GRANTED" line). An agent must not write that line for anyone —
# the auto-mode classifier refused the CTO session four times in one weekend, including on the
# CEO's explicit word, and it was right to: an agent writing a human's sign-off is a forged
# signature however sincere. The CEO's word IS the authority; the token was only its proxy. This
# script is how the CEO gives that word directly, without an agent writing on their behalf.
#
# HOW IT KEEPS AGENTS OUT. It runs only with a controlling terminal (/dev/tty) and asks you to
# retype the gate name there. An agent's tool shell has no terminal, so it cannot run this by
# accident or as a convenience. It is not proof against a deliberate workaround (faking a pty,
# typing into a window) — no local check can be — but any such workaround is a visible, deliberate
# act in that session's transcript, the same standard as the attested-submit path in qa-send.sh.
# Sessions are also blocked from writing CEO-AUTHORIZATION.md directly (deny-authorization-forge.sh).
#
# Appends to <sprint-dir>/CEO-AUTHORIZATION.md one section per gate, with a sha256 seal over
# gate|words|time that check-authorization.sh verifies.
# Exit: 0 recorded · 2 usage · 4 no terminal (run it yourself in Terminal) · 5 not confirmed
set -uo pipefail
DIR="${1:-}"; GATE="${2:-}"; WORDS="${3:-}"
if [ -z "$DIR" ] || [ -z "$GATE" ] || [ -z "$WORDS" ] || [ $# -ne 3 ]; then
    echo "usage: ceo-authorize.sh <sprint-dir> <gate> \"<your words, verbatim>\"" >&2; exit 2
fi
[ -d "$DIR" ] || { echo "ceo-authorize: not a directory: $DIR" >&2; exit 2; }
case "$GATE" in *[!A-Za-z0-9._-]*) echo "ceo-authorize: gate name may use letters, digits, . _ - only" >&2; exit 2 ;; esac
if ! { exec 3</dev/tty; } 2>/dev/null; then
    echo "ceo-authorize: no terminal. This records the CEO's own authorization and must be run by the CEO" >&2
    echo "  in a Terminal window, not from an agent session. Copy the command into Terminal and run it there." >&2
    exit 4
fi
echo "You are recording, as the CEO:" > /dev/tty
echo "  gate:  $GATE" > /dev/tty
echo "  words: $WORDS" > /dev/tty
echo "  into:  $DIR/CEO-AUTHORIZATION.md" > /dev/tty
printf 'Retype the gate name to confirm: ' > /dev/tty
IFS= read -r CONFIRM <&3; exec 3<&-
[ "$CONFIRM" = "$GATE" ] || { echo "ceo-authorize: not confirmed (typed '$CONFIRM'). Nothing recorded." >&2; exit 5; }
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SEAL="$(printf '%s|%s|%s' "$GATE" "$WORDS" "$TS" | shasum -a 256 | cut -c1-64)"
F="$DIR/CEO-AUTHORIZATION.md"
[ -f "$F" ] || printf '# CEO authorizations\n\nRecorded by the CEO with scripts/agentic/ceo-authorize.sh. Agents never write this file.\n' > "$F"
{
    printf '\n## %s\n' "$GATE"
    printf -- '- authorized_by: CEO\n'
    printf -- '- words: "%s"\n' "$(printf '%s' "$WORDS" | sed 's/"/\\"/g')"
    printf -- '- recorded_at: %s\n' "$TS"
    printf -- '- recorded_via: ceo-authorize.sh, interactive terminal %s, user %s%s\n' "$(tty 2>/dev/null || echo '?')" "$(id -un)" "$([ -n "${CLAUDECODE:-}" ] && echo ', CLAUDECODE set')"
    printf -- '- seal: %s\n' "$SEAL"
} >> "$F"
echo "recorded: $GATE -> $F"
