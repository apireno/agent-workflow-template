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
#     is an error. So the prompt is passed as an argument (macOS ARG_MAX is 1 MiB, but see the
#     TRUNCATION guard below: agy itself keeps far less than that).
#   - `--model gemini-3.1-pro-low -p='Reply with exactly OK'` -> "OK" in ~14s, nothing written
#     to the working directory. (That smoke test could not have caught the RCA below: a prompt
#     that invites no tool never calls one.)
#
# RCA 2026-10-12 (docs/rca/2026-10-12-agy-empty-completions.md). ~28% of agy reviews came back
# EMPTY: agy is an agent, and review prompts invite tool use (the persona says "read …", the
# artifact quotes file paths), so the model calls `read_file` or a shell `command`. Headless print
# mode cannot prompt for that permission, auto-denies it, and the denial ABORTS the whole turn —
# "jetski: no output produced". Prompt-dependent, not size- or version-dependent: the same prompt
# failed 6/6 in plan mode, default mode, and plan+slash-disabled; with the NO_TOOLS preamble below
# it returned a full verdict 2/2, then 6/6 through vp-review.sh on three other dev-reports whose
# lanes had logged the failure (vp-eng + vp-prod each, 46-116 s). Separately, `--mode plan` was a
# no-op all along: agy ignores it when slash commands are disabled ("--mode plan has no effect
# while slash command expansion is disabled"), so it was never a guard and is no longer passed.
#
# GUARDS (why each exists):
#   - NO_TOOLS PREAMBLE, first in every prompt. Everything a review needs is inline; telling the
#     model so is what stops the tool call that aborts the turn. It also means no prompt can begin
#     with "/", so it can never be read as a slash command.
#   - EMPTY SCRATCH CWD. agy is an agent with tools; a review must not read or write the repo.
#     It runs in a fresh temp dir and never with --dangerously-skip-permissions, so any tool call
#     is denied rather than run. Any file that appears there afterwards is reported on stderr.
#   - --disable-slash-commands. Review prompts quote skill names (/vp-review, /handoff); in
#     print mode those would otherwise be EXPANDED as commands rather than read as text.
#   - TOOL-DENIED is named. If the model still reaches for a tool, the failure says so (exit 3)
#     with the tool's name, instead of reading as a generic empty answer.
#   - GEMINI ONLY. agy's menu includes Claude models. A "cross-family" review that silently ran
#     on Claude is the shared-method bias this engine exists to avoid, so a non-gemini model is
#     refused unless AGY_ALLOW_NON_GEMINI=1.
#   - EMPTY ANSWER = FAILURE (exit 3). An empty verdict must never read as a review that ran.
#   - TRUNCATION (kgspin-tuner BUG-717, 2026-10-20). agy delivers only the first 191,392 bytes of
#     a prompt to the model and drops the rest SILENTLY (rc 0, status SUCCESS), whether the prompt
#     goes in as `-p=` or on stdin. A review over that size is a verdict on a truncated artifact
#     that reads as a full one. So the whole prompt agy would receive (preamble + stdin) is
#     measured BEFORE agy is touched, and anything over AGY_PROMPT_MAX_BYTES (95 % of the probed
#     ceiling) is refused, exit 2, nothing on stdout. Remedies: shorten the artifact, review it
#     on kimi (REVIEW_ENGINE=kimi / --engine kimi), or split it.
#
# MODEL — resolved at CALL TIME from `agy models`, never hard-coded (2026-10-19). agy auto-updates
# and Google retires model ids under it: the first default here, gemini-3.1-pro-high, vanished
# within a week and every lane review failed until someone edited this file. Now:
#   AGY_MODEL unset  -> the best Gemini offered right now: non-Flash before Flash, then -high >
#                       -medium > -low, then the highest version number. Printed on stderr.
#   AGY_MODEL=a,b,c  -> the first of these that is offered; none offered -> exit 2 listing what IS.
#   The list is cached for an hour ($TMPDIR/agy-models.cache) so a review fan-out costs one lookup.
#
# ENV: AGY_MODEL (unset = auto; or a comma preference list) · AGY_TIMEOUT seconds
#      (default 600) · AGY_BIN (default agy) · AGY_ALLOW_NON_GEMINI=1
# Exit: 0 ok · 2 usage/config · 3 empty or failed completion · agy's own code otherwise
set -uo pipefail

AGY_BIN="${AGY_BIN:-agy}"
MODEL_PREF="${AGY_MODEL:-}"
TIMEOUT_S="${AGY_TIMEOUT:-600}"
# agy's measured silent-truncation ceiling (kgspin-tuner BUG-717 probe, 2026-10-20: the model saw
# exactly the first 191,392 bytes of every larger prompt, via -p= and via stdin alike). The refusal
# limit is 95 % of it, so the guard never sits on the edge of a ceiling that may move with agy.
AGY_TRUNCATION_CEILING_BYTES=191392
AGY_PROMPT_MAX_BYTES=181822

command -v "$AGY_BIN" >/dev/null 2>&1 || { echo "agy-exec: '$AGY_BIN' not on PATH (install Antigravity's CLI, or set AGY_BIN)." >&2; exit 2; }

# ── read the prompt and refuse oversize BEFORE agy is touched (BUG-717) ──────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agy-exec.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/.prompt"
BYTES=$(wc -c < "$WORK/.prompt" | tr -d ' ')
[ "$BYTES" -gt 0 ] || { echo "agy-exec: empty prompt on stdin." >&2; exit 2; }
NO_TOOLS='IMPORTANT: Everything you need is in this message. Do not call any tools, do not run commands, do not read files. Reply with the review as plain markdown text only.

'
SENT_BYTES=$(( BYTES + $(printf '%s' "$NO_TOOLS" | wc -c | tr -d ' ') ))
if [ "$SENT_BYTES" -gt "$AGY_PROMPT_MAX_BYTES" ]; then
    {
        echo "agy-exec: PROMPT-TOO-LARGE — refused, agy not called, no review written."
        echo "  prompt bytes: $SENT_BYTES (stdin $BYTES + no-tools preamble); limit: $AGY_PROMPT_MAX_BYTES (95 % of $AGY_TRUNCATION_CEILING_BYTES)."
        echo "  agy truncates silently above 191,392 bytes (kgspin-tuner BUG-717, 2026-10-20): the model would"
        echo "  judge only the first part of the artifact and the verdict would read as a full review."
        echo "  Remedies: shorten the artifact; route the review to kimi (--engine kimi, or REVIEW_ENGINE=kimi);"
        echo "  or split the artifact and review the parts."
    } >&2
    exit 2
fi
PROMPT="${NO_TOOLS}$(cat "$WORK/.prompt")"; rm -f "$WORK/.prompt"

# ── resolve the model from what agy offers NOW ──────────────────────────────────────────────
CACHE="${TMPDIR:-/tmp}/agy-models.cache"
if [ ! -s "$CACHE" ] || [ -n "$(find "$CACHE" -mmin +60 2>/dev/null)" ] || [ "${AGY_MODELS_NOCACHE:-0}" = "1" ]; then
    "$AGY_BIN" models 2>/dev/null | awk '/^[a-z0-9][a-z0-9.-]*[ \t]/{print $1}' > "$CACHE.tmp" && [ -s "$CACHE.tmp" ] && mv "$CACHE.tmp" "$CACHE"
    rm -f "$CACHE.tmp"
fi
[ -s "$CACHE" ] || { echo "agy-exec: could not list models (\`$AGY_BIN models\` returned nothing — signed in?)." >&2; exit 2; }
MODEL="$(python3 - "$CACHE" "$MODEL_PREF" <<'PYM'
import re, sys
offered=[l.strip() for l in open(sys.argv[1]) if l.strip()]
pref=[m.strip() for m in sys.argv[2].split(",") if m.strip()]
if pref:
    hit=next((m for m in pref if m in offered), "")
    print(hit); sys.exit(0)
def key(m):
    eff={"high":3,"medium":2,"low":1}.get(m.rsplit("-",1)[-1],0)
    ver=tuple(int(x) for x in re.findall(r"\d+", m.split("-")[1] if len(m.split("-"))>1 else "0")) or (0,)
    return ("flash" not in m, eff, ver)
gem=sorted((m for m in offered if m.startswith("gemini-")), key=key, reverse=True)
print(gem[0] if gem else "")
PYM
)"
if [ -z "$MODEL" ]; then
    echo "agy-exec: no usable model. Asked for: ${MODEL_PREF:-auto (best Gemini)}. agy offers now:" >&2
    grep '^gemini-' "$CACHE" | sed 's/^/  /' >&2
    exit 2
fi
[ -z "$MODEL_PREF" ] && echo "agy-exec: auto-selected $MODEL from \`agy models\`" >&2
case "$MODEL" in
    gemini-*) : ;;
    *) [ "${AGY_ALLOW_NON_GEMINI:-0}" = "1" ] || { echo "agy-exec: model '$MODEL' is not a Gemini model. This engine is the Gemini cross-family reviewer; set AGY_ALLOW_NON_GEMINI=1 to override on purpose." >&2; exit 2; } ;;
esac

mkdir -p "$WORK/cwd"

START=$(date +%s)
( cd "$WORK/cwd" && "$AGY_BIN" --model "$MODEL" --disable-slash-commands \
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
if [ "$OUTB" -eq 0 ] && grep -q 'no output produced' "$WORK/err"; then
    TOOL="$(grep -oE 'required the "[^"]+"' "$WORK/err" | head -1 | sed 's/required the //')"
    echo "agy-exec: TOOL-DENIED — the model called a tool (${TOOL:-unknown}) despite the no-tools preamble;" >&2
    echo "  headless mode auto-denied it and agy aborted the turn with no output. This is a failed" >&2
    echo "  review, not an empty one. Re-run on another engine (REVIEW_ENGINE=kimi) and report the" >&2
    echo "  prompt if it recurs. See docs/rca/2026-10-12-agy-empty-completions.md." >&2
    exit 3
fi
if [ "$OUTB" -eq 0 ] || ! grep -q '[^[:space:]]' "$WORK/out"; then
    echo "agy-exec: empty completion (exit 0, no text). Treating as a failed review." >&2
    tail -20 "$WORK/err" >&2
    exit 3
fi
cat "$WORK/out"
