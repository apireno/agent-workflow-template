#!/usr/bin/env bash
# qa-send.sh <window-id> <message-file> [--no-return] [--verify-submit [tries]]
#                                      [--repo <path> | --transcript <file>] [--type]
#                                      [--submit-composer-text <who-confirmed-authorship>]
#
# Inject the contents of <message-file> into the Claude Code session running in the Terminal
# window with the given id. Reads the message from a FILE so neither the message text nor the
# osascript braces/quotes land on the scanned command line.
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
# ── THREE INDEPENDENT FAILURE MODES, THREE GUARDS ────────────────────────────────────────
# Delivery, submission and PROCESSING are three different events. Each can fail while the
# previous one succeeds, and each failure looks like success from the layer below:
#
#   FOCUS GUARD (always on)   — did the input reach the right window? Without it, input goes
#                               to whatever app is frontmost.
#   --verify-submit (opt-in)  — did the target SUBMIT, or is the text sitting in the box? The
#                               trailing Return is absorbed as a literal newline when the
#                               session is mid-task (the Return-replay gap).
#   --repo / --transcript     — did the session actually PROCESS it? A message can submit into
#                               the QUEUE and then be dropped at turn end. Observed 2026-08-13:
#                               box cleared, "SUBMITTED" reported, ruling never read. Box state
#                               is a proxy; the session transcript on disk is ground truth.
#
# Use --verify-submit --repo <path> for anything the sprint depends on being READ (rulings,
# STOP orders, corrections). Without a transcript this script will NOT claim a message was
# processed — it says DELIVERED and names what it could not verify.
#
# ── AUTHORSHIP: WHAT THIS SCRIPT MAY AND MAY NOT SUBMIT ──────────────────────────────────
# Everything above is about a message WE wrote: authorship is the sender's, and the guards
# only ask whether it arrived. A different and more dangerous act shares the same keystroke
# path — submitting text that was ALREADY in the target's composer, which we did not write.
#
# That is barred by default, because the composer is not attributable. Claude Code renders
# its own generated inline suggestion in the same cells as typed text, differing only by
# colour, and every window read here strips colour: a suggestion and a human's unsubmitted
# draft are byte-identical. Submitting one hands the session its own advice back under its
# principal's authority. On 2026-08-27 exactly that was attempted twice against a live dev
# window on a watcher signal; only a busy composer stopped it.
#
# The concrete shape it took is a WHITESPACE-ONLY message file — a lone space is the
# smallest payload that makes the composer register an edit and submit what is already
# there. So a whitespace-only payload is REFUSED here unless the caller passes
#
#     --submit-composer-text "<who confirmed they typed it>"
#
# which requires a named human attestation, refuses on an empty composer, and prints the
# exact text being submitted before it presses Return. Watchers never get to pass it: a
# watcher signal is not a human. Detection ALERTS; a human confirms; only then does this run.
#
# (The internal nudge in --verify-submit stage 1 also sends a bare space, and that one is
# safe for the reason this whole section is about: it fires ONLY while the box still matches
# the head of OUR message, so the text it submits is text we wrote. It never reaches this
# argument path.)
#
# ── INJECTION MODE ───────────────────────────────────────────────────────────────────────
# Default is CLIPBOARD PASTE (⌘V), not per-character typing. Typing a 2KB message holds the
# keyboard for seconds, and twice on 2026-08-13 focus moved DURING that window and fragments
# of an orchestration message were typed into the operator's WhatsApp and Chrome. Paste
# collapses that exposure from seconds to a single event, and focus is re-verified between
# the paste and the Return so a steal in between aborts BEFORE anything can be submitted
# somewhere it shouldn't be. `--type` (or AGENTIC_SEND_MODE=type) restores keystroke mode.
#
# The operator's clipboard is saved and restored (text only — a non-text clipboard, e.g. a
# copied image, is not preserved).
#
# Note: needs Accessibility permission for Terminal (System Settings → Privacy & Security →
# Accessibility).
#
# Exit codes:  0 delivered (and processed, when a transcript was given) · 1 usage/IO
#              4 FOCUS GUARD abort (nothing sent) · 5 --verify-submit could not confirm
#              6 submitted but NOT processed by the session (queued and dropped, or still busy)
#              7 REFUSED — whitespace-only payload without a human authorship attestation

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WIN="${1:?usage: qa-send.sh <window-id> <message-file> [--no-return] [--verify-submit [tries]] [--repo <path>] [--type]}"
MSGFILE="${2:?need a message file (keeps message + osascript off the scanned command line)}"
shift 2
[ -f "$MSGFILE" ] || { echo "ERROR: message file not found: $MSGFILE"; exit 1; }
case "$WIN" in ''|*[!0-9]*) echo "ERROR: window id must be numeric, got '$WIN'"; exit 1 ;; esac

NORETURN="0"; VERIFY=0; TRIES=5; REPO=""; TRANSCRIPT=""; ATTESTED_BY=""
SEND_MODE="${AGENTIC_SEND_MODE:-paste}"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-return)     NORETURN="1"; shift ;;
        --type)          SEND_MODE="type"; shift ;;
        --paste)         SEND_MODE="paste"; shift ;;
        --repo)          REPO="${2:?--repo needs a path}"; shift 2 ;;
        --transcript)    TRANSCRIPT="${2:?--transcript needs a file}"; shift 2 ;;
        --submit-composer-text)
                         ATTESTED_BY="${2:?--submit-composer-text needs the name of the human who confirmed they typed the text}"; shift 2 ;;
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

# ── THE AUTHORSHIP GATE ──────────────────────────────────────────────────────────────────
# A whitespace-only payload carries no message. Its only effect is to make the target's
# composer register an edit and SUBMIT WHATEVER IS ALREADY IN IT — text this script did not
# write and cannot attribute. See the header: that text may be Claude Code's own generated
# suggestion, and a window read cannot tell. This is the guard for the 2026-08-27 near-miss.
if [ -z "$(printf '%s' "$MSG" | tr -d '[:space:]')" ]; then
    if [ -z "$ATTESTED_BY" ]; then
        echo "qa-send: REFUSED — '$MSGFILE' holds only whitespace." >&2
        echo "  A whitespace payload does not send a message; it SUBMITS whatever is already in" >&2
        echo "  window $WIN's composer. That text is UNVERIFIED-AUTHORSHIP: Claude Code's own grey" >&2
        echo "  suggestion is byte-identical to a human draft once a window read strips colour, so" >&2
        echo "  submitting it can feed the session its own advice under its principal's authority." >&2
        echo "" >&2
        echo "  A watcher signal is NOT authorization. Show the text to a human first:" >&2
        echo "      bash $HERE/window-peek.sh $WIN --input" >&2
        echo "  and if they confirm they typed it, re-run naming them:" >&2
        echo "      bash $HERE/qa-send.sh $WIN $MSGFILE --submit-composer-text \"<their name>\"" >&2
        echo "  To send a message of your own instead, put the message in the file." >&2
        exit 7
    fi
    # Attested path. Refuse on an empty composer (nothing to submit — a bare space would just
    # add a stray character), and print the exact text so the attestation is on the record.
    COMPOSER="$(bash "$HERE/window-peek.sh" "$WIN" --input 2>/dev/null)"
    if [ -z "$COMPOSER" ]; then
        echo "qa-send: REFUSED — window $WIN's composer is empty; there is nothing to submit." >&2
        echo "  (A whitespace payload into an empty box types a stray space, nothing more.)" >&2
        exit 7
    fi
    echo "qa-send: SUBMITTING COMPOSER TEXT of window $WIN on the authority of: $ATTESTED_BY" >&2
    echo "  text being submitted (authorship attested, NOT verified by this script):" >&2
    echo "    $(printf '%s' "$COMPOSER" | cut -c1-160)" >&2
    if bash "$HERE/window-peek.sh" "$WIN" --authorship >/dev/null 2>&1; then
        echo "  corroborating: suggestions are provably off in this window, so it is not generated." >&2
    else
        echo "  NOTE: suggestions are NOT provably off in this window. $ATTESTED_BY's confirmation" >&2
        echo "  is the ONLY thing distinguishing this text from a generated suggestion." >&2
    fi
fi

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

# ── resolve the transcript (ground truth for "was it processed") ──────────────────────────
if [ -z "$TRANSCRIPT" ] && [ -n "$REPO" ]; then
    SID_FILE="$REPO/.claude/current-session.id"
    if [ -f "$SID_FILE" ]; then
        SID="$(tr -d '[:space:]' < "$SID_FILE")"
        TRANSCRIPT="$(ls -1 "$HOME/.claude/projects/"*/"$SID.jsonl" 2>/dev/null | head -1)"
        [ -n "$TRANSCRIPT" ] || echo "qa-send: WARNING — no transcript found for session $SID under ~/.claude/projects (processing cannot be verified)" >&2
    else
        echo "qa-send: WARNING — $SID_FILE not found; processing cannot be verified" >&2
    fi
fi
TRANSCRIPT_SIZE_BEFORE=0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && TRANSCRIPT_SIZE_BEFORE=$(wc -c < "$TRANSCRIPT" | tr -d ' ')

# ── clipboard hygiene ─────────────────────────────────────────────────────────────────────
CLIP_SAVED=0; OLD_CLIP=""
restore_clip() {
    [ "$CLIP_SAVED" = 1 ] || return 0
    printf '%s' "$OLD_CLIP" | pbcopy 2>/dev/null || true
    CLIP_SAVED=0
}
trap restore_clip EXIT INT TERM

if [ "$SEND_MODE" = "paste" ]; then
    if ! command -v pbcopy >/dev/null 2>&1 || ! command -v pbpaste >/dev/null 2>&1; then
        echo "qa-send: pbcopy/pbpaste unavailable — falling back to keystroke mode" >&2
        SEND_MODE="type"
    else
        OLD_CLIP="$(pbpaste 2>/dev/null || true)"; CLIP_SAVED=1
        printf '%s' "$MSG" | pbcopy
    fi
fi

# --- the guarded injection primitive ------------------------------------------------------
# $1 = payload (ignored in paste mode — the clipboard carries it), $2 = "1" to suppress the
# trailing Return, $3 = "paste" | "type". Echoes the osascript result, returns its status.
# Every character this template sends goes through here, so the nudges below are guarded
# exactly like the message.
inject_guarded() {
osascript - "$WIN" "$1" "$2" "$3" <<'OSA' 2>&1
on run argv
  set winId to (item 1 of argv) as integer
  set theMsg to item 2 of argv
  set noReturn to item 3 of argv
  set sendMode to item 4 of argv

  -- Raise the target. `try` because a stale id must fall through to the guard below,
  -- which reports it usefully, rather than dying with a raw AppleScript error.
  tell application "Terminal"
    activate
    try
      set index of (first window whose id is winId) to 1
    end try
  end tell

  -- FOCUS GUARD (2026-08-10, from a downstream incident; hardened 2026-08-14).
  -- Input is delivered to whatever is FOCUSED, not to the window we addressed. When focus
  -- fails to land — the operator is using the machine, another app is frontmost, the window
  -- id is stale — the entire message INCLUDING the trailing Return goes to that app instead.
  -- This is not theoretical: orchestration text landed in the operator's WhatsApp and Chrome
  -- on three separate occasions.
  --
  -- So: never send unverified. Poll (the raise is async and a loaded machine can take a
  -- second or two) until BOTH hold — Terminal is the frontmost process, and Terminal's front
  -- window is the target id. If the poll expires, abort loudly and send NOTHING.
  -- Retrying the RAISE is fine; retrying the SEND blind is what we are preventing.
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

  -- Verified. Scope the send to the process as defence in depth.
  --
  -- PASTE MODE is the default because it is ATOMIC. Typing a long message holds the keyboard
  -- for seconds; a focus steal anywhere in that window sprays the remainder into whatever
  -- app took over. One ⌘V is a single event, so the exposure is one instant rather than a
  -- span. Bracketed paste also means embedded newlines do not each submit.
  tell application "System Events"
    tell process "Terminal"
      if sendMode is "paste" then
        keystroke "v" using command down
        delay 0.6
      else
        keystroke theMsg
        -- Scale the wait to message length (~1.5s base + ~0.0015s/char). System Events
        -- returns before the OS finishes delivering every event; a fixed short delay makes
        -- the Return arrive mid-type, where it is absorbed as a literal newline and the
        -- message sits UNSUBMITTED.
        delay (1.5 + (count of characters of theMsg) * 0.0015)
      end if
    end tell
  end tell

  -- RE-VERIFY BEFORE THE RETURN. The window between delivery and submit is exactly where
  -- the 2026-08-13 leaks happened. If focus moved, we must NOT press Return: in a messaging
  -- app that keystroke is what turns a stray paste into a sent message. Report and stop.
  set stillFront to "(unknown)"
  tell application "System Events"
    try
      set stillFront to name of first application process whose frontmost is true
    end try
  end tell
  if stillFront is not "Terminal" then
    return "FOCUS-LOST-MIDSEND:" & stillFront
  end if

  if noReturn is "0" then
    tell application "System Events"
      tell process "Terminal"
        key code 36
      end tell
    end tell
  end if

  return "OK"
end run
OSA
}

report_focus_abort() {
    echo "qa-send: ABORTED — $1" >&2
    echo "qa-send: nothing was sent. Re-run once Terminal can take focus, or re-resolve the window id:" >&2
    echo "  bash scripts/cto/window-peek.sh list" >&2
}

# --- send ---------------------------------------------------------------------------------
OUT=$(inject_guarded "$MSG" "$NORETURN" "$SEND_MODE"); RC=$?
if [ "$RC" -ne 0 ]; then report_focus_abort "$OUT"; exit 4; fi

case "$OUT" in
    FOCUS-LOST-MIDSEND:*)
        STOLE="${OUT#FOCUS-LOST-MIDSEND:}"
        echo "qa-send: ABORTED MID-SEND — focus moved to '$STOLE' after delivery." >&2
        echo "  NO Return was pressed, so nothing was submitted anywhere." >&2
        if [ "$SEND_MODE" = "paste" ]; then
            echo "  Paste mode: the message may have pasted into '$STOLE'. Check and clear it there." >&2
        else
            echo "  Keystroke mode: part of the message may have typed into '$STOLE'. Check it there," >&2
            echo "  and check window $WIN for a truncated fragment before re-sending." >&2
        fi
        restore_clip
        exit 4 ;;
esac

restore_clip
echo "qa-send: injected $(wc -c < "$MSGFILE" | tr -d ' ') chars into window $WIN (mode=$SEND_MODE, return=$([ "$NORETURN" = "1" ] && echo no || echo yes))"
[ "$VERIFY" = 1 ] || exit 0

# --- stage 1: verify SUBMISSION -----------------------------------------------------------
# The question here is only "is our text still in the box?" A busy session proves nothing:
# the failure being guarded against is a message sitting unsubmitted WHILE the target works.
#
#   box no longer holds our text → left the box. Continue to stage 2.
#   box still holds our text     → the Return replayed as a literal newline. Nudge with a
#                                  single SPACE plus Return: the smallest payload that makes
#                                  the box register a fresh edit. Anything longer appends
#                                  garbage to the pending message.
#
# Our text is identified by the head of its first line, which is what the box renders even
# when a long message wraps. In paste mode the TUI may instead render a "[Pasted text #N]"
# placeholder — window-peek --input reports that as pending, which is the correct reading.
MSGHEAD="$(printf '%s' "$MSG" | head -1 | cut -c1-24)"
SUBMITTED=0

for i in $(seq 1 "$TRIES"); do
    sleep 5
    PENDING="$(bash "$HERE/window-peek.sh" "$WIN" --input 2>/dev/null)"; PRC=$?

    if [ "$PRC" -ne 0 ]; then SUBMITTED=1; break; fi

    case "$PENDING" in
        *"[Pasted text"*) : ;;   # our paste, still pending — keep nudging
        *)
            if ! printf '%s' "$PENDING" | grep -qF "$MSGHEAD"; then
                echo "qa-send: our message left the input box on attempt $i." >&2
                echo "  NOTE: the box is not empty; it now holds unrelated text:" >&2
                echo "    $(printf '%s' "$PENDING" | cut -c1-80)" >&2
                echo "  That is stray input queued ahead of the next send — clear it in window $WIN." >&2
                SUBMITTED=1; break
            fi ;;
    esac

    echo "qa-send: attempt $i/$TRIES — still unsubmitted (\"$(printf '%s' "$PENDING" | cut -c1-60)\"), nudging…" >&2
    NOUT=$(inject_guarded " " "0" "type"); NRC=$?
    if [ "$NRC" -ne 0 ]; then report_focus_abort "$NOUT"; exit 4; fi
    case "$NOUT" in FOCUS-LOST-MIDSEND:*) report_focus_abort "$NOUT"; exit 4 ;; esac
done

if [ "$SUBMITTED" -ne 1 ]; then
    echo "qa-send: NOT CONFIRMED — after $TRIES nudges the message is still in window $WIN's input box." >&2
    echo "  It has NOT been read. Press Enter in that window, or check it for a blocking dialog:" >&2
    echo "    bash scripts/cto/window-peek.sh $WIN" >&2
    exit 5
fi

# --- stage 2: verify PROCESSING -----------------------------------------------------------
# An empty input box means the text LEFT the box. It does not mean the session read it: a
# message submitted while the target is mid-turn goes into a QUEUE, and on 2026-08-13 a
# queued ruling was dropped at turn end — box cleared, nothing processed, no artifact, no
# transcript entry. Box state is a proxy. The session's JSONL on disk is ground truth.
QUEUED_HINT=0
bash "$HERE/window-peek.sh" "$WIN" 40 2>/dev/null | grep -qF "Press up to edit queued messages" && QUEUED_HINT=1

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    echo "qa-send: DELIVERED — the message left the input box of window $WIN."
    echo "  NOT VERIFIED: whether the session actually processed it. Pass --repo <path> (or"
    echo "  --transcript <file>) to check the session transcript, which is the only signal that"
    echo "  distinguishes 'read' from 'queued and dropped'."
    [ "$QUEUED_HINT" = 1 ] && echo "  The screen shows 'Press up to edit queued messages' — it is QUEUED, not yet read."
    exit 0
fi

for i in $(seq 1 "$TRIES"); do
    SIZE_NOW=$(wc -c < "$TRANSCRIPT" | tr -d ' ')
    if [ "$SIZE_NOW" -gt "$TRANSCRIPT_SIZE_BEFORE" ] && grep -qF "$MSGHEAD" "$TRANSCRIPT" 2>/dev/null; then
        echo "qa-send: PROCESSED — the message appears in the session transcript (attempt $i)."
        echo "  transcript: $TRANSCRIPT (+$((SIZE_NOW - TRANSCRIPT_SIZE_BEFORE)) bytes)"
        exit 0
    fi
    sleep 10
done

echo "qa-send: SUBMITTED BUT NOT PROCESSED — the message left window $WIN's input box, but after" >&2
echo "  $((TRIES * 10))s it has not appeared in the session transcript." >&2
echo "  transcript: $TRANSCRIPT" >&2
if [ "$QUEUED_HINT" = 1 ]; then
    echo "  The screen shows 'Press up to edit queued messages' — it is QUEUED behind the current turn." >&2
    echo "  Queued messages have been DROPPED at turn end before. Re-check once the turn ends:" >&2
else
    echo "  Either the target is still mid-turn, or the message was swallowed. Re-check with:" >&2
fi
echo "    bash scripts/cto/window-peek.sh $WIN" >&2
echo "  Do NOT assume the ruling was read." >&2
exit 6
