#!/bin/bash
# orchestrate-sprint.sh — Parallel CTO sprint orchestration across multiple repos
#
# Fires dev team calls in parallel for all assigned repos, waits for all
# responses, and writes a summary report. Does NOT handle Q&A loops or
# VP reviews — those are CTO (Claude Code) responsibilities after reading
# the summary.
#
# Usage:
#   ./scripts/cto/orchestrate-sprint.sh \
#     --assignments /tmp/cto/session/assignments.tsv \
#     --output-dir /tmp/cto/session/responses/ \
#     [--timeout 600] \
#     [--max-turns 50] \
#     [--dry-run]
#
# Assignments TSV format (tab-separated, NO header row, one project per line):
#   project_name<TAB>sprint_number<TAB>/absolute/repo/path<TAB>/path/to/goal.md
#
# Example assignments.tsv:
#   acme-core	05	/path/to/repos/acme-core	/tmp/cto/session/acme-core-goal.md
#   acme-web	03	/path/to/repos/acme-web	/tmp/cto/session/acme-web-goal.md
#
# Output layout (in --output-dir):
#   {project_name}-response.md    — raw dev team response with status trailer
#   {project_name}-status.txt     — one of: SPRINT_PLAN_READY | QUESTIONS_READY | TIMEOUT | ERROR
#   summary.md                    — human-readable summary for the CTO to read
#
# Exit codes:
#   0  All teams: SPRINT_PLAN_READY
#   1  Mixed results (some ready, some questions, some errors)
#   2  All teams failed (timeout or error)
#
# Environment:
#   CLAUDE_BIN  — override path to claude CLI (default: claude)
#   SCRIPT_DIR  — auto-detected; override if needed
#
# Compatible with bash 3.2+ (macOS default).

set -euo pipefail

# ─── Locate scripts directory ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALL_DEV_TEAM="${SCRIPT_DIR}/call-dev-team.sh"

if [ ! -x "$CALL_DEV_TEAM" ]; then
    echo "Error: call-dev-team.sh not found or not executable at: $CALL_DEV_TEAM" >&2
    exit 2
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
ASSIGNMENTS_FILE=""
OUTPUT_DIR=""
TIMEOUT=600
MAX_TURNS=50
DRY_RUN=0
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# ─── Parse arguments ──────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 --assignments FILE --output-dir DIR [--timeout N] [--max-turns N] [--dry-run]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --assignments) ASSIGNMENTS_FILE="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";        shift 2 ;;
        --timeout)     TIMEOUT="$2";            shift 2 ;;
        --max-turns)   MAX_TURNS="$2";          shift 2 ;;
        --dry-run)     DRY_RUN=1;               shift 1 ;;
        --help|-h)     usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# ─── Validate ─────────────────────────────────────────────────────────────────
if [ -z "$ASSIGNMENTS_FILE" ]; then
    echo "Error: --assignments is required" >&2; exit 2
fi
if [ -z "$OUTPUT_DIR" ]; then
    echo "Error: --output-dir is required" >&2; exit 2
fi
if [ ! -f "$ASSIGNMENTS_FILE" ]; then
    echo "Error: assignments file not found: $ASSIGNMENTS_FILE" >&2; exit 2
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
SUMMARY_FILE="${OUTPUT_DIR}/summary.md"

# ─── Parse assignments ────────────────────────────────────────────────────────
# Format: project_name<TAB>sprint_number<TAB>repo_path<TAB>goal_file
# Skip blank lines and comment lines starting with #

PROJECTS=()
SPRINTS=()
REPOS=()
GOALS=()

while IFS=$'\t' read -r project sprint repo goal || [ -n "$project" ]; do
    # Skip blanks and comments
    [ -z "$project" ] && continue
    case "$project" in \#*) continue ;; esac

    if [ -z "$sprint" ] || [ -z "$repo" ] || [ -z "$goal" ]; then
        echo "Warning: malformed assignment line, skipping: $project" >&2
        continue
    fi
    if [ ! -d "$repo" ]; then
        echo "Error: repo path does not exist for $project: $repo" >&2
        exit 2
    fi
    if [ ! -f "$goal" ]; then
        echo "Error: goal file not found for $project: $goal" >&2
        exit 2
    fi

    PROJECTS+=("$project")
    SPRINTS+=("$sprint")
    REPOS+=("$repo")
    GOALS+=("$goal")
done < "$ASSIGNMENTS_FILE"

NUM_PROJECTS=${#PROJECTS[@]}

if [ "$NUM_PROJECTS" -eq 0 ]; then
    echo "Error: no valid assignments found in $ASSIGNMENTS_FILE" >&2
    exit 2
fi

# ─── Write summary header ─────────────────────────────────────────────────────
{
    echo "# CTO Sprint Orchestration Summary"
    echo ""
    echo "**Started:** ${TIMESTAMP}"
    echo "**Projects:** ${NUM_PROJECTS}"
    echo "**Timeout per team:** ${TIMEOUT}s"
    echo "**Max turns per team:** ${MAX_TURNS}"
    echo ""
    echo "---"
    echo ""
    echo "## Assignments Fired"
    echo ""
    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        echo "- **${PROJECTS[$i]}** — Sprint ${SPRINTS[$i]} — \`${REPOS[$i]}\`"
        echo "  Goal: \`${GOALS[$i]}\`"
    done
    echo ""
    echo "---"
    echo ""
} > "$SUMMARY_FILE"

# ─── Dry run mode ────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN — would fire ${NUM_PROJECTS} dev team calls:"
    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        echo "  ${PROJECTS[$i]}: ${REPOS[$i]} (sprint ${SPRINTS[$i]})"
    done
    {
        echo "## DRY RUN — No calls made"
        echo ""
        echo "Pass without --dry-run to execute."
    } >> "$SUMMARY_FILE"
    echo "Summary written to: $SUMMARY_FILE"
    exit 0
fi

# ─── Fire dev team calls in parallel ─────────────────────────────────────────
echo "Firing ${NUM_PROJECTS} dev team call(s) in parallel..."
echo ""

# Store PIDs and output files for tracking
PIDS=()
OUTPUT_FILES=()
STATUS_FILES=()
EXIT_CODE_FILES=()

for i in $(seq 0 $((NUM_PROJECTS - 1))); do
    project="${PROJECTS[$i]}"
    sprint="${SPRINTS[$i]}"
    repo="${REPOS[$i]}"
    goal="${GOALS[$i]}"

    out_file="${OUTPUT_DIR}/${project}-response.md"
    status_file="${OUTPUT_DIR}/${project}-status.txt"
    exit_code_file="${OUTPUT_DIR}/${project}-exitcode.txt"

    OUTPUT_FILES+=("$out_file")
    STATUS_FILES+=("$status_file")
    EXIT_CODE_FILES+=("$exit_code_file")

    echo "  ▶ ${project} (sprint ${sprint}) — firing..."

    # Build the goal prompt incorporating sprint number context
    GOAL_WITH_CONTEXT="$(cat <<GOAL_EOF
You are the dev team for the ${project} project. The CTO has assigned you Sprint ${sprint}.

$(cat "$goal")
GOAL_EOF
)"

    # Fire in background, capture exit code to file
    (
        CLAUDE_BIN="$CLAUDE_BIN" \
        "$CALL_DEV_TEAM" \
            --repo "$repo" \
            --prompt "$GOAL_WITH_CONTEXT" \
            --output "$out_file" \
            --timeout "$TIMEOUT" \
            --max-turns "$MAX_TURNS"
        echo $? > "$exit_code_file"
    ) &

    PIDS+=($!)
done

echo ""
echo "Waiting for ${NUM_PROJECTS} dev team(s) to complete..."
echo "(timeout: ${TIMEOUT}s each)"
echo ""

# ─── Wait for all jobs and collect results ────────────────────────────────────
READY_COUNT=0
QUESTIONS_COUNT=0
TIMEOUT_COUNT=0
ERROR_COUNT=0

for i in $(seq 0 $((NUM_PROJECTS - 1))); do
    project="${PROJECTS[$i]}"
    pid="${PIDS[$i]}"
    status_file="${STATUS_FILES[$i]}"
    exit_code_file="${EXIT_CODE_FILES[$i]}"

    # Wait for the background job
    wait "$pid" 2>/dev/null || true

    # Read exit code written by the subshell
    raw_exit=3
    if [ -f "$exit_code_file" ]; then
        raw_exit=$(cat "$exit_code_file" | tr -d '[:space:]')
    fi

    # Translate exit code to status string
    case "$raw_exit" in
        0) status="SPRINT_PLAN_READY"; READY_COUNT=$((READY_COUNT + 1)) ;;
        1) status="QUESTIONS_READY";   QUESTIONS_COUNT=$((QUESTIONS_COUNT + 1)) ;;
        2) status="TIMEOUT";           TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1)) ;;
        *) status="ERROR";             ERROR_COUNT=$((ERROR_COUNT + 1)) ;;
    esac

    echo "$status" > "$status_file"

    echo "  ✓ ${project}: ${status}"
done

echo ""

# ─── Write summary results ────────────────────────────────────────────────────
COMPLETED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

{
    echo "## Results"
    echo ""
    echo "**Completed:** ${COMPLETED_AT}"
    echo ""
    echo "| Project | Sprint | Status | Response File |"
    echo "|---------|--------|--------|---------------|"

    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        project="${PROJECTS[$i]}"
        sprint="${SPRINTS[$i]}"
        status_file="${STATUS_FILES[$i]}"
        out_file="${OUTPUT_FILES[$i]}"
        status=$(cat "$status_file" 2>/dev/null || echo "UNKNOWN")

        # Emoji indicator
        case "$status" in
            SPRINT_PLAN_READY) indicator="✅" ;;
            QUESTIONS_READY)   indicator="❓" ;;
            TIMEOUT)           indicator="⏱️" ;;
            *)                 indicator="❌" ;;
        esac

        echo "| ${project} | ${sprint} | ${indicator} ${status} | \`${out_file}\` |"
    done

    echo ""
    echo "---"
    echo ""
    echo "## Summary Counts"
    echo ""
    echo "- ✅ SPRINT_PLAN_READY: **${READY_COUNT}**"
    echo "- ❓ QUESTIONS_READY: **${QUESTIONS_COUNT}**"
    echo "- ⏱️ TIMEOUT: **${TIMEOUT_COUNT}**"
    echo "- ❌ ERROR: **${ERROR_COUNT}**"
    echo ""
    echo "---"
    echo ""
    echo "## CTO Next Steps"
    echo ""

    if [ "$READY_COUNT" -gt 0 ]; then
        echo "### ✅ SPRINT_PLAN_READY Teams — Run VP Reviews"
        echo ""
        echo "For each SPRINT_PLAN_READY team, run VP reviews on their sprint plan:"
        echo ""
        for i in $(seq 0 $((NUM_PROJECTS - 1))); do
            project="${PROJECTS[$i]}"
            sprint="${SPRINTS[$i]}"
            repo="${REPOS[$i]}"
            status=$(cat "${STATUS_FILES[$i]}" 2>/dev/null || echo "UNKNOWN")
            if [ "$status" = "SPRINT_PLAN_READY" ]; then
                sprint_pad=$(printf "%02d" "$sprint")
                echo "\`\`\`bash"
                echo "# ${project} — Sprint ${sprint_pad}"
                echo "./scripts/agentic/vp-review.sh vp-prod \\"
                echo "  ${repo}/docs/sprints/sprint-${sprint_pad}/sprint-plan.md \\"
                echo "  ${repo}/docs/sprints/sprint-${sprint_pad}/product-review.md"
                echo ""
                echo "./scripts/agentic/vp-review.sh vp-eng \\"
                echo "  ${repo}/docs/sprints/sprint-${sprint_pad}/sprint-plan.md \\"
                echo "  ${repo}/docs/sprints/sprint-${sprint_pad}/vp-eng-review.md"
                echo "\`\`\`"
                echo ""
            fi
        done
    fi

    if [ "$QUESTIONS_COUNT" -gt 0 ]; then
        echo "### ❓ QUESTIONS_READY Teams — Synthesize Answers and Re-Call"
        echo ""
        echo "Read each team's questions from their repo, then re-call with answers:"
        echo ""
        for i in $(seq 0 $((NUM_PROJECTS - 1))); do
            project="${PROJECTS[$i]}"
            sprint="${SPRINTS[$i]}"
            repo="${REPOS[$i]}"
            status=$(cat "${STATUS_FILES[$i]}" 2>/dev/null || echo "UNKNOWN")
            if [ "$status" = "QUESTIONS_READY" ]; then
                sprint_pad=$(printf "%02d" "$sprint")
                out_file="${OUTPUT_FILES[$i]}"
                echo "\`\`\`bash"
                echo "# ${project} — read questions, then re-call"
                echo "cat ${repo}/docs/sprints/sprint-${sprint_pad}/cto-questions.md"
                echo ""
                echo "# After writing answers to /tmp/cto/session/${project}-answers.md:"
                echo "./scripts/cto/call-dev-team.sh \\"
                echo "  --repo ${repo} \\"
                echo "  --prompt \"\$(cat /tmp/cto/session/${project}-answers.md)\" \\"
                echo "  --prior ${out_file} \\"
                echo "  --output ${out_file%.*}-2.md"
                echo "\`\`\`"
                echo ""
            fi
        done
    fi

    if [ "$TIMEOUT_COUNT" -gt 0 ] || [ "$ERROR_COUNT" -gt 0 ]; then
        echo "### ❌ Failed Teams — Investigate"
        echo ""
        for i in $(seq 0 $((NUM_PROJECTS - 1))); do
            project="${PROJECTS[$i]}"
            repo="${REPOS[$i]}"
            status=$(cat "${STATUS_FILES[$i]}" 2>/dev/null || echo "UNKNOWN")
            out_file="${OUTPUT_FILES[$i]}"
            if [ "$status" = "TIMEOUT" ] || [ "$status" = "ERROR" ]; then
                echo "- **${project}** (${status}): check \`${out_file}\` and \`${repo}\` for partial work."
            fi
        done
        echo ""
    fi

} >> "$SUMMARY_FILE"

echo "Summary written to: $SUMMARY_FILE"
echo ""

# ─── Final exit code ──────────────────────────────────────────────────────────
if [ "$READY_COUNT" -eq "$NUM_PROJECTS" ]; then
    exit 0   # All done
elif [ $((TIMEOUT_COUNT + ERROR_COUNT)) -eq "$NUM_PROJECTS" ]; then
    exit 2   # All failed
else
    exit 1   # Mixed results
fi
