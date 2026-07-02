---
name: sprint-fanout
description: Draft per-repo sprint plans via parallel gemini for a given PRD or goal. Each plan lands at the target repo's docs/sprints/sprint-XX/sprint-plan.md path. Use when the CEO wants to start a multi-repo sprint based on a PRD or shared goal, wants to see how the dev teams would scope a piece of work, or says things like "draft plans for X across these repos" or "let's scope work for this PRD". Auto-fire when the CEO references a PRD/goal path and asks for sprint planning. CEO can still type the slash for explicit gating.
allowed-tools: Bash(*) Read Write
argument-hint: <prd-or-goal-path> [--repos repo1,repo2] [--sprint NN] [--dry-run]
---

# Sprint Fanout: $ARGUMENTS

Drafts a sprint-plan.md per active repo by feeding the PRD/goal + per-repo CLAUDE.md to the **configured engine** in parallel. Engine resolved by `scripts/agentic/resolve-review-engine.sh` (`REVIEW_ENGINE` env → `.review-engine` file → default `subagent`). For CLI engines (`gemini`/`kimi`/`claude-p`) the body drafts inline; for `subagent`/`handoff` the body stages per-repo prompts and the CTO drafts them via the Agent tool.

## Setup + dispatch

```!
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || { echo "ERROR: not in a repo"; exit 1; }

# zsh doesn't word-split unquoted parameter expansion by default. Skills run
# in whatever shell the harness uses (zsh on macOS). This makes `for tok in $ARGS`
# behave consistently in both bash and zsh.
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

# Parse arguments
ARGS="$ARGUMENTS"
PRD_PATH=""
REPOS_FILTER=""
SPRINT=""
DRY_RUN=0

for tok in $ARGS; do
  case "$tok" in
    --repos=*)   REPOS_FILTER="${tok#--repos=}" ;;
    --sprint=*)  SPRINT="${tok#--sprint=}" ;;
    --dry-run)   DRY_RUN=1 ;;
    --*)         echo "Unknown flag: $tok" >&2 ;;
    *)           [ -z "$PRD_PATH" ] && PRD_PATH="$tok" ;;
  esac
done

if [ -z "$PRD_PATH" ] || [ ! -f "$PRD_PATH" ]; then
  echo "ERROR: provide a path to a PRD or goal file as the first argument"
  echo "Usage: /sprint-fanout <path> [--repos r1,r2] [--sprint NN] [--dry-run]"
  exit 1
fi

# Resolve sprint number — default to next available across repos, but for v1
# require explicit --sprint if not provided
if [ -z "$SPRINT" ]; then
  SPRINT="XX-TBD"
fi

# Output dir for staging + summary
OUT=/tmp/cto/sprint-fanout-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
echo "Staging dir: $OUT"
echo "PRD/goal: $PRD_PATH"
echo "Sprint: $SPRINT"
echo "Dry-run: $DRY_RUN"
echo ""

# Read active repos
python3 - <<PYEOF > "$OUT/repos.tsv"
import re
with open('.cto/projects.yaml') as f:
    text = f.read()
blocks = re.split(r'(?=- name:)', text)
filter_set = set("$REPOS_FILTER".split(',')) if "$REPOS_FILTER" else None
for b in blocks:
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    a = re.search(r'active:\s*(\S+)', b)
    if not m or not p:
        continue
    name = m.group(1)
    path = p.group(1)
    is_active = (a is None) or a.group(1).lower() not in ('false','no','0')
    if not is_active:
        continue
    if filter_set and name not in filter_set:
        continue
    print(f"{name}\t{path}")
PYEOF

NUM_REPOS=$(wc -l < "$OUT/repos.tsv" | tr -d ' ')
echo "Active target repos: $NUM_REPOS"
cat "$OUT/repos.tsv" | sed 's/^/  /'
echo ""

if [ "$NUM_REPOS" -eq 0 ]; then
  echo "ERROR: no active repos matched"
  exit 1
fi

# Resolve the engine (shared resolver) — configurable per CEO 2026-06-19, not hardcoded gemini.
RESOLVER="$ROOT/scripts/agentic/resolve-review-engine.sh"
ENGINE=$( [ -x "$RESOLVER" ] && "$RESOLVER" || echo subagent ) || true
case "$ENGINE" in claude) ENGINE=claude-p;; dual) ENGINE=gemini;; none|"") ENGINE=subagent;; esac
[ "$ENGINE" = "claude-p-blocked" ] && { echo "ENGINE=claude-p refused (metered; set REVIEW_ALLOW_METERED=1)"; exit 3; }
[ "$ENGINE" = "claude-p" ] && [ "${REVIEW_ALLOW_METERED:-0}" != "1" ] && { echo "ERROR: claude-p is metered; set REVIEW_ALLOW_METERED=1."; exit 1; }
echo "ENGINE=$ENGINE"
echo ""
echo "Staging per-repo prompts$( [ "$ENGINE" = gemini ] || [ "$ENGINE" = claude-p ] && echo ' + firing in parallel' )..."
date
PRD_CONTENT=$(cat "$PRD_PATH")

while IFS=$'\t' read -r REPO_NAME REPO_PATH; do
  REPO_CLAUDE_MD=""
  [ -f "$REPO_PATH/CLAUDE.md" ] && REPO_CLAUDE_MD=$(head -200 "$REPO_PATH/CLAUDE.md")

  PROMPT_FILE="$OUT/${REPO_NAME}-prompt.md"
  cat > "$PROMPT_FILE" <<EOF
You are the Dev Team for the repo: $REPO_NAME at $REPO_PATH.

TASK: Draft a sprint plan for sprint $SPRINT scoped to your repo's portion of the following PRD/goal.

PRD / GOAL:
---
$PRD_CONTENT
---

YOUR REPO'S CLAUDE.md (first 200 lines for context):
---
$REPO_CLAUDE_MD
---

OUTPUT REQUIREMENTS:
- Produce a sprint plan in markdown
- Title: "# Sprint $SPRINT — <one-line summary>"
- Sections: Scope, Tasks (numbered list with file paths + effort estimates), Test Plan, Acceptance Criteria, Dependencies, Risks
- Keep tasks specific to THIS repo only. Do not propose work in other repos.
- If the PRD doesn't apply to this repo, output: "NO_SCOPE_FOR_THIS_REPO" and explain in one line why.
- Do NOT write code in the plan. Plan only.
EOF

  OUT_PLAN="$OUT/${REPO_NAME}-plan.md"
  if [ "$ENGINE" = "gemini" ] || [ "$ENGINE" = "kimi" ] || [ "$ENGINE" = "codex" ] || [ "$ENGINE" = "claude-p" ]; then
    # Stdin-only invocation — every CLI engine reads the prompt on stdin.
    if [ "$ENGINE" = "gemini" ]; then RUNCMD="cat '$PROMPT_FILE' | gemini"
    elif [ "$ENGINE" = "kimi" ]; then RUNCMD="cat '$PROMPT_FILE' | '$ROOT/scripts/agentic/openrouter-chat.sh'"
    elif [ "$ENGINE" = "codex" ]; then RUNCMD="cat '$PROMPT_FILE' | '$ROOT/scripts/agentic/codex-exec.sh'"  # UNTESTED (2026-07-02)
    else RUNCMD="cat '$PROMPT_FILE' | claude -p --max-turns 1"; fi
    echo "  -> firing $ENGINE for $REPO_NAME (timeout 300s)..."
    ( gtimeout 300 sh -c "$RUNCMD" > "$OUT_PLAN" 2> "$OUT/${REPO_NAME}.log" \
        && echo "SUCCESS" > "$OUT/${REPO_NAME}.status" \
        || echo "ERROR($?)" > "$OUT/${REPO_NAME}.status" ) &
  else
    # subagent / handoff: a skill body can't draft via an Agent/window — the CTO does (Your task).
    echo "  -> staged prompt for $REPO_NAME (engine=$ENGINE: CTO drafts via the Agent tool)"
    echo "PENDING" > "$OUT/${REPO_NAME}.status"
  fi
done < "$OUT/repos.tsv"

wait
if [ "$ENGINE" = "gemini" ] || [ "$ENGINE" = "kimi" ] || [ "$ENGINE" = "codex" ] || [ "$ENGINE" = "claude-p" ]; then
  echo "All $ENGINE calls done at $(date)"
else
  echo "DISPATCH=$ENGINE — prompts staged; the CTO drafts each plan via the Agent tool (see Your task)."
fi
echo ""

# Report per-repo result
echo "=== RESULTS ==="
printf "%-32s %-12s %s\n" "REPO" "STATUS" "PLAN PATH"
echo "------------------------------------------------------------------------"
while IFS=$'\t' read -r REPO_NAME REPO_PATH; do
  STATUS=$(cat "$OUT/${REPO_NAME}.status" 2>/dev/null || echo "UNKNOWN")
  PLAN="$OUT/${REPO_NAME}-plan.md"
  SIZE=$(wc -c < "$PLAN" 2>/dev/null || echo "0")
  # The NO_SCOPE_FOR_THIS_REPO sentinel only marks whole-plan-skip if it appears
  # in the FIRST 5 lines (i.e. the gemini response opens with it). Plans that
  # mention it inline as a per-PRD callout ("PRD-011 NO_SCOPE_FOR_THIS_REPO —
  # belongs to other repo") are valid plans, not skips.
  if head -5 "$PLAN" 2>/dev/null | grep -q "NO_SCOPE_FOR_THIS_REPO"; then NO_SCOPE=1; else NO_SCOPE=0; fi
  if [ "$NO_SCOPE" -gt 0 ]; then
    STATUS="SKIPPED"
    NOTE="(no scope for this repo)"
  else
    NOTE="$SIZE bytes"
  fi
  printf "%-32s %-12s %s %s\n" "$REPO_NAME" "$STATUS" "$PLAN" "$NOTE"
done < "$OUT/repos.tsv"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "DRY-RUN: plans staged at $OUT but NOT written to per-repo sprint dirs."
  echo "Review the plans, then re-run without --dry-run to land them."
else
  echo ""
  echo "Writing plans to per-repo sprint dirs..."
  while IFS=$'\t' read -r REPO_NAME REPO_PATH; do
    STATUS=$(cat "$OUT/${REPO_NAME}.status" 2>/dev/null || echo "UNKNOWN")
    [ "$STATUS" != "SUCCESS" ] && continue
    PLAN="$OUT/${REPO_NAME}-plan.md"
    # The NO_SCOPE_FOR_THIS_REPO sentinel only marks whole-plan-skip if it appears
  # in the FIRST 5 lines (i.e. the gemini response opens with it). Plans that
  # mention it inline as a per-PRD callout ("PRD-011 NO_SCOPE_FOR_THIS_REPO —
  # belongs to other repo") are valid plans, not skips.
  if head -5 "$PLAN" 2>/dev/null | grep -q "NO_SCOPE_FOR_THIS_REPO"; then NO_SCOPE=1; else NO_SCOPE=0; fi
    [ "$NO_SCOPE" -gt 0 ] && continue
    DEST_DIR="$REPO_PATH/docs/sprints/sprint-$SPRINT"
    mkdir -p "$DEST_DIR"
    cp "$PLAN" "$DEST_DIR/sprint-plan.md"
    echo "  wrote $DEST_DIR/sprint-plan.md"
  done < "$OUT/repos.tsv"
fi
```

## Your task as CTO

**First check the `ENGINE=` / `DISPATCH=` lines in the script output.**

**If `DISPATCH=subagent` (default) or `handoff`:** the plans were NOT drafted yet — you draft them now. For each `repo=… prompt=… plan=… dest=…` repo, launch one `Task`/Agent call in parallel (single message), instructing it to read the staged prompt file (`$OUT/<repo>-prompt.md`), draft the sprint plan exactly per the prompt's OUTPUT REQUIREMENTS (markdown only, this-repo-only, `NO_SCOPE_FOR_THIS_REPO` if it doesn't apply), and **write it to both `$OUT/<repo>-plan.md` and the dest `…/docs/sprints/sprint-<NN>/sprint-plan.md`** (unless `--dry-run`, then staging only). When all return, proceed to synthesize. (Engine is bright-line clean: in-session Agent = subscription pool.)

**If the CLI engine ran (gemini/kimi/codex/claude-p):** (note: `codex` is ⚠️ untested — sanity-check its output before trusting it the way you would gemini/kimi) plans are already drafted + landed above.

Then, regardless of engine, synthesize:

1. **Headline:** "Drafted N plans, M skipped (no scope), K failed"
2. **For each non-skipped plan:** read it briefly via Read tool, note the top 2-3 tasks and the effort estimate
3. **Cross-repo synthesis:** flag any tasks across repos that seem to duplicate work or that imply an interface contract that wasn't in the PRD
4. **Recommend next step to CEO:**
   - If plans look good: `/vp-review docs/sprints/sprint-NN/sprint-plan.md` per repo, then `/sprint-accept`
   - If plans need revision: identify which repos and what to fix, suggest re-running with refined prompt

Present a tight summary to the CEO. Brief. Sign as: — CTO
