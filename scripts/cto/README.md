# CTO ops scripts — the analyzer-friendly rule

Claude Code's command analyzer prompts on command SHAPE, not on trust. Inline quoting,
heredocs, pipes, and command substitution cannot be statically analyzed, so they prompt
**every time a new shape appears — regardless of `permissions.allow`.** An orchestration
session that improvises shell at the prompt therefore stops on a dialog every few minutes.

The rule:

1. **Any shell shape needed twice becomes a committed script here, invoked with plain
   positional arguments.** Only the invoking command line is scanned, and
   `bash scripts/cto/<script>.sh <arg> <arg>` is a stable, analyzable shape. Push the
   quoting, the substitution, and the loop *inside* the file.

2. **A script and its allowlist entry are one unit — *where the posture is tight*.** If a
   settings file grants blanket `Bash(*)` (the CTO template currently does), a per-script
   entry adds nothing and is dead weight. If the posture is tightened — or in a dev-team
   repo running a narrower permission set — the script needs its own entry, added in the
   same commit:

   ```
   "Bash(bash $CLAUDE_PROJECT_DIR/scripts/cto/<script>.sh:*)"
   ```

   Use **`$CLAUDE_PROJECT_DIR`** — that is the variable Claude Code actually expands in
   Bash permission rules. An invented variable name expands to nothing, so the rule
   matches nothing while *looking* allowlisted.
   ([settings reference](https://docs.claude.com/en/docs/claude-code/settings))

   Note what an allowlist entry does **not** buy you: it does not suppress the analyzer
   prompt from rule 1. Brace-plus-quote command lines prompt even under `Bash(*)`. Shape
   is the fix; the allowlist is only about the invocation being permitted at all.

3. **Generic mechanism lives here; project-specific wrappers live downstream.** The test
   is not "is it useful" but **"can it run in a repo that knows nothing about your
   project?"** A script that names your app's ports, process names, bringup script,
   database, or repos is downstream tooling — it belongs in that project's private
   `<project>-cto` home, following the same two-part rule. Send the *pattern* back here,
   not the wrapper.

   > Genericizing by find-and-replacing literals with `${VAR:-default}` does not satisfy
   > this. That transformation has already shipped a script whose URLs lost their `:`,
   > whose paths doubled a directory segment, and which still hard-coded two project
   > process names. If a script needs project knowledge to be useful, the honest move is
   > to leave it downstream and upstream the convention instead.

4. **Anything that emits keystrokes routes through `qa-send.sh`, and any new keystroke
   tool MUST carry a focus guard.** macOS delivers synthetic keystrokes to whatever app is
   **focused**, not to the window you addressed. When focus fails to land — the operator is
   using the machine, another app is frontmost, the window id is stale — the entire message
   *including the trailing Return* types into that app. This is not hypothetical: an
   orchestration message once landed in an operator's personal messaging app and may have
   auto-sent.

   So a keystroke path must verify, immediately before typing, that the target app is
   frontmost **and** that its front window is the target window — and on mismatch abort
   loudly having sent **nothing**. Retrying the *raise* is fine; retrying the *keystroke*
   blind is exactly the failure. `qa-send.sh` implements this; call it rather than writing a
   second copy, because a second copy of the logic is a second copy of the risk. Treat a
   missing focus guard as an automatic BLOCKER in review.

   **Delivery is not submission — they fail independently.** The trailing Return is absorbed
   as a literal newline when the target is mid-task, so a perfectly delivered message can sit
   unread in an input box forever; three orchestration rulings were lost this way in one day.
   Anything that must be *read* — a ruling, a STOP, a correction — sends with
   `--verify-submit`, which polls the input box and nudges until our text leaves it. Verify
   against the **box**, never against the spinner: a busy target proves nothing, because
   sitting unsubmitted while the session works is the whole failure.

   Both guards share `AGENTIC_WORKING_RE`, the busy-marker regex, with
   `watch-file-or-prompt.sh`. It tracks a vendor's TUI and *will* drift — it is one override
   for every tool that reads a screen, and it is derived from observed screens, not docs.

5. **No inventory list in this file.** A hand-maintained list of what's in this directory
   goes stale the first time someone forgets to update it, and a stale inventory is worse
   than none — it gets read as authoritative. Every script's own header says what it does
   and why it exists; `ls scripts/cto/` is the inventory.

## What is already here

Each of these carries its own header explaining its contract and the failure that
motivated it. Read the header before using or changing one.

Scripts are macOS + Terminal.app bound wherever they touch windows (`osascript`) — the
same constraint as `/handoff`, `/send`, and `/close-window`. The file- and process-
watching halves are portable.
