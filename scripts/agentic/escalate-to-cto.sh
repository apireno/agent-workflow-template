#!/bin/bash
# escalate-to-cto.sh — Escalate an issue or question from a project repo to the CTO
#
# DEFAULT (file-drop): writes an escalation memo to the CTO inbox
# (${CTO_INBOX:-$HOME/.cto/inbox}/<project>-<timestamp>.md). The CTO drains it with
# /escalate-drain, rules on it, and writes the response to the path named in the memo.
# No model is called and no `claude -p` is spawned — `claude -p` is the metered
# programmatic path and the fleet does not use it (see docs/personas/cto.md
# "Handling Escalations from Dev Teams (file-drop pattern)").
#
# LEGACY (--sync): fires `claude -p` synchronously into the CTO repo. Deprecated; kept only
# as an explicit opt-in for setups that still want it. It needs the CTO repo location:
#   1. CTO_REPO environment variable
#   2. .cto-path file in this repo's root (one line: absolute path)
#
# Usage:
#   # Minimal — describe the issue inline
#   ./scripts/agentic/escalate-to-cto.sh --issue "Auth token design conflicts with multi-tenant ADR-003"
#
#   # With a sprint (number OR slug) and a context file
#   ./scripts/agentic/escalate-to-cto.sh \
#     --issue "VP Eng review flagged a BLOCKER we can't resolve internally" \
#     --context docs/sprints/sprint-my-feature-20260101/vp-eng-review.md \
#     --sprint my-feature-20260101
#
#   # From a persona, multiple context files
#   ./scripts/agentic/escalate-to-cto.sh \
#     --persona "VP of Engineering" \
#     --issue "Cross-repo data contract conflict on the events schema" \
#     --context docs/architecture/decisions/ADR-007.md \
#     --context docs/sprints/sprint-05/sprint-plan.md
#
# --sprint accepts any sprint identifier: a number (5 → sprint-05) or a slug. The sprint
# directory is resolved as the first existing of docs/sprints/<id>, docs/sprints/sprint-<id>,
# docs/sprints/sprint-<NN> (numeric ids only); if none exists, docs/sprints/sprint-<id>
# (or docs/sprints/<id> when the id already starts with "sprint-"). The sprint is
# auto-detected from a --context path under docs/sprints/<dir>/ when --sprint is omitted.
#
# Output:
#   Memo:     ${CTO_INBOX:-~/.cto/inbox}/<project>-<timestamp>.md
#   Response: <sprint-dir>/cto-escalation-<timestamp>.md, or
#             ${TMPDIR:-/tmp}/cto-escalation-<project>-<timestamp>.md without a sprint
#             (the CTO writes it; read it once /escalate-drain has run)
#
# Exit codes:
#   0  Memo dropped (or, with --sync, response received and written)
#   1  --sync only: CTO repo not configured
#   2  Usage error, or error writing the memo / during the --sync call
#
# Compatible with bash 3.2+ (macOS default).

set -euo pipefail

# ─── Locate repo ──────────────────────────────────────────────────────────────
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
TIMEOUT=300  # --sync only: 5 minutes for a CTO advisory response
INBOX="${CTO_INBOX:-$HOME/.cto/inbox}"

# ─── Defaults ─────────────────────────────────────────────────────────────────
ISSUE=""
PERSONA="Dev Team"
SPRINT=""
CONTEXT_FILES=()
NON_INTERACTIVE=0
SYNC=0

# ─── Parse arguments ──────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 --issue TEXT [--persona TEXT] [--sprint ID] [--context FILE] ... [--sync]" >&2
    echo "" >&2
    echo "  --issue TEXT       Required. The question or issue to escalate." >&2
    echo "  --persona TEXT     Who is escalating (default: Dev Team)" >&2
    echo "  --sprint ID        Sprint number or slug (auto-detected from a docs/sprints/ context path)" >&2
    echo "  --context FILE     File to include as supporting context (repeatable)" >&2
    echo "  --sync             LEGACY: call 'claude -p' in the CTO repo instead of dropping a memo" >&2
    echo "                     (metered programmatic path; not used by the fleet)" >&2
    echo "  --non-interactive  --sync only: exit 1 if the CTO repo is not configured" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)           [ $# -ge 2 ] || usage; ISSUE="$2";            shift 2 ;;
        --persona)         [ $# -ge 2 ] || usage; PERSONA="$2";          shift 2 ;;
        --sprint)          [ $# -ge 2 ] || usage; SPRINT="$2";           shift 2 ;;
        --context)         [ $# -ge 2 ] || usage; CONTEXT_FILES+=("$2"); shift 2 ;;
        --sync)            SYNC=1;            shift 1 ;;
        --non-interactive) NON_INTERACTIVE=1; shift 1 ;;
        --help|-h)         usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [ -z "$ISSUE" ]; then
    echo "Error: --issue is required" >&2; usage
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
PROJECT_NAME="$(basename "$REPO_ROOT")"

# ─── Resolve the sprint directory (any slug; never parsed as a number) ────────
# Auto-detect from a context path: take the directory directly under docs/sprints/.
if [ -z "$SPRINT" ]; then
    for cf in "${CONTEXT_FILES[@]:-}"; do
        [ -n "$cf" ] || continue
        _seg="$(printf '%s\n' "$cf" | sed -n 's#.*docs/sprints/\([^/][^/]*\)/.*#\1#p' | head -1)"
        if [ -n "$_seg" ] && [ "$_seg" != "_templates" ]; then
            SPRINT="$_seg"
            break
        fi
    done
fi

SPRINT_DIR=""
if [ -n "$SPRINT" ]; then
    case "$SPRINT" in
        */*|.|..) echo "Error: --sprint must be a sprint id or slug, not a path: $SPRINT" >&2; exit 2 ;;
    esac
    _base="${REPO_ROOT}/docs/sprints"
    if [ -d "${_base}/${SPRINT}" ]; then
        SPRINT_DIR="${_base}/${SPRINT}"
    elif [ -d "${_base}/sprint-${SPRINT}" ]; then
        SPRINT_DIR="${_base}/sprint-${SPRINT}"
    elif printf '%s' "$SPRINT" | grep -qE '^[0-9]+$'; then
        # Numeric id → zero-padded legacy dir. 10# keeps "08"/"09" from being read as octal.
        SPRINT_DIR="${_base}/sprint-$(printf '%02d' "$((10#$SPRINT))")"
    else
        case "$SPRINT" in
            sprint-*) SPRINT_DIR="${_base}/${SPRINT}" ;;
            *)        SPRINT_DIR="${_base}/sprint-${SPRINT}" ;;
        esac
    fi
    RESPONSE_FILE="${SPRINT_DIR}/cto-escalation-${TIMESTAMP}.md"
else
    RESPONSE_FILE="${TMPDIR:-/tmp}"
    RESPONSE_FILE="${RESPONSE_FILE%/}/cto-escalation-${PROJECT_NAME}-${TIMESTAMP}.md"
fi

# ─── Build escalation body ────────────────────────────────────────────────────
CONTEXT_BLOCK=""
for cf in "${CONTEXT_FILES[@]:-}"; do
    [ -n "$cf" ] || continue
    if [ -f "$cf" ]; then
        CONTEXT_BLOCK+="
### Context: $(basename "$cf")
\`Path: $cf\`

$(cat "$cf")

---
"
    else
        echo "Warning: context file not found, skipping: $cf" >&2
    fi
done

SPRINT_LINE=""
if [ -n "$SPRINT" ]; then
    SPRINT_LINE="**Current Sprint:** ${SPRINT}"
fi

ESCALATION_PROMPT="You are receiving an escalation from one of your dev teams.

**From:** ${PERSONA}
**Project:** ${PROJECT_NAME}
**Repo:** ${REPO_ROOT}
${SPRINT_LINE}
**Escalation timestamp:** ${TIMESTAMP}

---

## Issue

${ISSUE}

---

## Supporting Context
${CONTEXT_BLOCK:-
(No additional context files provided. The issue description above is the full context.)
}

---

## What We Need From You

Please provide:
1. **Your ruling / guidance** — a direct answer or decision if one is needed
2. **Reasoning** — why you're recommending this approach (cross-repo implications, existing ADRs, architectural constraints)
3. **Action items** — specific next steps for the escalating team, with file paths where relevant
4. **Any cross-repo implications** — does this affect other repos? If so, which ones and how?

If you need more context before ruling, state exactly what you need and from which file or team.

Read your CTO persona at docs/personas/cto.md before responding.
"

# ─── DEFAULT: drop a memo in the CTO inbox ────────────────────────────────────
if [ "$SYNC" -eq 0 ]; then
    if ! mkdir -p "$INBOX" 2>/dev/null || [ ! -w "$INBOX" ]; then
        echo "Error: CTO inbox is not writable: $INBOX" >&2
        exit 2
    fi
    # Two escalations in the same second must not overwrite each other: claim the name
    # atomically (noclobber create) before writing. The claimed file is empty for a moment;
    # the drain shows it as an empty memo at worst, never a clobbered one.
    MEMO="${INBOX}/${PROJECT_NAME}-${TIMESTAMP}.md"
    _n=1
    until ( set -C; : > "$MEMO" ) 2>/dev/null; do
        _n=$((_n + 1))
        [ "$_n" -le 100 ] || { echo "Error: could not claim a memo name in $INBOX" >&2; exit 2; }
        MEMO="${INBOX}/${PROJECT_NAME}-${TIMESTAMP}-${_n}.md"
    done
    _tmp="${INBOX}/.${PROJECT_NAME}-${TIMESTAMP}.tmp.$$"
    {
        echo "# Escalation — ${PROJECT_NAME}"
        echo ""
        echo "**From:** ${PERSONA} @ ${PROJECT_NAME}"
        echo "**Repo:** ${REPO_ROOT}"
        [ -n "$SPRINT" ] && echo "**Sprint:** ${SPRINT}"
        echo "**Timestamp:** ${TIMESTAMP}"
        echo "**CTO response should land at:** ${RESPONSE_FILE}"
        echo ""
        echo "---"
        echo ""
        printf '%s\n' "$ESCALATION_PROMPT"
    } > "$_tmp" || { rm -f "$_tmp"; echo "Error: could not write memo: $MEMO" >&2; exit 2; }
    # Atomic rename (the dot-prefixed .tmp name never matches the drain's *.md find, so it never sees a
    # half-written memo).
    mv "$_tmp" "$MEMO"

    echo ""
    echo "Escalation memo dropped in the CTO inbox."
    echo "   Project:  ${PROJECT_NAME}"
    echo "   Issue:    ${ISSUE}"
    [ -n "$SPRINT" ] && echo "   Sprint:   ${SPRINT}"
    echo "   Memo:     ${MEMO}"
    echo "   Response: ${RESPONSE_FILE}  (written by the CTO after /escalate-drain)"
    echo ""
    exit 0
fi

# ─── LEGACY --sync: fire claude -p in the CTO repo ────────────────────────────
echo "Warning: --sync uses 'claude -p' (metered programmatic path). The default file-drop" >&2
echo "         escalation needs no model call; prefer it." >&2

# macOS has no native `timeout`; coreutils ships it as `gtimeout`.
if command -v timeout > /dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "Warning: neither 'timeout' nor 'gtimeout' found. On macOS: brew install coreutils." >&2
    echo "Proceeding without timeout guard." >&2
    TIMEOUT_BIN=""
fi

CTO_REPO="${CTO_REPO:-}"
if [ -z "$CTO_REPO" ] && [ -f "${REPO_ROOT}/.cto-path" ]; then
    CTO_REPO=$(tr -d '[:space:]' < "${REPO_ROOT}/.cto-path")
fi
if [ -z "$CTO_REPO" ]; then
    echo "Error: CTO repo not configured (needed for --sync only)." >&2
    echo "Set CTO_REPO or create ${REPO_ROOT}/.cto-path with the CTO repo's absolute path," >&2
    echo "or drop --sync to use the default inbox memo." >&2
    exit 1
fi
if [ ! -d "$CTO_REPO" ]; then
    echo "Error: CTO repo path does not exist: $CTO_REPO" >&2
    exit 2
fi

OUTPUT_FILE="$RESPONSE_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo ""
echo "Escalating to CTO (--sync)..."
echo "   Project: ${PROJECT_NAME}"
echo "   Issue:   ${ISSUE}"
[ -n "$SPRINT" ] && echo "   Sprint:  ${SPRINT}"
echo "   CTO at:  ${CTO_REPO}"
echo ""

{
    echo "# CTO Escalation Response"
    echo ""
    echo "**From:** ${PERSONA} @ ${PROJECT_NAME}"
    echo "**Issue:** ${ISSUE}"
    [ -n "$SPRINT" ] && echo "**Sprint:** ${SPRINT}"
    echo "**Timestamp:** ${TIMESTAMP}"
    echo ""
    echo "---"
    echo ""
} > "$OUTPUT_FILE"

cd "$CTO_REPO"

RESPONSE=""
EXIT_CODE=0

if [ -n "$TIMEOUT_BIN" ]; then
    RESPONSE=$(printf '%s\n' "$ESCALATION_PROMPT" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "$TIMEOUT_BIN" "$TIMEOUT" "$CLAUDE_BIN" -p --max-turns 5 2>&1) || EXIT_CODE=$?
else
    RESPONSE=$(printf '%s\n' "$ESCALATION_PROMPT" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "$CLAUDE_BIN" -p --max-turns 5 2>&1) || EXIT_CODE=$?
fi

if [ $EXIT_CODE -eq 124 ]; then
    { echo "## CTO RESPONSE: TIMEOUT"; echo ""; echo "The CTO call timed out after ${TIMEOUT}s."; } >> "$OUTPUT_FILE"
    echo "CTO call timed out. Partial response (if any) saved to: $OUTPUT_FILE" >&2
    exit 2
fi

if [ $EXIT_CODE -ne 0 ]; then
    { echo "## CTO RESPONSE: ERROR (exit ${EXIT_CODE})"; echo ""; echo "$RESPONSE"; } >> "$OUTPUT_FILE"
    echo "CTO call failed (exit ${EXIT_CODE}). Output saved to: $OUTPUT_FILE" >&2
    exit 2
fi

echo "$RESPONSE" >> "$OUTPUT_FILE"

echo "CTO response received."
echo "   Saved to: $OUTPUT_FILE"
echo ""
echo "$RESPONSE"
