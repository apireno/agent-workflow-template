---
name: handoff
description: Phase 2 execution launcher. Writes per-repo mission briefs to each target repo's docs/sprints/<sprint>/brief.md and opens a Terminal tab per repo running claude interactively; the kickoff prompt tells each session to read its brief. Use when the CEO approves a sprint plan and wants to fan out dev work across repos.
allowed-tools: Bash(*) Read Write
argument-hint: <sprint-XX> [--repos repo1,repo2] [--dry-run]
---

# Phase 2 Handoff: $ARGUMENTS

Generates mission briefs and launches per-repo dev-team sessions.

## Generate briefs + dispatch

```!
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || { echo "ERROR: not in a repo"; exit 1; }

# zsh doesn't word-split unquoted parameter expansion by default. Skills run
# in whatever shell the harness uses (zsh on macOS). This makes `for tok in $ARGS`
# behave consistently in both bash and zsh.
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

ARGS="$ARGUMENTS"
SPRINT=""
REPOS_FILTER=""
DRY_RUN=0

for tok in $ARGS; do
  case "$tok" in
    --repos=*)   REPOS_FILTER="${tok#--repos=}" ;;
    --dry-run)   DRY_RUN=1 ;;
    --*)         echo "Unknown flag: $tok" >&2 ;;
    *)           [ -z "$SPRINT" ] && SPRINT="$tok" ;;
  esac
done

if [ -z "$SPRINT" ]; then
  echo "Usage: /handoff <sprint-XX> [--repos r1,r2] [--dry-run]"
  exit 1
fi

# Normalize: the CEO types the slug either as `sprint-foo-20260101` (with prefix)
# or `foo-20260101` (bare). Strip the `sprint-` prefix once here so every
# downstream use of $SPRINT is the BARE slug — then `sprint-$SPRINT` is always
# correct. Bug fix for the doubled-`sprint-` prefix in the mission-brief paths
# observed across every sprint of session 2026-05-22/24 (handoff, corpus-gen,
# corpus-curate, llm-validation, model-selection).
SPRINT="${SPRINT#sprint-}"

# Resolve target repos
TARGETS=$(python3 - <<PYEOF
import re
with open('.cto/projects.yaml') as f:
    text = f.read()
filter_set = set("$REPOS_FILTER".split(',')) if "$REPOS_FILTER" else None
for b in re.split(r'(?=- name:)', text):
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    a = re.search(r'active:\s*(\S+)', b)
    if not m or not p:
        continue
    is_active = (a is None) or a.group(1).lower() not in ('false','no','0')
    if not is_active:
        continue
    if filter_set and m.group(1) not in filter_set:
        continue
    # NOTE: str.lstrip() takes a CHARSET, not a prefix. Use removeprefix (Python 3.9+).
    _sprint = '$SPRINT'.removeprefix('sprint-') if '$SPRINT'.startswith('sprint-') else '$SPRINT'
    sprint_dir = f"{p.group(1)}/docs/sprints/sprint-{_sprint}"
    plan = f"{sprint_dir}/sprint-plan.md"
    import os
    if os.path.isfile(plan):
        print(f"{m.group(1)}\t{p.group(1)}\t{plan}")
PYEOF
)

if [ -z "$TARGETS" ]; then
  echo "ERROR: no target repos found with a sprint-plan.md at sprint-$SPRINT"
  exit 1
fi

NUM=$(echo "$TARGETS" | wc -l | tr -d ' ')
echo "Target repos with sprint-plan.md present: $NUM"
# Display the target list with a bash read-loop, NOT awk with $1/$3 — the skill
# harness substitutes $1/$3 as positional-arg placeholders, which clobbers awk
# field references and produces a syntax error.
echo "$TARGETS" | while IFS=$'\t' read -r d_name d_path d_plan; do
  printf "  %-32s -> %s\n" "$d_name" "$d_plan"
done
echo ""

# Build mission brief per repo and drop into docs/sprints/<sprint>/brief.md
# docs/, NOT .claude/ — writes to .claude/ are gated as security-sensitive
# (hooks/permissions live there) and prompt even under acceptEdits; docs/ is an
# ordinary reviewable artifact path. (CEO 2026-06-08)
echo "Building mission briefs..."
PATHS_TO_OPEN=""
while IFS=$'\t' read -r REPO_NAME REPO_PATH PLAN_PATH; do
  BRIEF_FILE="$REPO_PATH/docs/sprints/sprint-$SPRINT/brief.md"
  mkdir -p "$REPO_PATH/docs/sprints/sprint-$SPRINT"
  # Clear any stale pending-prompt.md so the SessionStart hook can't auto-paste an
  # old brief; the kickoff prompt points the session at the docs brief explicitly.
  rm -f "$REPO_PATH/.claude/pending-prompt.md"

  cat > "$BRIEF_FILE" <<BRIEFEOF
# Mission Brief — sprint-$SPRINT (Phase 2 execution)

You are the Dev Team for $REPO_NAME. The CTO has approved the sprint plan below.
Implement it. When done, write \`docs/sprints/sprint-$SPRINT/dev-report.md\` and tests.

## Sprint plan

$(cat "$PLAN_PATH")

## Acceptance criteria

- All tasks in the sprint plan complete
- Tests pass (run them; report failures in dev-report.md)
- dev-report.md committed to docs/sprints/sprint-$SPRINT/dev-report.md
- demo-output.md if any [AUTO] demo steps exist
- Sign-off: — Dev

## On crash recovery

This session was launched via the CTO's \`/handoff\` skill. If you crash:
- Your session ID is recorded in \`.claude/current-session.id\`
- The CTO can resume you with \`/resume-dev-team $REPO_NAME\`
- A new Terminal tab will open running \`claude --resume <session-id>\`
BRIEFEOF
  echo "  wrote $BRIEF_FILE"
  PATHS_TO_OPEN="$PATHS_TO_OPEN $REPO_PATH"
done <<< "$TARGETS"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "DRY-RUN: briefs dropped. No Terminal tabs opened."
  echo "Inspect the briefs at each repo's docs/sprints/sprint-$SPRINT/brief.md, then re-run without --dry-run."
  exit 0
fi

# Open Terminal tab per repo
#
# Note on the kickoff prompt: the brief lives in docs/sprints/<sprint>/brief.md
# (NOT .claude/ — those writes are gated and prompt even under acceptEdits). We
# pass a kickoff prompt as the positional `prompt` argument to `claude` telling it
# to READ that docs brief and execute — this becomes the first user message and
# triggers immediate execution. The legacy SessionStart auto-paste-brief.sh hook
# (which read .claude/pending-prompt.md) is now vestigial; we rm the stale file
# above so it can't paste an old brief.
KICKOFF="Read docs/sprints/sprint-$SPRINT/brief.md in full as your mission brief, then execute it. you are pre-approved by the CTO and 5 VP personas. do not ask for permission to proceed."

# Short task descriptor for the Terminal tab title: strip the `sprint-` prefix
# and any trailing -YYYYMMDD date.
#   sprint-lexical-primitive-migration-20260520  ->  lexical-primitive-migration
SHORT_DESC=$(echo "$SPRINT" | sed -E 's/^sprint-//; s/-[0-9]{8}$//')

echo ""
echo "Opening Terminal tabs (one per repo) with auto-kickoff..."
for REPO_PATH in $PATHS_TO_OPEN; do
  REPO_NAME=$(basename "$REPO_PATH")
  echo "  -> $REPO_NAME"
  # Terminal tab title: "<repo> · <task>" so the CEO can ID tabs at a glance.
  # Claude Code itself writes the Terminal `custom title` slot with its current-
  # task summary — an external `set custom title` alone gets overwritten within
  # seconds. CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 stops Claude Code touching the
  # title; the `set custom title` below then sticks for the life of the session.
  # The trailing bare `newTab` keeps "tab N of window id NNNN" as the last output
  # line so the window-id parse below still works unchanged.
  TAB_TITLE="$REPO_NAME · $SHORT_DESC"
  TAB_INFO=$(osascript <<APPLESCRIPT 2>&1 | tail -1
tell application "Terminal"
    activate
    set newTab to do script "cd $REPO_PATH && export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 && echo '[handoff] launching claude for $REPO_NAME...' && claude \"$KICKOFF\""
    set custom title of newTab to "$TAB_TITLE"
    newTab
end tell
APPLESCRIPT
)
  echo "      $TAB_INFO"
  # Parse window id from "tab N of window id NNNN" and persist for /send + /close-window
  WIN_ID=$(echo "$TAB_INFO" | grep -oE 'window id [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -n "$WIN_ID" ]; then
    echo "$WIN_ID" > "$REPO_PATH/.claude/terminal-window.id"
    echo "      recorded window id: $WIN_ID -> $REPO_PATH/.claude/terminal-window.id"
  else
    echo "      WARN: could not parse window id from osascript output; /send + /close-window will not work for this repo until manually set"
  fi
done
echo ""
echo "All sessions launched with auto-kickoff prompt."
```

## Your task as CTO

The handoff is fired. Per-repo briefs are at each `<repo>/docs/sprints/sprint-<slug>/brief.md`. Terminal tabs are opening.

Summarize for the CEO:

1. **Headline:** "N repos handed off — Terminal tabs opening"
2. **Per repo:** name + sprint-plan path (or paths from above)
3. **CEO next actions:**
   - Watch the Terminal tabs for the SessionStart hook auto-paste (you should see the brief appear in each session)
   - Use `/peek <repo>` from the CTO session to monitor any specific repo's thinking
   - Use `/sprint-status` for at-a-glance
   - When all repos write `dev-report.md`, run `/sprint-accept <sprint-dir>` per repo
4. **Crash recovery reminder:** if any tab crashes, `/resume-dev-team <repo>` will spin a new tab via `claude --resume`

Sign as: — CTO
