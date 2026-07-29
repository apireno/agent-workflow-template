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
#   kimi    — pipes prompt to openrouter-chat.sh (OpenRouter, default moonshotai/kimi-k2.6;
#             cross-family independent reviewer, non-Anthropic metered — pennies)
#   codex   — ⚠️ UNTESTED (2026-07-02, no live `codex` install to verify against) — pipes prompt
#             to codex-exec.sh (OpenAI Codex CLI `codex exec`, non-interactive). A second
#             cross-family independent reviewer alongside kimi. See codex-exec.sh header.
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
# Defer to the shared resolver (single source of truth: REVIEW_ENGINE env -> .review-engine
# file -> default subagent; legacy aliasing; claude-p metered quarantine). This CLI executor
# can only RUN the CLI engines (gemini, kimi, codex, claude-p); subagent/handoff are orchestrator-driven
# (the /vp-review skill fans them via the Agent tool / windows) and are rejected below.
RESOLVER="$(dirname "$0")/resolve-review-engine.sh"
if [ -x "$RESOLVER" ]; then
    ENGINE=$("$RESOLVER") || { rc=$?; [ "$ENGINE" = "claude-p-blocked" ] 2>/dev/null; exit $rc; }
else
    # Fallback if the shared resolver isn't present: env -> file -> subagent (legacy aliasing).
    if [ -n "${REVIEW_ENGINE:-}" ]; then ENGINE="$REVIEW_ENGINE"
    elif [ -f "$REPO_ROOT/.review-engine" ]; then ENGINE="$(tr -d '[:space:]' < "$REPO_ROOT/.review-engine")"
    else ENGINE="subagent"; fi
    case "$ENGINE" in claude) ENGINE="claude-p";; dual) ENGINE="gemini";; none|"") ENGINE="subagent";; esac
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

# kimi/codex engine executors (ship with this repo's scripts)
OPENROUTER_CHAT="$(cd "$(dirname "$0")" && pwd)/openrouter-chat.sh"
CODEX_EXEC="$(cd "$(dirname "$0")" && pwd)/codex-exec.sh"

# --- Argument parsing ---
if [ $# -lt 3 ]; then
    echo "Usage: $0 <persona> <input-file> <output-file>"
    echo "Available personas: vp-eng vp-prod vp-security vp-compliance vp-devops vp-datascience"
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
    vp-datascience)
        PERSONA_FILE="docs/personas/vp-datascience.md"
        ;;
    vp-dba)
        PERSONA_FILE="docs/personas/vp-dba.md"
        CONCERNS_FILE="docs/personas/concerns/dba.md"
        ;;
    *)
        echo "Error: Unknown persona '$PERSONA'"
        echo "Available personas: vp-eng vp-prod vp-security vp-compliance vp-devops vp-datascience vp-dba"
        exit 1
        ;;
esac

# Resolve to absolute paths.
#
# Persona definitions travel WITH this script, so resolve them against the script's own
# location first and fall back to the cwd repo only if that misses. Resolving against
# `git rev-parse` alone silently couples the review to wherever the operator happens to
# stand: run from a project repo that carries no vp-datascience.md and the review fails,
# even though the CTO home two directories away has it. A reviewer's identity must not
# depend on the caller's shell.
SCRIPT_HOME="$(cd "$(dirname "$0")/../.." && pwd)"
resolve_asset() {
    # $1 = repo-relative path (e.g. docs/personas/vp-product.md); echoes the first hit.
    if [ -f "$SCRIPT_HOME/$1" ]; then echo "$SCRIPT_HOME/$1"
    elif [ -f "$REPO_ROOT/$1" ]; then echo "$REPO_ROOT/$1"
    else echo "$SCRIPT_HOME/$1"; fi   # report the canonical path in the not-found error
}

PERSONA_FILE="$(resolve_asset "$PERSONA_FILE")"

# Concerns and context are PROJECT-specific by design (a project's real security posture,
# its private domain knowledge), so those prefer the cwd repo and fall back to the script
# home — the opposite precedence to the persona, deliberately.
resolve_project_asset() {
    if [ -f "$REPO_ROOT/$1" ]; then echo "$REPO_ROOT/$1"
    elif [ -f "$SCRIPT_HOME/$1" ]; then echo "$SCRIPT_HOME/$1"
    else echo "$REPO_ROOT/$1"; fi
}

if [ -n "$CONCERNS_FILE" ]; then
    CONCERNS_FILE="$(resolve_project_asset "$CONCERNS_FILE")"
fi

if [ -n "$CONTEXT_FILE" ]; then
    CONTEXT_FILE="$(resolve_project_asset "$CONTEXT_FILE")"
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

# --- ADR-042 Tenet 4 toolchain compliance (sprint-layer-3-hardening-20260512) ---
# Retry-with-backoff. Detect empty output and rate-limit markers BEFORE
# writing the output file. Don't swallow stderr — capture it so
# diagnostics surface when the LLM CLI fails. Exit non-zero on any
# failure mode so callers (and the harness) see the failure.

# Rate-limit markers we treat as failures (Gemini + Claude common forms).
_RATE_LIMIT_PATTERNS='HTTP 429|rate.?limit|quota.?exceeded|RESOURCE_EXHAUSTED|too many requests'

# Tunables (override via env).
VP_REVIEW_MAX_ATTEMPTS="${VP_REVIEW_MAX_ATTEMPTS:-3}"
VP_REVIEW_BACKOFF_INITIAL_SEC="${VP_REVIEW_BACKOFF_INITIAL_SEC:-2}"

# Returns 0 if body is acceptable, 1 if empty, 2 if rate-limited.
_inspect_output_body() {
    local out_file="$1"
    if [ ! -s "$out_file" ]; then
        return 1
    fi
    # Match case-insensitively, dot-all on the first 4KB so a marker
    # buried in CLI stderr-merged output still trips.
    if LC_ALL=C grep -qiE "$_RATE_LIMIT_PATTERNS" "$out_file" 2>/dev/null; then
        # Heuristic guard: only treat as rate-limit if the file is short
        # (a real review document is hundreds of lines and won't pivot
        # on these keywords); a review of a security memo legitimately
        # contains the term "rate-limit" in its analysis.
        local size
        size=$(wc -c < "$out_file" | tr -d ' ')
        if [ "$size" -lt 4096 ]; then
            return 2
        fi
    fi
    return 0
}

# Wraps a single CLI invocation with stderr capture so a failed
# invocation is diagnosable (was: 2>/dev/null silently ate everything).
run_gemini() {
    local out_file="$1"
    local stderr_file="${out_file}.gemini-stderr.log"
    cat "$PROMPT_FILE" | "$GEMINI_CMD" > "$out_file" 2>"$stderr_file"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[vp-review] gemini exited with code $rc" >&2
        [ -s "$stderr_file" ] && echo "[vp-review] gemini stderr (tail):" >&2 \
            && tail -5 "$stderr_file" >&2
    fi
    return $rc
}

run_kimi() {
    local out_file="$1"
    local stderr_file="${out_file}.kimi-stderr.log"
    cat "$PROMPT_FILE" | "$OPENROUTER_CHAT" > "$out_file" 2>"$stderr_file"
    local rc=$?
    # Surface the per-call usage line (spend visibility) even on success.
    grep -h '^openrouter-chat: model=' "$stderr_file" >&2 || true
    if [ "$rc" -ne 0 ]; then
        echo "[vp-review] kimi (openrouter) exited with code $rc" >&2
        [ -s "$stderr_file" ] && echo "[vp-review] kimi stderr (tail):" >&2 \
            && tail -5 "$stderr_file" >&2
    fi
    return $rc
}

run_codex() {
    # ⚠️ UNTESTED (2026-07-02) — see codex-exec.sh header.
    local out_file="$1"
    local stderr_file="${out_file}.codex-stderr.log"
    cat "$PROMPT_FILE" | "$CODEX_EXEC" > "$out_file" 2>"$stderr_file"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[vp-review] codex exited with code $rc" >&2
        [ -s "$stderr_file" ] && echo "[vp-review] codex stderr (tail):" >&2 \
            && tail -20 "$stderr_file" >&2
    fi
    return $rc
}

run_claude() {
    local out_file="$1"
    local stderr_file="${out_file}.claude-stderr.log"
    cat "$PROMPT_FILE" | "$CLAUDE_CMD" -p --max-turns 1 > "$out_file" 2>"$stderr_file"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[vp-review] claude exited with code $rc" >&2
        [ -s "$stderr_file" ] && echo "[vp-review] claude stderr (tail):" >&2 \
            && tail -5 "$stderr_file" >&2
    fi
    return $rc
}

# Retry wrapper. Calls the runner, inspects the output, retries on
# empty / rate-limited body up to VP_REVIEW_MAX_ATTEMPTS times with
# exponential backoff.
run_with_retry() {
    local runner_fn="$1"
    local out_file="$2"
    local label="$3"
    local attempt=1
    local backoff="$VP_REVIEW_BACKOFF_INITIAL_SEC"
    local diag

    while [ "$attempt" -le "$VP_REVIEW_MAX_ATTEMPTS" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo "[vp-review] ${label}: retry $attempt/$VP_REVIEW_MAX_ATTEMPTS after ${backoff}s..." >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
        fi

        # Invoke. Don't fail-fast on non-zero rc — body inspection is
        # the canonical signal (some CLIs return 0 even with empty body).
        "$runner_fn" "$out_file" || true

        _inspect_output_body "$out_file" && diag=0 || diag=$?
        case "$diag" in
            0)
                return 0
                ;;
            1)
                echo "[vp-review] ${label}: empty output (attempt $attempt)" >&2
                ;;
            2)
                echo "[vp-review] ${label}: rate-limit marker detected (attempt $attempt)" >&2
                ;;
        esac
        attempt=$((attempt + 1))
    done

    echo "[vp-review] ${label}: FAILED after $VP_REVIEW_MAX_ATTEMPTS attempts (last diag=$diag)" >&2
    # Deliberately NO automatic fallback to another engine. Engines are not
    # interchangeable evidence: the reason to run kimi or codex is that a DIFFERENT model
    # family reviewed the work, and silently substituting one would leave a verdict
    # labelled with an engine that never ran it. Fail loudly, name the override, let a
    # human choose the substitute knowingly.
    {
        # $* here would be the FUNCTION's args, not the script's — reconstruct from the
        # parsed positionals so the suggested command is actually runnable.
        echo "[vp-review] engine '${label}' is unavailable. Re-run naming a different engine explicitly:"
        echo "    REVIEW_ENGINE=kimi     $0 ${PERSONA:-<vp>} ${INPUT_FILE:-<artifact>} ${OUTPUT_FILE:-<out.md>}   # OpenRouter, needs OPENROUTER_API_KEY"
        echo "    REVIEW_ENGINE=subagent ...          # in-session Agent tool, via the /vp-review skill"
        echo "  Or change this repo's default:  echo <engine> > .review-engine"
        echo "  NOT auto-substituted on purpose — a verdict must name the engine that actually produced it."
    } >&2
    rm -f "$out_file"
    return 1
}

# Dry-run mode: exercise the inspection + retry logic against a
# caller-supplied synthetic body without invoking any LLM. Set
# VP_REVIEW_DRY_RUN=empty to produce an empty body; =429 to produce a
# rate-limit body; =ok to produce a plausibly-real body. Used by the
# unit test for Stream 6.
if [ -n "${VP_REVIEW_DRY_RUN:-}" ]; then
    case "$VP_REVIEW_DRY_RUN" in
        empty)
            : > "$OUTPUT_FILE"
            ;;
        429)
            printf 'HTTP 429: rate limit exceeded\n' > "$OUTPUT_FILE"
            ;;
        ok)
            # Produce a long-enough body that the heuristic guard does
            # not classify it as a rate-limit short-circuit.
            python3 -c "import sys; sys.stdout.write('# review\n\n' + ('valid review content line\n' * 200))" > "$OUTPUT_FILE"
            ;;
        *)
            echo "[vp-review] unknown VP_REVIEW_DRY_RUN=$VP_REVIEW_DRY_RUN" >&2
            exit 1
            ;;
    esac
    # set -e would exit on a non-zero return; capture into a variable
    # so the case statement can branch on it.
    _inspect_output_body "$OUTPUT_FILE" && DRY_RUN_RC=0 || DRY_RUN_RC=$?
    case "$DRY_RUN_RC" in
        0)
            echo "[vp-review] dry-run OK"
            exit 0
            ;;
        1)
            echo "[vp-review] dry-run detected empty body" >&2
            rm -f "$OUTPUT_FILE"
            exit 1
            ;;
        2)
            echo "[vp-review] dry-run detected rate-limit marker" >&2
            rm -f "$OUTPUT_FILE"
            exit 1
            ;;
    esac
fi

echo "Requesting $PERSONA review of $(basename "$INPUT_FILE") [engine: $ENGINE]..."

case "$ENGINE" in
    gemini)
        run_with_retry run_gemini "$OUTPUT_FILE" "gemini"
        ;;
    kimi)
        if [ -z "${OPENROUTER_API_KEY:-}" ]; then
            echo "Error: engine 'kimi' requires OPENROUTER_API_KEY in the environment." >&2
            exit 1
        fi
        run_with_retry run_kimi "$OUTPUT_FILE" "kimi"
        ;;
    codex)
        # ⚠️ UNTESTED (2026-07-02) — see codex-exec.sh header. Not hard-requiring an env var:
        # unlike kimi (OpenRouter needs a key, full stop), codex exec can also authenticate via
        # a prior `codex login` OAuth session with no key present.
        if [ -z "${CODEX_API_KEY:-}${OPENAI_API_KEY:-}" ]; then
            echo "[vp-review] note: neither CODEX_API_KEY nor OPENAI_API_KEY set — proceeding on the" >&2
            echo "  assumption a 'codex login' OAuth session is active. If this fails, set one of those." >&2
        fi
        run_with_retry run_codex "$OUTPUT_FILE" "codex"
        ;;
    claude-p)
        # ⚠️ METERED Anthropic API (Agent-SDK credit pool). The shared resolver already
        # enforced REVIEW_ALLOW_METERED=1; this is a defense-in-depth second gate.
        if [ "${REVIEW_ALLOW_METERED:-0}" != "1" ]; then
            echo "Error: engine 'claude-p' is the metered API path; set REVIEW_ALLOW_METERED=1 to opt in." >&2
            exit 1
        fi
        run_with_retry run_claude "$OUTPUT_FILE" "claude-p"
        ;;
    subagent|handoff)
        # This CLI executor cannot run an in-session Agent or a window — those are
        # orchestrator (main-loop) actions. The /vp-review skill fans them; calling
        # this script directly with these engines is a usage error.
        echo "Error: engine '$ENGINE' is orchestrator-driven, not a CLI run." >&2
        echo "  Use the /vp-review skill (it fans subagent/handoff reviews via the Agent tool / windows)," >&2
        echo "  or pick a CLI engine: REVIEW_ENGINE=kimi $0 $PERSONA $INPUT_FILE $OUTPUT_FILE" >&2
        exit 2
        ;;
    *)
        echo "Error: Unknown engine '$ENGINE'. Use: kimi | codex (untested) | gemini | claude-p (metered) | subagent | handoff" >&2
        exit 1
        ;;
esac

# --- Verify output (defense-in-depth: retry wrapper already cleaned
#     up + returned non-zero on failure; this is the final gate) ---
if [ -s "$OUTPUT_FILE" ]; then
    LINES=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
    echo "Review written to: $OUTPUT_FILE ($LINES lines)"
else
    echo "[vp-review] FAIL: Output file is missing or empty after retries."
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
