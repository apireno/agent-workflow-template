#!/usr/bin/env bash
# vp-author.sh — persona-authored ARTIFACT drafting via the configured engine.
#
#   vp-author.sh <persona> <task-prompt-file> <output-file>
#
# The authoring counterpart to vp-review.sh. That script is review-shaped — persona
# reads an artifact, emits a verdict, and its prompt hard-constrains the model to
# "REVIEW mode ONLY, never author". Drafting a PRD, an ADR, or a co-authored analysis
# section is a different job, and doing it by piping a hand-built prompt straight into
# an engine (observed 4+ times in one session) loses three things this script keeps:
#
#   1. PERSONA RESOLUTION — the same script-home-first lookup vp-review uses, so the
#      persona is found regardless of the caller's cwd.
#   2. PROVENANCE — every authored file is stamped with the engine, model, persona, and
#      prompt hash that produced it. An artifact drafted by an external model and left
#      unmarked is indistinguishable from one a human wrote; that matters when the
#      artifact is a PRD or an ADR someone later treats as a decision record.
#   3. THE NO-SELF-SIGN CONSTRAINT — an authored artifact may PROPOSE, never RATIFY.
#      A persona drafting its own sign-off is the same failure as a dev team reading a
#      blanket pre-approval as a signature: authority has to come from outside the
#      artifact. The prompt says so explicitly, and the stamp makes it checkable.
#
# Engine: resolved by resolve-review-engine.sh (REVIEW_ENGINE env -> .review-engine ->
# default). CLI engines only (kimi/gemini/codex/claude-p) — subagent/handoff are
# orchestrator-driven and rejected, same contract as vp-review.sh.
#
# Usage:
#   vp-author.sh vp-product /tmp/prd-task.md docs/roadmap/prds/PRD-042.md
#   REVIEW_ENGINE=kimi vp-author.sh vp-datascience /tmp/ds-task.md docs/analysis.md

set -uo pipefail

PERSONA="${1:?usage: vp-author.sh <persona> <task-prompt-file> <output-file>}"
TASK_FILE="${2:?need a task prompt file}"
OUTPUT_FILE="${3:?need an output file path}"
[ -f "$TASK_FILE" ] || { echo "vp-author: task prompt file not found: $TASK_FILE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

case "$PERSONA" in
    vp-eng)         REL="docs/personas/vp-engineering.md" ;;
    vp-prod)        REL="docs/personas/vp-product.md" ;;
    vp-security)    REL="docs/personas/vp-security.md" ;;
    vp-compliance)  REL="docs/personas/vp-compliance.md" ;;
    vp-devops)      REL="docs/personas/vp-devops.md" ;;
    vp-datascience) REL="docs/personas/vp-datascience.md" ;;
    vp-dba)         REL="docs/personas/vp-dba.md" ;;
    cto)            REL="docs/personas/cto.md" ;;
    *) echo "vp-author: unknown persona '$PERSONA'" >&2
       echo "  known: vp-eng vp-prod vp-security vp-compliance vp-devops vp-datascience vp-dba cto" >&2
       exit 1 ;;
esac

# Personas travel with the script; prefer its home, fall back to the cwd repo.
if   [ -f "$SCRIPT_HOME/$REL" ]; then PERSONA_FILE="$SCRIPT_HOME/$REL"
elif [ -f "$REPO_ROOT/$REL" ];   then PERSONA_FILE="$REPO_ROOT/$REL"
else echo "vp-author: persona file not found: $REL (looked in $SCRIPT_HOME and $REPO_ROOT)" >&2; exit 1; fi

RESOLVER="$SCRIPT_DIR/resolve-review-engine.sh"
if [ -x "$RESOLVER" ]; then ENGINE=$("$RESOLVER") || exit $?
else ENGINE="${REVIEW_ENGINE:-subagent}"; fi
case "$ENGINE" in claude) ENGINE=claude-p ;; dual) ENGINE=gemini ;; none|"") ENGINE=subagent ;; esac

case "$ENGINE" in
    subagent|handoff)
        echo "vp-author: engine '$ENGINE' is orchestrator-driven, not a CLI run." >&2
        echo "  Author it in-session via the Agent tool with the persona at:" >&2
        echo "    $PERSONA_FILE" >&2
        echo "  Or pick a CLI engine:  REVIEW_ENGINE=kimi $0 $PERSONA $TASK_FILE $OUTPUT_FILE" >&2
        exit 1 ;;
    claude-p)
        [ "${REVIEW_ALLOW_METERED:-0}" = "1" ] || { echo "vp-author: claude-p is metered; set REVIEW_ALLOW_METERED=1 to opt in." >&2; exit 3; } ;;
esac

PROMPT_FILE="$(mktemp)"; trap 'rm -f "$PROMPT_FILE"' EXIT
{
    cat "$PERSONA_FILE"
    cat <<'EOF'

=== AUTHORING TASK ===
Adopt the persona above and AUTHOR the document described below.

Output ONLY the finished document in markdown. No preamble, no commentary about the
task, no code fences wrapping the whole document.

HARD CONSTRAINTS:
- You are DRAFTING, not deciding. The artifact may PROPOSE, RECOMMEND, or REQUEST.
- Never write a sign-off, ratification, approval, or signature — not your own and not
  anyone else's. If the document needs one, leave an explicit unsigned placeholder
  naming who must sign. Authority comes from outside the artifact.
- Do not claim a review was performed, a test was run, or a metric was measured unless
  the task material below actually contains that evidence.
- State uncertainty as uncertainty. A drafted number presented as a finding is a defect.
- Write source code only if the task explicitly asks for it; artifacts are the default.

=== TASK ===
EOF
    cat "$TASK_FILE"
} > "$PROMPT_FILE"

case "$ENGINE" in
    kimi)     RUNNER="$SCRIPT_DIR/openrouter-chat.sh" ;;
    codex)    RUNNER="$SCRIPT_DIR/codex-exec.sh" ;;
    gemini)   RUNNER="" ;;
    claude-p) RUNNER="" ;;
esac

echo "vp-author: $PERSONA authoring -> $OUTPUT_FILE [engine: $ENGINE]" >&2
BODY="$(mktemp)"; ERRF="$(mktemp)"
trap 'rm -f "$PROMPT_FILE" "$BODY" "$ERRF"' EXIT

if   [ "$ENGINE" = "gemini" ];   then cat "$PROMPT_FILE" | gemini > "$BODY" 2>"$ERRF"
elif [ "$ENGINE" = "claude-p" ]; then cat "$PROMPT_FILE" | claude -p --max-turns 1 > "$BODY" 2>"$ERRF"
else cat "$PROMPT_FILE" | "$RUNNER" > "$BODY" 2>"$ERRF"; fi
RC=$?

if [ "$RC" -ne 0 ] || [ ! -s "$BODY" ]; then
    echo "vp-author: engine '$ENGINE' produced no document (rc=$RC). stderr tail:" >&2
    tail -10 "$ERRF" >&2
    echo "vp-author: NOT written — $OUTPUT_FILE left untouched." >&2
    echo "  Re-run naming another engine explicitly, e.g. REVIEW_ENGINE=kimi $0 $PERSONA $TASK_FILE $OUTPUT_FILE" >&2
    exit 1
fi

# Provenance stamp. Engines report their model on stderr (openrouter-chat prints a usage
# line); fall back to the engine name when they don't.
MODEL="$(grep -ho 'model=[^ ]*' "$ERRF" 2>/dev/null | head -1 | cut -d= -f2)"
PROMPT_SHA="$(shasum -a 256 "$PROMPT_FILE" 2>/dev/null | cut -c1-12)"
mkdir -p "$(dirname "$OUTPUT_FILE")"
{
    echo "<!-- authored-by: $PERSONA persona via vp-author.sh"
    echo "     engine: $ENGINE   model: ${MODEL:-$ENGINE}"
    echo "     generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)   prompt-sha256: ${PROMPT_SHA:-unknown}"
    echo "     DRAFT — proposes only. Any sign-off must be added by the named human/role,"
    echo "     never by the drafting persona. -->"
    echo ""
    cat "$BODY"
} > "$OUTPUT_FILE"

echo "vp-author: wrote $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes to $OUTPUT_FILE (stamped $ENGINE/${MODEL:-$ENGINE})" >&2
[ -s "$ERRF" ] && grep -h 'prompt_tokens' "$ERRF" >&2
exit 0
