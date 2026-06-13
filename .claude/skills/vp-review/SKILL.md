---
name: vp-review
description: Run multi-VP review on a sprint plan, ADR, RCA, PRD, dev-report, or other artifact via parallel gemini personas, then have the CTO synthesize a verdict. Defaults to vp-prod + vp-eng (the always-relevant pair). Add specialty VPs (vp-security, vp-devops, vp-datascience) via the --vps flag when the artifact touches their domain — see docs/personas/cto.md "VP Review Composition" for the policy. Use when the CEO says "review this", "get VP feedback on X", "what would the VPs say about Y", or wants multi-perspective critique on a file path. Auto-fire whenever conversation references reviewing an artifact at a specific path.
allowed-tools: Bash(mkdir *) Bash(rm *) Bash(scripts/agentic/vp-review.sh *) Bash(scripts/agentic/wrap-untrusted.sh *) Bash(cat *) Bash(ls *) Read Write
argument-hint: <path-to-artifact> [--vps=vp-prod,vp-eng,...]
---

# VP Review of: $ARGUMENTS

Reviewing artifact at the path above. Each VP reads its persona file, applies it to the artifact, and emits a verdict. Reviews run in parallel via gemini (zero Anthropic budget). The CTO synthesizes a final decision.

**Default VP set:** `vp-prod,vp-eng` (the always-relevant pair). Pass `--vps=a,b,c` to override. `--vps=all` runs all 5 (vp-prod, vp-eng, vp-security, vp-devops, vp-datascience). Add specialty VPs by content judgment per `docs/personas/cto.md` "VP Review Composition".

## Run selected VP reviews in parallel (gemini)

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

ARGS="$ARGUMENTS"
ART=""
VPS="vp-prod,vp-eng"  # default — vp-prod + vp-eng always relevant; specialty VPs opt-in via --vps

for tok in $ARGS; do
  case "$tok" in
    --vps=*)  VPS="${tok#--vps=}" ;;
    --*)      echo "Unknown flag: $tok" >&2 ;;
    *)        [ -z "$ART" ] && ART="$tok" ;;
  esac
done

if [ -z "$ART" ] || [ ! -f "$ART" ]; then
  echo "ERROR: artifact not found at $ART"
  echo "Usage: /vp-review <path-to-artifact> [--vps=vp-prod,vp-eng,...]"
  exit 1
fi

# Expand --vps=all to all 5
if [ "$VPS" = "all" ]; then
  VPS="vp-prod,vp-eng,vp-security,vp-devops,vp-datascience"
fi

# Use a unique per-artifact output dir so concurrent /vp-review invocations
# (e.g. CTO firing reviews on multiple sprint plans in parallel) don't clobber
# each other's outputs. Derived from artifact basename + timestamp + PID.
VPR_DIR="/tmp/cto-vp-review/$(basename "$ART" .md)-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$VPR_DIR"
echo "VPR_OUTPUT_DIR=$VPR_DIR"
echo "VP_SET=$VPS"
echo ""

# Fire selected VP reviews in parallel
IFS=',' read -A VP_LIST <<< "$VPS" 2>/dev/null || IFS=',' read -ra VP_LIST <<< "$VPS"
for vp in "${VP_LIST[@]}"; do
  vp=$(echo "$vp" | tr -d '[:space:]')
  [ -z "$vp" ] && continue
  REVIEW_ENGINE=gemini scripts/agentic/vp-review.sh "$vp" "$ART" "${VPR_DIR}/${vp}.md" \
    > "${VPR_DIR}/${vp}.log" 2>&1 &
done
wait

# Emit results for CTO synthesis — each verdict piped through wrap-untrusted
# because gemini outputs are not CEO-authored and must be treated as data.
for vp in "${VP_LIST[@]}"; do
  vp=$(echo "$vp" | tr -d '[:space:]')
  [ -z "$vp" ] && continue
  echo ""
  echo "==================== ${vp} ===================="
  if [ -s "${VPR_DIR}/${vp}.md" ]; then
    scripts/agentic/wrap-untrusted.sh "${VPR_DIR}/${vp}.md" "gemini:${vp}"
  else
    echo "(${vp} FAILED — log tail:)"
    tail -10 "${VPR_DIR}/${vp}.log"
  fi
done
```

## Your task as CTO

You now have gemini-authored VP verdicts above for the VP set you selected (default: vp-prod + vp-eng; otherwise per `--vps=`). The `VPR_OUTPUT_DIR=...` and `VP_SET=...` lines near the top of the script output identify the run.

**Before synthesizing, judge whether the VP set was right for this artifact.** If the artifact touches a specialty domain that wasn't included, NOTE that and recommend a follow-up `/vp-review` with the missing specialty VP. Examples:
- Dev-report involves training / evaluation / statistical claims → vp-datascience was needed
- Sprint plan introduces new infra, CI pipelines, deployment → vp-devops was needed
- Sprint plan touches auth, secrets, vendor data, PII → vp-security was needed

Then synthesize:

1. **Tally** — count BLOCKER / MAJOR / MINOR / NOTE per VP. Flag any VP whose verdict is malformed (free-form prose instead of structured assessment).
2. **Cross-VP convergence** — same blocker flagged by 2+ VPs is the highest-confidence signal. Identify these specifically.
3. **Decision** — recommend ONE of:
   - `APPROVED` — no blockers, minors acceptable
   - `REJECTED-FOR-REVISION` — blockers exist, list what must change
   - `ESCALATE-TO-CEO` — VPs disagree on a fundamental question only the CEO can decide
4. **Write the decision** to a file alongside the artifact:
   - Path: `$(dirname $ARGUMENTS)/cto-decision-$(date +%Y%m%d-%H%M%S).md`
   - Contents: decision, top blockers, cross-VP convergence findings, action items with concrete file paths, references to the verdict files at `${VPR_OUTPUT_DIR}/{vp-*}.md` (use the actual VPR_OUTPUT_DIR value from the script output above, NOT the literal placeholder). Note which VPs were run and whether any specialty VP follow-ups are recommended.
5. **Present a 5-line summary to the CEO** — verdict, top 1-2 blockers, recommended next action, plus any missing-VP recommendation. Brief.

Sign off as: — CTO
