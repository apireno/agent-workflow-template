#!/usr/bin/env bash
# watch-file-or-prompt.sh [--stream] [--pattern <regex>] [--idle-escalation <min>]
#                         [--idle-watch <path>] <target-file> [window-id] [interval] [newer-than]
#
# Watch a sprint: does the artifact exist, is the session blocked, is it still alive?
#
#   <target-file>  path to wait for. Must become NON-EMPTY: review engines pre-create
#                  their output file and fill it at completion, so existence alone is
#                  a false "done". Pass "-" to watch only the window.
#   [window-id]    Terminal window to watch for blocking prompts, content matches, and
#                  liveness. Omit to watch the file only.
#   [interval]     poll seconds (default 45).
#   [newer-than]   epoch seconds, or the literal "now". Fire only when mtime EXCEEDS it —
#                  for waiting on a REWRITE of a file that already exists. "now"
#                  self-captures the baseline at startup so callers never embed
#                  $(stat ...) in the command line (see WHY A SCRIPT FILE below).
#
# TWO MODES
#
#   default (single-shot)  Exits 0 on the first file event. Prompt detection prints but
#                          does not exit. Output format is unchanged from the original —
#                          existing callers keep working.
#
#   --stream               Never exits on a file event; runs until the watched window
#                          disappears or you kill it. Emits ONE TAGGED LINE PER EVENT:
#
#                              <TAG>\t<iso8601>\t<detail>
#
#                          TAGs: FILE_UPDATED · PROMPT_BLOCK · PATTERN_HIT ·
#                                IDLE_ESCALATION · WINDOW_GONE
#
#                          Built for a supervising harness to consume as an event stream
#                          across a whole sprint instead of re-arming a single-shot
#                          watcher per event. After FILE_UPDATED the mtime baseline
#                          re-arms automatically, so successive rewrites each fire.
#                          WINDOW_GONE is terminal: the session died or was closed, and
#                          nothing further is worth watching — it exits 0.
#
#   --pattern <regex>      Extra trigger: emit PATTERN_HIT when the window's on-screen
#                          text matches. Use for sprint-specific milestones ("tests
#                          passed", "BLOCKER", a filename). Repeats are rate-limited to
#                          one per 5 minutes, like PROMPT_BLOCK, so a persistent line on
#                          screen does not flood the stream.
#
#   --idle-escalation <min>  THE BLOCKED-STATE TRIGGER. Everything above watches for
#                          SUCCESS — a file lands, a pattern matches, a dialog appears. A
#                          session that finishes its turn and stops to ASK something
#                          produces none of those: no artifact, no dialog, no new output.
#                          It is byte-identical to a session working hard, and the
#                          orchestrator sleeps until a human asks why nothing is done. An
#                          overnight run lost hours to exactly this.
#
#                          Fires IDLE_ESCALATION when, for <min> consecutive minutes, ALL of:
#                            · no busy marker on screen (AGENTIC_WORKING_RE, below)
#                            · the screen has not changed at all (checksummed each poll)
#                            · nothing new written under --idle-watch, if given
#                          The clock re-arms after each firing, so a session left blocked
#                          escalates every <min> minutes rather than once. In default
#                          (single-shot) mode this is terminal and exits 3 — distinguishing
#                          "the artifact landed" (0) from "the session stopped without
#                          producing it" (3).
#
#                          Not a substitute for PROMPT_BLOCK: that catches a permission
#                          dialog in seconds by matching it. This catches everything else,
#                          by noticing the absence of progress.
#
#   --idle-watch <path>    File or directory whose newest mtime counts as activity for the
#                          idle clock (depth-capped at 3). Use the sprint dir: a team
#                          writing notes and test output is working, even while the
#                          <target-file> report does not exist yet.
#
# DIVISION OF LABOUR with the neighbouring watcher:
#   wait-for-artifact.sh  — watches a session's JSONL IDLE TIME plus a target file, and
#                           answers "has this session settled?" (READY vs CEILING).
#   this script           — watches the FILE, the SCREEN, and the WINDOW, and answers
#                           "did the artifact land, is the session blocked, is it alive?"
# Use wait-for-artifact when you care whether the agent is done thinking; use this when
# you care whether the deliverable exists and whether something is in the way.
#
# WHY A SCRIPT FILE: Claude Code's command analyzer prompts on any command line mixing
# braces, quotes, command substitution, or heredocs — by design, and NO permissions.allow
# rule suppresses it. Inline watcher one-liners trip it on every new shape. As a
# committed script only the invocation
#     bash scripts/cto/watch-file-or-prompt.sh --stream <file> <win> <secs>
# is scanned: a stable, allowlistable shape. Same reason qa-send.sh and
# wait-for-artifact.sh exist — see their headers.
#
# NOTE ON HARNESS TIMEOUTS: a supervising harness may reap tracked background commands
# after a few minutes. Wrapping this in the harness's own monitor is plumbing on the
# caller's side; --stream exists so that wrapper never has to re-implement the triggers.
#
# macOS + Terminal.app for the window half (osascript); the file half is portable.

set -uo pipefail

STREAM=0
PATTERN=""
IDLE_MIN=0
IDLE_WATCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --stream)  STREAM=1; shift ;;
        --pattern) PATTERN="${2:?--pattern needs a regex}"; shift 2 ;;
        --idle-escalation) IDLE_MIN="${2:?--idle-escalation needs minutes}"; shift 2
                   case "$IDLE_MIN" in ''|*[!0-9]*) echo "--idle-escalation needs whole minutes" >&2; exit 1 ;; esac ;;
        --idle-watch) IDLE_WATCH="${2:?--idle-watch needs a path}"; shift 2 ;;
        --) shift; break ;;
        -)  break ;;              # the "watch the window only" sentinel, not a flag
        -*) echo "unknown flag: $1" >&2; exit 1 ;;
        *) break ;;
    esac
done

TARGET="${1:?usage: watch-file-or-prompt.sh [--stream] [--pattern RE] <target-file|-> [window-id] [interval] [newer-than|now]}"
WIN="${2:-}"
INTERVAL="${3:-45}"
NEWER_THAN="${4:-}"
[ "$TARGET" = "-" ] && TARGET=""
[ -z "$TARGET" ] && [ -z "$WIN" ] && { echo "nothing to watch: give a target file, a window id, or both" >&2; exit 1; }

# BSD (macOS) and GNU (Linux) stat disagree on flags; support both.
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit()     { printf '%s\t%s\t%s\n' "$1" "$(now_iso)" "$2"; }

# Prompt shapes Claude Code renders when it blocks. Override for other TUIs:
#   WATCH_PROMPT_RE='...' bash scripts/cto/watch-file-or-prompt.sh ...
# Kept configurable because these strings track a vendor's UI, and a watcher that
# silently stops matching is worse than one that never matched.
PROMPT_RE="${WATCH_PROMPT_RE:-❯ 1\.|Deny \(esc\)|Do you want|Yes, and}"
PROMPT_SHOW_RE="${WATCH_PROMPT_SHOW_RE:-❯|wants|Do you}"

# Marker that the session is BUSY (as opposed to stopped and waiting). Same vendor-UI
# caveat as the prompt shapes above, and the same variable qa-send.sh --verify-submit
# reads — set AGENTIC_WORKING_RE once and both tools track the change.
#
# Derived from observed screens: the discriminator is a present-tense spinner carrying a
# LIVE ELAPSED TIMER — "✶ Moseying… (5m 2s · ↓ 12.2k tokens)" — versus the past-tense line
# an idle session leaves behind, "✻ Worked for 3m 48s". Matching the spinner GLYPH alone
# reports an idle session as busy, because the idle line carries one too.
WORKING_RE="${AGENTIC_WORKING_RE:-esc to interrupt|ctrl\+b to run in background|… \([0-9]+[hms]}"

# Newest mtime under a path (file or directory). Depth-capped: an idle probe must not walk
# a whole repo every poll. BSD stat first, GNU second — same split as mtime_of.
newest_mtime() {
    local p="$1" out=""
    [ -e "$p" ] || { echo 0; return; }
    [ -f "$p" ] && { mtime_of "$p"; return; }
    out=$(find "$p" -maxdepth 3 -type f -exec stat -f %m {} + 2>/dev/null) || out=""
    [ -n "$out" ] || out=$(find "$p" -maxdepth 3 -type f -exec stat -c %Y {} + 2>/dev/null) || out=""
    out=$(printf '%s\n' "$out" | sort -rn | head -1)
    printf '%s\n' "${out:-0}"
}

# cksum, not a crypto hash: this only has to answer "did the screen change at all".
hash_of() { printf '%s' "$1" | cksum | tr -d ' '; }

IDLE_SECS=$((IDLE_MIN * 60))
if [ "$IDLE_SECS" -gt 0 ] && [ -z "$WIN" ]; then
    echo "--idle-escalation needs a window id: the busy/idle signal is read off the screen" >&2; exit 1
fi
idle_since=$(date +%s)
last_screen_hash=""
last_idle_mtime=$([ -n "$IDLE_WATCH" ] && newest_mtime "$IDLE_WATCH" || echo 0)

# Returns: 0 alive · 1 gone · 2 cannot tell (Terminal not running / no automation grant).
# "Cannot tell" must NEVER be reported as WINDOW_GONE — a quit Terminal.app or a revoked
# permission would otherwise read as a dead sprint and end the watch early.
#
# Discriminates on AppleScript's error CODE, not on exit status: Terminal answers a
# missing window with -1728 ("Can not get window id N"), which is the only signal that
# actually means gone. Do not substitute a `pgrep` check here — Terminal.app's process
# name is a full path, so `pgrep -x Terminal` never matches and every window trigger
# (including prompt detection) silently goes dead.
window_alive() {
    local err
    # `is running` first: a bare `tell application "Terminal"` would LAUNCH it.
    [ "$(osascript -e 'application "Terminal" is running' 2>/dev/null)" = "true" ] || return 2
    err=$(osascript -e "tell application \"Terminal\" to get id of window id $1" 2>&1 >/dev/null)
    [ -z "$err" ] && return 0
    printf '%s' "$err" | grep -q -- '-1728' && return 1
    return 2
}

[ -n "$TARGET" ] && [ "$NEWER_THAN" = "now" ] && NEWER_THAN="$(mtime_of "$TARGET")"

last_prompt=0
last_pattern=0

while true; do
    # --- file trigger ---
    if [ -n "$TARGET" ] && [ -s "$TARGET" ]; then
        MT="$(mtime_of "$TARGET")"
        if [ -z "$NEWER_THAN" ] || [ "$MT" -gt "$NEWER_THAN" ]; then
            if [ "$STREAM" -eq 1 ]; then
                emit FILE_UPDATED "$TARGET"
                NEWER_THAN="$MT"          # re-arm: the next rewrite fires too
            else
                if [ -z "$NEWER_THAN" ]; then echo "EVENT file-landed: $TARGET"; else echo "EVENT file-updated: $TARGET"; fi
                exit 0
            fi
        fi
    fi

    # --- window triggers ---
    if [ -n "$WIN" ]; then
        window_alive "$WIN"; ALIVE=$?
        if [ "$ALIVE" -eq 1 ]; then
            if [ "$STREAM" -eq 1 ]; then
                emit WINDOW_GONE "window $WIN closed or crashed"
            else
                echo "EVENT window-gone: $WIN (closed or crashed)"
            fi
            exit 0
        fi

        if [ "$ALIVE" -eq 0 ]; then
            SCREEN="$(osascript -e "tell application \"Terminal\" to get contents of window id $WIN" 2>/dev/null | tail -18)"
            now=$(date +%s)

            if printf '%s' "$SCREEN" | grep -qE "$PROMPT_RE"; then
                if [ $((now - last_prompt)) -gt 300 ]; then
                    DETAIL="$(printf '%s' "$SCREEN" | grep -E "$PROMPT_SHOW_RE" | tail -2 | tr '\n' ' ' | cut -c1-200)"
                    if [ "$STREAM" -eq 1 ]; then
                        emit PROMPT_BLOCK "window $WIN: ${DETAIL}"
                    else
                        echo "EVENT window-prompt-blocked (window $WIN):"
                        printf '%s\n' "$SCREEN" | grep -E "$PROMPT_SHOW_RE" | tail -4 | sed 's/^/    /'
                    fi
                    last_prompt=$now
                fi
            fi

            if [ -n "$PATTERN" ] && printf '%s' "$SCREEN" | grep -qE "$PATTERN"; then
                if [ $((now - last_pattern)) -gt 300 ]; then
                    DETAIL="$(printf '%s' "$SCREEN" | grep -E "$PATTERN" | tail -1 | cut -c1-200)"
                    if [ "$STREAM" -eq 1 ]; then
                        emit PATTERN_HIT "window $WIN: ${DETAIL}"
                    else
                        echo "EVENT window-pattern-hit (window $WIN): ${DETAIL}"
                    fi
                    last_pattern=$now
                fi
            fi

            # --- idle / blocked-state trigger ---
            # Three independent progress signals. ANY of them resets the clock; only their
            # simultaneous absence for IDLE_SECS means the session has actually stopped.
            # The screen checksum is the load-bearing one — a busy session repaints its
            # elapsed-time counter every second, so an unchanged screen is strong evidence.
            if [ "$IDLE_SECS" -gt 0 ]; then
                SCREEN_HASH="$(hash_of "$SCREEN")"
                IDLE_MT=0
                [ -n "$IDLE_WATCH" ] && IDLE_MT="$(newest_mtime "$IDLE_WATCH")"
                BUSY=0
                printf '%s' "$SCREEN" | grep -qE "$WORKING_RE" && BUSY=1

                if [ "$BUSY" -eq 1 ] || [ "$SCREEN_HASH" != "$last_screen_hash" ] || [ "$IDLE_MT" -gt "$last_idle_mtime" ]; then
                    idle_since=$now
                fi
                last_screen_hash="$SCREEN_HASH"
                [ "$IDLE_MT" -gt "$last_idle_mtime" ] && last_idle_mtime="$IDLE_MT"

                if [ $((now - idle_since)) -ge "$IDLE_SECS" ]; then
                    # Drop blank and border-only rows: the useful context is the last lines
                    # of TEXT, and a TUI frame would otherwise fill the whole detail field.
                    TAIL="$(printf '%s' "$SCREEN" \
                        | grep -v '^[[:space:]]*$' \
                        | grep -vE '^[[:space:]]*[─━│┌┐└┘├┤┬┴┼╭╮╰╯]+[[:space:]]*$' \
                        | tail -2 | tr '\n' ' ' | cut -c1-200)"
                    IDLE_DETAIL="window $WIN idle ${IDLE_MIN}m — no busy marker, screen unchanged; likely awaiting a ruling: ${TAIL}"
                    if [ "$STREAM" -eq 1 ]; then
                        emit IDLE_ESCALATION "$IDLE_DETAIL"
                        idle_since=$now     # re-arm: escalate again after another IDLE_MIN
                    else
                        echo "EVENT idle-escalation: $IDLE_DETAIL"
                        exit 3
                    fi
                fi
            fi
        fi
    fi

    sleep "$INTERVAL"
done
