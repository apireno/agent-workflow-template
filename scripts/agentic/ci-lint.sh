#!/usr/bin/env bash
# ci-lint.sh — the CI traps that turn real runs into "cancelled", in a repo's .github/workflows.
#
#   ci-lint.sh <repo-path>        exit 0 clean · 1 findings · 2 usage
#
# WHY (fleet report 2026-11-04): self-hosted jobs timed out at 15 min while the runner's pre-job
# host-lock hook waits up to 3 h, so every queued run read "cancelled"; a label event cancelled a
# 90-min job through cancel-in-progress. Both look like flaky CI; both are configuration.
#
# Checks (a finding names the workflow, the job and the fix):
#   TIMEOUT-UNDER-WAIT  a self-hosted job whose timeout-minutes (GitHub's default: 360) is below the
#                       runner's maximum pre-job wait. Declare the wait once per repo in
#                       .claude/land.yaml as `ci_hook_max_wait_min: <minutes>`; the job needs
#                       timeout >= wait + its own run time. (Or make the hook fail fast, printing the
#                       lock holder and its expected end.)
#   LABEL-CANCELS-HEAVY a pull_request trigger that fires on labeled/unlabeled/edited AND a
#                       concurrency group with cancel-in-progress: a label change cancels the run in
#                       flight. For heavy jobs (self-hosted, or timeout >= 30 min) drop those event
#                       types, or skip them in the job's `if:`. Example: docs/ci/_templates/heavy-job.yml
# land-lane.sh prints these as warnings at step 4.
set -uo pipefail
REPO="${1:-}"; [ -n "$REPO" ] && [ -d "$REPO" ] || { echo "usage: ci-lint.sh <repo-path>" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"
[ -d "$REPO/.github/workflows" ] || { echo "ci-lint: $(basename "$REPO") has no .github/workflows — nothing to check"; exit 0; }
WAIT="$(sed -n 's/^ci_hook_max_wait_min:[[:space:]]*\([0-9]*\).*/\1/p' "$REPO/.claude/land.yaml" 2>/dev/null | head -1)"
python3 - "$REPO" "${WAIT:-}" <<'PY'
import glob, os, sys
repo, wait = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    print("ci-lint: PyYAML not available to this python3 — workflows NOT checked (pip install pyyaml)"); sys.exit(1)
wait = int(wait) if wait else None
LABELISH = {"labeled", "unlabeled", "edited"}
findings = []
for wf in sorted(glob.glob(os.path.join(repo, ".github/workflows/*.y*ml"))):
    name = os.path.relpath(wf, repo)
    try: d = yaml.safe_load(open(wf)) or {}
    except Exception as e: findings.append(f"{name}: unparsable ({e})"); continue
    on = d.get("on", d.get(True)) or {}
    types = set()
    if isinstance(on, dict) and isinstance(on.get("pull_request"), dict):
        types = set(on["pull_request"].get("types") or [])
    wf_cancel = isinstance(d.get("concurrency"), dict) and bool(d["concurrency"].get("cancel-in-progress"))
    for jid, job in (d.get("jobs") or {}).items():
        if not isinstance(job, dict): continue
        ro = job.get("runs-on"); ro = ro if isinstance(ro, list) else [ro]
        selfhosted = any(isinstance(x, str) and x == "self-hosted" for x in ro)
        tmo = job.get("timeout-minutes", 360)
        try: tmo = int(tmo)
        except (TypeError, ValueError): tmo = 360
        if selfhosted and wait is not None and tmo < wait:
            findings.append(f"TIMEOUT-UNDER-WAIT  {name} job '{jid}': timeout-minutes {tmo} < the runner's pre-job wait {wait} min "
                            f"(.claude/land.yaml ci_hook_max_wait_min) — queued runs will read 'cancelled'. Set timeout-minutes >= {wait} + run time.")
        cancel = wf_cancel or (isinstance(job.get("concurrency"), dict) and bool(job["concurrency"].get("cancel-in-progress")))
        heavy = selfhosted or tmo >= 30
        hit = types & LABELISH
        if heavy and cancel and hit:
            findings.append(f"LABEL-CANCELS-HEAVY  {name} job '{jid}': pull_request types include {', '.join(sorted(hit))} with cancel-in-progress — "
                            f"a label/edit event cancels the run in flight. Drop those types for heavy jobs, or guard the job with "
                            f"if: github.event.action != 'labeled' && github.event.action != 'unlabeled' && github.event.action != 'edited'.")
for f in findings: print("  " + f)
print(f"ci-lint: {os.path.basename(repo)} — {'clean' if not findings else str(len(findings)) + ' finding(s)'}"
      + ("" if wait is not None else " (no ci_hook_max_wait_min in .claude/land.yaml: timeout-vs-wait not checked)"))
sys.exit(1 if findings else 0)
PY
