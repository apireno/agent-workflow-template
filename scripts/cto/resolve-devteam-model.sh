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
#   3. built-in default = default     (the ACCOUNT default — see VALUES below)
#
# FILE FORMAT (.cto/devteam-model) — blank lines and #-comments ignored:
#   default                 <- bare line: the fleet default
#   acme-tuner=fable        <- optional per-repo override, one per line
#   acme-demo-app=sonnet
#
# VALUES, best first:
#
#   default  — RECOMMENDED, and the built-in. Passes `--model default`, which resolves
#              to the ACCOUNT default at launch: it follows Anthropic as they move it
#              (including context-window variants — today that is Opus 5 with 1M), and
#              because it is a CLI flag it is NOT the machine-global default a /model
#              pick rewrites. Tracking Anthropic and isolation from /model are usually
#              wanted together, and this is the only value that gives both.
#              Verified: `claude --model default` is accepted by the catalog, where
#              `--model bogus-model-xyz` warns; and a `/model default` on 2026-07-26
#              resolved to claude-opus-4-8[1m] while the SAVED default was Sonnet 5 —
#              i.e. it reads the account default, not the local one.
#
#   an alias — 'opus', 'sonnet', 'haiku', 'fable'. Use when the fleet should sit on a
#              specific family regardless of what Anthropic makes default. Tracks the
#              latest model OF THAT FAMILY, so it never stales, but it may not select
#              a context variant (plain `opus` is not the 1M build).
#
#   full name— 'claude-opus-5[1m]'. Only when you need one exact build. It silently
#              ages into a retired model with nobody editing the line; revisit each
#              model release.
#
#   inherit  — emit nothing; take the machine-global default. This is the
#              pre-2026-09-03 behaviour and it is NOT "the account default": the two
#              coincide only until someone runs /model, at which point the fleet
#              follows that pick. If what you want is "whatever Anthropic defaults
#              to", the value you want is `default`, not this. Kept as a deliberate,
#              on-the-record opt-out.
#
# OUTPUT: the model on stdout, or EMPTY for `inherit`. Diagnostics to stderr so
# `M=$(resolve-devteam-model.sh acme-core)` stays clean. --explain prints the why.
#
# TWO MORE MODES (model policy, 2026-09-25 — .cto/model-budget.yaml names `lane:` and `stretch:`):
#   --alias       print the Agent-tool alias (opus|sonnet|haiku|fable) for the resolved value,
#                 so skills pass `model:` on every subagent call instead of inheriting the
#                 PARENT's model. `default`/`inherit` map to the policy's `lane:` family,
#                 because the Agent tool has no "account default" value and omitting `model`
#                 is exactly the inheritance being removed.
#   --is-stretch  exit 0 if the resolved value is the policy's `stretch:` family, 1 if not.
#                 /handoff refuses a stretch pin unless the CEO passed --model= on that call.
#
# USAGE: resolve-devteam-model.sh [repo-name] [--explain | --alias | --is-stretch]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_MODEL="default"
REPO_NAME=""
EXPLAIN=0
MODE="value"

for arg in "$@"; do
    case "$arg" in
        --explain) EXPLAIN=1 ;;
        --alias)   MODE="alias" ;;
        --is-stretch) MODE="stretch" ;;
        -h|--help) sed -n '2,72p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         [ -z "$REPO_NAME" ] && REPO_NAME="$arg" ;;
    esac
done

note() { [ "$EXPLAIN" -eq 1 ] && echo "resolve-devteam-model: $*" >&2; return 0; }

policy() { # policy <lane|stretch> <fallback>: read .cto/model-budget.yaml beside the pin file
    local key="$1" fb="$2" base v=""
    for base in "${ROOT:-}" "$(cd "$HERE/../.." && pwd)"; do
        [ -n "$base" ] && [ -f "$base/.cto/model-budget.yaml" ] || continue
        v="$(sed -n "s/^$key:[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p" "$base/.cto/model-budget.yaml" | head -1)"
        break
    done
    printf '%s' "${v:-$fb}" | tr '[:upper:]' '[:lower:]'
}
family() { # family <value> -> opus|sonnet|haiku|fable|<value>
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *fable*) echo fable ;; *opus*) echo opus ;; *sonnet*) echo sonnet ;; *haiku*) echo haiku ;;
        *) printf '%s\n' "$1" ;;
    esac
}

emit() {
    # in: _M (resolved value)
    if [ "$MODE" = "alias" ]; then
        case "$_M" in
            ""|default|inherit) policy lane opus; echo; note "alias: '$_M' -> the policy's lane family" ;;
            *) family "$_M" ;;
        esac
        exit 0
    fi
    if [ "$MODE" = "stretch" ]; then
        case "$_M" in ""|default|inherit) exit 1 ;; esac
        [ "$(family "$_M")" = "$(policy stretch fable)" ] && exit 0 || exit 1
    fi
    if [ "$_M" = "inherit" ]; then
        note "inherit — no --model flag; the tab takes the machine-global default."
        note "  That default is whatever /model last saved, in ANY window — which is"
        note "  NOT the account default once anyone has run /model. If you set this to"
        note "  track Anthropic's default, the value you want is 'default', not 'inherit'."
        note "  See docs/memos/2026-09-03-rca-handoff-model-inheritance.md."
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
note "built-in default = '$_M' (the account default, resolved at launch)"
emit
