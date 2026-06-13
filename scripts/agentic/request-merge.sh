#!/bin/bash
# request-merge.sh — Run Tier 3 VP reviews and prepare a merge request
# Usage: ./scripts/agentic/request-merge.sh <init-id>
#
# Example:
#   ./scripts/agentic/request-merge.sh INIT-001
#
# What it does:
#   1. Verifies you're on a feature branch (not main)
#   2. Verifies the initiative brief exists and has exit criteria
#   3. Generates a diff summary (main...HEAD)
#   4. Runs ALL five VP reviews (Eng, Prod, Security, Compliance, DevOps)
#   5. Creates/updates the merge checklist
#   6. Prints summary for CEO review
#
# Prerequisites:
#   - At least one LLM CLI installed (Gemini or Claude)
#   - All sprints completed with passing tests
#   - On the initiative's feature branch
#
# Engine selection: same as vp-review.sh — uses REVIEW_ENGINE env var,
# .review-engine file, or auto-detects.

set -e

INIT_ID="${1:-}"

if [ -z "$INIT_ID" ]; then
    echo "Usage: ./scripts/agentic/request-merge.sh <init-id>"
    echo ""
    echo "  init-id:  Initiative identifier (e.g., INIT-001)"
    echo ""
    echo "This runs Tier 3 merge reviews with all five VPs."
    exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
INIT_DIR="docs/initiatives/${INIT_ID}"
MERGE_DIR="${INIT_DIR}/merge-review"
CURRENT_BRANCH=$(git branch --show-current)
TODAY=$(date +%Y-%m-%d)

# --- Engine selection (same logic as vp-review.sh) ---
GEMINI_CMD=""
if command -v gemini > /dev/null 2>&1; then
    GEMINI_CMD="gemini"
elif [ -x "$HOME/.local/bin/gemini" ]; then
    GEMINI_CMD="$HOME/.local/bin/gemini"
elif [ -x "/usr/local/bin/gemini" ]; then
    GEMINI_CMD="/usr/local/bin/gemini"
fi

CLAUDE_CMD=""
if command -v claude > /dev/null 2>&1; then
    CLAUDE_CMD="claude"
fi

resolve_engine() {
    if [ -n "${REVIEW_ENGINE:-}" ]; then
        echo "$REVIEW_ENGINE"
        return
    fi
    if [ -f "$REPO_ROOT/.review-engine" ]; then
        cat "$REPO_ROOT/.review-engine" | tr -d '[:space:]'
        return
    fi
    if [ -n "$GEMINI_CMD" ] && [ -n "$CLAUDE_CMD" ]; then
        echo "dual"
    elif [ -n "$GEMINI_CMD" ]; then
        echo "gemini"
    elif [ -n "$CLAUDE_CMD" ]; then
        echo "claude"
    else
        echo "none"
    fi
}

ENGINE=$(resolve_engine)

if [ "$ENGINE" = "none" ]; then
    echo "ERROR: No LLM CLI found. Install one of:"
    echo "  Gemini CLI: https://github.com/google-gemini/gemini-cli"
    echo "  Claude CLI: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

echo "Engine: $ENGINE"

# Safety checks
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
    echo "ERROR: You are on '$CURRENT_BRANCH'. Switch to the initiative's feature branch."
    exit 1
fi

if [ ! -f "$INIT_DIR/initiative-brief.md" ]; then
    echo "ERROR: Initiative brief not found at $INIT_DIR/initiative-brief.md"
    exit 1
fi

echo "=== Tier 3 Merge Review: $INIT_ID ==="
echo "  Branch: $CURRENT_BRANCH → main"
echo "  Date: $TODAY"
echo ""

# Create merge review directory
mkdir -p "$MERGE_DIR"

# Generate diff summary
echo "Generating diff summary..."
DIFF_STAT=$(git diff main...HEAD --stat 2>/dev/null || echo "(could not generate diff — main branch may not exist locally)")
DIFF_SHORTLOG=$(git log main...HEAD --oneline 2>/dev/null || echo "(could not generate log)")
DIFF_FILES_CHANGED=$(echo "$DIFF_STAT" | tail -1)

cat > "$MERGE_DIR/diff-summary.md" << EOF
# Diff Summary: $CURRENT_BRANCH vs main

**Generated:** $TODAY

## Commits
\`\`\`
$DIFF_SHORTLOG
\`\`\`

## Files Changed
\`\`\`
$DIFF_STAT
\`\`\`
EOF
echo "  Saved diff summary to $MERGE_DIR/diff-summary.md"

# Find the latest sprint's dev report and test results for context
LATEST_SPRINT_DIR=""
for d in "$INIT_DIR"/sprints/sprint-*; do
    if [ -d "$d" ]; then
        LATEST_SPRINT_DIR="$d"
    fi
done

LATEST_DEV_REPORT=""
LATEST_TEST_RESULTS=""
if [ -n "$LATEST_SPRINT_DIR" ]; then
    if [ -f "$LATEST_SPRINT_DIR/dev-report.md" ]; then
        LATEST_DEV_REPORT="$LATEST_SPRINT_DIR/dev-report.md"
    fi
    if [ -f "$LATEST_SPRINT_DIR/test-results.md" ]; then
        LATEST_TEST_RESULTS="$LATEST_SPRINT_DIR/test-results.md"
    fi
fi

# Anti-jailbreak suffix (same as vp-review.sh)
ANTI_JAILBREAK="

---
IMPORTANT: You are a REVIEWER. Your output MUST be a markdown review document ONLY.
FORBIDDEN outputs: source code, config files, scripts, YAML, JSON, shell commands,
Dockerfiles, Terraform, CloudFormation, or any executable content.
If you find yourself writing code, STOP. Write a recommendation instead."

# Function to run a single VP merge review
run_vp_review() {
    local VP_NAME="$1"
    local PERSONA_FILE="$2"
    local CONCERNS_FILE="$3"
    local OUTPUT_FILE="$4"
    local REVIEW_FOCUS="$5"

    echo "  Running $VP_NAME review..."

    PROMPT_FILE=$(mktemp)
    trap "rm -f '$PROMPT_FILE'" EXIT

    cat > "$PROMPT_FILE" << HEADER
You are the $VP_NAME conducting a TIER 3 MERGE REVIEW.

This is a comprehensive review of an entire initiative before it merges to main.
Unlike sprint-level reviews, you are evaluating the CUMULATIVE impact of all changes.

$REVIEW_FOCUS

HEADER

    # Add persona
    if [ -f "$PERSONA_FILE" ]; then
        echo "=== YOUR PERSONA ===" >> "$PROMPT_FILE"
        cat "$PERSONA_FILE" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    # Add concerns
    if [ -f "$CONCERNS_FILE" ]; then
        echo "=== PROJECT CONCERNS ===" >> "$PROMPT_FILE"
        cat "$CONCERNS_FILE" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    # Add protocol
    if [ -f "docs/personas/PROTOCOL.md" ]; then
        echo "=== PROTOCOL ===" >> "$PROMPT_FILE"
        cat "docs/personas/PROTOCOL.md" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    # Add initiative brief
    echo "=== INITIATIVE BRIEF ===" >> "$PROMPT_FILE"
    cat "$INIT_DIR/initiative-brief.md" >> "$PROMPT_FILE"
    echo "" >> "$PROMPT_FILE"

    # Add diff summary
    echo "=== DIFF SUMMARY (all changes in this branch) ===" >> "$PROMPT_FILE"
    cat "$MERGE_DIR/diff-summary.md" >> "$PROMPT_FILE"
    echo "" >> "$PROMPT_FILE"

    # Add latest dev report if available
    if [ -n "$LATEST_DEV_REPORT" ]; then
        echo "=== LATEST DEV REPORT ===" >> "$PROMPT_FILE"
        cat "$LATEST_DEV_REPORT" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    # Add latest test results if available
    if [ -n "$LATEST_TEST_RESULTS" ]; then
        echo "=== LATEST TEST RESULTS ===" >> "$PROMPT_FILE"
        cat "$LATEST_TEST_RESULTS" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    # Add anti-jailbreak
    echo "$ANTI_JAILBREAK" >> "$PROMPT_FILE"

    # Check prompt size
    LINE_COUNT=$(wc -l < "$PROMPT_FILE" | tr -d ' ')
    echo "    Prompt: $LINE_COUNT lines"

    # Run the configured engine
    case "$ENGINE" in
        gemini)
            cat "$PROMPT_FILE" | "$GEMINI_CMD" > "$OUTPUT_FILE" 2>/dev/null
            ;;
        claude)
            cat "$PROMPT_FILE" | "$CLAUDE_CMD" -p --max-turns 1 > "$OUTPUT_FILE" 2>/dev/null
            ;;
        dual)
            # Primary: Gemini
            cat "$PROMPT_FILE" | "$GEMINI_CMD" > "$OUTPUT_FILE" 2>/dev/null
            # Secondary: Claude (parallel file for comparison)
            local CLAUDE_OUT="${OUTPUT_FILE%.md}-claude.md"
            cat "$PROMPT_FILE" | "$CLAUDE_CMD" -p --max-turns 1 > "$CLAUDE_OUT" 2>/dev/null
            ;;
    esac

    if [ -s "$OUTPUT_FILE" ]; then
        OUTPUT_LINES=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
        echo "    Output: $OUTPUT_LINES lines → $OUTPUT_FILE"
    else
        echo "    WARNING: Empty output. Gemini may have failed. Check $OUTPUT_FILE"
    fi

    rm -f "$PROMPT_FILE"
    trap - EXIT
}

echo ""
echo "Running Tier 3 VP reviews..."
echo ""

# VP of Engineering — architecture coherence across all sprints
run_vp_review \
    "VP of Engineering" \
    "docs/personas/vp-engineering.md" \
    "docs/personas/context/vp-eng-context.md" \
    "$MERGE_DIR/eng-review.md" \
    "Focus on: architectural coherence across all sprints, test coverage adequacy, anti-pattern detection, ADR compliance, technical debt introduced, and whether the implementation matches the initiative's technical goals."

# VP of Product — feature acceptance against initiative brief
run_vp_review \
    "VP of Product" \
    "docs/personas/vp-product.md" \
    "docs/personas/context/vp-product-context.md" \
    "$MERGE_DIR/prod-acceptance.md" \
    "Focus on: whether all exit criteria are met, whether the delivered features match the initiative brief's scope, any gaps between what was promised and what was built, and whether the user-facing behavior meets product expectations."

# VP of Security — cumulative security review
run_vp_review \
    "VP of Security" \
    "docs/personas/vp-security.md" \
    "docs/personas/concerns/security.md" \
    "$MERGE_DIR/security-review.md" \
    "Focus on: new attack surface introduced by the cumulative changes, credential/secret handling, data flow changes, new dependencies with known vulnerabilities, API security, input validation, and whether the changes comply with the project's security posture."

# VP of Compliance — cumulative compliance review
run_vp_review \
    "VP of Compliance" \
    "docs/personas/vp-compliance.md" \
    "docs/personas/concerns/compliance.md" \
    "$MERGE_DIR/compliance-review.md" \
    "Focus on: data handling changes (PII, retention, consent), new third-party integrations and their ToS, open-source license compatibility of new dependencies, regulatory implications, and audit trail completeness."

# VP of DevOps — deployment and operational readiness
run_vp_review \
    "VP of DevOps" \
    "docs/personas/vp-devops.md" \
    "docs/personas/concerns/devops.md" \
    "$MERGE_DIR/devops-review.md" \
    "Focus on: CI/CD pipeline compatibility, deployment strategy, new infrastructure requirements, monitoring/alerting gaps, dependency management, environment configuration changes, and operational runbook needs."

echo ""
echo "=== All Tier 3 reviews complete ==="
echo ""

# Verify all review files exist
MISSING=0
for review in eng-review.md prod-acceptance.md security-review.md compliance-review.md devops-review.md; do
    if [ ! -s "$MERGE_DIR/$review" ]; then
        echo "  MISSING or EMPTY: $MERGE_DIR/$review"
        MISSING=$((MISSING + 1))
    else
        echo "  OK: $MERGE_DIR/$review"
    fi
done

echo ""

if [ "$MISSING" -gt 0 ]; then
    echo "WARNING: $MISSING review(s) are missing or empty. Re-run failed reviews before proceeding."
else
    echo "All 5 VP reviews are on disk."
fi

echo ""
echo "Next steps:"
echo ""
echo "  1. Read all review files in $MERGE_DIR/"
echo "  2. Address any BLOCKER items"
echo "  3. Update the merge checklist: $MERGE_DIR/merge-checklist.md"
echo "  4. Present the merge review summary to the CEO"
echo "  5. CEO approves → merge the branch:"
echo "     git checkout main && git merge $CURRENT_BRANCH"
echo ""
echo "  Or open a PR:"
echo "     gh pr create --base main --head $CURRENT_BRANCH --title '$INIT_ID: $INIT_NAME'"
