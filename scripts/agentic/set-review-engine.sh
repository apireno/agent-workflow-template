#!/usr/bin/env bash
# set-review-engine.sh — the WRITER counterpart to resolve-review-engine.sh.
#
# resolve-review-engine.sh answers "which engine runs this review?". This one SETS it, with
# validation, so no caller hand-rolls `printf '<engine>\n' > .review-engine` again. Every
# such open-coded write in this template drifted at least once: one seeded a dead engine
# (`gemini`), two wrote to `.claude/.review-engine`, a path the resolver never reads.
#
#   set-review-engine.sh --menu                  # print the selectable menu (one per line:
#                                                #   name<TAB>cost<TAB>one-line description)
#   set-review-engine.sh --fleet-default         # print the default a new repo should get
#   set-review-engine.sh <repo-path> <engine>    # validate, then write <repo-path>/.review-engine
#
# SELECTABLE vs RESOLVABLE. The resolver still understands `gemini` and `claude-p` so old
# values degrade predictably; neither may be CHOSEN here. gemini has no CLI access on this
# plan (2026-06-19) and claude-p is the metered Anthropic path behind REVIEW_ALLOW_METERED.
# A setup flow must never offer an engine that cannot run.
#
# FLEET DEFAULT. A project picks its engine once, at project start, the same way it picks a
# permissions posture. That choice lives in the CTO home's own `.review-engine` and is what
# `--fleet-default` reports, so push-to-repos.sh seeds and heals dev repos to the project's
# choice instead of a hardcoded constant. Override for one invocation with FLEET_REVIEW_ENGINE.

set -uo pipefail

SELECTABLE="subagent kimi codex handoff"

print_menu() {
    printf 'subagent\t$0\tClaude Code Agent tool, in-session. Subscription pool, no API key, no external CLI. Same-family: Claude reviewing Claude.\n'
    printf 'kimi\t~pennies\tOpenRouter (moonshotai/kimi-k2.6). Cross-FAMILY independent reviewer — the strongest accept-gate. Metered but non-Anthropic. Needs OPENROUTER_API_KEY.\n'
    printf 'codex\t~pennies\tOpenAI Codex CLI (codex exec). A second cross-family reviewer. UNTESTED — treat first run as a smoke test. Needs the codex CLI.\n'
    printf 'handoff\t$0\tReview runs in its own interactive Claude window. Subscription pool. Slowest; use when a review needs tools.\n'
}

fleet_default() {
    if [ -n "${FLEET_REVIEW_ENGINE:-}" ]; then printf '%s\n' "$FLEET_REVIEW_ENGINE"; return; fi
    # The CTO home is this script's own repo when run from a CTO home, else its parent's
    # <project>-cto. Read its choice; fall back to the bright-line-safe built-in.
    local home eng=""
    home="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    [ -f "$home/.review-engine" ] && eng="$(tr -d '[:space:]' < "$home/.review-engine" | tr '[:upper:]' '[:lower:]')"
    case " $SELECTABLE " in *" $eng "*) printf '%s\n' "$eng"; return ;; esac
    printf 'subagent\n'
}

case "${1:-}" in
    --menu)           print_menu; exit 0 ;;
    --fleet-default)  fleet_default; exit 0 ;;
    ''|-h|--help)
        echo "usage: set-review-engine.sh <repo-path> <engine>   (engines: $SELECTABLE)"
        echo "       set-review-engine.sh --menu | --fleet-default"
        exit 1 ;;
esac

REPO="$1"
ENGINE="$(printf '%s' "${2:?need an engine: $SELECTABLE}" | tr '[:upper:]' '[:lower:]')"
[ -d "$REPO" ] || { echo "ERROR: not a directory: $REPO" >&2; exit 1; }

case " $SELECTABLE " in
    *" $ENGINE "*) ;;
    *)
        case "$ENGINE" in
            gemini)   echo "ERROR: 'gemini' is UNAVAILABLE — no CLI access on this plan since 2026-06-19, API path unused." >&2 ;;
            claude-p|claude|dual)
                      echo "ERROR: '$ENGINE' is the metered Anthropic path (or an alias for it) and is quarantined." >&2 ;;
            *)        echo "ERROR: unknown engine '$ENGINE'." >&2 ;;
        esac
        echo "  Selectable: $SELECTABLE" >&2
        exit 1 ;;
esac

# Warn but do not refuse: a project may configure the engine before the key is in the shell.
if [ "$ENGINE" = "kimi" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "NOTE: OPENROUTER_API_KEY is not set in this shell — 'kimi' needs it at review time." >&2
fi
if [ "$ENGINE" = "codex" ] && ! command -v codex >/dev/null 2>&1; then
    echo "NOTE: the 'codex' CLI is not on PATH — 'codex' needs it at review time." >&2
fi

# Repo ROOT is the only location the resolver reads; a copy under .claude/ silently disagrees.
if [ -f "$REPO/.claude/.review-engine" ]; then
    echo "  removing unread $REPO/.claude/.review-engine (=$(tr -d '[:space:]' < "$REPO/.claude/.review-engine"))" >&2
    rm -f "$REPO/.claude/.review-engine"
fi

printf '%s\n' "$ENGINE" > "$REPO/.review-engine"
echo "review engine for $(basename "$REPO"): $ENGINE"
