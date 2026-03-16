#!/bin/bash
# vp-review.sh — Automated VP review via Gemini CLI
#
# Assembles a prompt from a persona definition + concerns file + artifact,
# pipes it to the Gemini CLI, and writes the response to an output file.
#
# Usage:
#   ./scripts/vp-review.sh <persona> <input-file> <output-file>
#
# Examples:
#   ./scripts/vp-review.sh vp-eng docs/sprints/sprint-01/sprint-plan.md docs/sprints/sprint-01/vp-eng-review.md
#   ./scripts/vp-review.sh vp-prod docs/sprints/sprint-01/sprint-plan.md docs/sprints/sprint-01/product-review.md
#   ./scripts/vp-review.sh vp-security docs/sprints/sprint-01/sprint-plan.md docs/sprints/sprint-01/security-review.md
#   ./scripts/vp-review.sh vp-compliance docs/sprints/sprint-01/sprint-plan.md docs/sprints/sprint-01/compliance-review.md
#   ./scripts/vp-review.sh vp-devops docs/sprints/sprint-01/sprint-plan.md docs/sprints/sprint-01/infra-review.md
#
# The script resolves persona files relative to the repo root.
# Run from the repo root or set REPO_ROOT.

set -euo pipefail

# --- Configuration ---
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GEMINI_CMD="${GEMINI_CMD:-gemini}"

# --- Persona mapping ---
declare -A PERSONA_FILES=(
    [vp-eng]="docs/personas/vp-engineering.md"
    [vp-prod]="docs/personas/vp-product.md"
    [vp-security]="docs/personas/vp-security.md"
    [vp-compliance]="docs/personas/vp-compliance.md"
    [vp-devops]="docs/personas/vp-devops.md"
)

declare -A CONCERNS_FILES=(
    [vp-eng]=""
    [vp-prod]=""
    [vp-security]="docs/personas/concerns/security.md"
    [vp-compliance]="docs/personas/concerns/compliance.md"
    [vp-devops]="docs/personas/concerns/devops.md"
)

declare -A CONTEXT_FILES=(
    [vp-eng]="docs/personas/context/vp-eng-context.md"
    [vp-prod]="docs/personas/context/vp-product-context.md"
    [vp-security]=""
    [vp-compliance]=""
    [vp-devops]=""
)

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
=== END CRITICAL INSTRUCTIONS ===
"

# --- Argument parsing ---
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <persona> <input-file> <output-file>"
    echo ""
    echo "Available personas: ${!PERSONA_FILES[*]}"
    exit 1
fi

PERSONA="$1"
INPUT_FILE="$2"
OUTPUT_FILE="$3"

# Validate persona
if [[ -z "${PERSONA_FILES[$PERSONA]+x}" ]]; then
    echo "Error: Unknown persona '$PERSONA'"
    echo "Available personas: ${!PERSONA_FILES[*]}"
    exit 1
fi

# Resolve paths
PERSONA_FILE="$REPO_ROOT/${PERSONA_FILES[$PERSONA]}"
CONCERNS_FILE=""
CONTEXT_FILE=""

if [[ -n "${CONCERNS_FILES[$PERSONA]}" ]]; then
    CONCERNS_FILE="$REPO_ROOT/${CONCERNS_FILES[$PERSONA]}"
fi

if [[ -n "${CONTEXT_FILES[$PERSONA]}" ]]; then
    CONTEXT_FILE="$REPO_ROOT/${CONTEXT_FILES[$PERSONA]}"
fi

# Validate files exist
if [[ ! -f "$PERSONA_FILE" ]]; then
    echo "Error: Persona file not found: $PERSONA_FILE"
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: Input file not found: $INPUT_FILE"
    exit 1
fi

# --- Assemble the prompt ---
PROMPT="You are adopting the following persona for this review. Read it carefully and fully embody this role.

=== PERSONA DEFINITION ===
$(cat "$PERSONA_FILE")
=== END PERSONA DEFINITION ===
"

# Add concerns file if it exists
if [[ -n "$CONCERNS_FILE" && -f "$CONCERNS_FILE" ]]; then
    PROMPT+="

=== PROJECT CONCERNS ===
$(cat "$CONCERNS_FILE")
=== END PROJECT CONCERNS ===
"
fi

# Add context file if it exists
if [[ -n "$CONTEXT_FILE" && -f "$CONTEXT_FILE" ]]; then
    PROMPT+="

=== PROJECT CONTEXT ===
$(cat "$CONTEXT_FILE")
=== END PROJECT CONTEXT ===
"
fi

# Also include the protocol for context on artifact formats
PROTOCOL_FILE="$REPO_ROOT/docs/personas/PROTOCOL.md"
if [[ -f "$PROTOCOL_FILE" ]]; then
    PROMPT+="

=== COMMUNICATION PROTOCOL ===
$(cat "$PROTOCOL_FILE")
=== END COMMUNICATION PROTOCOL ===
"
fi

# Add the artifact to review
PROMPT+="

=== ARTIFACT TO REVIEW ===
File: $INPUT_FILE

$(cat "$INPUT_FILE")
=== END ARTIFACT ===

Please review the above artifact according to your persona definition, using the appropriate output template. Write your review as a complete markdown document.
$ANTI_JAILBREAK"

# --- Create output directory if needed ---
mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Call Gemini CLI ---
echo "Requesting $PERSONA review of $(basename "$INPUT_FILE")..."
echo "$PROMPT" | "$GEMINI_CMD" > "$OUTPUT_FILE" 2>/dev/null

# --- Verify output ---
if [[ -s "$OUTPUT_FILE" ]]; then
    echo "Review written to: $OUTPUT_FILE"
    echo "$(wc -l < "$OUTPUT_FILE") lines"
else
    echo "Warning: Output file is empty. Gemini may have failed."
    rm -f "$OUTPUT_FILE"
    exit 1
fi
