#!/bin/bash
# preflight.sh — SessionStart safety check for the skills-driven architecture
#
# Invoked by the SessionStart hook in .claude/settings.json. Runs a battery of
# operational checks and emits any warnings/errors to stdout (which the hook
# treats as additionalContext into Claude's session).
#
# Designed to fail-fast on critical issues (e.g., gemini CLI missing entirely)
# and warn on advisory issues (e.g., date past June 15 with claude -p still in
# scripts). Failing the SessionStart hook does NOT abort the session — but the
# warnings appear in Claude's context, so the CTO sees them at conversation start.
#
# Exit codes:
#   0 — preflight passed (may still have advisory warnings)
#   2 — critical failure (gemini missing or scripts/agentic broken)

set -uo pipefail
# NOTE: not using set -e — we want to collect all issues, not stop at first

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CRITICAL_FAILURES=0
ADVISORY_WARNINGS=0

emit_critical() {
    echo "[CRITICAL] $1"
    CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1))
}

emit_warning() {
    echo "[WARN] $1"
    ADVISORY_WARNINGS=$((ADVISORY_WARNINGS + 1))
}

emit_ok() {
    : # silent on success to keep additionalContext lean
}

# ─── 1. Date / June 15 deadline ──────────────────────────────────────────────
TODAY_EPOCH=$(date +%s)
DEADLINE_EPOCH=$(date -j -f "%Y-%m-%d" "2026-06-15" "+%s" 2>/dev/null || echo "0")
if [ "$TODAY_EPOCH" -ge "$DEADLINE_EPOCH" ] && [ "$DEADLINE_EPOCH" != "0" ]; then
    # Past the deadline — claude -p is now metered, scan for it
    P_USAGE=$(grep -rEln '\bclaude -p\b|\bclaude --print\b' "$REPO_ROOT/scripts/" 2>/dev/null | grep -v _deprecated | head -5)
    if [ -n "$P_USAGE" ]; then
        emit_critical "Past 2026-06-15 and \`claude -p\` invocations still present in:"
        echo "$P_USAGE" | sed 's/^/    /'
        echo "    Each invocation now draws from the metered Agent SDK credit pool."
    fi
else
    DAYS_LEFT=$(( (DEADLINE_EPOCH - TODAY_EPOCH) / 86400 ))
    if [ "$DAYS_LEFT" -lt 30 ] && [ "$DAYS_LEFT" -gt 0 ]; then
        emit_warning "${DAYS_LEFT} days until 2026-06-15 Agent SDK billing change. Verify ADR-046 implementation is on track."
    fi
fi

# ─── 2. Gemini CLI availability ──────────────────────────────────────────────
if ! command -v gemini > /dev/null 2>&1; then
    emit_critical "gemini CLI not found in PATH. The skills-driven architecture depends on gemini for parallel cheap work. Install: see https://github.com/google-gemini/gemini-cli"
fi

# ─── 3. ANTHROPIC_API_KEY should NOT be set in this environment ──────────────
# The CTO session runs on Max subscription. If ANTHROPIC_API_KEY is set,
# claude -p calls would silently route to the API instead of subscription.
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    emit_warning "ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN is set. Any \`claude -p\` invocations would charge against API, not subscription. Verify intent."
fi

# ─── 4. Persona files present ────────────────────────────────────────────────
MISSING_PERSONAS=""
for persona in cto dev-team vp-engineering vp-product vp-security vp-devops vp-compliance vp-datascience; do
    if [ ! -f "$REPO_ROOT/docs/personas/${persona}.md" ]; then
        MISSING_PERSONAS="$MISSING_PERSONAS $persona"
    fi
done
if [ -n "$MISSING_PERSONAS" ]; then
    emit_warning "Missing persona files:$MISSING_PERSONAS"
fi

# ─── 5. Telemetry ledger freshness (if exists) ───────────────────────────────
# Not implemented yet — Sprint B. Just check the ledger path is reachable if defined.
LEDGER="${HOME}/.cto/telemetry/rate-window.jsonl"
if [ -f "$LEDGER" ]; then
    LAST_TS_EPOCH=$(stat -f %m "$LEDGER" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    STALENESS=$(( NOW - LAST_TS_EPOCH ))
    if [ "$STALENESS" -gt 90 ]; then
        emit_warning "Telemetry ledger is ${STALENESS}s stale (threshold 90s). Daemon may be down."
    fi
fi

# ─── 6. .cto/queue/ writability (if exists) ──────────────────────────────────
if [ -d "$HOME/.cto/inbox" ]; then
    if [ ! -w "$HOME/.cto/inbox" ]; then
        emit_critical "~/.cto/inbox/ exists but is not writable. Escalation drain will fail."
    fi
fi

# ─── 7. wrap-untrusted.sh executable check ───────────────────────────────────
if [ -f "$REPO_ROOT/scripts/agentic/wrap-untrusted.sh" ]; then
    if [ ! -x "$REPO_ROOT/scripts/agentic/wrap-untrusted.sh" ]; then
        emit_critical "scripts/agentic/wrap-untrusted.sh exists but is not executable. Skills depend on it."
    fi
fi

# ─── Summary line (always emitted) ───────────────────────────────────────────
echo ""
if [ "$CRITICAL_FAILURES" -gt 0 ]; then
    echo "preflight: ${CRITICAL_FAILURES} critical, ${ADVISORY_WARNINGS} warnings — read above before proceeding"
    exit 2
elif [ "$ADVISORY_WARNINGS" -gt 0 ]; then
    echo "preflight: ok with ${ADVISORY_WARNINGS} warnings — read above"
    exit 0
else
    echo "preflight: ok"
    exit 0
fi
