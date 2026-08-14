#!/usr/bin/env bash
# window-peek.sh — read what is ON SCREEN in a Terminal window (or list all windows).
#
#   window-peek.sh list                # every Terminal window: "<id> | <title>"
#   window-peek.sh <window-id> [N]     # last N (default 15) non-blank on-screen lines
#   window-peek.sh <window-id> --input  # ONLY the pending input line (the ❯ row)
#   window-peek.sh <window-id> --queued # is the session holding SUBMITTED-but-unread messages?
#
# Companion to /peek, NOT a replacement. /peek tails the session JSONL — the model's
# thinking and tool calls. This shows the SCREEN: permission dialogs, queued-but-
# unsubmitted input, and shell output the JSONL never records. When a session looks
# hung, /peek shows the last thing it did; this shows what it is waiting on.
#
# --input MODE (stray-input hygiene). Text sitting UNSUBMITTED in a session's input box
# is invisible to every other tool: it produces no JSONL, no artifact, no screen change.
# It stays invisible until something submits it — at which point it lands ahead of, or
# concatenated with, the next real message. Check before sending. Contract:
#
#     prints the pending text, exit 0     — something is queued
#     prints nothing,        exit 3       — box is empty (the clean state)
#
# so callers can branch on the exit code:
#     if bash scripts/cto/window-peek.sh "$WIN" --input; then echo "stray input — clear it first"; fi
#
# The pending text is matched by the LAST '❯' on screen. That heuristic prefers the input
# box (bottom of the viewport) over a shell prompt using the same glyph, and it reads only
# the FIRST line of a wrapped multi-line message — enough to tell "queued" from "clean",
# not a faithful transcript of the whole draft.
#
# macOS + Terminal.app only, like the rest of the window-orchestration layer
# (/handoff, /send, /close-window). Read-only: it never sends keystrokes.
#
# Requires Accessibility/Automation permission for Terminal (same grant /send needs).

set -uo pipefail

if [ "${1:-}" = "list" ]; then
    osascript -e 'tell application "Terminal"
        set out to ""
        repeat with w in windows
            set out to out & (id of w) & " | " & (name of w) & linefeed
        end repeat
        return out
    end tell' 2>/dev/null || { echo "window-peek: could not enumerate Terminal windows (is Terminal running? is Automation permission granted?)" >&2; exit 1; }
    exit 0
fi

# Accept --input/--queued on either side of the window id so both orderings work.
WIN=""; N=""; INPUT_MODE=0; QUEUED_MODE=0
QUEUED_HINT_TEXT="${AGENTIC_QUEUED_HINT:-Press up to edit queued messages}"
for a in "$@"; do
    case "$a" in
        --input)  INPUT_MODE=1 ;;
        --queued) QUEUED_MODE=1 ;;
        *) if [ -z "$WIN" ]; then WIN="$a"; else N="$a"; fi ;;
    esac
done
: "${WIN:?usage: window-peek.sh list | window-peek.sh <window-id> [lines] | window-peek.sh <window-id> --input|--queued}"
N="${N:-15}"

CONTENTS="$(osascript -e "tell application \"Terminal\" to get contents of window id $WIN" 2>/dev/null)"
if [ -z "$CONTENTS" ]; then
    echo "window-peek: no contents for window id $WIN (closed, or wrong id — try 'window-peek.sh list')" >&2
    exit 1
fi

if [ "$QUEUED_MODE" -eq 1 ]; then
    # QUEUED is a state of its own, and the one the box cannot show: the text left the input
    # box (so --input reads clean) but the session has not read it — it is stacked behind the
    # current turn. Messages in that state have been dropped at turn end, so "box cleared"
    # must never be reported as "delivered and read" while this hint is on screen.
    if printf '%s\n' "$CONTENTS" | grep -qF "$QUEUED_HINT_TEXT"; then
        printf '%s\n' "queued: the session is holding submitted message(s) behind the current turn"
        exit 0
    fi
    echo "window-peek: no queued-message hint on screen for window $WIN" >&2
    exit 3
fi

if [ "$INPUT_MODE" -eq 1 ]; then
    # Last ❯ line → strip everything through the marker, then the box's right border and
    # trailing padding. What survives is the queued text, or nothing.
    PENDING="$(printf '%s\n' "$CONTENTS" \
        | grep '❯' \
        | tail -1 \
        | sed -e 's/.*❯[[:space:]]*//' -e 's/[[:space:]]*[│|][[:space:]]*$//' -e 's/[[:space:]]*$//')"
    # TUI chrome is not pending input. The hint line in particular sits directly under the box
    # and, when it lands on the matched row, reads as a draft that is not there — a caller
    # then nudges a box that was already clear. Strip the known furniture, then re-test.
    PENDING="$(printf '%s' "$PENDING" \
        | sed -e "s/$QUEUED_HINT_TEXT//g" \
              -e 's/? for shortcuts//g' \
              -e 's/\/ for commands//g' \
              -e 's/⏵⏵ *accept edits on//g' \
              -e 's/[[:space:]]*$//')"
    if [ -z "$PENDING" ]; then
        echo "window-peek: input box empty for window $WIN" >&2
        exit 3
    fi
    printf '%s\n' "$PENDING"
    exit 0
fi

# Drop blank lines, keep the tail. grep exiting 1 on an all-blank window is not an
# error here, so it must not take the script down (this ran under `set -e` once and
# turned an empty-but-live window into a hard failure).
printf '%s\n' "$CONTENTS" | grep -v '^[[:space:]]*$' | tail -n "$N" || true
