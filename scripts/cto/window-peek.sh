#!/usr/bin/env bash
# window-peek.sh — read what is ON SCREEN in a Terminal window (or list all windows).
#
#   window-peek.sh list                # every Terminal window: "<id> | <title>"
#   window-peek.sh <window-id> [N]     # last N (default 15) non-blank on-screen lines
#   window-peek.sh <window-id> --input  # ONLY the composer line (the ❯ row)
#   window-peek.sh <window-id> --queued # is the session holding SUBMITTED-but-unread messages?
#   window-peek.sh <window-id> --authorship  # can text in this window be a generated suggestion?
#
# Companion to /peek, NOT a replacement. /peek tails the session JSONL — the model's
# thinking and tool calls. This shows the SCREEN: permission dialogs, queued-but-
# unsubmitted input, and shell output the JSONL never records. When a session looks
# hung, /peek shows the last thing it did; this shows what it is waiting on.
#
# --input MODE (composer hygiene). Text sitting UNSUBMITTED in a session's composer is
# invisible to every other tool: it produces no JSONL, no artifact, no screen change. It
# stays invisible until something submits it — at which point it lands ahead of, or
# concatenated with, the next real message. Check before sending. Contract:
#
#     prints the composer text, exit 0    — something is in the box
#     prints nothing,           exit 3    — box is empty (the clean state)
#
# so callers can branch on the exit code:
#     if bash scripts/cto/window-peek.sh "$WIN" --input; then echo "composer not clear"; fi
#
# ── OBSERVED TEXT IS NOT ATTRIBUTED TEXT (read before acting on --input) ──────────────────
# This mode reports that the composer is NON-EMPTY. It CANNOT report who put the text there,
# and no version of it ever will:
#
#   Claude Code renders its generated inline suggestion through the SAME text-input renderer
#   as typed characters, in the same cells, differing only by a dim/colour attribute — and
#   `Terminal … get contents` returns plain text with every attribute stripped. A generated
#   suggestion and a human's typed-but-unsubmitted draft are BYTE-IDENTICAL here. There is
#   no prefix, no marker, no separate row, and the suggestion is persisted nowhere on disk
#   to compare against (verified against Claude Code 2.1.248).
#
# So the output of this mode is UNVERIFIED-AUTHORSHIP text. The rule that follows is not a
# style preference — it is the reason this warning exists:
#
#   **NEVER submit composer text on a watcher signal.** Detection ALERTS; a human confirms
#   authorship per incident before anything submits. A generated suggestion echoes the
#   session's own last recommendation, so auto-submitting one hands the session its own
#   advice back wearing its principal's authority — a fabricated directive that every
#   downstream artifact then records as a CEO decision. Observed 2026-08-27: two submit
#   attempts on a suggestion, stopped only by a busy composer.
#
# Directive provenance is two-class: (a) typed by the human in their own channel, (b)
# orchestrator-authored and verify-submitted via qa-send.sh, where authorship is the
# SENDER's. Window-recovered text is neither until a human claims it.
#
# --authorship MODE is the one-directional escape from that ambiguity. /handoff, /qa-drive
# and /resume-dev-team launch with CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0, and that launch
# line stays in the window's scrollback. If we can see it, this window CANNOT produce a
# suggestion and composer text in it was necessarily put there by a human or by us:
#
#     exit 0  — suggestions provably OFF in this window (composer text is not generated)
#     exit 3  — unproven. NOT proof of the opposite: the launch line may have scrolled out
#               of the buffer, or the session was started by hand. Treat as unverified.
#
# The asymmetry is deliberate. A safety check may only ever return "provably safe" or
# "unknown"; a check that guessed "probably human" would be the same defect in a new coat.
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
WIN=""; N=""; INPUT_MODE=0; QUEUED_MODE=0; AUTHORSHIP_MODE=0
QUEUED_HINT_TEXT="${AGENTIC_QUEUED_HINT:-Press up to edit queued messages}"
for a in "$@"; do
    case "$a" in
        --input)      INPUT_MODE=1 ;;
        --queued)     QUEUED_MODE=1 ;;
        --authorship) AUTHORSHIP_MODE=1 ;;
        *) if [ -z "$WIN" ]; then WIN="$a"; else N="$a"; fi ;;
    esac
done
: "${WIN:?usage: window-peek.sh list | window-peek.sh <window-id> [lines] | window-peek.sh <window-id> --input|--queued|--authorship}"
N="${N:-15}"

# The env var every orchestrated launch path exports. Searched for in the window's SCROLLBACK,
# where the launch command line is echoed by the shell. Presence proves the session cannot
# render a generated composer suggestion; absence proves nothing (see the header).
SUGGESTION_KILL="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0"

# 0 = provably off, 3 = unproven. `history` (full scrollback) not `contents` (visible screen):
# the launch line scrolls out of view within seconds but stays in the buffer for a long time.
suggestions_provably_off() {
    osascript -e "tell application \"Terminal\" to return (history of window id $WIN)" 2>/dev/null \
        | grep -qF "$SUGGESTION_KILL"
}

if [ "$AUTHORSHIP_MODE" -eq 1 ]; then
    if suggestions_provably_off; then
        echo "suggestions OFF (launch line in scrollback) — composer text in window $WIN is not generated"
        exit 0
    fi
    echo "window-peek: UNPROVEN for window $WIN — no '$SUGGESTION_KILL' in the scrollback." >&2
    echo "  This is NOT proof suggestions are on: the launch line may have scrolled out of the" >&2
    echo "  buffer, or the session was started by hand. Treat composer text as unverified-authorship." >&2
    exit 3
fi

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
    # The text goes to stdout unchanged (callers parse it). The banner goes to stderr, so it
    # reaches a human reading the run and cannot corrupt a pipeline. It is printed on EVERY
    # hit, not on a heuristic: the whole point is that this layer cannot tell the two cases
    # apart, and a warning that only fires when we think it matters is a warning that will be
    # missing on the day it does.
    printf '%s\n' "$PENDING"
    if suggestions_provably_off; then
        echo "window-peek: authorship OK — suggestions are provably off in window $WIN," >&2
        echo "  so this text was put there by a human or by us. It is still UNSUBMITTED:" >&2
        echo "  a human confirms it is theirs before anything submits it." >&2
    else
        echo "window-peek: UNVERIFIED AUTHORSHIP — this may be Claude Code's own generated grey" >&2
        echo "  suggestion, which is byte-identical to typed text once colour is stripped." >&2
        echo "  DO NOT SUBMIT IT. Alert a human and let them confirm they typed it." >&2
        echo "  (Orchestrated windows launch with $SUGGESTION_KILL; this one shows no such" >&2
        echo "   launch line, so the ambiguity is real here.)" >&2
    fi
    exit 0
fi

# Drop blank lines, keep the tail. grep exiting 1 on an all-blank window is not an
# error here, so it must not take the script down (this ran under `set -e` once and
# turned an empty-but-live window into a hard failure).
printf '%s\n' "$CONTENTS" | grep -v '^[[:space:]]*$' | tail -n "$N" || true
