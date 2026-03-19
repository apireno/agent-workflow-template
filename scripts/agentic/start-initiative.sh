#!/bin/bash
# start-initiative.sh — Create a feature branch and scaffold initiative folder
# Usage: ./scripts/agentic/start-initiative.sh <init-id> <branch-name> [initiative-name]
#
# Examples:
#   ./scripts/agentic/start-initiative.sh INIT-001 feature/tuner-v2 "Tuner V2 Overhaul"
#   ./scripts/agentic/start-initiative.sh INIT-002 fix/graph-corruption "Graph Corruption Fix"
#   ./scripts/agentic/start-initiative.sh INIT-003 experiment/llm-caching "LLM Response Caching"
#
# What it does:
#   1. Creates a feature branch off main
#   2. Scaffolds docs/initiatives/<init-id>/ with brief template and folders
#   3. Commits the scaffolding
#   4. Prints next steps

set -e

INIT_ID="${1:-}"
BRANCH_NAME="${2:-}"
INIT_NAME="${3:-Untitled Initiative}"

if [ -z "$INIT_ID" ] || [ -z "$BRANCH_NAME" ]; then
    echo "Usage: ./scripts/agentic/start-initiative.sh <init-id> <branch-name> [initiative-name]"
    echo ""
    echo "  init-id:      Initiative identifier (e.g., INIT-001)"
    echo "  branch-name:  Git branch name (e.g., feature/tuner-v2)"
    echo "  initiative-name: Human-readable name (default: 'Untitled Initiative')"
    echo ""
    echo "Examples:"
    echo "  ./scripts/agentic/start-initiative.sh INIT-001 feature/tuner-v2 'Tuner V2 Overhaul'"
    echo "  ./scripts/agentic/start-initiative.sh INIT-002 fix/graph-corruption 'Graph Corruption Fix'"
    exit 1
fi

TODAY=$(date +%Y-%m-%d)
INIT_DIR="docs/initiatives/${INIT_ID}"
TEMPLATE_DIR="docs/initiatives/_templates"

# Ensure we're on main and up to date
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
    echo "WARNING: Currently on branch '$CURRENT_BRANCH', not main."
    echo "Continuing anyway — the new branch will be created from '$CURRENT_BRANCH'."
    echo ""
fi

# Check if branch already exists
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
    echo "ERROR: Branch '$BRANCH_NAME' already exists."
    echo "If this initiative is already started, switch to it with: git checkout $BRANCH_NAME"
    exit 1
fi

# Check if initiative dir already exists
if [ -d "$INIT_DIR" ]; then
    echo "ERROR: Initiative directory '$INIT_DIR' already exists."
    exit 1
fi

echo "Creating initiative: $INIT_NAME ($INIT_ID)"
echo "  Branch: $BRANCH_NAME"
echo "  Directory: $INIT_DIR"
echo ""

# Create the branch
git checkout -b "$BRANCH_NAME"
echo "  Created branch: $BRANCH_NAME"

# Scaffold the initiative directory
mkdir -p "$INIT_DIR/sprints"
mkdir -p "$INIT_DIR/amendments"
mkdir -p "$INIT_DIR/merge-review"

# Copy and customize the initiative brief template
if [ -f "$TEMPLATE_DIR/initiative-brief.md" ]; then
    sed "s/{INITIATIVE_NAME}/$INIT_NAME/g; s/{INIT-XXX}/$INIT_ID/g; s/{YYYY-MM-DD}/$TODAY/g; s|{branch-type}/{slug}|$BRANCH_NAME|g" \
        "$TEMPLATE_DIR/initiative-brief.md" > "$INIT_DIR/initiative-brief.md"
else
    cat > "$INIT_DIR/initiative-brief.md" << EOF
# Initiative: $INIT_NAME

**ID:** $INIT_ID
**Branch:** \`$BRANCH_NAME\`
**Created:** $TODAY
**Status:** Active

## Goal
{Fill in the initiative goal}

## Scope
{Fill in deliverables and exit criteria}
EOF
fi

# Copy merge checklist template
if [ -f "$TEMPLATE_DIR/merge-review/merge-checklist.md" ]; then
    sed "s/{INIT-XXX}/$INIT_ID/g; s/{initiative name}/$INIT_NAME/g; s/{branch-name}/$BRANCH_NAME/g; s/{YYYY-MM-DD}/$TODAY/g" \
        "$TEMPLATE_DIR/merge-review/merge-checklist.md" > "$INIT_DIR/merge-review/merge-checklist.md"
fi

# Stage and commit
git add "$INIT_DIR/"
git commit -m "init($INIT_ID): scaffold initiative — $INIT_NAME

Branch: $BRANCH_NAME
Created initiative directory with brief template, sprint folder,
amendments folder, and merge review folder.
"

echo ""
echo "Done! Initiative scaffolded."
echo ""
echo "Next steps:"
echo ""
echo "  1. Fill in the initiative brief:"
echo "     $INIT_DIR/initiative-brief.md"
echo ""
echo "  2. Have VP Eng or VP Prod review and refine the brief"
echo ""
echo "  3. Get CEO approval on the brief"
echo ""
echo "  4. Start the first sprint:"
echo "     ./scripts/agentic/start-sprint.sh $INIT_ID sprint-01"
echo ""
echo "  When all exit criteria are met:"
echo "     ./scripts/agentic/request-merge.sh $INIT_ID"
