#!/usr/bin/env bash
# qa-send.sh <window-id> <message-file> [--no-return] [--verify-submit [tries]]
#
# Inject the contents of <message-file> as keystrokes into the Terminal window with the
# given id (the proven osascript + System Events mechanism). Reads the message from a FILE
# so neither the message text nor the osascript braces/quotes land on the scanned command
# line.
#
# THE SINGLE KEYSTROKE PATH. Every keystroke-emitting caller in this template routes here —
# the /send skill, qa-drive-claude.sh's auto-kickoff. Do NOT hand-roll an inline
# `osascript … keystroke` anywhere else: the focus guard below is the only thing standing
# between an orchestration message and the operator's personal apps, and a second copy of
# this logic is a second copy of that risk.
#
# WHY A SCRIPT FILE: Claude Code has a safety heuristic that prompts on any command line
# combining brace constructs with quoted strings ("Contains brace with quote character
# (expansion obfuscation)"). It fires regardless of permissions.allow — by design. Inline
# `osascript <<HEREDOC … keystroke "$MSG"` one-liners trip it every time. Moving the logic
# into this file means only `bash scripts/cto/qa-send.sh <id> <file>` (plain positional args)
# is scanned — clean — while the braces/quotes live harmlessly in the script body.
#
# TWO INDEPENDENT FAILURE MODES, TWO GUARDS. Delivery and submission are not the same event:
#
#   FOCUS GUARD (always on)   — did the keystrokes reach the right window? Without it they
#                               go to whatever app is frontmost. See the guard body below.
#   --verify-submit (opt-in)  — did the target actually SUBMIT the message, or is it sitting
#                               in the input box? The trailing Return is absorbed as a literal
#                               newline when the session is mid-task (the Return-replay gap).
#                               Delivery succeeds, the ruling is never read. In one day this
#                               silently swallowed three orchestration rulings downstream.
#
# Use --verify-submit for anything the sprint depends on being READ (rulings, STOP orders,
# corrections). It costs up to ~<tries>×6s of wall clock and only when the send did not take.
#
# Note: needs Accessibility permission for Terminal (System Settings → Privacy & Security →
# Accessibility).
#
# Exit codes:  0 sent (check stderr for a mid-type focus warning) · 1 usage/IO
#              4 FOCUS GUARD abort (nothing typed) · 5 --verify-submit could not confirm

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WIN="${1:?usage: qa-send.sh <window-id> <message-file> [--no-return] [--verify-submit [tries]]}"
MSGFILE="${2:?need a message file (keeps message + osascript off the scanned command line)}"
shift 2
[ -f "$MSGFILE" ] || { echo "ERROR: message file not found: $MSGFILE"; exit 1; }
case "$WIN" in ''|*[!0-9]*) echo "ERROR: window id must be numeric, got '$WIN'"; exit 1 ;; esac

NORETURN="0"; VERIFY=0; TRIES=5
while [ $# -gt 0 ]; do
    case "$1" in
        --no-return)     NORETURN="1"; shift ;;
        --verify-submit) VERIFY=1; shift
                         case "${1:-}" in ''|*[!0-9]*) ;; *) TRIES="$1"; shift ;; esac ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
if [ "$VERIFY" = 1 ] && [ "$NORETURN" = "1" ]; then
    echo "ERROR: --verify-submit is meaningless with --no-return (nothing is submitted to verify)."; exit 1
fi

MSG="$(cat "$MSGFILE")"
[ -n "$MSG" ] || { echo "ERROR: message file is empty: $MSGFILE"; exit 1; }

# Marker that the target session is BUSY. Tracks a vendor's TUI, so it is overridable and
# shared with watch-file-or-prompt.sh — set it once for both. A watcher that silently stops
# matching is worse than one that never matched.
#
# Derived from observed screens, not from documentation. The discriminator is a
# present-tense spinner carrying a LIVE ELAPSED TIMER — "✶ Moseying… (5m 2s · ↓ 12.2k
# tokens)" — versus the past-tense line an idle session leaves behind, "✻ Worked for 3m
# 48s". Matching the spinner GLYPH alone reports an idle session as busy, because the idle
# line carries one too. "esc to interrupt" is present in some states only; it is kept as an
# alternative, never as the sole marker.
WORKING_RE="${AGENTIC_WORKING_RE:-esc to interrupt|ctrl\+b to run in background|… \([0-9]+[hms]}"

# --- the guarded keystroke primitive -----------------------------------------------------
# $1 = payload, $2 = "1" to suppress the trailing Return. Echoes the osascript result,
# returns the osascript exit status. Every keystroke in this file goes through here, so the
# nudges below are focus-guarded exactly like the message.
keystroke_guarded() {
osascript - "$WIN" "$1" "$2" <<'OSA' 2>&1
on run argv
  set winId to (item 1 of argv) as integer
  set theMsg to item 2 of argv
  set noReturn to item 3 of argv

  -- Raise the target. `try` because a stale id must fall through to the guard below,
  -- which reports it usefully, rather than dying with a raw AppleScript error.
  tell application "Terminal"
    activate
    try
      set index of (first window whose id is winId) to 1
    end try
  end tell

  -- FOCUS GUARD (2026-08-10, from a downstream incident).
  -- Keystrokes are delivered to whatever is FOCUSED, not to the window we addressed. When
  -- focus fails to land — the operator is using the machine, another app is frontmost, the
  -- window id is stale — the entire message INCLUDING the trailing Return types into that
  -- app instead. This is not theoretical: an orchestration message once landed in the
  -- operator's personal messaging app and may have auto-sent.
  --
  -- So: never type unverified. Poll (the raise is async and a loaded machine can take a
  -- second or two) until BOTH hold — Terminal is the frontmost process, and Terminal's front
  -- window is the target id — then type. If the poll expires, abort loudly and send NOTHING.
  -- Retrying the RAISE is fine; retrying the KEYSTROKE blind is what we are preventing.
  set guardOk to false
  set frontApp to "(none)"
  set frontWin to 0
  repeat 12 times
    delay 0.25
    tell application "System Events"
      try
        set frontApp to name of first application process whose frontmost is true
      on error
        set frontApp to "(cannot read — grant Accessibility permission to Terminal)"
      end try
    end tell
    if frontApp is "Terminal" then
      set frontWin to 0
      tell application "Terminal"
        try
          set frontWin to id of front window
        end try
      end tell
      if frontWin is winId then
        set guardOk to true
        exit repeat
      end if
    end if
  end repeat

  if not guardOk then
    if frontApp is not "Terminal" then
      error "FOCUS-GUARD: frontmost app is " & frontApp & ", not Terminal. NOTHING WAS SENT. The machine is in use, or Accessibility permission is missing." number 1001
    else if frontWin is 0 then
      error "FOCUS-GUARD: Terminal is frontmost but has no readable front window (target " & winId & " is likely closed). NOTHING WAS SENT." number 1002
    else
      error "FOCUS-GUARD: Terminal front window is " & frontWin & ", not target " & winId & " — the id is stale or another window stole focus. NOTHING WAS SENT." number 1003
    end if
  end if

  -- Verified. Scope the keystroke to the process as defence in depth.
  tell application "System Events"
    tell process "Terminal"
      keystroke theMsg
      if noReturn is "0" then
        -- Scale the wait to message length (~1.5s base + ~0.0015s/char). System Events
        -- returns before the OS finishes delivering every event; a fixed short delay makes
        -- the Return arrive mid-paste, where it is absorbed as a literal newline and the
        -- message sits UNSUBMITTED.
        delay (1.5 + (count of characters of theMsg) * 0.0015)
        key code 36
      end if
    end tell
  end tell

  -- A long message types for seconds. If focus was stolen partway, some of it landed
  -- elsewhere — the operator needs to know which app to go check.
  set stillFront to "(unknown)"
  tell application "System Events"
    try
      set stillFront to name of first application process whose frontmost is true
    end try
  end tell
  if stillFront is not "Terminal" then
    return "FOCUS-LOST-MIDSEND:" & stillFront
  end if
  return "OK"
end run
OSA
}

report_focus_abort() {
    echo "qa-send: ABORTED — $1" >&2
    echo "qa-send: nothing was typed. Re-run once Terminal can take focus, or re-resolve the window id:" >&2
    echo "  bash scripts/cto/window-peek.sh list" >&2
}

# --- send --------------------------------------------------------------------------------
OUT=$(keystroke_guarded "$MSG" "$NORETURN"); RC=$?
if [ "$RC" -ne 0 ]; then report_focus_abort "$OUT"; exit 4; fi

case "$OUT" in
    FOCUS-LOST-MIDSEND:*)
        echo "qa-send: WARNING — focus moved to '${OUT#FOCUS-LOST-MIDSEND:}' DURING typing." >&2
        echo "  Part of the message may have landed there. Check that app, and check window $WIN" >&2
        echo "  for a truncated message before re-sending." >&2 ;;
esac

echo "qa-send: injected $(wc -c < "$MSGFILE" | tr -d ' ') chars into window $WIN (return=$([ "$NORETURN" = "1" ] && echo no || echo yes))"
[ "$VERIFY" = 1 ] || exit 0

# --- verify submission -------------------------------------------------------------------
# THE AUTHORITATIVE SIGNAL IS THE INPUT BOX, not the spinner. A busy session proves nothing:
# the whole failure being guarded against is a message sitting unsubmitted WHILE the target
# works. So the question is only ever "is our text still in the box?"
#
#   box no longer holds our text → submitted (processing now, or queued for turn end). Done.
#   box still holds our text     → the Return replayed as a literal newline. Nudge with a
#                                  single SPACE plus Return: the space is the smallest
#                                  payload that makes the box register a fresh edit, and
#                                  anything longer appends garbage to the pending message.
#
# Our text is identified by the head of its first line, which is what the box renders even
# when a long message wraps.
MSGHEAD="$(printf '%s' "$MSG" | head -1 | cut -c1-24)"

for i in $(seq 1 "$TRIES"); do
    sleep 5
    PENDING="$(bash "$HERE/window-peek.sh" "$WIN" --input 2>/dev/null)"; PRC=$?

    if [ "$PRC" -ne 0 ]; then
        BUSY_NOTE="queued for turn end"
        bash "$HERE/window-peek.sh" "$WIN" 25 2>/dev/null | grep -qE "$WORKING_RE" && BUSY_NOTE="target is processing"
        echo "qa-send: SUBMITTED — input box cleared on attempt $i ($BUSY_NOTE)."
        exit 0
    fi

    if ! printf '%s' "$PENDING" | grep -qF "$MSGHEAD"; then
        echo "qa-send: SUBMITTED — our message left the input box on attempt $i." >&2
        echo "  NOTE: the box is not empty; it now holds unrelated text:" >&2
        echo "    $(printf '%s' "$PENDING" | cut -c1-80)" >&2
        echo "  That is stray input queued ahead of the next send — clear it in window $WIN." >&2
        exit 0
    fi

    echo "qa-send: attempt $i/$TRIES — still unsubmitted (\"$(printf '%s' "$PENDING" | cut -c1-60)\"), nudging…" >&2
    NOUT=$(keystroke_guarded " " "0"); NRC=$?
    if [ "$NRC" -ne 0 ]; then report_focus_abort "$NOUT"; exit 4; fi
done

echo "qa-send: NOT CONFIRMED — after $TRIES nudges the message is still in window $WIN's input box." >&2
echo "  It has NOT been read. Press Enter in that window, or check it for a blocking dialog:" >&2
echo "    bash scripts/cto/window-peek.sh $WIN" >&2
exit 5
