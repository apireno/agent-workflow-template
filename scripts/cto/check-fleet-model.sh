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
EXPECTED="${CTO_EXPECTED_MODEL:-opus}"
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

# ─── audit: does anything we ship pin a model? ───────────────────────────────
audit() {
    echo "== static audit: model pinning in launch sites =="
    local hits=0

    # 1. --model / -m flags on a claude launch, and model env vars
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "  PIN  $line"
        hits=$((hits + 1))
    done < <(grep -rnE -- '--model[ =]|ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|CLAUDE_MODEL' \
                 "$ROOT/scripts" "$ROOT/.claude" 2>/dev/null \
             | grep -v '/check-fleet-model\.sh:')

    # 2. a "model" key in any settings file this repo ships to the fleet
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if grep -qE '^[[:space:]]*"model"[[:space:]]*:' "$f" 2>/dev/null; then
            echo "  PIN  $f  (\"model\" key in a shipped settings file)"
            hits=$((hits + 1))
        fi
    done < <(find "$ROOT/.claude" -maxdepth 1 -name 'settings*.json*' -type f 2>/dev/null)

    if [ "$hits" -eq 0 ]; then
        echo "  clean — no launch site sets a model. Dev tabs inherit the machine-global"
        echo "  default, which /model rewrites. Run the observed check below to see what"
        echo "  that default actually is right now."
    else
        FAIL=1
    fi
    echo ""
}

# ─── observed: what did each session actually run on? ────────────────────────
observed() {
    echo "== observed: model per session (last ${DAYS}d, from JSONL transcripts) =="
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
               echo "  Nothing here pins a model — the source is Claude Code's own /model picker,"
               echo "  which saves the choice as the machine-global default for NEW sessions."
               echo "  A model chosen in the CTO window is the model the next /handoff tab starts on."
               echo "  Fix: run /model in an affected window and pick the default; then re-run this."
               FAIL=1
           fi
           ;;
esac

if [ "$FAIL" -ne 0 ]; then
    exit 3
fi
echo "fleet model: ok — nothing pins a model, no observed drift from '${EXPECTED}'."
exit 0
