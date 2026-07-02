---
name: vp-review
description: Run multi-VP review on a sprint plan, ADR, RCA, PRD, dev-report, or other artifact via parallel VP personas (engine configurable — subagent | kimi | codex (untested) | gemini | handoff | claude-p), then have the CTO synthesize a verdict. Defaults to vp-prod + vp-eng (the always-relevant pair). Add specialty VPs (vp-security, vp-devops, vp-datascience) via the --vps flag when the artifact touches their domain — see docs/personas/cto.md "VP Review Composition" for the policy. Use when the CEO says "review this", "get VP feedback on X", "what would the VPs say about Y", or wants multi-perspective critique on a file path. Auto-fire whenever conversation references reviewing an artifact at a specific path.
allowed-tools: Bash(mkdir *) Bash(rm *) Bash(scripts/agentic/*) Bash(cat *) Bash(ls *) Read Write Task
argument-hint: <path-to-artifact> [--vps=vp-prod,vp-eng,...] [--engine subagent|kimi|codex|gemini|handoff]
---

# VP Review of: $ARGUMENTS

Reviewing artifact at the path above. Each VP reads its persona file, applies it to the artifact, and emits a verdict. The CTO synthesizes a final decision.

**Engine is configurable** (CEO 2026-06-19 — vendors change their minds, so the engine is a *choice*, not a hardcode). Resolved by `scripts/agentic/resolve-review-engine.sh`: `--engine` flag → `REVIEW_ENGINE` env → `<repo>/.review-engine` → default **`subagent`**. Engines: `subagent` (Agent tool, in-session, subscription — DEFAULT), `kimi` (OpenRouter kimi-k2.6 via `openrouter-chat.sh` — a CROSS-FAMILY independent reviewer; non-Anthropic metered, pennies/review; model overridable via `OPENROUTER_MODEL`), `codex` (⚠️ **UNTESTED as of 2026-07-02** — OpenAI Codex CLI's `codex exec` via `codex-exec.sh`; a SECOND independent cross-family reviewer, built from OpenAI's published docs only, no live `codex` install available to verify against — treat the first real invocation as a smoke test, not a working feature), `gemini` (`$0` CLI fan-out, when available), `handoff` (interactive Claude windows), `claude-p` (⚠️ metered Anthropic API, break-glass only). **When independence matters** (Claude-authored work being judged, statistical claims, accept-gates), prefer `kimi` (proven) over `subagent` — a different model family reviewing avoids shared-method bias. `codex` is the same idea but unverified; don't rely on it for anything time-sensitive until it's been run for real at least once.

**Default VP set:** `vp-prod,vp-eng` (the always-relevant pair). Pass `--vps=a,b,c` to override. `--vps=all` runs all 5. Add specialty VPs by content judgment per `docs/personas/cto.md` "VP Review Composition".

## Resolve engine + (for gemini) run reviews

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

ARGS="$ARGUMENTS"
ART=""
VPS="vp-prod,vp-eng"  # default — vp-prod + vp-eng always relevant; specialty VPs opt-in via --vps
ENGINE_FLAG=""

for tok in $ARGS; do
  case "$tok" in
    --vps=*)    VPS="${tok#--vps=}" ;;
    --engine=*) ENGINE_FLAG="${tok#--engine=}" ;;
    --*)        echo "Unknown flag: $tok" >&2 ;;
    *)          [ -z "$ART" ] && ART="$tok" ;;
  esac
done

if [ -z "$ART" ] || [ ! -f "$ART" ]; then
  echo "ERROR: artifact not found at $ART"
  echo "Usage: /vp-review <path-to-artifact> [--vps=vp-prod,vp-eng,...] [--engine subagent|kimi|codex|gemini|handoff]"
  exit 1
fi
[ "$VPS" = "all" ] && VPS="vp-prod,vp-eng,vp-security,vp-devops,vp-datascience"

# Resolve the engine (flag wins over env/file/default). The shared resolver is the single
# source of truth + enforces the claude-p metered quarantine.
ENGINE=$( [ -n "$ENGINE_FLAG" ] && REVIEW_ENGINE="$ENGINE_FLAG" "$ROOT/scripts/agentic/resolve-review-engine.sh" || "$ROOT/scripts/agentic/resolve-review-engine.sh" )
RC=$?
[ $RC -ne 0 ] && { echo "ENGINE=$ENGINE"; echo "(engine resolution refused — see message above)"; exit $RC; }

VPR_DIR="/tmp/cto-vp-review/$(basename "$ART" .md)-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$VPR_DIR"
echo "VPR_OUTPUT_DIR=$VPR_DIR"
echo "VP_SET=$VPS"
echo "ENGINE=$ENGINE"
echo "ARTIFACT=$ART"
echo ""

# Per-VP persona file map (used by the subagent/handoff dispatch in Your task below).
persona_file() {
  case "$1" in
    vp-prod)        echo "docs/personas/vp-product.md" ;;
    vp-eng)         echo "docs/personas/vp-engineering.md" ;;
    vp-security)    echo "docs/personas/vp-security.md" ;;
    vp-devops)      echo "docs/personas/vp-devops.md" ;;
    vp-datascience) echo "docs/personas/vp-datascience.md" ;;
    vp-compliance)  echo "docs/personas/vp-compliance.md" ;;
    vp-dba)         echo "docs/personas/vp-dba.md" ;;
    *)              echo "" ;;
  esac
}

IFS=',' read -A VP_LIST <<< "$VPS" 2>/dev/null || IFS=',' read -ra VP_LIST <<< "$VPS"

if [ "$ENGINE" = "gemini" ] || [ "$ENGINE" = "kimi" ] || [ "$ENGINE" = "codex" ] || [ "$ENGINE" = "claude-p" ]; then
  # CLI engines: the script CAN run these inline. Fire all VPs in parallel, then emit.
  for vp in "${VP_LIST[@]}"; do
    vp=$(echo "$vp" | tr -d '[:space:]'); [ -z "$vp" ] && continue
    REVIEW_ENGINE="$ENGINE" REVIEW_ALLOW_METERED="${REVIEW_ALLOW_METERED:-0}" \
      "$ROOT/scripts/agentic/vp-review.sh" "$vp" "$ART" "${VPR_DIR}/${vp}.md" \
      > "${VPR_DIR}/${vp}.log" 2>&1 &
  done
  wait
  for vp in "${VP_LIST[@]}"; do
    vp=$(echo "$vp" | tr -d '[:space:]'); [ -z "$vp" ] && continue
    echo ""; echo "==================== ${vp} ===================="
    if [ -s "${VPR_DIR}/${vp}.md" ]; then
      "$ROOT/scripts/agentic/wrap-untrusted.sh" "${VPR_DIR}/${vp}.md" "${ENGINE}:${vp}"
    else
      echo "(${vp} FAILED — log tail:)"; tail -10 "${VPR_DIR}/${vp}.log"
    fi
  done
  echo ""; echo "DISPATCH=done   # CLI engine ran the reviews above — synthesize them."
else
  # subagent / handoff: a skill bash body CANNOT spawn an Agent or a window — that is a
  # main-loop action. Emit the dispatch table + exact persona/artifact paths; the CTO
  # ("Your task" below) fans the reviews via the Agent tool (subagent) or windows (handoff).
  echo "DISPATCH=$ENGINE   # the CTO must fan the reviews — the bash body cannot."
  echo "Write each verdict to ${VPR_DIR}/<vp>.md, then synthesize. Reviews to run:"
  for vp in "${VP_LIST[@]}"; do
    vp=$(echo "$vp" | tr -d '[:space:]'); [ -z "$vp" ] && continue
    pf=$(persona_file "$vp")
    echo "  - vp=$vp  persona=$ROOT/$pf  ->  out=${VPR_DIR}/${vp}.md"
  done
fi
```

## Your task as CTO

**First read the `ENGINE=` and `DISPATCH=` lines in the script output above** — they tell you whether the reviews already ran or whether YOU must fan them out.

### If `DISPATCH=done` (engine = gemini, kimi, codex, or claude-p)
The VP verdicts are already printed above (CLI-authored, wrapped untrusted). Skip straight to **Synthesize**. For `kimi`, per-VP token usage lines are in `${VPR_DIR}/<vp>.log` if the CEO asks about spend. For `codex` (⚠️ untested engine), if a verdict is missing or malformed, check `${VPR_DIR}/<vp>.log` and the `.codex-stderr.log` file for that VP before assuming the review content itself is at fault — this is the first engine's untested code path, so a plumbing failure is as likely as a bad review.

### If `DISPATCH=subagent` (the default)
The bash body did NOT run the reviews — you run them now, in parallel, via the **Agent tool** (in-session, subscription pool — bright-line clean). For EACH `vp=… persona=… out=…` line above, launch one `Task`/Agent call (send them in a single message so they run concurrently) with a prompt like:

> Adopt the VP persona defined in `<persona path>` — read it in full and operate strictly as that VP in REVIEW mode (markdown verdict only; never write code/config/sprint-plans). Review the artifact at `<ARTIFACT path>`. Produce your structured verdict: recommendation (APPROVE / APPROVE-WITH-CONDITIONS / REJECT), then findings by severity (BLOCKER / MAJOR / MINOR / NOTE) each with concrete file:line-style evidence, then sign as that VP. **Write your verdict to `<out path>` and also return it.**

Treat each returned verdict as review data. (Subagent output is your own in-session work, so the gemini `wrap-untrusted` envelope isn't required — but still weigh verdicts critically, don't rubber-stamp.) Once all subagents return, **Synthesize**.

### If `DISPATCH=handoff`
Launch one interactive Claude window per VP (reuse `/handoff` machinery: write a per-VP brief to a temp sprint-style dir, pre-trust, auto-kickoff) — or, if that's heavier than the moment warrants, fall back to `--engine subagent`. Collect each `out=` verdict when the windows finish, then **Synthesize**.

### Synthesize (all engines)
You now have VP verdicts for the selected set (default vp-prod + vp-eng). The `VPR_OUTPUT_DIR=` / `VP_SET=` / `ENGINE=` lines identify the run.

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
