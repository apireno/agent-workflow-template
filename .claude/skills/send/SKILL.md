---
name: send
description: Send a message to a running Phase 2 dev-team Claude Code session by injecting it into the recorded Terminal window via osascript. Use when /peek shows the dev team asking a question, when VP review feedback needs to reach a running session, or when you want to pass a follow-up instruction without spawning a new tab. Auto-fire when the CEO says things like "tell the tuner team to X", "respond to the morphology dev team with Y", "ask the dev team to Z". Cheaper than /resume-dev-team because there is no new session, no conversation-history reload, no token cost. A bare NUMERIC first argument is treated as a Terminal window id and addressed directly — use that for windows the repo registry cannot name: a second sprint on the same repo (handoff overwrites the single recorded id slot), a QA drive window, or another orchestration session with no repo binding.
allowed-tools: Bash(*) Read
argument-hint: <repo-name|window-id> <message>
---

# Send to dev team: $ARGUMENTS

Injects a message into the live Claude Code session running in the repo's recorded Terminal window. The dev team sees the message as if a human typed it at the prompt.

```!
set -uo pipefail
# CTO-HOME ANCHORING. These skills read the fleet registry, which lives in the CTO home
# — but `git rev-parse` returns whatever repo the SHELL happens to sit in. A lingering cd
# into a project repo made /handoff report "no target repos found" and made vp-review
# resolve personas against the wrong tree. $CLAUDE_PROJECT_DIR is the session's project
# root regardless of cwd drift, so it is the correct anchor; git root is the fallback.
CTO_HOME_REQUIRED=1
# >>> CTO-HOME ANCHOR (canonical — sync with: bash scripts/cto/lint-skills.sh --apply) >>>
# Fleet state lives in the CTO home, and neither obvious anchor is reliable alone:
# `git rev-parse` returns whatever repo the SHELL sits in, so one lingering cd into a dev
# repo silently retargets the skill; and $CLAUDE_PROJECT_DIR was observed EMPTY in skill
# shells (2026-08-13) — /handoff then resolved the registry against a dev repo and refused
# with an error that blamed the registry rather than the anchoring. So: try every anchor,
# VALIDATE each candidate before accepting it, and when none holds either fail naming the
# real cause or fall back explicitly and say so.
# Skills that read the fleet registry set CTO_HOME_REQUIRED=1 before this block.
#
# NO POSITIONAL PARAMETERS IN THIS BLOCK — no dollar-1, no dollar-2, not even awk's dollar-1.
# (Spelled out rather than written literally, because the rewrite described next hits comments
#  too: a literal example here would itself be replaced with argument text.)
#
# This block is embedded in SKILL.md, and the skill runtime rewrites every dollar-followed-by-
# digits token in the FILE with the invocation's arguments before the shell ever sees it. The
# rewrite is document-wide: no awareness of code fences, no escape (a backslash before it does
# not protect it — it renders empty), and it applies inside comments and string literals alike.
# A shell function's own positional parameter is therefore replaced by argument text, and when
# the skill is invoked with no arguments it is replaced by nothing at all.
#
# The first version of this block used positional parameters and was consequently broken from
# the day it shipped: _cto_is_home tested a garbage path on every candidate, so the anchor
# NEVER matched, and every skill carrying it silently fell back to the cwd repo — precisely the
# confident wrong answer it was written to prevent. Found 2026-09-01, six weeks after it
# shipped, because the fallback usually landed on the right repo by luck.
#
# Candidates are passed in named variables instead. Brace-wrapped positionals happen to survive
# the rewrite; do not use them either — the next person to write the bare form reintroduces the
# bug, and it fails silently. Guarded by lint CHECK E.
_CTO_REJECTED=""
_CTO_CAND=""
_cto_is_home() {          # in: _CTO_CAND · appends to _CTO_REJECTED
  [ -n "$_CTO_CAND" ] && [ -f "$_CTO_CAND/.cto/projects.yaml" ] || return 1
  # The PUBLIC template ships a placeholder registry (/Users/yourname/repos/my-project).
  # Accepting it resolves cleanly and then reports a fleet of repos that do not exist —
  # a confident wrong answer, which is worse than the error it replaced. Observed live:
  # four dev repos still point .cto-path at the template, so this is the real path.
  if grep -q '/Users/yourname/' "$_CTO_CAND/.cto/projects.yaml" 2>/dev/null; then
    _CTO_REJECTED="$_CTO_REJECTED  $_CTO_CAND (placeholder registry — the unconfigured template)"
    return 1
  fi
  return 0
}
# Sets _CTO_FOUND rather than printing: a $(…) capture runs in a SUBSHELL, so the rejected-
# candidate diagnostics collected by _cto_is_home would be discarded exactly when they are
# needed — on the failure path.
_CTO_FOUND=""
_cto_walk() {             # in: _CTO_START · out: _CTO_FOUND
  _d="$_CTO_START"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    _CTO_CAND="$_d"; _cto_is_home && { _CTO_FOUND="$_d"; return 0; }
    if [ -f "$_d/.cto-path" ]; then
      _p="$(tr -d '[:space:]' < "$_d/.cto-path")"
      _CTO_CAND="$_p"; _cto_is_home && { _CTO_FOUND="$_p"; return 0; }
    fi
    # `--` because a mis-rendered candidate can begin with a dash, and `dirname --repos=x`
    # exits with "illegal option" instead of walking. That message was the only outward sign
    # of the rewrite bug above for two weeks, and it was read as cosmetic noise.
    _d="$(dirname -- "$_d")"
  done
  return 1
}
ROOT=""
for _c in "${CTO_HOME:-}" "${CTO_REPO:-}" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$_c" ] || continue
  _CTO_CAND="$_c"; _cto_is_home && { ROOT="$_c"; break; }
done
if [ -z "$ROOT" ]; then _CTO_START="$PWD"; if _cto_walk; then ROOT="$_CTO_FOUND"; fi; fi
if [ -z "$ROOT" ] && [ -f "$HOME/.cto/home" ]; then
  _p="$(tr -d '[:space:]' < "$HOME/.cto/home")"
  _CTO_CAND="$_p"; _cto_is_home && ROOT="$_p"
fi
if [ -z "$ROOT" ]; then
  if [ "${CTO_HOME_REQUIRED:-0}" = "1" ]; then
    echo "ERROR: no CTO home found — no directory containing .cto/projects.yaml." >&2
    echo "  \$CTO_HOME='${CTO_HOME:-}'  \$CTO_REPO='${CTO_REPO:-}'  \$CLAUDE_PROJECT_DIR='${CLAUDE_PROJECT_DIR:-}'" >&2
    echo "  walked up from: $PWD" >&2
    # Report the permanent anchor's CONTENT, not just that the remedy exists. When the anchor
    # is set correctly and the skill still fails, the error must not keep recommending it —
    # that loop cost a full diagnosis cycle on 2026-09-01.
    if [ -f "$HOME/.cto/home" ]; then
      echo "  ~/.cto/home is SET and was tested: '$(tr -d '[:space:]' < "$HOME/.cto/home")'" >&2
      echo "  It did not validate, so the remedy below is already applied and is NOT the fix." >&2
      echo "  Check that path holds .cto/projects.yaml, then suspect the skill rendering itself." >&2
    else
      echo "  This is an ANCHORING failure, not a missing registry. Run the skill from the CTO" >&2
      echo "  home, or fix it permanently:  echo /path/to/<project>-cto > ~/.cto/home" >&2
    fi
    [ -n "$_CTO_REJECTED" ] && { echo "  rejected candidates:" >&2; printf '%s\n' "$_CTO_REJECTED" >&2; }
    exit 1
  fi
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "NOTE: no CTO home found; using the current repo ($ROOT)." >&2
fi
CTO_REGISTRY="$ROOT/.cto/projects.yaml"
cd "$ROOT" || { echo "ERROR: cannot enter $ROOT" >&2; exit 1; }
# <<< CTO-HOME ANCHOR <<<
if [ ! -f "$CTO_REGISTRY" ]; then
  echo "ERROR: fleet registry not found at $CTO_REGISTRY"
  echo "  This skill must run from the CTO home (the repo holding .cto/projects.yaml)."
  echo "  If you are in a project repo, the session project dir is wrong — reopen in the CTO home."
  exit 1
fi
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

# Capture the skill arguments via a single-quoted heredoc so the message body
# may contain ANY character — double-quotes, $, backticks — without breaking
# shell parsing. A bare ARGS="$ARGUMENTS" breaks the moment the message has a ".
ARGS=$(cat <<'__CTO_SEND_ARGUMENTS_EOF__'
$ARGUMENTS
__CTO_SEND_ARGUMENTS_EOF__
)
REPO_NAME=""
MESSAGE=""

# First token is repo name; everything after is the message
read -r REPO_NAME MESSAGE <<< "$ARGS"

if [ -z "$REPO_NAME" ] || [ -z "$MESSAGE" ]; then
  echo "Usage: /send <repo-name> <message>"
  echo "       /send <window-id>  <message>      # id-direct, see below"
  echo "Example: /send acme-service-a please switch to validating PRD-114 first"
  exit 1
fi

# ID-DIRECT ADDRESSING. A repo's terminal-window.id is a SINGLE SLOT that /handoff
# overwrites, so a second sprint against the same repo silently steals the first
# window's address — and some windows (a QA drive, another CTO session) have no repo
# binding at all. A bare numeric first token addresses that window directly, skipping
# registry + slot resolution entirely. `window-peek.sh list` enumerates ids.
case "$REPO_NAME" in
  ''|*[!0-9]*) ID_DIRECT=0 ;;
  *)           ID_DIRECT=1 ;;
esac

if [ "$ID_DIRECT" -eq 1 ]; then
  WIN_ID="$REPO_NAME"
  REPO_NAME="window $WIN_ID"
else
# Resolve repo path. Accepts exact name OR suffix alias ("tuner" -> "acme-service-a").
REPO_PATH=$(python3 - <<PYEOF
import re, sys
with open('$CTO_REGISTRY') as f:
    text = f.read()
arg = "$REPO_NAME"
for b in re.split(r'(?=- name:)', text):
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    if m and m.group(1) == arg and p:
        print(p.group(1)); break
else:
    candidates = []
    for b in re.split(r'(?=- name:)', text):
        m = re.search(r'- name:\s*(\S+)', b)
        p = re.search(r'path:\s*(\S+)', b)
        if not m or not p: continue
        if m.group(1) == f"acme-{arg}" or m.group(1).endswith(f"-{arg}"):
            candidates.append((m.group(1), p.group(1)))
    if len(candidates) == 1: print(candidates[0][1])
    elif len(candidates) > 1: print(f"ERROR: ambiguous alias '{arg}' matches: {[c[0] for c in candidates]}", file=sys.stderr)
PYEOF
)

if [ -z "$REPO_PATH" ]; then
  echo "ERROR: repo '$REPO_NAME' not found in $CTO_REGISTRY (tried exact + suffix-alias match)"
  exit 1
fi

# Resolve through the append-only window registry first: it knows about EVERY window opened
# for this repo and checks each against Terminal, so a repo running two sprints refuses to
# guess instead of silently addressing the newest one. Exit 3 = ambiguous (choices printed).
WIN_ID="$(bash "$ROOT/scripts/cto/window-registry.sh" resolve "$REPO_PATH" 2>/dev/null)"; RRC=$?
if [ "$RRC" -eq 3 ]; then
  bash "$ROOT/scripts/cto/window-registry.sh" resolve "$REPO_PATH"   # re-run for the message
  exit 1
fi
if [ -z "$WIN_ID" ]; then
  WIN_ID_FILE="$REPO_PATH/.claude/terminal-window.id"
  if [ ! -f "$WIN_ID_FILE" ]; then
    echo "ERROR: no live window for $REPO_NAME (no registry entry, no $WIN_ID_FILE)"
    echo "Either the session was not launched via /handoff, or the window has been closed."
    echo "Fix: run  bash scripts/cto/window-peek.sh list  and send id-direct:  /send <window-id> <message>"
    exit 1
  fi
  WIN_ID=$(cat "$WIN_ID_FILE" | tr -d '[:space:]')
  echo "NOTE: no registry entry — falling back to the legacy single slot (window $WIN_ID)." >&2
fi
fi

# Write the message to a temp file — qa-send.sh reads it from there so neither the
# message text nor any osascript braces land on the scanned command line.
MSG_FILE=$(mktemp /tmp/cto-send-msg-XXXXXX)
trap "rm -f '$MSG_FILE'" EXIT
printf '%s' "$MESSAGE" > "$MSG_FILE"

echo "Sending to $REPO_NAME (window id $WIN_ID):"
echo "  $MESSAGE" | head -c 200
echo ""

# DELEGATE to the single keystroke path. This skill used to carry its own copy of the
# osascript, and that copy had no FOCUS GUARD: `set frontmost of window id N to true` can
# fail (-10006 observed live) and the keystroke fired anyway — into whatever app was
# focused. A downstream incident had an orchestration message land in the operator's
# personal messaging app that way. qa-send.sh verifies Terminal is frontmost AND its front
# window is the target id before typing a single character, and aborts sending NOTHING
# otherwise. Do not reinstate an inline osascript here.
# --verify-submit + --repo: check the message was SUBMITTED (the trailing Return is absorbed
# as a newline when the target is mid-task) and then that it was actually PROCESSED. Box-
# cleared is not proof: on 2026-08-13 a ruling submitted into the queue was dropped at turn
# end — box clear, "SUBMITTED" reported, nothing read. --repo lets qa-send check the session
# transcript on disk, which is the only signal that separates "read" from "queued and lost".
VERIFY_ARGS=""
[ "$ID_DIRECT" -eq 0 ] && [ -n "${REPO_PATH:-}" ] && VERIFY_ARGS="--repo $REPO_PATH"
bash "$ROOT/scripts/cto/qa-send.sh" "$WIN_ID" "$MSG_FILE" --verify-submit $VERIFY_ARGS
SEND_RC=$?

echo ""
if [ "$SEND_RC" -eq 6 ]; then
  echo "DELIVERED BUT NOT PROCESSED by $REPO_NAME (window id $WIN_ID)."
  echo "The message left the input box but has not appeared in the session transcript."
  echo "Do NOT report this as delivered: it may be queued behind the current turn, and queued"
  echo "messages have been dropped at turn end before. Re-check with /peek $REPO_NAME, and"
  echo "re-send once the turn ends if it never lands."
  exit "$SEND_RC"
fi
if [ "$SEND_RC" -ne 0 ]; then
  echo "NOT SENT to $REPO_NAME (window id $WIN_ID) — see the FOCUS-GUARD reason above."
  echo "Nothing was typed anywhere. Common causes: the machine is in use by the operator,"
  echo "the window id is stale (run: bash scripts/cto/window-peek.sh list), or Accessibility"
  echo "permission is not granted to Terminal."
  exit "$SEND_RC"
fi
echo "Message delivered to $REPO_NAME (window id $WIN_ID) — see the qa-send verdict above."
echo "Then /peek $REPO_NAME to see the response."
```

## Your task as CTO

The message has been injected into the dev-team session. Tell the CEO:

1. **Confirmation:** "Injected N chars into $REPO_NAME (window id $WIN_ID)." **If the script
   aborted with a FOCUS-GUARD error, say NOTHING WAS SENT** — do not describe the message as
   delivered, and relay the guard's reason (machine in use / stale window id / missing
   Accessibility permission) so the CEO knows what to fix before a retry.
2. **Report the qa-send verdict verbatim, and do not upgrade it.** The script now checks
   three separate things and says which one it got to:
   - `PROCESSED` — it is in the session transcript. This is the only one that means "read".
   - `DELIVERED` — it left the input box, but processing could not be checked (no transcript).
   - `SUBMITTED BUT NOT PROCESSED` (exit 6) — it left the box and never reached the session.
     Queued behind the current turn, and queued messages have been dropped at turn end.
   - `NOT CONFIRMED` (exit 5) / focus abort (exit 4) — it was never submitted / never sent.

   Never describe anything below `PROCESSED` as delivered-and-read.
3. **Next step:** once submitted, `/peek $REPO_NAME` to see the response (id-direct sends have no repo to peek — use `bash scripts/cto/window-peek.sh <id>` instead).

**What this skill is NOT for.** `/send` carries a message *you wrote* — authorship is yours,
and that is what makes it safe. Text you find already sitting in a dev team's composer is a
different thing: Claude Code's own generated grey suggestion is byte-identical to a human's
unsubmitted draft once a window read strips colour. Never submit it on a watcher signal — show
it to the CEO and let them claim it. See `docs/personas/cto.md` "Directive provenance".

Sign as: — CTO
