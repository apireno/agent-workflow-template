#!/bin/bash
# check-fleet-model.sh — which model is each session ACTUALLY running, and does
# anything in this repo pin one?
#
# Background (RCA 2026-09-03): dev-team tabs launched by /handoff inherit the
# machine-global model default. Claude Code's /model picker writes that default
# ("saved as your default for new sessions"), so a model chosen once in the CTO
# window silently becomes the model every subsequently launched dev tab runs on.
# No script in this repo sets a model — which is exactly why nothing caught it.
#
# Two modes:
#   --audit     static: assert no launch site pins a model (no --model, no
#               ANTHROPIC_MODEL, no "model" key in any settings.json we ship)
#   (default)   observed: read the model each tracked session actually ran on,
#               straight out of its JSONL transcript. Configuration can lie;
#               the transcript cannot.
#
# Exit codes:
#   0 — no drift, no pinning
#   3 — drift detected (a session ran on a model that does not match
#       CTO_EXPECTED_MODEL, default: opus) or a launch site pins a model
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# What SHOULD a session be on? The configured dev-tab pin, reduced to its family
# word so an alias ('opus') and a full name ('claude-opus-5[1m]') both match the
# 'claude-opus-5' a transcript records. CTO_EXPECTED_MODEL overrides; 'opus' is the
# floor when nothing is configured.
EXPECTED="${CTO_EXPECTED_MODEL:-}"
EXPECTED_IS_ASSUMED=0
if [ -z "$EXPECTED" ]; then
    _PIN="$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-devteam-model.sh" 2>/dev/null)"
    case "$_PIN" in
        ""|default)
            # `default` resolves at launch to whatever Anthropic currently defaults to,
            # and `inherit` to whatever /model last saved — neither is knowable from
            # here, so the family word is an ASSUMPTION, flagged as one. Override with
            # CTO_EXPECTED_MODEL when the account default moves off Opus.
            EXPECTED="opus"; EXPECTED_IS_ASSUMED=1 ;;
        *)  EXPECTED="$(printf '%s' "$_PIN" | sed -E 's/^claude-//; s/-[0-9].*$//; s/\[.*//')" ;;
    esac
    [ -z "$EXPECTED" ] && { EXPECTED="opus"; EXPECTED_IS_ASSUMED=1; }
fi
MODE="observed"
DAYS="${CTO_MODEL_SCAN_DAYS:-7}"

for arg in "$@"; do
    case "$arg" in
        --audit)   MODE="audit" ;;
        --days=*)  DAYS="${arg#--days=}" ;;
        --expect=*) EXPECTED="${arg#--expect=}" ;;
        -h|--help)
            sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    esac
done

FAIL=0

# ─── audit: is the pin explicit and traceable, or hardcoded? ─────────────────
# Pinning is now CORRECT (RCA 2026-09-03): a launcher that passes no model inherits
# whatever /model last saved globally. What must never appear is a model name
# hardcoded at a launch site — that is a second invisible source of truth, and it
# ages into a retired model without anyone editing the line. Every pin resolves
# through resolve-devteam-model.sh, so the audit checks the SHAPE of the pin.
audit() {
    echo "== static audit: how launch sites choose a model =="
    local hits=0

    # A hardcoded model at a launch site: --model followed by a literal rather than
    # a shell variable, or a model env var assigned a literal.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "  HARDCODED  $line"
        hits=$((hits + 1))
    done < <(grep -rnE -- "--model[= ]+[\"']?(claude-|opus|sonnet|haiku|fable)|ANTHROPIC_MODEL=[^\"']*[a-z]" \
                 "$ROOT/scripts" "$ROOT/.claude" 2>/dev/null \
             | grep -v '/check-fleet-model\.sh:' \
             | grep -v '/resolve-devteam-model\.sh:' \
             | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')

    # A "model" key in a settings file we ship: silent, per-repo, and invisible at
    # the launch line. Config that decides cost must be visible where the cost is
    # incurred.
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if grep -qE '^[[:space:]]*"model"[[:space:]]*:' "$f" 2>/dev/null; then
            echo "  HARDCODED  $f  (\"model\" key in a shipped settings file)"
            hits=$((hits + 1))
        fi
    done < <(find "$ROOT/.claude" -maxdepth 1 -name 'settings*.json*' -type f 2>/dev/null)

    if [ "$hits" -eq 0 ]; then
        echo "  clean — no hardcoded model at any launch site."
    else
        FAIL=1
    fi

    # What WILL the next handoff pass? Resolve it and say so; a pin nobody can read
    # off is only marginally better than no pin.
    if [ -x "$HERE/resolve-devteam-model.sh" ]; then
        local resolved
        resolved="$("$HERE/resolve-devteam-model.sh" 2>/dev/null)"
        if [ -n "$resolved" ]; then
            echo "  dev-tab pin: --model '$resolved'   (resolve-devteam-model.sh)"
        else
            echo "  dev-tab pin: NONE — orchestrated tabs inherit the machine-global default"
            echo "               that /model writes in any window — which is NOT the account"
            echo "               default once anyone has run /model. To track Anthropic's"
            echo "               default AND stay isolated from /model:"
            echo "                   echo default > <cto-home>/.cto/devteam-model"
        fi
    fi
    echo ""
}

# ─── observed: what did each session actually run on? ────────────────────────
observed() {
    echo "== observed: model per session (last ${DAYS}d, from JSONL transcripts) =="
    if [ "$EXPECTED_IS_ASSUMED" -eq 1 ]; then
        echo "  (expecting '${EXPECTED}' — ASSUMED, since the pin resolves at launch rather"
        echo "   than here. Set CTO_EXPECTED_MODEL if the account default moves families.)"
    fi
    printf "  %-28s %-10s %-22s %-22s\n" REPO AGE FIRST-MSG-MODEL LAST-MSG-MODEL
    printf "  %-28s %-10s %-22s %-22s\n" "----" "---" "---------------" "--------------"
    local drift
    drift="$(python3 - "$DAYS" "$EXPECTED" <<'PY'
import os, glob, json, sys, time
days, expected = float(sys.argv[1]), sys.argv[2]
cutoff = time.time() - days * 86400
rows, drift = [], 0
for d in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*"))):
    files = [f for f in glob.glob(os.path.join(d, "*.jsonl")) if os.stat(f).st_mtime >= cutoff]
    if not files:
        continue
    f = max(files, key=lambda p: os.stat(p).st_mtime)
    first = last = None
    with open(f, errors="ignore") as fh:
        for line in fh:
            if '"model"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            msg = o.get("message")
            m = msg.get("model") if isinstance(msg, dict) else None
            if not m or m == "<synthetic>":
                continue
            first = first or m
            last = m
    if not first:
        continue
    repo = os.path.basename(d).replace("-Users-apireno-repos-", "").lstrip("-")
    age = int((time.time() - os.stat(f).st_mtime) / 3600)
    age = f"{age}h" if age < 48 else f"{age // 24}d"
    flag = "" if expected in (last or "") else "  <-- DRIFT"
    if flag:
        drift += 1
    rows.append(f"  {repo:<28.28} {age:<10} {first:<22} {last:<22}{flag}")
print("\n".join(rows))
print("DRIFT_COUNT=%d" % drift, file=sys.stderr)
PY
)"
    echo "$drift"
    echo ""
}

case "$MODE" in
    audit) audit ;;
    *)     audit
           DRIFT_OUT="$(observed 2>&1)"
           echo "$DRIFT_OUT" | grep -v '^DRIFT_COUNT='
           if echo "$DRIFT_OUT" | grep -q 'DRIFT'; then
               echo "DRIFT: a session ran on a model not matching '${EXPECTED}'."
               echo "  Orchestrated windows (/handoff, /resume-dev-team, qa-drive) are pinned at"
               echo "  launch, so drift there means one of three things: the session predates the"
               echo "  pin, it was launched by hand rather than by a launcher, or /model was run"
               echo "  INSIDE it. A session launched by hand inherits the machine-global default"
               echo "  that /model saves from any window — the pin cannot reach it."
               echo "  Fix: run /model in the affected window (a running session keeps the model"
               echo "  it started on), or close it and re-launch through the launcher."
               FAIL=1
           fi
           ;;
esac

if [ "$FAIL" -ne 0 ]; then
    exit 3
fi
echo "fleet model: ok — pin is resolved not hardcoded, no observed drift from '${EXPECTED}'."
exit 0
