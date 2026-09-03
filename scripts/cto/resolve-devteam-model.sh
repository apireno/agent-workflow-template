#!/usr/bin/env bash
# resolve-devteam-model.sh — SINGLE SOURCE OF TRUTH for the model an ORCHESTRATED
# window runs on. Every launcher (/handoff, /resume-dev-team, qa-drive) resolves
# through this so a dev tab's model is a decision this repo records, not an
# inheritance from whatever was last picked in some other window.
#
# WHY THIS EXISTS (RCA 2026-09-03): Claude Code's `/model` picker changes the
# window you type it in AND saves the choice as the machine-global default for
# every session started afterwards. A launcher that passes no model inherits that.
# On 2026-09-02 a Fable pick in the CTO window was inherited by all three tabs of
# the next handoff — visible at message #1 of each transcript, invisible everywhere
# else. `claude --model X` is scoped to "the current session" (its own --help says
# so) and writes nothing back, so pinning at launch decouples the two: the CEO
# picks freely in the CTO window, dev tabs get what this file says.
#
# PRECEDENCE (highest wins):
#   1. DEVTEAM_MODEL env var          (per-invocation: DEVTEAM_MODEL=fable /handoff ...)
#   2. <cto-home>/.cto/devteam-model  (per-fleet default + optional per-repo overrides)
#   3. built-in default = opus        (an ALIAS — tracks the latest Opus, never stales)
#
# FILE FORMAT (.cto/devteam-model) — blank lines and #-comments ignored:
#   opus                    <- bare line: the fleet default
#   acme-tuner=fable        <- optional per-repo override, one per line
#   acme-demo-app=sonnet
#
# VALUES: any alias `claude --model` takes ('opus', 'sonnet', 'haiku', 'fable') or a
# full model name ('claude-opus-5[1m]'). Prefer an ALIAS: it tracks the latest model
# of that family, where a pinned full name silently ages into a retired one. Use a
# full name only when you specifically need a variant an alias does not select —
# e.g. the 1M-context build, which matters for long sprints.
#
#   inherit  — special value: emit nothing, take the machine-global default. This is
#              the pre-2026-09-03 behaviour. Deliberate opt-out, not a default: it
#              reintroduces exactly the silent inheritance the RCA is about.
#
# OUTPUT: the model on stdout, or EMPTY for `inherit`. Diagnostics to stderr so
# `M=$(resolve-devteam-model.sh acme-core)` stays clean. --explain prints the why.
#
# USAGE: resolve-devteam-model.sh [repo-name] [--explain]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_MODEL="opus"
REPO_NAME=""
EXPLAIN=0

for arg in "$@"; do
    case "$arg" in
        --explain) EXPLAIN=1 ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         [ -z "$REPO_NAME" ] && REPO_NAME="$arg" ;;
    esac
done

note() { [ "$EXPLAIN" -eq 1 ] && echo "resolve-devteam-model: $*" >&2; return 0; }

emit() {
    # in: _M (resolved value)
    if [ "$_M" = "inherit" ]; then
        note "inherit — no --model flag; the tab takes the machine-global default."
        note "  That default is whatever /model last saved, in ANY window. See"
        note "  docs/memos/2026-09-03-rca-handoff-model-inheritance.md."
        echo ""
    else
        echo "$_M"
    fi
    exit 0
}

# ─── 1. env var ──────────────────────────────────────────────────────────────
if [ -n "${DEVTEAM_MODEL:-}" ]; then
    _M="${DEVTEAM_MODEL}"
    note "DEVTEAM_MODEL env var = '$_M' (per-invocation override)"
    emit
fi

# ─── 2. .cto/devteam-model ───────────────────────────────────────────────────
# Resolve the CTO home the same way every other CTO script does.
CONF=""
if [ -f "$HERE/_cto-home-anchor.sh" ]; then
    # shellcheck disable=SC1090
    . "$HERE/_cto-home-anchor.sh" 2>/dev/null || true
fi
for _base in "${ROOT:-}" "$(cd "$HERE/../.." && pwd)"; do
    [ -n "$_base" ] || continue
    if [ -f "$_base/.cto/devteam-model" ]; then CONF="$_base/.cto/devteam-model"; break; fi
done

if [ -n "$CONF" ]; then
    FILE_DEFAULT=""
    REPO_OVERRIDE=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -z "$line" ] && continue
        case "$line" in
            *=*)
                _k="${line%%=*}"; _v="${line#*=}"
                [ -n "$REPO_NAME" ] && [ "$_k" = "$REPO_NAME" ] && REPO_OVERRIDE="$_v"
                ;;
            *)  [ -z "$FILE_DEFAULT" ] && FILE_DEFAULT="$line" ;;
        esac
    done < "$CONF"

    if [ -n "$REPO_OVERRIDE" ]; then
        _M="$REPO_OVERRIDE"
        note "$CONF: per-repo override for '$REPO_NAME' = '$_M'"
        emit
    fi
    if [ -n "$FILE_DEFAULT" ]; then
        _M="$FILE_DEFAULT"
        note "$CONF: fleet default = '$_M'"
        emit
    fi
    note "$CONF exists but sets no default — falling through"
else
    note "no .cto/devteam-model file — falling through"
fi

# ─── 3. built-in default ─────────────────────────────────────────────────────
_M="$DEFAULT_MODEL"
note "built-in default = '$_M' (alias; tracks the latest Opus)"
emit
