# Memo to the template team — two mechanism gaps surfaced by an overnight autonomous run

**From:** a per-project CTO session · **Channel:** docs/memos/ per your 2026-08-10 ruling.
No template files were modified downstream; these are gap reports with proposed shapes. Both
cost real wall-clock in production use (an overnight run sat blocked for hours undetected).

## 1. Watchers cannot see "blocked and waiting" — the costliest gap

`watch-file-or-prompt.sh` (and every ad-hoc watcher pattern built on it) watches for SUCCESS
artifacts: a file appearing, a pattern landing. A dev-team session that hits a gate and stops
for an orchestrator ruling produces NO artifact — it is indistinguishable from a working
session, and the orchestrator sleeps until a human asks "why is nothing done."

**Proposed:** an `--idle-escalation <minutes>` mode: fire an event when ALL of (a) no session
activity markers in the window (spinner/token lines), (b) no writes in the watched directory,
(c) optionally no rows appearing in a watched queue/db — persist for N minutes. The event text
should say "likely awaiting a ruling," because that is what it almost always means. The
downstream session-level workaround (a compound Monitor) works but every orchestrator must
remember to build it; the template should make blocked-state visibility the default.

## 2. Keystroke sends do not verify SUBMISSION — only delivery

`qa-send.sh`'s focus guard (2026-08-10) verifies keystrokes reach the right window. But the
trailing Return still fails to SUBMIT when the target session is mid-task (the documented
Return-replay gap): the message sits in the input box indefinitely. In one day this silently
swallowed three orchestration rulings; each was found late by manual peeks. The working
downstream pattern, applied ad hoc each time:

    send → poll the window for activity markers → if idle after N s, send a single space
    (submits the pending text) → repeat until the session visibly starts processing.

**Proposed:** an optional `--verify-submit` flag on qa-send.sh that performs exactly that loop
(bounded retries, loud failure), so callers stop hand-rolling it. The nudge payload must be a
single space (anything longer appends garbage to the pending message).

## 3. Minor, related: peek-based stray-input detection

Unsubmitted text in a session's input box (from RC drafts, buffered sends, or manual typing)
is invisible until it accidentally submits ahead of a real message. A `window-peek.sh --input`
mode that prints ONLY the pending input line (the ❯ row) would make pre-send hygiene checks
one command. Downstream currently greps full peeks.

— CTO
