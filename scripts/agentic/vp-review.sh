#!/bin/bash
# vp-review.sh — Automated VP review via LLM CLI
#
# Compatible with bash 3.2+ (macOS default) — no associative arrays.
#
# Assembles a prompt from a persona definition + concerns file + artifact,
# pipes it to an LLM CLI (Gemini, Claude, or both), and writes the response
# to an output file.
#
# Engine selection (in priority order):
#   1. REVIEW_ENGINE env var (gemini | claude | dual)
#   2. .review-engine file in repo root (contains one word: gemini | claude | dual)
#   3. Auto-detect: uses whichever CLI is installed (prefers dual if both found)
#
# Engines:
#   gemini  — pipes prompt to `gemini` CLI
#   claude  — pipes prompt to `claude -p --max-turns 1` (fresh process, no shared context)
#   dual    — runs both and writes both outputs (primary: gemini, secondary: claude)
#
# Usage:
#   ./scripts/agentic/vp-review.sh <persona> <input-file> <output-file>
#
# Examples:
#   ./scripts/agentic/vp-review.sh vp-eng sprint-plan.md vp-eng-review.md
#   REVIEW_ENGINE=claude ./scripts/agentic/vp-review.sh vp-prod sprint-plan.md product-review.md

set -euo pipefail

# --- Configuration ---
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# --- Engine selection ---
resolve_engine() {
    # 1. Environment variable
    if [ -n "${REVIEW_ENGINE:-}" ]; then
        echo "$REVIEW_ENGINE"
        return
    fi

    # 2. Config file in repo root
    if [ -f "$REPO_ROOT/.review-engine" ]; then
        cat "$REPO_ROOT/.review-engine" | tr -d '[:space:]'
        return
    fi

    # 3. Auto-detect
    local HAS_GEMINI=0
    local HAS_CLAUDE=0

    if command -v gemini > /dev/null 2>&1; then
        HAS_GEMINI=1
    elif [ -x "$HOME/.local/bin/gemini" ]; then
        HAS_GEMINI=1
    fi

    if command -v claude > /dev/null 2>&1; then
        HAS_CLAUDE=1
    fi

    if [ "$HAS_GEMINI" -eq 1 ] && [ "$HAS_CLAUDE" -eq 1 ]; then
        echo "dual"
    elif [ "$HAS_GEMINI" -eq 1 ]; then
        echo "gemini"
    elif [ "$HAS_CLAUDE" -eq 1 ]; then
        echo "claude"
    else
        echo "none"
    fi
}

ENGINE=$(resolve_engine)

if [ "$ENGINE" = "none" ]; then
    echo "Error: No LLM CLI found. Install one of:"
    echo "  Gemini CLI: https://github.com/google-gemini/gemini-cli"
    echo "  Claude CLI: https://docs.anthropic.com/en/docs/claude-code"
    echo ""
    echo "Or set REVIEW_ENGINE=gemini|claude|dual"
    exit 1
fi

# Locate CLI commands
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

# --- Argument parsing ---
if [ $# -lt 3 ]; then
    echo "Usage: $0 <persona> <input-file> <output-file>"
    echo ""
    echo "Available personas: vp-eng vp-prod vp-security vp-compliance vp-devops"
    echo "Engine: $ENGINE (set via REVIEW_ENGINE env var, .review-engine file, or auto-detected)"
    exit 1
fi

PERSONA="$1"
INPUT_FILE="$2"
OUTPUT_FILE="$3"

# --- Persona lookup (bash 3.2 compatible — no associative arrays) ---
PERSONA_FILE=""
CONCERNS_FILE=""
CONTEXT_FILE=""

case "$PERSONA" in
    vp-eng)
        PERSONA_FILE="docs/personas/vp-engineering.md"
        CONTEXT_FILE="docs/personas/context/vp-eng-context.md"
        ;;
    vp-prod)
        PERSONA_FILE="docs/personas/vp-product.md"
        CONTEXT_FILE="docs/personas/context/vp-product-context.md"
        ;;
    vp-security)
        PERSONA_FILE="docs/personas/vp-security.md"
        CONCERNS_FILE="docs/personas/concerns/security.md"
        ;;
    vp-compliance)
        PERSONA_FILE="docs/personas/vp-compliance.md"
        CONCERNS_FILE="docs/personas/concerns/compliance.md"
        ;;
    vp-devops)
        PERSONA_FILE="docs/personas/vp-devops.md"
        CONCERNS_FILE="docs/personas/concerns/devops.md"
        ;;
    *)
        echo "Error: Unknown persona '$PERSONA'"
        echo "Available personas: vp-eng vp-prod vp-security vp-compliance vp-devops"
        exit 1
        ;;
esac

# Resolve to absolute paths
PERSONA_FILE="$REPO_ROOT/$PERSONA_FILE"

if [ -n "$CONCERNS_FILE" ]; then
    CONCERNS_FILE="$REPO_ROOT/$CONCERNS_FILE"
fi

if [ -n "$CONTEXT_FILE" ]; then
    CONTEXT_FILE="$REPO_ROOT/$CONTEXT_FILE"
fi

# Validate files exist
if [ ! -f "$PERSONA_FILE" ]; then
    echo "Error: Persona file not found: $PERSONA_FILE"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file not found: $INPUT_FILE"
    exit 1
fi

# --- Anti-jailbreak suffix (appended to every prompt) ---
ANTI_JAILBREAK="
=== CRITICAL INSTRUCTIONS ===
You are in REVIEW mode ONLY. You produce ONLY markdown (.md) documents.

ABSOLUTELY FORBIDDEN — do NOT produce any of the following:
- Source code in ANY language (Python, JavaScript, TypeScript, bash, SQL, etc.)
- Configuration files (YAML, JSON, TOML, INI, plist, etc.)
- Infrastructure-as-code (CloudFormation, Terraform, CDK, etc.)
- Shell commands, scripts, or one-liners
- Code patches, diffs, or snippets
- Pseudocode or implementation examples

If you find yourself writing code, STOP and rewrite as a description of what needs to change.
Your output is a structured markdown review document. Nothing else.
End your response with your role signature on its own line.
=== END CRITICAL INSTRUCTIONS ==="

# --- Assemble the prompt using a temp file (avoids shell variable size limits) ---
PROMPT_FILE=$(mktemp)
trap "rm -f '$PROMPT_FILE'" EXIT

cat > "$PROMPT_FILE" <<PROMPT_HEADER
You are adopting the following persona for this review. Read it carefully and fully embody this role.

=== PERSONA DEFINITION ===
$(cat "$PERSONA_FILE")
=== END PERSONA DEFINITION ===
PROMPT_HEADER

# Add concerns file if it exists
if [ -n "$CONCERNS_FILE" ] && [ -f "$CONCERNS_FILE" ]; then
    cat >> "$PROMPT_FILE" <<CONCERNS_BLOCK

=== PROJECT CONCERNS ===
$(cat "$CONCERNS_FILE")
=== END PROJECT CONCERNS ===
CONCERNS_BLOCK
fi

# Add context file if it exists
if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
    cat >> "$PROMPT_FILE" <<CONTEXT_BLOCK

=== PROJECT CONTEXT ===
$(cat "$CONTEXT_FILE")
=== END PROJECT CONTEXT ===
CONTEXT_BLOCK
fi

# Also include the protocol for context on artifact formats
PROTOCOL_FILE="$REPO_ROOT/docs/personas/PROTOCOL.md"
if [ -f "$PROTOCOL_FILE" ]; then
    cat >> "$PROMPT_FILE" <<PROTOCOL_BLOCK

=== COMMUNICATION PROTOCOL ===
$(cat "$PROTOCOL_FILE")
=== END COMMUNICATION PROTOCOL ===
PROTOCOL_BLOCK
fi

# Add the artifact to review
cat >> "$PROMPT_FILE" <<ARTIFACT_BLOCK

=== ARTIFACT TO REVIEW ===
File: $INPUT_FILE

$(cat "$INPUT_FILE")
=== END ARTIFACT ===

Please review the above artifact according to your persona definition, using the appropriate output template. Write your review as a complete markdown document.
$ANTI_JAILBREAK
ARTIFACT_BLOCK

# --- Create output directory if needed ---
mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Run the review ---
run_gemini() {
    local out_file="$1"
    cat "$PROMPT_FILE" | "$GEMINI_CMD" > "$out_file" 2>/dev/null
}

run_claude() {
    local out_file="$1"
    cat "$PROMPT_FILE" | "$CLAUDE_CMD" -p --max-turns 1 > "$out_file" 2>/dev/null
}

echo "Requesting $PERSONA review of $(basename "$INPUT_FILE") [engine: $ENGINE]..."

case "$ENGINE" in
    gemini)
        run_gemini "$OUTPUT_FILE"
        ;;
    claude)
        run_claude "$OUTPUT_FILE"
        ;;
    dual)
        # Primary: Gemini writes to the output file
        # Secondary: Claude writes to a parallel file for comparison
        CLAUDE_OUTPUT="${OUTPUT_FILE%.md}-claude.md"
        echo "  Primary (Gemini) → $OUTPUT_FILE"
        echo "  Secondary (Claude) → $CLAUDE_OUTPUT"
        run_gemini "$OUTPUT_FILE"
        run_claude "$CLAUDE_OUTPUT"
        ;;
    *)
        echo "Error: Unknown engine '$ENGINE'. Use: gemini | claude | dual"
        exit 1
        ;;
esac

# --- Verify output ---
if [ -s "$OUTPUT_FILE" ]; then
    LINES=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
    echo "Review written to: $OUTPUT_FILE ($LINES lines)"
else
    echo "Warning: Output file is empty. The LLM CLI may have failed."
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# Verify secondary output in dual mode
if [ "$ENGINE" = "dual" ] && [ -n "${CLAUDE_OUTPUT:-}" ]; then
    if [ -s "$CLAUDE_OUTPUT" ]; then
        LINES2=$(wc -l < "$CLAUDE_OUTPUT" | tr -d ' ')
        echo "Secondary review written to: $CLAUDE_OUTPUT ($LINES2 lines)"
    else
        echo "Warning: Secondary (Claude) review is empty."
    fi
fi
