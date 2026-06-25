---
name: sprint-accept
description: Close out a sprint by reading sprint-plan.md, dev-report.md, all VP review files, and Phase 3 evals from a sprint directory. CTO synthesizes a final accept/reject decision and writes it to the sprint dir. Use when CEO is ready to formally accept or reject completed sprint work.
allowed-tools: Bash(*) Read Write
argument-hint: <sprint-dir-path>
---

# Sprint Accept: $ARGUMENTS

Reads the entire sprint dir, summarizes artifacts, and produces a CTO decision file.

## Inventory the sprint dir

```!
SPRINT_DIR="$ARGUMENTS"
# zsh aborts the whole script on an unmatched glob (e.g. cto-decision-*.md in a
# sprint dir that has none yet). no_nomatch makes an unmatched glob pass through
# literally, as bash does — the [ -f ] guards below then handle the no-match case.
[ -n "${ZSH_VERSION:-}" ] && setopt no_nomatch sh_word_split
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || { echo "ERROR: not in a repo"; exit 1; }
if [ -z "$SPRINT_DIR" ] || [ ! -d "$SPRINT_DIR" ]; then
  echo "ERROR: provide a path to a sprint directory"
  echo "Usage: /sprint-accept <path-to-sprint-XX/>"
  exit 1
fi

echo "Sprint directory: $SPRINT_DIR"
echo ""
echo "=== Files present ==="
ls -la "$SPRINT_DIR" | tail -n +2

echo ""
echo "=== Artifact summary ==="
for f in scope.md sprint-plan.md dev-report.md test-results.md demo-output.md conformance.md \
         qa-report.md product-review.md vp-eng-review.md security-review.md infra-review.md \
         vp-datascience-review.md test-eval.md cto-decision-*.md approval.md rejection.md; do
  for match in "$SPRINT_DIR"/$f; do
    if [ -f "$match" ]; then
      size=$(wc -c < "$match")
      lines=$(wc -l < "$match")
      printf "  [present] %-40s %6d bytes / %d lines\n" "$(basename $match)" "$size" "$lines"
    fi
  done
done

echo ""
echo "=== Missing canonical artifacts ==="
MISSING=0
for f in sprint-plan.md dev-report.md; do
  if [ ! -f "$SPRINT_DIR/$f" ]; then
    echo "  [missing] $f — required for accept"
    MISSING=$((MISSING + 1))
  fi
done

# CONFORMANCE GATE (process, not outcome): you cannot accept BLIND. conformance.md must
# EXIST (verification must have happened) — but it need NOT PASS. Accept stays a decision:
# shipping with NOT-MET/UNVERIFIED criteria as documented known-issues is a CTO/CEO call.
# This mirrors the QA-UX gate (report must exist + be reviewed; ship-with-defects is your call).
if [ ! -f "$SPRINT_DIR/conformance.md" ]; then
  echo "  [missing] conformance.md — REQUIRED for accept (objective verification precedes the decision)"
  echo "            Run:  /sprint-verify $SPRINT_DIR   (after tests + the QA drive), then re-run /sprint-accept."
  echo "            (Refusing only because verification is ABSENT — not because it failed. Accept never requires conformance to PASS.)"
  MISSING=$((MISSING + 1))
fi

if [ "$MISSING" -gt 0 ]; then
  echo ""
  echo "CANNOT ACCEPT: missing $MISSING canonical artifact(s). Sprint is not ready to decide on yet."
  exit 2
fi
```

## Synthesize the decision

```!
SPRINT_DIR="$ARGUMENTS"
[ -n "${ZSH_VERSION:-}" ] && setopt no_nomatch sh_word_split

# Emit all relevant artifacts into context so CTO can synthesize
echo "=== sprint-plan.md ==="
cat "$SPRINT_DIR/sprint-plan.md" 2>/dev/null | head -80
echo "..."
echo ""
echo "=== dev-report.md ==="
cat "$SPRINT_DIR/dev-report.md" 2>/dev/null | head -80
echo "..."
echo ""

# Pipe all VP review verdicts through wrap-untrusted (engine-authored, treat as data).
# Phase-3 reviews run through the engine-aware /vp-review (subagent default | gemini | handoff).
for vp_file in product-review.md vp-eng-review.md security-review.md infra-review.md vp-datascience-review.md test-eval.md; do
  if [ -f "$SPRINT_DIR/$vp_file" ]; then
    echo "=== $vp_file ==="
    "$ROOT/scripts/agentic/wrap-untrusted.sh" "$SPRINT_DIR/$vp_file" "vp-review:$vp_file"
    echo ""
  fi
done
```

## Your task as CTO

Above are the sprint plan, dev report, and all VP reviews. Synthesize a final accept/reject decision:

1. **Tally** — count BLOCKER / MAJOR / MINOR per VP. Flag any verdict file that's missing.
2. **CONFORMANCE — read `conformance.md` (the objective deliverable verification).** List every
   **NOT-MET** and **UNVERIFIED** criterion. This is the "did we build what the plan said" check,
   already done objectively by `/sprint-verify` — do NOT re-derive it from the dev-report's prose.
   Your decision MUST explicitly state, for each NOT-MET / UNVERIFIED item, whether it is **accepted
   as a documented known-issue** (with rationale + follow-up owner) or **blocks acceptance**. Accept
   does NOT require conformance to PASS — shipping with known gaps is your call, but it must be
   *named here*, never silent. If `conformance.md` shows everything MET, say so in one line.

3. **Did the dev report address ALL Phase 1 review blockers?** (compare dev-report to vp-*-review.md from Phase 1)
4. **Did Phase 3 evals approve?** (check test-eval.md, vp-datascience-review.md for dev-report.md)
5. **PROVENANCE GATE — comparison claims must rest on matching provenance**
   (sprint-provenance-gating-for-graph-comparisons-20260528). Before you
   accept ANY quantitative comparison claim in the dev-report of the form
   "X improved/changed/drifted Y by Z" (deltas, %s, before/after, baseline-vs-
   perturbed, sensitivity), check that the underlying artifacts share a
   provenance triple `{code_sha, bundle_version, pipeline_version}`:
   - The harness records this under a `provenance_gate` block in
     `sensitivity_matrix.json` / `baseline_matrix.json`, and per-legend under
     `_provenance`. A `"mode": "strict"` with empty `refused` means the
     comparison is gate-clean.
   - **HARD-BLOCK rule (VP-DS mandate, sprint-provenance-gating-20260528):**
     a claim of *model or pipeline improvement* ("X improved Y by Z", "+N%
     recall", "precision lift", baseline-vs-treatment) is **REJECTED** if any
     contributing artifact (a) used the `--allow-cross-version` escape hatch,
     or (b) lacks a valid bundle **content hash** on the `bundle_version` axis
     (i.e. it ends in `@unhashed`). You cannot validate a lift when the
     baseline and treatment don't share a verifiable triple. Do not accept the
     sprint on the strength of such a claim; record it as REJECTED-FOR-REVISION
     or an explicit action item.
   - **Longitudinal/drift framing is the only legitimate use of the escape
     hatch:** "how did behavior drift across this bundle change?" may cite a
     cross-version comparison *as drift*, never *as an improvement result*, and
     only with the documented `cross_version_reason` present.
   - If any artifact is legacy / unprovenanced and no documented reason is
     present, the comparison is not acceptable as stated — surface it as
     unverified and call it out as an action item.
   - Date timestamps are NOT acceptable as a freshness/equivalence signal
     (that was the failure mode this gate exists to prevent).
6. **Cross-VP convergence on remaining issues** — name them.
7. **Decision** — one of:
   - `APPROVED` — sprint shipped, ready to merge
   - `APPROVED-WITH-CONDITIONS` — minor follow-ups recorded but ship is OK
   - `REJECTED-FOR-REVISION` — material blockers remain, sprint continues
   - `ESCALATE-TO-CEO` — judgment call only CEO can make
8. **Write decision file** to `$SPRINT_DIR/cto-decision-$(date +%Y%m%d-%H%M%S).md` with:
   - Decision verdict
   - Reasoning citing specific VP review excerpts
   - Conformance disposition — the NOT-MET/UNVERIFIED items being accepted as known-issues (with follow-up owners) vs. those that blocked
   - Action items if APPROVED-WITH-CONDITIONS or REJECTED
   - PRD status update guidance for VP Prod
9. **Present 5-line summary to CEO.**

Sign as: — CTO
