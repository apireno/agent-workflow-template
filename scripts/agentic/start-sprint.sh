#!/bin/bash
# start-sprint.sh — Scaffold a sprint folder within an initiative
# Usage: ./scripts/agentic/start-sprint.sh <init-id> <sprint-id>
#
# Examples:
#   ./scripts/agentic/start-sprint.sh INIT-001 sprint-01
#   ./scripts/agentic/start-sprint.sh INIT-001 sprint-02
#
# What it does:
#   1. Verifies you're on the initiative's branch (not main)
#   2. Verifies the initiative brief exists
#   3. Creates the sprint folder with template copies
#   4. Prints the sprint workflow reminder

set -e

INIT_ID="${1:-}"
SPRINT_ID="${2:-}"

if [ -z "$INIT_ID" ] || [ -z "$SPRINT_ID" ]; then
    echo "Usage: ./scripts/agentic/start-sprint.sh <init-id> <sprint-id>"
    echo ""
    echo "  init-id:    Initiative identifier (e.g., INIT-001)"
    echo "  sprint-id:  Sprint identifier (e.g., sprint-01)"
    echo ""
    echo "Example:"
    echo "  ./scripts/agentic/start-sprint.sh INIT-001 sprint-01"
    exit 1
fi

INIT_DIR="docs/initiatives/${INIT_ID}"
SPRINT_DIR="${INIT_DIR}/sprints/${SPRINT_ID}"
TEMPLATE_DIR="docs/sprints/_templates"
CURRENT_BRANCH=$(git branch --show-current)

# Safety checks
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
    echo "ERROR: You are on '$CURRENT_BRANCH'. Sprints must run on a feature branch."
    echo "Switch to the initiative's branch first, or create one with:"
    echo "  ./scripts/agentic/start-initiative.sh $INIT_ID <branch-name>"
    exit 1
fi

if [ ! -f "$INIT_DIR/initiative-brief.md" ]; then
    echo "ERROR: Initiative brief not found at $INIT_DIR/initiative-brief.md"
    echo "Create the initiative first with:"
    echo "  ./scripts/agentic/start-initiative.sh $INIT_ID <branch-name>"
    exit 1
fi

if [ -d "$SPRINT_DIR" ]; then
    echo "ERROR: Sprint directory already exists: $SPRINT_DIR"
    echo "If resuming this sprint, just cd into the directory and continue."
    exit 1
fi

echo "Starting sprint: $SPRINT_ID (initiative $INIT_ID)"
echo "  Branch: $CURRENT_BRANCH"
echo "  Directory: $SPRINT_DIR"
echo ""

# Create sprint directory
mkdir -p "$SPRINT_DIR"

# Copy relevant templates if they exist
for template in scope.md sprint-plan.md dev-report.md; do
    if [ -f "$TEMPLATE_DIR/$template" ]; then
        sed "s/sprint-XX/$SPRINT_ID/g" "$TEMPLATE_DIR/$template" > "$SPRINT_DIR/$template.template"
    fi
done

# Create a sprint-scope.md stub that references the initiative brief
cat > "$SPRINT_DIR/scope.md" << EOF
# $SPRINT_ID Scope

**Initiative:** $INIT_ID
**Branch:** \`$CURRENT_BRANCH\`
**Initiative Brief:** \`$INIT_DIR/initiative-brief.md\`

---

## Sprint Goal
{What specific items from the initiative brief does this sprint address?}

## Deliverables from Initiative Brief

{Reference specific In Scope items from the initiative brief:}

1. [ ] {Initiative item X — acceptance criterion}
2. [ ] {Initiative item Y — acceptance criterion}

## Out of Scope This Sprint
{Items from the initiative that are deferred to later sprints}

## Open Questions
{Anything the dev team needs clarified before planning}
EOF

echo "  Created sprint directory with scope template"
echo ""
echo "Sprint $SPRINT_ID is ready. Follow the workflow in CLAUDE.md:"
echo ""
echo "  Phase 1 — Planning:"
echo "    1. Read the initiative brief: $INIT_DIR/initiative-brief.md"
echo "    2. Read the sprint scope: $SPRINT_DIR/scope.md"
echo "    3. Write sprint plan: $SPRINT_DIR/sprint-plan.md"
echo "    4. Run VP reviews:"
echo "       ./scripts/agentic/vp-review.sh vp-prod $SPRINT_DIR/sprint-plan.md $SPRINT_DIR/product-review.md"
echo "       ./scripts/agentic/vp-review.sh vp-eng $SPRINT_DIR/sprint-plan.md $SPRINT_DIR/vp-eng-review.md"
echo "    5. Present to CEO for approval"
echo ""
echo "  Phase 2 — Execution (after CEO approval)"
echo "  Phase 3 — Evaluation (VP reviews on dev report)"
echo ""
echo "  See CLAUDE.md for the full mandatory sequence."
