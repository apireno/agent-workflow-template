#!/usr/bin/env bash
# agy-exec.sh — stdin prompt -> stdout completion via Google Antigravity's CLI (`agy`) in print
# mode. The CLI-shaped executor behind the `agy` review engine: same stdin->stdout contract as
# openrouter-chat.sh and codex-exec.sh, so every dispatch site treats it identically:
#     cat prompt | agy-exec.sh > out
#
# WHY. The Gemini CLI died for this plan on 2026-06-19 (UNSUPPORTED_CLIENT); Antigravity's own CLI
# works. It runs on the Antigravity plan's quota, not per-token OpenRouter credit — and on
# 2026-10-07 the review engine was most of a ~$30/month OpenRouter bill (kimi K2.6 averages ~10k
# output tokens per review). A Gemini reviewer is also a second cross-family opinion beside kimi.
#
# VERIFIED 2026-10-07 against agy 1.3.1:
#   - `-p` takes the prompt as its VALUE (`-p='…'`); it does NOT read stdin, and a bare `-p`
#     is an error. So the prompt is passed as an argument (macOS ARG_MAX is 1 MiB; refused
#     above PROMPT_MAX_BYTES with a clear message rather than an opaque exec failure).
#   - `--model gemini-3.1-pro-low --mode plan -p='Reply with exactly OK'` -> "OK" in ~14s,
#     nothing written to the working directory.
#
# GUARDS (why each exists):
#   - EMPTY SCRATCH CWD. agy is an agent with tools; a review must not read or write the repo.
#     It runs in a fresh temp dir, in `--mode plan`, never with --dangerously-skip-permissions.
#     Any file that appears there afterwards is reported on stderr (a tool ran that shouldn't).
#   - --disable-slash-commands. Review prompts quote skill names (/vp-review, /handoff); in
#     print mode those would otherwise be EXPANDED as commands rather than read as text.
#   - GEMINI ONLY. agy's menu includes Claude models. A "cross-family" review that silently ran
#     on Claude is the shared-method bias this engine exists to avoid, so a non-gemini model is
#     refused unless AGY_ALLOW_NON_GEMINI=1.
#   - EMPTY ANSWER = FAILURE (exit 3). An empty verdict must never read as a review that ran.
#
# ENV: AGY_MODEL (default gemini-3.1-pro-high; `agy models` lists them) · AGY_TIMEOUT seconds
#      (default 600) · AGY_BIN (default agy) · AGY_ALLOW_NON_GEMINI=1
# Exit: 0 ok · 2 usage/config · 3 empty or failed completion · agy's own code otherwise
set -uo pipefail

AGY_BIN="${AGY_BIN:-agy}"
MODEL="${AGY_MODEL:-gemini-3.1-pro-high}"
TIMEOUT_S="${AGY_TIMEOUT:-600}"
PROMPT_MAX_BYTES=900000

command -v "$AGY_BIN" >/dev/null 2>&1 || { echo "agy-exec: '$AGY_BIN' not on PATH (install Antigravity's CLI, or set AGY_BIN)." >&2; exit 2; }
case "$MODEL" in
    gemini-*) : ;;
    *) [ "${AGY_ALLOW_NON_GEMINI:-0}" = "1" ] || { echo "agy-exec: model '$MODEL' is not a Gemini model. This engine is the Gemini cross-family reviewer; set AGY_ALLOW_NON_GEMINI=1 to override on purpose." >&2; exit 2; } ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agy-exec.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/.prompt"
BYTES=$(wc -c < "$WORK/.prompt" | tr -d ' ')
[ "$BYTES" -gt 0 ] || { echo "agy-exec: empty prompt on stdin." >&2; exit 2; }
[ "$BYTES" -le "$PROMPT_MAX_BYTES" ] || { echo "agy-exec: prompt is $BYTES bytes; agy takes it as an argument and the limit here is $PROMPT_MAX_BYTES. Trim the artifact." >&2; exit 2; }
PROMPT="$(cat "$WORK/.prompt")"; rm -f "$WORK/.prompt"
mkdir -p "$WORK/cwd"

START=$(date +%s)
( cd "$WORK/cwd" && "$AGY_BIN" --model "$MODEL" --mode plan --disable-slash-commands \
      --print-timeout "${TIMEOUT_S}s" -p="$PROMPT" ) > "$WORK/out" 2> "$WORK/err"
RC=$?
SECS=$(( $(date +%s) - START ))
OUTB=$(wc -c < "$WORK/out" | tr -d ' ')
echo "agy-exec: model=$MODEL seconds=$SECS bytes_in=$BYTES bytes_out=$OUTB rc=$RC" >&2
if [ -n "$(ls -A "$WORK/cwd" 2>/dev/null)" ]; then
    echo "agy-exec: WARNING — the session created files in its scratch dir (a tool ran in plan mode):" >&2
    ls -A "$WORK/cwd" | head -10 | sed 's/^/  /' >&2
fi
if [ "$RC" -ne 0 ]; then
    tail -20 "$WORK/err" >&2
    exit "$RC"
fi
if [ "$OUTB" -eq 0 ] || ! grep -q '[^[:space:]]' "$WORK/out"; then
    echo "agy-exec: empty completion (exit 0, no text). Treating as a failed review." >&2
    tail -20 "$WORK/err" >&2
    exit 3
fi
cat "$WORK/out"
