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

# ─── 0. First-run onboarding trigger ─────────────────────────────────────────
# A fresh clone has no real .cto/projects.yaml (only the .example) and no
# .claude/.setup-done marker. Surface a directive the CTO persona cannot miss —
# printed first, ahead of the pass/fail checks below, so onboarding happens
# before any other work this session. /setup writes the marker on completion.
if [ ! -f "$REPO_ROOT/.claude/.setup-done" ] && [ ! -f "$REPO_ROOT/.cto/projects.yaml" ]; then
    echo "[FIRST-RUN] No .cto/projects.yaml and no .claude/.setup-done marker — this looks like a"
    echo "  fresh clone. BEFORE addressing any other request this session, invoke the /setup skill"
    echo "  now (env/prerequisite checks + fleet registration Q&A). Do this even if the CEO opened"
    echo "  with an unrelated directive — acknowledge it, then run /setup, then return to it."
    echo ""
fi

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
    # Past the deadline — claude -p is now metered, scan for UNGUARDED invocations.
    # Skip comment lines (mentions in docs/warnings aren't invocations) and skip any
    # file that also contains the REVIEW_ALLOW_METERED quarantine token — that's the
    # deliberate, already-gated claude-p break-glass path (resolve-review-engine.sh),
    # not a leftover unmigrated call.
    P_USAGE=""
    for f in $(grep -rlE '\bclaude -p\b|\bclaude --print\b' "$REPO_ROOT/scripts/" 2>/dev/null | grep -v _deprecated); do
        [ "$(basename "$f")" = "preflight.sh" ] && continue
        grep -q 'REVIEW_ALLOW_METERED' "$f" && continue
        grep -vE '^\s*#' "$f" | grep -v 'never claude -p' | grep -qE '\bclaude -p\b|\bclaude --print\b' && P_USAGE="$P_USAGE$f
"
    done
    if [ -n "$P_USAGE" ]; then
        # Advisory, not blocking — a fresh clone's day-1 setup path (/setup, /handoff,
        # /vp-review) never touches these files. Known architecture follow-up: rewire
        # off claude -p or rename to _deprecated-*, not a setup blocker.
        emit_warning "Past 2026-06-15: unguarded \`claude -p\` mentions (no REVIEW_ALLOW_METERED quarantine) in:"
        echo "$P_USAGE" | sed 's/^/    /'
        echo "    Not on the day-1 setup path — flagged as a follow-up, not a blocker."
    fi
else
    DAYS_LEFT=$(( (DEADLINE_EPOCH - TODAY_EPOCH) / 86400 ))
    if [ "$DAYS_LEFT" -lt 30 ] && [ "$DAYS_LEFT" -gt 0 ]; then
        emit_warning "${DAYS_LEFT} days until 2026-06-15 Agent SDK billing change. Verify ADR-046 implementation is on track."
    fi
fi

# ─── 2. Review engine availability ───────────────────────────────────────────
# gemini-CLI died 2026-06-19 (UNSUPPORTED_CLIENT) and is no longer required — the
# default engine is `subagent` (in-session Agent tool, needs nothing external) and
# `kimi` (OpenRouter) is the cross-family independent reviewer. Advisory only: a
# missing gemini/OPENROUTER_API_KEY does not block the skills-driven architecture.
if ! command -v gemini > /dev/null 2>&1; then
    emit_ok  # gemini optional; subagent/kimi cover review needs without it
fi
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    emit_warning "OPENROUTER_API_KEY not set. The 'kimi' review engine (cross-family independent VP reviews via OpenRouter) needs it. subagent (in-session) still works without it — see /vp-review."
fi

# ─── 3. ANTHROPIC_API_KEY should NOT be set in this environment ──────────────
# The CTO session runs on Max subscription. If ANTHROPIC_API_KEY is set,
# claude -p calls would silently route to the API instead of subscription.
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    emit_warning "ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN is set. Any \`claude -p\` invocations would charge against API, not subscription. Verify intent."
fi

# ─── 3a. Duplicate native libraries in the Python env ────────────────────────
# Two copies of one C++ runtime in a single interpreter share process-global
# state, and the usual symptom is a crash at EXIT — after the work is done and
# the artifacts are written, so every individual instance looks like ignorable
# noise. One machine reached 41 crash dumps before anyone read one (kgspin-core
# BUG-308). Never blocking: it is an environment smell, not a broken session.
#
# The scan costs ~10s, so it is CACHED and keyed on the environment fingerprint.
# We read the cached verdict (instant) and refresh in the background when stale,
# so a session start never waits for it.
DUPES="$(dirname "$0")/check-native-dupes.sh"
if [ -x "$DUPES" ]; then
    DUPE_OUT="$("$DUPES" 2>/dev/null)"; DUPE_RC=$?
    if [ "$DUPE_RC" -eq 1 ] && [ -n "$DUPE_OUT" ]; then
        # The scanner prints its own "[WARN] duplicate native libraries in <path>"
        # header, so emit the body as-is and only bump the advisory counter.
        emit_warning "$(printf '%s' "$DUPE_OUT" | head -1 | sed 's/^\[WARN\] //')"
        printf '%s\n' "$DUPE_OUT" | tail -n +2 | sed 's/^/  /'
    fi
    # Refresh detached so the next session sees current state without this one
    # paying for it. Ignored if already fresh.
    ( "$DUPES" --refresh --quiet >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

# ─── 3b. git identity + gh auth (needed for /new-project's publish commands) ──
if ! git config user.email > /dev/null 2>&1; then
    emit_warning "git user.email not configured (git config --global user.email you@example.com). Commits will fail until set."
fi
if command -v gh > /dev/null 2>&1; then
    if ! gh auth status > /dev/null 2>&1; then
        emit_warning "gh CLI installed but not authenticated (gh auth login). Needed to publish repos from /new-project."
    fi
else
    emit_warning "gh CLI not found. Needed to publish repos from /new-project (gh repo create ...). Install: https://cli.github.com/"
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

# ─── 8. Model drift (CTO homes only) ─────────────────────────────────────────
# Claude Code's /model picker saves the choice as the MACHINE-GLOBAL default for
# new sessions. Every dev tab /handoff opens inherits it. Nothing in this repo
# pins a model, so a model chosen once in the CTO window silently becomes the
# model the whole fleet runs on until someone notices the quota. See
# docs/memos/2026-09-03-rca-handoff-model-inheritance.md.
REPO_NAME="$(basename "$REPO_ROOT")"
case "$REPO_NAME" in
    agent-workflow-template|*-cto)
        if [ -x "$REPO_ROOT/scripts/cto/check-fleet-model.sh" ]; then
            MODEL_OUT="$("$REPO_ROOT/scripts/cto/check-fleet-model.sh" 2>/dev/null)"
            if [ $? -eq 3 ]; then
                emit_warning "model drift across the fleet — a session is running on a model that is not the default:"
                echo "$MODEL_OUT" | grep -E 'DRIFT|^  REPO|^  ----' | sed 's/^/    /'
                echo "    Nothing in this repo pins a model. The source is /model, which saves"
                echo "    the choice as the default for NEW sessions — so it propagates to every"
                echo "    tab /handoff opens next. Fix in the affected window with /model."
            fi
        fi
        ;;
esac

# ─── 8b. Weekly model budget (CTO homes only) — model policy 2026-09-25 ───────
# Always prints a compact read (the CTO's MODEL ADVICE line at session start quotes it);
# warnings (runway short of the reset, a lane or subagent on the stretch model, a CTO
# session doing routine work on it) count as preflight warnings. Policy + calibration:
# .cto/model-budget.yaml (see .example).
case "$REPO_NAME" in
    agent-workflow-template|*-cto)
        MBS="$REPO_ROOT/scripts/cto/model-budget.sh"
        if [ -f "$MBS" ]; then
            MB_OUT="$(bash "$MBS" 2>/dev/null)"
            echo "[MODEL BUDGET] $(printf '%s\n' "$MB_OUT" | head -1 | sed 's/^model-budget: //')"
            printf '%s\n' "$MB_OUT" | grep -E '^  [a-z]+ \((STRETCH|lane)\):|^  runway ' | sed 's/^  /    /'
            MB_WARN="$(printf '%s\n' "$MB_OUT" | sed -n '/^WARNINGS:/,$p' | sed '1d')"
            if [ -n "$MB_WARN" ]; then
                emit_warning "model budget — $(printf '%s\n' "$MB_WARN" | grep -c .) finding(s); the CTO names them in its first reply with a MODEL ADVICE line:"
                printf '%s\n' "$MB_WARN" | cut -c1-230 | head -12 | sed 's/^  /    /'
            fi
        fi
        ;;
esac

# ─── 9. Governed derived artifacts (CTO homes only) — ADR-002 ────────────────
# For every registry entry flagged `derived_artifacts: required`, run the gate in audit mode
# at HEAD and surface staleness the way an open sprint is surfaced. A required repo with no
# manifest is a warning too: nothing declared is not a pass.
case "$REPO_NAME" in
    agent-workflow-template|*-cto)
        DAG="$REPO_ROOT/scripts/agentic/derived-artifact-gate.sh"
        if [ -f "$DAG" ] && [ -f "$REPO_ROOT/.cto/projects.yaml" ]; then
            DAG_ROWS=""; DAG_BAD=0
            while IFS='|' read -r dname dpath; do
                [ -d "$dpath" ] || continue
                DOUT="$(bash "$DAG" --head --audit --require --repo "$dpath" 2>&1)"; DRC=$?
                if [ "$DRC" -eq 4 ]; then
                    DAG_BAD=$((DAG_BAD+1))
                    DAG_ROWS="$DAG_ROWS
    $(printf '%-24s %s' "$dname" 'NO-MANIFEST   flagged required, nothing declared — author .claude/derived-artifacts.yaml')"
                elif [ "$DRC" -eq 3 ]; then
                    DAG_BAD=$((DAG_BAD+1))
                    DAG_ROWS="$DAG_ROWS
$(printf '%s\n' "$DOUT" | grep -E '^  \S+ +(block|warn) +(STALE|LEAK|DEAD-ROOT|NO-GENERATOR|NO-STAMP|GEN-ERROR|BAD-ENTRY)' | cut -c1-150 | sed "s/^  /    $(printf '%-24s' "$dname") /")"
                fi
            done < <(python3 - "$REPO_ROOT/.cto/projects.yaml" <<'PYREG'
import re,sys
t=open(sys.argv[1]).read()
for b in re.split(r'(?=- name:)',t):
    n=re.search(r'- name:\s*(\S+)',b); p=re.search(r'path:\s*(\S+)',b); a=re.search(r'active:\s*(\S+)',b); r=re.search(r'derived_artifacts:\s*(\S+)',b)
    if n and p and r and r.group(1).lower()=='required' and ((a is None) or a.group(1).lower() not in ('false','no','0')):
        print(f"{n.group(1)}|{p.group(1)}")
PYREG
)
            if [ "$DAG_BAD" -gt 0 ]; then
                emit_warning "governed derived artifacts are not current in $DAG_BAD required repo(s) — ADR-002:"
                echo "    $(printf '%-24s %s' REPO 'ARTIFACT  MODE  STATE  DETAIL')"
                echo "$DAG_ROWS" | sed '/^$/d'
                echo "    Regenerate through each repo's generator (or: bash scripts/agentic/derived-artifact-gate.sh --fix there)."
                echo "    A stale graph is consulted at planning as if it were current — treat like an open sprint."
            fi
        fi
        # Cross-repo join ledger (ADR-002 §7) — advisory unless a repo sets boundary.join: verify-row
        JL="$REPO_ROOT/scripts/cto/join-ledger.sh"
        if [ -f "$JL" ] && [ -f "$REPO_ROOT/.cto/projects.yaml" ]; then
            JOUT="$(bash "$JL" --quiet 2>&1)"; JRC=$?
            if [ "$JRC" -eq 3 ]; then
                emit_warning "cross-repo boundary mismatch (ADR-002 §7) — a consumer calls a sibling in a shape the producer no longer has:"
                printf '%s\n' "$JOUT" | grep -E 'MISMATCH|MISSING' | head -12 | sed 's/^/    /'
                echo "    Full ledger: .cto/join-ledger.md — rule which side moves; the verify of the repo that moved the boundary carries the row."
            fi
        fi
        ;;
esac

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
