#!/bin/bash
# Agent Workflow Template — Project Setup
# Usage: ./setup.sh "My Project Name"

set -e

PROJECT_NAME="${1:-My Project}"

echo "Setting up agent workflow for: $PROJECT_NAME"
echo ""

# Update project name in persona files
for f in docs/personas/vp-engineering.md docs/personas/vp-product.md docs/personas/dev-team.md \
         docs/personas/vp-security.md docs/personas/vp-compliance.md docs/personas/vp-devops.md \
         docs/personas/concerns/security.md docs/personas/concerns/compliance.md docs/personas/concerns/devops.md; do
    if [ -f "$f" ]; then
        sed -i "s/{PROJECT_NAME}/$PROJECT_NAME/g" "$f"
        echo "  ✓ Updated $f"
    fi
done

# Set dates
TODAY=$(date +%Y-%m-%d)
for f in docs/personas/*.md docs/personas/concerns/*.md; do
    if [ -f "$f" ]; then
        sed -i "s/YYYY-MM-DD/$TODAY/g" "$f"
    fi
done
echo "  ✓ Set dates to $TODAY"

# Create directory structure
mkdir -p docs/sprints/sprint-01
mkdir -p docs/architecture/decisions
mkdir -p docs/security/threat-models
mkdir -p docs/security/audits
mkdir -p docs/compliance/tos
mkdir -p docs/operations/runbooks
mkdir -p docs/operations/monitoring
echo "  ✓ Created directory structure"

# Make vp-review.sh executable
if [ -f scripts/vp-review.sh ]; then
    chmod +x scripts/vp-review.sh
    echo "  ✓ Made scripts/vp-review.sh executable"
fi

# Create roadmap placeholder
if [ ! -f docs/roadmap/ROADMAP.md ]; then
    mkdir -p docs/roadmap/prds
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

# Check for Gemini CLI
if command -v gemini &> /dev/null; then
    GEMINI_VERSION=$(gemini --version 2>/dev/null || echo "unknown")
    echo "  ✓ Gemini CLI found (v$GEMINI_VERSION)"
else
    echo "  ⚠ Gemini CLI not found — install it for automated VP reviews"
    echo "    See: https://github.com/google-gemini/gemini-cli"
fi

echo ""
echo "Done! Next steps:"
echo ""
echo "  1. Fill in project concerns:"
echo "     - docs/personas/concerns/security.md   (attack surface, data classification)"
echo "     - docs/personas/concerns/compliance.md  (applicable regulations, ToS)"
echo "     - docs/personas/concerns/devops.md      (infrastructure, CI/CD, monitoring)"
echo ""
echo "  2. Customize persona Domain Knowledge sections:"
echo "     - docs/personas/vp-engineering.md"
echo "     - docs/personas/vp-product.md"
echo ""
echo "  3. (Optional) Create private context files (gitignored):"
echo "     - docs/personas/context/vp-eng-context.md"
echo "     - docs/personas/context/vp-product-context.md"
echo ""
echo "  4. Add technical standards to CLAUDE.md"
echo ""
echo "  5. Write your first PRD: docs/roadmap/prds/PRD-001-{slug}.md"
echo ""
echo "  To test the Gemini CLI review loop:"
echo "    echo '# Test Plan' > docs/sprints/sprint-01/sprint-plan.md"
echo "    ./scripts/vp-review.sh vp-eng docs/sprints/sprint-01/sprint-plan.md docs/sprints/sprint-01/vp-eng-review.md"
