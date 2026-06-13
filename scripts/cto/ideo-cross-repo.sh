#!/bin/bash
# ideo-cross-repo.sh — CTO-level IDEO ideation sprint across multiple repos
#
# Fires the existing ideo-sprint.sh in each target repo in parallel (each repo's
# VP personas generate ideas from their own context), then aggregates all ideas
# into a cross-repo synthesis with merged voting and ranked output.
#
# Phases:
#   Phase 1-4:  Run ideo-sprint.sh independently in each repo (parallel)
#   Phase 5:    Cross-repo merge — CTO synthesizes all phase3 results into one
#               unified, deduplicated, ranked idea pool
#   Phase 6:    Route top ideas to the relevant repo's VP of Product for PRD drafts
#
# Usage:
#   ./scripts/cto/ideo-cross-repo.sh \
#     --goal /path/to/ideation-goal.md \
#     --output-dir /tmp/cto/ideo-YYYYMMDD/ \
#     [--repos project1,project2,...] \
#     [--votes N] \
#     [--timeout 600] \
#     [--dry-run]
#
# If --repos is omitted, reads all active projects from .cto/projects.yaml.
#
# Goal file: same format as ideo-sprint.sh goal files
#   (docs/ideation/_templates/ideation-goal.md)
#   The same goal is sent to ALL repos — write it broadly enough to be relevant
#   across all target teams, or note which repos each constraint applies to.
#
# Output layout:
#   {output-dir}/
#     repos/
#       {project_name}/          — symlink or copy of that repo's ideo output
#         phase1-ideas.md
#         phase2-votes.md
#         phase3-merged-results.md
#         phase4-prds.md
#     phase5-cross-repo-synthesis.md    — merged, deduplicated, ranked ideas
#     phase5-routing.md                 — which ideas route to which repo VP
#     summary.md                        — CTO session summary
#
# Compatible with bash 3.2+ (macOS default). Requires Python 3 for YAML parsing.

set -euo pipefail

# ─── Locate scripts ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IDEO_SCRIPT="${TEMPLATE_ROOT}/scripts/agentic/ideo-sprint.sh"
CTO_CONFIG="${TEMPLATE_ROOT}/.cto/projects.yaml"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

if [ ! -x "$IDEO_SCRIPT" ]; then
    echo "Error: ideo-sprint.sh not found or not executable at: $IDEO_SCRIPT" >&2
    exit 2
fi

# macOS timeout compatibility
if command -v timeout > /dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "Warning: no timeout binary found. On macOS: brew install coreutils" >&2
    TIMEOUT_BIN=""
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
GOAL_FILE=""
OUTPUT_DIR=""
REPOS_ARG=""
VOTES=3
TIMEOUT=600
DRY_RUN=0

# ─── Parse arguments ──────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 --goal FILE --output-dir DIR [--repos p1,p2,...] [--votes N] [--timeout N] [--dry-run]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --goal)       GOAL_FILE="$2";  shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --repos)      REPOS_ARG="$2";  shift 2 ;;
        --votes)      VOTES="$2";      shift 2 ;;
        --timeout)    TIMEOUT="$2";    shift 2 ;;
        --dry-run)    DRY_RUN=1;       shift 1 ;;
        --help|-h)    usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [ -z "$GOAL_FILE" ]; then echo "Error: --goal is required" >&2; exit 2; fi
if [ -z "$OUTPUT_DIR" ]; then echo "Error: --output-dir is required" >&2; exit 2; fi
if [ ! -f "$GOAL_FILE" ]; then echo "Error: goal file not found: $GOAL_FILE" >&2; exit 2; fi

mkdir -p "${OUTPUT_DIR}/repos"

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
SUMMARY_FILE="${OUTPUT_DIR}/summary.md"

# ─── Load project list ────────────────────────────────────────────────────────
# If --repos provided, parse comma-separated names and look up paths.
# Otherwise load all active projects from .cto/projects.yaml.

PROJECT_NAMES=()
PROJECT_PATHS=()

load_from_yaml() {
    if [ ! -f "$CTO_CONFIG" ]; then
        echo "Error: .cto/projects.yaml not found at $CTO_CONFIG" >&2
        echo "Copy .cto/projects.yaml.example to .cto/projects.yaml and fill in your repos." >&2
        exit 2
    fi
    # Parse YAML with Python — extracts name and path for active projects
    python3 - <<PYEOF
import sys
try:
    # Try pyyaml first
    import yaml
    with open('$CTO_CONFIG') as f:
        data = yaml.safe_load(f)
    for p in data.get('projects', []):
        if p.get('active', True):
            print(p['name'] + '\t' + p['path'])
except ImportError:
    # Fallback: simple line-by-line parser for our known YAML format
    # Handles the projects.yaml.example structure
    with open('$CTO_CONFIG') as f:
        lines = f.readlines()
    name = None
    path = None
    active = True
    for line in lines:
        s = line.strip()
        if s.startswith('- name:'):
            if name and path and active:
                print(name + '\t' + path)
            name = s.split(':', 1)[1].strip().strip('"\'')
            path = None
            active = True
        elif s.startswith('path:'):
            path = s.split(':', 1)[1].strip().strip('"\'')
        elif s.startswith('active:'):
            val = s.split(':', 1)[1].strip().lower()
            active = val not in ('false', 'no', '0')
    if name and path and active:
        print(name + '\t' + path)
PYEOF
}

if [ -n "$REPOS_ARG" ]; then
    # Manual list — look up paths from YAML
    IFS=',' read -ra REQUESTED <<< "$REPOS_ARG"
    YAML_DATA=$(load_from_yaml)
    for req in "${REQUESTED[@]}"; do
        req=$(echo "$req" | tr -d ' ')
        matched_path=$(echo "$YAML_DATA" | awk -F'\t' -v name="$req" '$1==name{print $2}')
        if [ -z "$matched_path" ]; then
            echo "Error: project '$req' not found in .cto/projects.yaml" >&2
            exit 2
        fi
        PROJECT_NAMES+=("$req")
        PROJECT_PATHS+=("$matched_path")
    done
else
    while IFS=$'\t' read -r name path; do
        [ -z "$name" ] && continue
        PROJECT_NAMES+=("$name")
        PROJECT_PATHS+=("$path")
    done < <(load_from_yaml)
fi

NUM_PROJECTS=${#PROJECT_NAMES[@]}
if [ "$NUM_PROJECTS" -eq 0 ]; then
    echo "Error: no active projects found." >&2; exit 2
fi

# ─── Write summary header ─────────────────────────────────────────────────────
{
    echo "# CTO Cross-Repo IDEO Session"
    echo ""
    echo "**Started:** ${TIMESTAMP}"
    echo "**Goal:** \`${GOAL_FILE}\`"
    echo "**Repos:** ${NUM_PROJECTS}"
    echo ""
    echo "## Goal"
    echo ""
    cat "$GOAL_FILE"
    echo ""
    echo "---"
    echo ""
    echo "## Repos Included"
    echo ""
    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        echo "- **${PROJECT_NAMES[$i]}** — \`${PROJECT_PATHS[$i]}\`"
    done
    echo ""
} > "$SUMMARY_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN — would fire ideo-sprint.sh in ${NUM_PROJECTS} repos:"
    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        echo "  ${PROJECT_NAMES[$i]}: ${PROJECT_PATHS[$i]}"
    done
    echo "Summary written to: $SUMMARY_FILE"
    exit 0
fi

# ─── Phase 1-4: Run ideo-sprint.sh in each repo in parallel ──────────────────
echo "Firing ideo-sprint.sh in ${NUM_PROJECTS} repo(s) in parallel..."
echo ""

PIDS=()
IDEO_DIRS=()
STATUS_FILES=()

for i in $(seq 0 $((NUM_PROJECTS - 1))); do
    project="${PROJECT_NAMES[$i]}"
    repo="${PROJECT_PATHS[$i]}"

    ideo_out="${OUTPUT_DIR}/repos/${project}"
    mkdir -p "$ideo_out"
    IDEO_DIRS+=("$ideo_out")

    status_file="${OUTPUT_DIR}/repos/${project}-status.txt"
    STATUS_FILES+=("$status_file")

    echo "  ▶ ${project} — starting IDEO sprint..."

    # Fire ideo-sprint.sh in background from that repo's context
    (
        # The ideo-sprint.sh uses REPO_ROOT to resolve personas and engine config
        # We need it to run in the target repo's context
        if cd "$repo" 2>/dev/null; then
            # ideo-sprint.sh is in the template repo — use absolute path
            if [ -n "$TIMEOUT_BIN" ]; then
                "$TIMEOUT_BIN" "$TIMEOUT" \
                    env REPO_ROOT="$repo" \
                    "$IDEO_SCRIPT" "$GOAL_FILE" "$ideo_out" --votes "$VOTES" \
                    > "${ideo_out}/ideo-sprint.log" 2>&1 \
                    && echo "SUCCESS" > "$status_file" \
                    || echo "ERROR($?)" > "$status_file"
            else
                env REPO_ROOT="$repo" \
                    "$IDEO_SCRIPT" "$GOAL_FILE" "$ideo_out" --votes "$VOTES" \
                    > "${ideo_out}/ideo-sprint.log" 2>&1 \
                    && echo "SUCCESS" > "$status_file" \
                    || echo "ERROR($?)" > "$status_file"
            fi
        else
            echo "ERROR(cd)" > "$status_file"
        fi
    ) &

    PIDS+=($!)
done

echo ""
echo "Waiting for all IDEO sprints to complete... (timeout: ${TIMEOUT}s each)"
echo ""

# Wait for all background jobs
SUCCESS_COUNT=0
FAIL_COUNT=0

for i in $(seq 0 $((NUM_PROJECTS - 1))); do
    project="${PROJECT_NAMES[$i]}"
    pid="${PIDS[$i]}"
    status_file="${STATUS_FILES[$i]}"
    ideo_dir="${IDEO_DIRS[$i]}"

    wait "$pid" 2>/dev/null || true

    status=$(cat "$status_file" 2>/dev/null || echo "UNKNOWN")

    if [ "$status" = "SUCCESS" ]; then
        echo "  ✅ ${project}: complete"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ❌ ${project}: ${status} — check ${ideo_dir}/ideo-sprint.log"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo ""

if [ "$SUCCESS_COUNT" -eq 0 ]; then
    echo "All IDEO sprints failed. Check logs in ${OUTPUT_DIR}/repos/*/ideo-sprint.log"
    exit 2
fi

# ─── Phase 5: Cross-repo synthesis ───────────────────────────────────────────
echo "Phase 5: Cross-repo synthesis across ${SUCCESS_COUNT} completed repo(s)..."
echo ""

SYNTHESIS_FILE="${OUTPUT_DIR}/phase5-cross-repo-synthesis.md"
ROUTING_FILE="${OUTPUT_DIR}/phase5-routing.md"

# Aggregate all phase3 merged results
AGGREGATE_CONTEXT="You are the CTO running a cross-repo IDEO synthesis.

The following VP teams across ${SUCCESS_COUNT} repos independently ran IDEO ideation sprints
on the same goal. Each team produced ideas filtered through their repo's specific context.
Your job is to:

1. Identify **overlapping ideas** — where multiple teams converged on the same concept.
   Consolidate them into one idea, noting which repos validated it.
2. Identify **unique ideas** — concepts proposed by only one team that are still strong.
3. Remove **already-implemented ideas** — anything that appears to be about existing features.
4. **Rank the top 10 cross-repo ideas** by:
   - Vote count across all repos (higher = stronger consensus)
   - Strategic breadth (ideas that benefit multiple repos rank higher)
   - Novelty (ideas not already in any roadmap)
5. For each top idea, note: which repo(s) it came from, vote tally, and whether it
   requires multi-repo coordination or is single-repo.

---

## GOAL

$(cat "$GOAL_FILE")

---

## PER-REPO PHASE 3 RESULTS

"

for i in $(seq 0 $((NUM_PROJECTS - 1))); do
    project="${PROJECT_NAMES[$i]}"
    ideo_dir="${IDEO_DIRS[$i]}"
    status=$(cat "${STATUS_FILES[$i]}" 2>/dev/null || echo "UNKNOWN")
    phase3="${ideo_dir}/phase3-merged-results.md"

    if [ "$status" = "SUCCESS" ] && [ -f "$phase3" ]; then
        AGGREGATE_CONTEXT+="
### ${project}

$(cat "$phase3")

---
"
    else
        AGGREGATE_CONTEXT+="
### ${project}
(IDEO sprint did not complete — skipped)

---
"
    fi
done

AGGREGATE_CONTEXT+="
---

Please produce:

1. **Top 10 Cross-Repo Ideas** — ranked table with columns:
   | Rank | Idea | Origin Repos | Total Votes | Multi-repo? | Notes |
2. **Consolidated idea descriptions** — 2-3 sentences per top idea, synthesized from all descriptions
3. **Overlaps detected** — which repo ideas were consolidated and why
4. **Routing recommendations** — for each top idea, which repo's VP of Product should own the PRD?

End your response with: SYNTHESIS_COMPLETE
"

# Write synthesis prompt to temp file for traceability
SYNTH_PROMPT_FILE="${OUTPUT_DIR}/phase5-synthesis-prompt.md"
echo "$AGGREGATE_CONTEXT" > "$SYNTH_PROMPT_FILE"

# Run synthesis via claude -p in CTO repo context
cd "$TEMPLATE_ROOT"

SYNTH_EXIT=0
if [ -n "$TIMEOUT_BIN" ]; then
    SYNTH_RESPONSE=$(echo "$AGGREGATE_CONTEXT" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "$TIMEOUT_BIN" 300 "$CLAUDE_BIN" -p --max-turns 3 2>&1) || SYNTH_EXIT=$?
else
    SYNTH_RESPONSE=$(echo "$AGGREGATE_CONTEXT" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "$CLAUDE_BIN" -p --max-turns 3 2>&1) || SYNTH_EXIT=$?
fi

{
    echo "# Cross-Repo IDEO Synthesis"
    echo ""
    echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo "**Repos synthesized:** $(IFS=', '; echo "${PROJECT_NAMES[*]}")"
    echo ""
    echo "---"
    echo ""
    echo "$SYNTH_RESPONSE"
} > "$SYNTHESIS_FILE"

if [ $SYNTH_EXIT -ne 0 ]; then
    echo "  ⚠️  Synthesis call returned exit $SYNTH_EXIT — partial results in $SYNTHESIS_FILE"
else
    echo "  ✅ Synthesis complete → $SYNTHESIS_FILE"
fi

# ─── Phase 6: Routing ─────────────────────────────────────────────────────────
# Extract routing recommendations from synthesis and write as actionable plan

{
    echo "# Cross-Repo IDEO — PRD Routing Plan"
    echo ""
    echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "After reviewing the synthesis in \`phase5-cross-repo-synthesis.md\`, route"
    echo "each approved idea to the relevant repo's VP of Product using:"
    echo ""
    echo "\`\`\`bash"
    echo "# Template: route a top idea to the right repo's VP of Product"
    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        project="${PROJECT_NAMES[$i]}"
        repo="${PROJECT_PATHS[$i]}"
        echo ""
        echo "# For ideas routed to ${project}:"
        echo "./scripts/agentic/escalate-to-cto.sh \\"
        echo "  --persona 'CTO' \\"
        echo "  --issue 'Approved IDEO idea for VP Product to draft PRD: [IDEA TITLE]' \\"
        echo "  --context ${OUTPUT_DIR}/phase5-cross-repo-synthesis.md"
        echo "# OR: open ${repo} and ask VP of Product directly"
    done
    echo "\`\`\`"
    echo ""
    echo "---"
    echo ""
    echo "## Routing extracted from synthesis"
    echo ""
    echo "(CTO: fill in routing assignments after reviewing phase5-cross-repo-synthesis.md)"
    echo ""
    echo "| Idea | Owner Repo | VP of Product Action |"
    echo "|------|-----------|---------------------|"
    echo "| [idea 1] | [project name] | Draft PRD using prd-template.md |"
    echo "| [idea 2] | [project name] | Draft PRD using prd-template.md |"
} > "$ROUTING_FILE"

echo "  ✅ Routing plan → $ROUTING_FILE"
echo ""

# ─── Write final summary ──────────────────────────────────────────────────────
COMPLETED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

{
    echo "---"
    echo ""
    echo "## Results"
    echo ""
    echo "**Completed:** ${COMPLETED_AT}"
    echo ""
    echo "| Repo | Status | Phase3 Results |"
    echo "|------|--------|----------------|"
    for i in $(seq 0 $((NUM_PROJECTS - 1))); do
        project="${PROJECT_NAMES[$i]}"
        ideo_dir="${IDEO_DIRS[$i]}"
        status=$(cat "${STATUS_FILES[$i]}" 2>/dev/null || echo "UNKNOWN")
        phase3="${ideo_dir}/phase3-merged-results.md"
        icon="✅"
        [ "$status" != "SUCCESS" ] && icon="❌"
        echo "| ${project} | ${icon} ${status} | \`${phase3}\` |"
    done
    echo ""
    echo "## Output Files"
    echo ""
    echo "- **Per-repo results:** \`${OUTPUT_DIR}/repos/{project}/\`"
    echo "- **Cross-repo synthesis:** \`${SYNTHESIS_FILE}\`"
    echo "- **PRD routing plan:** \`${ROUTING_FILE}\`"
    echo ""
    echo "## CTO Next Steps"
    echo ""
    echo "1. Read \`phase5-cross-repo-synthesis.md\` — top 10 ideas ranked across all repos"
    echo "2. Present to CEO: \"Here are the top cross-repo ideas from the IDEO session...\""
    echo "3. For each CEO-approved idea: route to the appropriate repo's VP of Product"
    echo "   using \`phase5-routing.md\` as a guide"
    echo "4. Approved PRDs should be committed to \`docs/roadmap/prds/\` in the relevant repo"
} >> "$SUMMARY_FILE"

echo "Session complete."
echo ""
echo "  📄 Summary:    $SUMMARY_FILE"
echo "  🏆 Synthesis:  $SYNTHESIS_FILE"
echo "  📬 Routing:    $ROUTING_FILE"
echo ""

# Exit 0 if all succeeded, 1 if mixed
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
