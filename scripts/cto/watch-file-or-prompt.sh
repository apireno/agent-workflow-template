#!/usr/bin/env bash
# watch-file-or-prompt.sh <target-file> [window-id] [interval] [newer-than]
#
# Block until an artifact lands, and meanwhile notice if the session producing it is
# stuck on a permission dialog.
#
#   <target-file>  path to wait for. Must become NON-EMPTY: review engines pre-create
#                  their output file and fill it at completion, so existence alone is
#                  a false "done".
#   [window-id]    optional Terminal window to watch for a blocking prompt. Omit to
#                  watch the file only.
#   [interval]     poll seconds (default 45).
#   [newer-than]   epoch seconds, or the literal "now". Fire only when the file's
#                  mtime EXCEEDS it — for waiting on a REWRITE of a file that already
#                  exists. "now" self-captures the baseline at startup so callers never
#                  embed $(stat ...) in the command line (see WHY A SCRIPT FILE below).
#
# Exits 0 on "file-landed"/"file-updated". Prompt detection does NOT exit — it prints
# an event (at most once per 5 min) and keeps waiting, because a prompt is a thing for
# a human to clear, not the end of the wait.
#
# DIVISION OF LABOUR with the neighbouring watcher:
#   wait-for-artifact.sh  — watches a session's JSONL IDLE TIME plus a target file, and
#                           answers "has this session settled?" (READY vs CEILING).
#   this script           — watches the FILE plus the SCREEN, and answers "did the
#                           artifact land, and if not, is the session blocked?"
# Use wait-for-artifact when you care whether the agent is done thinking; use this when
# you care whether the deliverable exists and whether a dialog is in the way.
#
# WHY A SCRIPT FILE: Claude Code's command analyzer prompts on any command line mixing
# braces, quotes, command substitution, or heredocs — by design, and NO permissions.allow
# rule suppresses it. Inline watcher one-liners trip it on every new shape. As a
# committed script only the invocation
#     bash scripts/cto/watch-file-or-prompt.sh <file> [win] [secs] [newer]
# is scanned: a stable, allowlistable shape. Same reason qa-send.sh and
# wait-for-artifact.sh exist — see their headers.
#
# macOS + Terminal.app for the window half (osascript); the file half is portable.

set -uo pipefail

TARGET="${1:?usage: watch-file-or-prompt.sh <target-file> [window-id] [interval] [newer-than|now]}"
WIN="${2:-}"
INTERVAL="${3:-45}"
NEWER_THAN="${4:-}"

# BSD (macOS) and GNU (Linux) stat disagree on flags; support both.
mtime_of() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Prompt shapes Claude Code renders when it blocks. Override for other TUIs:
#   WATCH_PROMPT_RE='...' bash scripts/cto/watch-file-or-prompt.sh ...
# Kept configurable because these strings track a vendor's UI, and a watcher that
# silently stops matching is worse than one that never matched.
PROMPT_RE="${WATCH_PROMPT_RE:-❯ 1\.|Deny \(esc\)|Do you want|Yes, and}"
PROMPT_SHOW_RE="${WATCH_PROMPT_SHOW_RE:-❯|wants|Do you}"

[ "$NEWER_THAN" = "now" ] && NEWER_THAN="$(mtime_of "$TARGET")"

last_prompt=0
while true; do
    if [ -s "$TARGET" ]; then
        if [ -z "$NEWER_THAN" ]; then
            echo "EVENT file-landed: $TARGET"
            exit 0
        fi
        if [ "$(mtime_of "$TARGET")" -gt "$NEWER_THAN" ]; then
            echo "EVENT file-updated: $TARGET"
            exit 0
        fi
    fi

    if [ -n "$WIN" ]; then
        SCREEN="$(osascript -e "tell application \"Terminal\" to get contents of window id $WIN" 2>/dev/null | tail -18)"
        if printf '%s' "$SCREEN" | grep -qE "$PROMPT_RE"; then
            now=$(date +%s)
            if [ $((now - last_prompt)) -gt 300 ]; then
                echo "EVENT window-prompt-blocked (window $WIN):"
                printf '%s\n' "$SCREEN" | grep -E "$PROMPT_SHOW_RE" | tail -4 | sed 's/^/    /'
                last_prompt=$now
            fi
        fi
    fi

    sleep "$INTERVAL"
done
