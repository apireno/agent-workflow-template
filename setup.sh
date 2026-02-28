#!/bin/bash
# Agent Workflow Template — Project Setup
# Usage: ./setup.sh "My Project Name"

set -e

PROJECT_NAME="${1:-My Project}"

echo "Setting up agent workflow for: $PROJECT_NAME"
echo ""

# Update project name in persona files
for f in docs/personas/vp-engineering.md docs/personas/vp-product.md docs/personas/dev-team.md; do
    if [ -f "$f" ]; then
        sed -i "s/{PROJECT_NAME}/$PROJECT_NAME/g" "$f"
        echo "  ✓ Updated $f"
    fi
done

# Set dates
TODAY=$(date +%Y-%m-%d)
for f in docs/personas/*.md; do
    if [ -f "$f" ]; then
        sed -i "s/YYYY-MM-DD/$TODAY/g" "$f"
    fi
done
echo "  ✓ Set dates to $TODAY"

# Create first sprint directory
mkdir -p docs/sprints/sprint-01
echo "  ✓ Created docs/sprints/sprint-01/"

# Create roadmap placeholder
if [ ! -f docs/roadmap/ROADMAP.md ]; then
    cat > docs/roadmap/ROADMAP.md << 'ROADMAP'
# Product Roadmap

**Last Updated:** YYYY-MM-DD

## Vision
{What are we building and why?}

## Phases

### Phase 1: Foundation
{Core capabilities}

### Phase 2: Growth
{Expansion features}

### Phase 3: Scale
{Production readiness}

## PRD Index

| PRD | Title | Status | Phase |
|-----|-------|--------|-------|
| PRD-001 | {first feature} | Draft | 1 |
ROADMAP
    sed -i "s/YYYY-MM-DD/$TODAY/g" docs/roadmap/ROADMAP.md
    echo "  ✓ Created docs/roadmap/ROADMAP.md"
fi

echo ""
echo "Done! Next steps:"
echo "  1. Edit docs/personas/vp-engineering.md — fill in the Domain Knowledge and Anti-Pattern Watchlist sections"
echo "  2. Edit docs/personas/vp-product.md — fill in the Domain Knowledge section"
echo "  3. Edit docs/roadmap/ROADMAP.md — define your product vision and phases"
echo "  4. Write your first PRD in docs/roadmap/prds/PRD-001-{slug}.md"
echo ""
echo "To start a sprint:"
echo "  - Antigravity (VP Product): /vp_product_persona Write the scope for Sprint 01"
echo "  - Antigravity (VP Eng):     /vp_engineering_persona Review Sprint 01 scope"
echo "  - Claude Code (Dev Team):   Read docs/personas/dev-team.md and docs/sprints/sprint-01/"
