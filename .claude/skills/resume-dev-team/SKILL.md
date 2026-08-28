---
name: resume-dev-team
description: Recover a crashed per-repo Phase 2 session by reading its current-session.id and spawning a new Terminal tab running `claude --resume <session-id>`. Use when /sprint-status shows CRASHED for a repo or the CEO notices a dead session.
allowed-tools: Bash(*) Read
argument-hint: <repo-name>
---

# Resume Dev Team: $ARGUMENTS

```!
set -uo pipefail
CTO_HOME_REQUIRED=1
# >>> CTO-HOME ANCHOR (canonical — sync with: bash scripts/cto/lint-skills.sh --apply) >>>
# Fleet state lives in the CTO home, and neither obvious anchor is reliable alone:
# `git rev-parse` returns whatever repo the SHELL sits in, so one lingering cd into a dev
# repo silently retargets the skill; and $CLAUDE_PROJECT_DIR was observed EMPTY in skill
# shells (2026-08-13) — /handoff then resolved the registry against kgspin-tuner and refused
# with an error that blamed the registry rather than the anchoring. So: try every anchor,
# VALIDATE each candidate before accepting it, and when none holds either fail naming the
# real cause or fall back explicitly and say so.
# Skills that read the fleet registry set CTO_HOME_REQUIRED=1 before this block.
_CTO_REJECTED=""
_cto_is_home() {
  [ -n "$1" ] && [ -f "$1/.cto/projects.yaml" ] || return 1
  # The PUBLIC template ships a placeholder registry (/Users/yourname/repos/my-project).
  # Accepting it resolves cleanly and then reports a fleet of repos that do not exist —
  # a confident wrong answer, which is worse than the error it replaced. Observed live:
  # four dev repos still point .cto-path at the template, so this is the real path.
  if grep -q '/Users/yourname/' "$1/.cto/projects.yaml" 2>/dev/null; then
    _CTO_REJECTED="$_CTO_REJECTED  $1 (placeholder registry — the unconfigured template)"
    return 1
  fi
  return 0
}
# Sets _CTO_FOUND rather than printing: a $(…) capture runs in a SUBSHELL, so the rejected-
# candidate diagnostics collected by _cto_is_home would be discarded exactly when they are
# needed — on the failure path.
_CTO_FOUND=""
_cto_walk() {
  _d="$1"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    _cto_is_home "$_d" && { _CTO_FOUND="$_d"; return 0; }
    if [ -f "$_d/.cto-path" ]; then
      _p="$(tr -d '[:space:]' < "$_d/.cto-path")"
      _cto_is_home "$_p" && { _CTO_FOUND="$_p"; return 0; }
    fi
    _d="$(dirname "$_d")"
  done
  return 1
}
ROOT=""
for _c in "${CTO_HOME:-}" "${CTO_REPO:-}" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$_c" ] && _cto_is_home "$_c" && { ROOT="$_c"; break; }
done
if [ -z "$ROOT" ]; then if _cto_walk "$PWD"; then ROOT="$_CTO_FOUND"; fi; fi
if [ -z "$ROOT" ] && [ -f "$HOME/.cto/home" ]; then
  _p="$(tr -d '[:space:]' < "$HOME/.cto/home")"; _cto_is_home "$_p" && ROOT="$_p"
fi
if [ -z "$ROOT" ]; then
  if [ "${CTO_HOME_REQUIRED:-0}" = "1" ]; then
    echo "ERROR: no CTO home found — no directory containing .cto/projects.yaml." >&2
    echo "  \$CTO_HOME='${CTO_HOME:-}'  \$CTO_REPO='${CTO_REPO:-}'  \$CLAUDE_PROJECT_DIR='${CLAUDE_PROJECT_DIR:-}'" >&2
    echo "  walked up from: $PWD" >&2
    [ -n "$_CTO_REJECTED" ] && { echo "  rejected candidates:" >&2; printf '%s\n' "$_CTO_REJECTED" >&2; }
    echo "  This is an ANCHORING failure, not a missing registry. Run the skill from the CTO" >&2
    echo "  home, or fix it permanently:  echo /path/to/<project>-cto > ~/.cto/home" >&2
    exit 1
  fi
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "NOTE: no CTO home found; using the current repo ($ROOT)." >&2
fi
CTO_REGISTRY="$ROOT/.cto/projects.yaml"
cd "$ROOT" || { echo "ERROR: cannot enter $ROOT" >&2; exit 1; }
# <<< CTO-HOME ANCHOR <<<
if [ ! -f "$CTO_REGISTRY" ]; then
  echo "ERROR: fleet registry not found at $CTO_REGISTRY — run this from the CTO home."
  exit 1
fi
REPO_NAME="$ARGUMENTS"

if [ -z "$REPO_NAME" ]; then
  echo "Usage: /resume-dev-team <repo-name>"
  exit 1
fi

# Resolve repo path
REPO_PATH=$(python3 - <<PYEOF
import re
with open('$CTO_REGISTRY') as f:
    text = f.read()
for b in re.split(r'(?=- name:)', text):
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    if m and m.group(1) == "$REPO_NAME" and p:
        print(p.group(1))
        break
PYEOF
)

if [ -z "$REPO_PATH" ]; then
  echo "ERROR: repo '$REPO_NAME' not in .cto/projects.yaml"
  exit 1
fi

SESS_ID_FILE="$REPO_PATH/.claude/current-session.id"
if [ ! -f "$SESS_ID_FILE" ]; then
  echo "ERROR: no recorded session ID at $SESS_ID_FILE"
  echo "Either /handoff was never run for this repo, or the SessionStart hook didn't record the ID."
  echo "Recovery option: re-run /handoff <sprint-XX> --repos $REPO_NAME"
  exit 1
fi

SESSION_ID=$(cat "$SESS_ID_FILE" | tr -d '[:space:]')

# Verify the JSONL exists (sanity check before trying to resume)
JSONL=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
if [ -z "$JSONL" ]; then
  echo "ERROR: no JSONL found for session $SESSION_ID"
  echo "Session may have been deleted. Recovery option: re-run /handoff with --repos $REPO_NAME"
  exit 1
fi

echo "Resuming session $SESSION_ID for $REPO_NAME"
echo "JSONL: $JSONL"
echo "Last activity: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$JSONL")"
echo ""

# Open new Terminal tab running claude --resume
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0: no grey composer suggestions in an
# ORCHESTRATED window. Window peeks read plain text with colour stripped, so a
# generated suggestion is byte-identical to a human draft and a watcher can submit
# the session its own advice as if the CEO typed it (2026-08-27). Off at the source.
echo "Opening Terminal tab with claude --resume..."
osascript <<APPLESCRIPT 2>&1 | tail -1
tell application "Terminal"
    activate
    do script "cd $REPO_PATH && export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 && echo '[resume] resuming session $SESSION_ID for $REPO_NAME...' && claude --resume $SESSION_ID"
end tell
APPLESCRIPT

# Clear CRASHED flag if it exists
if [ -f "$REPO_PATH/.claude/CRASHED" ]; then
  rm "$REPO_PATH/.claude/CRASHED"
  echo "Cleared CRASHED flag."
fi
echo ""
echo "Resume tab launched. Watch the new Terminal window for the session to come back online."
```

## Your task as CTO

Confirm to the CEO:

1. **Session resumed** in a new Terminal tab
2. **CRASHED flag cleared** (if it was set)
3. **Recommend:** use `/peek $ARGUMENTS` to verify the resumed session is making progress

If the resume fails (e.g., session ID stale, JSONL missing), surface the error to the CEO and suggest re-running `/handoff` for that specific repo.

Sign as: — CTO
