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
# Also set date in PROTOCOL.md
if [ -f "docs/personas/PROTOCOL.md" ]; then
    sed -i "s/YYYY-MM-DD/$TODAY/g" "docs/personas/PROTOCOL.md"
fi
echo "  ✓ Set dates to $TODAY"

# Create directory structure
mkdir -p docs/initiatives/_templates/amendments
mkdir -p docs/initiatives/_templates/merge-review
mkdir -p docs/backlog/bugs
mkdir -p docs/backlog/ideas
mkdir -p docs/architecture/decisions
mkdir -p docs/security/threat-models
mkdir -p docs/security/audits
mkdir -p docs/compliance/tos
mkdir -p docs/operations/runbooks
mkdir -p docs/operations/monitoring
echo "  ✓ Created directory structure"

# Make all agentic scripts executable
for script in scripts/agentic/*.sh; do
    if [ -f "$script" ]; then
        chmod +x "$script"
        echo "  ✓ Made $script executable"
    fi
done

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

# Detect available LLM CLIs and set engine
HAS_GEMINI=0
HAS_CLAUDE=0

if command -v gemini &> /dev/null; then
    echo "  ✓ Gemini CLI found"
    HAS_GEMINI=1
else
    echo "  - Gemini CLI not found (optional: https://github.com/google-gemini/gemini-cli)"
fi

if command -v claude &> /dev/null; then
    echo "  ✓ Claude CLI found"
    HAS_CLAUDE=1
else
    echo "  - Claude CLI not found (optional: https://docs.anthropic.com/en/docs/claude-code)"
fi

# Set default engine based on what's available
if [ ! -f .review-engine ]; then
    if [ "$HAS_GEMINI" -eq 1 ] && [ "$HAS_CLAUDE" -eq 1 ]; then
        echo "dual" > .review-engine
        echo "  ✓ Review engine set to 'dual' (both Gemini + Claude)"
    elif [ "$HAS_GEMINI" -eq 1 ]; then
        echo "gemini" > .review-engine
        echo "  ✓ Review engine set to 'gemini'"
    elif [ "$HAS_CLAUDE" -eq 1 ]; then
        echo "claude" > .review-engine
        echo "  ✓ Review engine set to 'claude'"
    else
        echo "  ⚠ No LLM CLI found — install Gemini CLI or Claude CLI for automated VP reviews"
        echo "    Then create .review-engine with: gemini | claude | dual"
    fi
else
    CURRENT_ENGINE=$(cat .review-engine | tr -d '[:space:]')
    echo "  ✓ Review engine already configured: $CURRENT_ENGINE"
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
echo "  6. Start your first initiative:"
echo "     ./scripts/agentic/start-initiative.sh INIT-001 feature/{slug} 'Initiative Name'"
echo ""
echo "  To test the Gemini CLI review loop:"
echo "    echo '# Test Plan' > /tmp/test-plan.md"
echo "    ./scripts/agentic/vp-review.sh vp-eng /tmp/test-plan.md /tmp/test-review.md"
echo "    cat /tmp/test-review.md"
