#!/bin/bash
# call-dev-team.sh — Invoke a dev team (claude -p) in a project repo
#
# Sends a goal prompt to a dev team's Claude Code instance running in the
# context of a specific project repo (reads that repo's own CLAUDE.md).
#
# Completion signals detected in the response:
#   SPRINT_PLAN_READY  — sprint plan is on disk, ready for VP review (Phase 1 done)
#   DEV_REPORT_READY   — implementation done, dev report on disk (Phase 2/EXECUTE done)
#   QUESTIONS_READY    — dev team has questions before proceeding
#
# For Q&A loops: re-call with --prior pointing at the previous response file.
# The prior context is prepended to the new prompt so the dev team has full
# history of what was already asked and answered.
#
# Usage:
#   ./scripts/cto/call-dev-team.sh \
#     --repo /path/to/project-repo \
#     --prompt "$(cat goal.md)" \
#     --output /tmp/cto/project-response.md \
#     [--prior /tmp/cto/prior-response.md] \
#     [--timeout 600] \
#     [--max-turns 50]
#
# Exit codes:
#   0   SPRINT_PLAN_READY   — sprint plan on disk, proceed to VP review
#   0   DEV_REPORT_READY    — implementation done; dev report + branch on disk
#   1   QUESTIONS_READY     — dev team has questions, read output and re-call with answers
#   2   TIMEOUT             — call exceeded --timeout seconds
#   3   ERROR               — claude exited non-zero or produced no completion signal
#
# Environment:
#   CLAUDE_BIN  — override path to claude CLI (default: claude)
#
# Compatible with bash 3.2+ (macOS default).

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
REPO_PATH=""
PROMPT_TEXT=""
OUTPUT_FILE=""
PRIOR_FILE=""
TIMEOUT=600
MAX_TURNS=50
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# ─── Parse arguments ─────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 --repo PATH --prompt TEXT --output FILE [--prior FILE] [--timeout N] [--max-turns N]" >&2
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)      REPO_PATH="$2";   shift 2 ;;
        --prompt)    PROMPT_TEXT="$2"; shift 2 ;;
        --output)    OUTPUT_FILE="$2"; shift 2 ;;
        --prior)     PRIOR_FILE="$2";  shift 2 ;;
        --timeout)   TIMEOUT="$2";     shift 2 ;;
        --max-turns) MAX_TURNS="$2";   shift 2 ;;
        --help|-h)   usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# ─── Validate ─────────────────────────────────────────────────────────────────
if [ -z "$REPO_PATH" ]; then
    echo "Error: --repo is required" >&2; exit 3
fi
if [ -z "$PROMPT_TEXT" ]; then
    echo "Error: --prompt is required" >&2; exit 3
fi
if [ -z "$OUTPUT_FILE" ]; then
    echo "Error: --output is required" >&2; exit 3
fi
if [ ! -d "$REPO_PATH" ]; then
    echo "Error: repo path does not exist: $REPO_PATH" >&2; exit 3
fi
if ! command -v "$CLAUDE_BIN" > /dev/null 2>&1; then
    echo "Error: claude CLI not found. Set CLAUDE_BIN or ensure 'claude' is in PATH." >&2; exit 3
fi

# macOS has no native `timeout`; coreutils ships it as `gtimeout`. Prefer
# whichever is on PATH.
if command -v timeout > /dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "Error: neither 'timeout' nor 'gtimeout' found. On macOS: brew install coreutils." >&2
    exit 3
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

# ─── Build full prompt ────────────────────────────────────────────────────────
# If prior context exists, prepend it so the dev team has the full conversation
# history including any questions already asked and any CTO answers given.
PRIOR_BLOCK=""
if [ -n "$PRIOR_FILE" ] && [ -f "$PRIOR_FILE" ]; then
    PRIOR_BLOCK="$(cat <<'PRIOR_DELIM'
--- PRIOR EXCHANGE (for context — do not repeat this work) ---

PRIOR_DELIM
)$(cat "$PRIOR_FILE")

--- END PRIOR EXCHANGE ---

"
fi

SIGNAL_INSTRUCTIONS="
---
EXECUTION MODE — read carefully:

The goal file you received may be one of two modes. **Check the goal file's
\"Type:\" header AND look for the literal string \"plan APPROVED\" or
\"EXECUTE — no plan-first cycle\":**

  PLAN MODE (default for greenfield work)
    Goal file says \"Type: Plan-first\" or describes scope without prior
    plan/VP-review references. Follow your CLAUDE.md Phase 1 fully:
    write sprint plan, run vp-review.sh for VP-Eng + VP-Prod, address
    BLOCKERs, present plan to CTO. Emit SPRINT_PLAN_READY when done.

  EXECUTE MODE (when CTO has already approved a plan)
    Goal file explicitly says \"plan APPROVED\" / \"EXECUTE — no plan-first
    cycle\" / references prior planning artifacts on disk (sprint-plan.md +
    vp-eng-review.md + product-review.md already exist in the sprint folder).
    SKIP Phase 1 entirely. Read the prior plan + reviews, then go directly
    to Phase 2: implement the plan, run tests, write dev-report.md, run
    Phase 3 vp-review.sh evaluations on the dev report, push the branch.
    Emit DEV_REPORT_READY when the implementation is committed and pushed.
    Do NOT re-author the plan. Do NOT run additional VP review rounds on
    the plan. The CTO has already approved.

COMPLETION SIGNALS — MANDATORY:

After completing your current phase, you MUST emit exactly one of these
tokens on its own line at the very end of your response:

  SPRINT_PLAN_READY
    Phase 1 complete. Sprint plan + VP reviews on disk. Awaiting CTO approval.

  DEV_REPORT_READY
    Phase 2 (EXECUTE) complete. Implementation committed, branch pushed,
    dev-report.md on disk, Phase 3 evaluations complete (or skipped per
    goal-file directive). Use this when CTO authorized EXECUTE directly OR
    after CTO approves a SPRINT_PLAN_READY plan in a follow-up call.

  QUESTIONS_READY
    Use when: you have questions for the CTO that must be answered before
    you can proceed. Write your questions to
    docs/sprints/sprint-XX/cto-questions.md first, then emit this signal.

Do NOT emit a signal until you have completed the work for that phase.
Do NOT emit multiple signals.
Read your CLAUDE.md sprint workflow for the canonical procedure of each phase.
---
"

FULL_PROMPT="${PRIOR_BLOCK}${PROMPT_TEXT}${SIGNAL_INSTRUCTIONS}"

# ─── Invoke claude -p ─────────────────────────────────────────────────────────
REPO_NAME="$(basename "$REPO_PATH")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "# Dev Team Response — ${REPO_NAME}" > "$OUTPUT_FILE"
echo "# Called at: ${TIMESTAMP}" >> "$OUTPUT_FILE"
echo "# Repo: ${REPO_PATH}" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# cd into the repo so claude picks up that repo's CLAUDE.md
cd "$REPO_PATH"

RESPONSE=""
EXIT_CODE=0

RESPONSE=$(echo "$FULL_PROMPT" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    "$TIMEOUT_BIN" "$TIMEOUT" "$CLAUDE_BIN" -p \
    --max-turns "$MAX_TURNS" \
    2>&1) || EXIT_CODE=$?

if [ $EXIT_CODE -eq 124 ]; then
    # timeout(1) returns 124 on timeout
    {
        echo "## STATUS: TIMEOUT"
        echo ""
        echo "Dev team call timed out after ${TIMEOUT}s."
        echo "The repo may still have partial work on disk."
        echo ""
        echo "Partial response captured:"
        echo "$RESPONSE"
    } >> "$OUTPUT_FILE"
    exit 2
fi

if [ $EXIT_CODE -ne 0 ]; then
    {
        echo "## STATUS: ERROR"
        echo ""
        echo "claude -p exited with code ${EXIT_CODE}."
        echo ""
        echo "Output:"
        echo "$RESPONSE"
    } >> "$OUTPUT_FILE"
    exit 3
fi

echo "$RESPONSE" >> "$OUTPUT_FILE"

# ─── Detect completion signal ─────────────────────────────────────────────────
# Check for signal tokens anywhere in the response (dev team may include
# explanatory text before the token).
if echo "$RESPONSE" | grep -qE '^SPRINT_PLAN_READY[[:space:]]*$'; then
    echo "" >> "$OUTPUT_FILE"
    echo "## STATUS: SPRINT_PLAN_READY" >> "$OUTPUT_FILE"
    exit 0
elif echo "$RESPONSE" | grep -qE '^DEV_REPORT_READY[[:space:]]*$'; then
    echo "" >> "$OUTPUT_FILE"
    echo "## STATUS: DEV_REPORT_READY" >> "$OUTPUT_FILE"
    exit 0
elif echo "$RESPONSE" | grep -qE '^QUESTIONS_READY[[:space:]]*$'; then
    echo "" >> "$OUTPUT_FILE"
    echo "## STATUS: QUESTIONS_READY" >> "$OUTPUT_FILE"
    exit 1
else
    # No signal — dev team didn't follow protocol
    {
        echo ""
        echo "## STATUS: ERROR — NO COMPLETION SIGNAL"
        echo ""
        echo "The dev team response did not end with one of the expected signals:"
        echo "  - SPRINT_PLAN_READY  (Phase 1 done)"
        echo "  - DEV_REPORT_READY   (Phase 2/EXECUTE done)"
        echo "  - QUESTIONS_READY    (questions for CTO)"
        echo ""
        echo "This usually means:"
        echo "  - The CLAUDE.md in this repo is missing the completion signal instructions"
        echo "  - The dev team ran out of turns before finishing"
        echo "  - There was an unexpected error mid-task"
        echo ""
        echo "Recommended action: re-call with a reminder prompt, or inspect the repo manually."
    } >> "$OUTPUT_FILE"
    exit 3
fi
