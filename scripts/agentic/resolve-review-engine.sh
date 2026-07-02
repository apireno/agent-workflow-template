#!/usr/bin/env bash
# resolve-review-engine.sh — SINGLE SOURCE OF TRUTH for which engine runs a review /
# fan-out / ideation pass. Every review-ish skill + script resolves through this so the
# choice is consistent and configurable for any vendor eventuality (CEO 2026-06-19:
# "we shouldn't need a replacement for gemini ... just another choice that needs to be set
# by the cto or vp or dev persona ... the companies will continue to change their mind").
#
# PRECEDENCE (highest wins):
#   1. REVIEW_ENGINE env var        (per-invocation, per-persona)
#   2. <repo>/.review-engine file   (per-repo default)
#   3. built-in default = subagent  (bright-line clean, in-session)
#
# ENGINE MENU:
#   gemini    — `cat <prompt> | gemini` CLI fan-out. $0. Self-contained (the calling
#               script runs it inline). NOTE: gemini-CLI free tier was deprecated by
#               Google 2026-06-19 (UNSUPPORTED_CLIENT); selectable again whenever access
#               returns (paid tier / Antigravity-compatible client / different account).
#   kimi      — OpenRouter chat API via `openrouter-chat.sh` (default model
#               moonshotai/kimi-k2.6; override with OPENROUTER_MODEL — any OpenRouter slug,
#               so deepseek/qwen panels ride the same executor). Metered but NON-Anthropic
#               (pennies per review) — bright-line clean. The cross-FAMILY independent
#               reviewer now that gemini-CLI is gone; also the fallback when Claude
#               subscription limits are hit mid-sprint. Requires OPENROUTER_API_KEY.
#   codex     — ⚠️ UNTESTED (2026-07-02, no live `codex` install to verify against — built from
#               OpenAI's published docs only, see codex-exec.sh header for specifics). OpenAI
#               Codex CLI's non-interactive `codex exec` mode via `codex-exec.sh`. A SECOND
#               independent cross-family reviewer alongside kimi (GPT-family vs. Moonshot-family
#               vs. Claude — three genuinely different training lineages). Metered on OpenAI's
#               side (API key) or draws on a ChatGPT subscription's included usage — bright-line
#               clean either way (not Anthropic). Requires the `codex` CLI installed; treat the
#               first real invocation as a smoke test.
#   subagent  — the persona review runs via the Claude Code **Agent tool**, IN-SESSION.
#               Subscription pool (NOT the metered Agent-SDK pool). A skill's bash body
#               CANNOT spawn a subagent, so scripts emit the `DISPATCH=subagent` sentinel
#               and the ORCHESTRATOR (CTO/main loop) fans the Agent calls. DEFAULT.
#   handoff   — the persona review runs in an interactive Claude **window** (/handoff
#               machinery). Subscription pool. Scripts emit `DISPATCH=handoff`; the
#               skill/orchestrator launches the window(s).
#   claude-p  — `claude -p --max-turns 1`. ⚠️ METERED ANTHROPIC API (Agent-SDK credit pool,
#               post-2026-06-15). BRIGHT-LINE: never a default, never auto-selected; runs
#               ONLY on an explicit, eyes-open opt-in (REVIEW_ENGINE=claude-p AND
#               REVIEW_ALLOW_METERED=1). Kept on the menu only as a break-glass escape hatch.
#
# LEGACY ALIASES (old .review-engine / REVIEW_ENGINE values are remapped, with a stderr note):
#   claude -> claude-p   (the old "claude" always meant claude -p)
#   dual   -> gemini     (dual fired gemini + claude -p; the claude-p half is now quarantined)
#   none   -> subagent   (old "no CLI found" sentinel; subagent needs no external CLI)
#
# OUTPUT: the resolved engine name on stdout (one word). Diagnostics go to stderr so
# `ENGINE=$(resolve-review-engine.sh)` stays clean. `--explain` prints the why to stderr.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
EXPLAIN=0
[ "${1:-}" = "--explain" ] && EXPLAIN=1

note() { [ "$EXPLAIN" -eq 1 ] && echo "resolve-review-engine: $*" >&2; return 0; }

raw=""
src=""
if [ -n "${REVIEW_ENGINE:-}" ]; then
  raw="$REVIEW_ENGINE"; src="REVIEW_ENGINE env"
elif [ -f "$REPO_ROOT/.review-engine" ]; then
  raw="$(tr -d '[:space:]' < "$REPO_ROOT/.review-engine")"; src="$REPO_ROOT/.review-engine"
else
  raw="subagent"; src="built-in default"
fi

# normalize + alias
engine="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
case "$engine" in
  claude)        note "alias: 'claude' -> 'claude-p' (the old value always meant claude -p)"; engine="claude-p" ;;
  dual)          note "alias: 'dual' -> 'gemini' (claude-p half quarantined)"; engine="gemini" ;;
  none|"")       note "alias: '${engine:-empty}' -> 'subagent'"; engine="subagent" ;;
  gemini|kimi|codex|subagent|handoff|claude-p) : ;;
  *)             note "unknown engine '$engine' from $src -> falling back to 'subagent'"; engine="subagent" ;;
esac

note "resolved '$engine' (from $src; raw='$raw')"

# claude-p quarantine: selectable, but never silently. Refuse unless the operator
# explicitly opted into metered API for THIS invocation.
if [ "$engine" = "claude-p" ] && [ "${REVIEW_ALLOW_METERED:-0}" != "1" ]; then
  echo "ERROR: engine 'claude-p' is the METERED Anthropic API path (bright-line). It runs ONLY with" >&2
  echo "  REVIEW_ALLOW_METERED=1 set explicitly for this invocation. Refusing. Pick kimi|codex|gemini|subagent|handoff," >&2
  echo "  or re-run with REVIEW_ALLOW_METERED=1 if you truly intend to spend API credit." >&2
  echo "claude-p-blocked"
  exit 3
fi

echo "$engine"
