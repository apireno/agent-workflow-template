#!/usr/bin/env bash
# codex-exec.sh — stdin prompt -> stdout completion via OpenAI Codex CLI's non-interactive
# `codex exec` mode. The CLI-shaped executor behind the `codex` review engine.
#
# ⚠️ UNTESTED (2026-07-02): built from OpenAI's published docs (developers.openai.com/codex/*),
# NOT verified against a live `codex` install — none was available on the machine this was
# authored on. Treat the FIRST real invocation as a smoke test, not a working feature. If it
# fails, check: (a) `codex --version` actually exists and matches the flags used below (Codex
# CLI has churned these — `--full-auto` is already noted as deprecated-but-kept upstream), (b)
# auth (see below), (c) whether `codex exec -` really prints ONLY the final message to stdout on
# your installed version, as docs describe, vs. also leaking progress/JSON there.
#
# Same stdin->stdout contract as openrouter-chat.sh / the old gemini CLI, so every engine
# dispatch site treats it identically: `cat prompt | codex-exec.sh > out`.
#
# Auth: `codex exec` supports both ChatGPT OAuth login (subscription) and API-key auth. For
# unattended automation like this, OpenAI's own docs recommend API-key auth scoped per-run —
# CODEX_API_KEY (preferred) or OPENAI_API_KEY (fallback). If neither is set, this script still
# attempts the call in case a prior `codex login` OAuth session is active locally; it does not
# hard-require a key.
#
# Sandbox/approval: deliberately left at Codex's default READ-ONLY sandbox (no --sandbox flag —
# a review task should never write files; this mirrors the same review-mode-only constraint the
# gemini/kimi/claude-p engines enforce via prompt). `--ask-for-approval never` is passed so a
# headless run can't stall waiting on an interactive approval prompt.
#
# env:
#   CODEX_API_KEY / OPENAI_API_KEY   optional; unattended API-key auth (see above)
#   CODEX_EXEC_TIMEOUT               seconds, default 600 (uses gtimeout/timeout if present)
#
# stdout: the completion text only. stderr: Codex's own progress stream + diagnostics.
# Non-zero exit on missing `codex` binary, command failure, or empty output.

set -uo pipefail

if ! command -v codex >/dev/null 2>&1; then
    echo "codex-exec: 'codex' CLI not found in PATH. Install: https://developers.openai.com/codex/cli" >&2
    exit 1
fi

PROMPT="$(cat)"
if [ -z "${PROMPT// }" ]; then
    echo "codex-exec: empty prompt on stdin" >&2
    exit 1
fi

TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
[ -z "$TIMEOUT_BIN" ] && command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
TIMEOUT_SEC="${CODEX_EXEC_TIMEOUT:-600}"

OUT="$(mktemp)"
ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT

if [ -n "$TIMEOUT_BIN" ]; then
    printf '%s' "$PROMPT" | "$TIMEOUT_BIN" "$TIMEOUT_SEC" codex exec --ask-for-approval never - > "$OUT" 2>"$ERR"
else
    printf '%s' "$PROMPT" | codex exec --ask-for-approval never - > "$OUT" 2>"$ERR"
fi
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "codex-exec: 'codex exec' exited with code $RC" >&2
    [ -s "$ERR" ] && { echo "codex-exec: stderr tail:" >&2; tail -20 "$ERR" >&2; }
    exit 1
fi

if [ ! -s "$OUT" ]; then
    echo "codex-exec: empty completion. stderr tail:" >&2
    tail -20 "$ERR" >&2
    exit 1
fi

cat "$OUT"
echo "codex-exec: done (see stderr above for codex's own progress stream, if any)" >&2
