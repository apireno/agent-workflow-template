#!/usr/bin/env bash
# check-dev-report.sh — the dev-report sections the plan's Declares line makes mandatory.
#
#   check-dev-report.sh <sprint-dir>      exit 0 ok · 1 missing/empty section · 2 usage
#
# The sprint plan's header line `**Declares:** new-mechanisms: yes|no · measurements: yes|no ·
# llm-stages: yes|no` (docs/sprints/_templates/sprint-plan.md) says what the sprint adds. At accept:
#   new-mechanisms: yes  -> dev-report.md needs a non-empty `## Wiring` section, each row WIRED or
#                           UNWIRED (an UNWIRED row is reported; accepting it is the CEO/CTO's call)
#   measurements: yes    -> a non-empty `## Statistical Risks` section
#   llm-stages: yes      -> sprint-plan.md needs a filled `## LLM-Stage Budget` section
# A plan WITHOUT a Declares line (written before 2026-11-04) is reported, not refused.
# Fleet report 2026-11-04: mechanisms landed unwired; sweeps ran with zero graded cells.
set -uo pipefail
D="${1:-}"; [ -n "$D" ] && [ -d "$D" ] || { echo "usage: check-dev-report.sh <sprint-dir>" >&2; exit 2; }
python3 - "$D" <<'PY'
import os, re, sys
d = sys.argv[1]
plan = open(os.path.join(d, "sprint-plan.md"), errors="replace").read() if os.path.isfile(os.path.join(d, "sprint-plan.md")) else ""
rep = open(os.path.join(d, "dev-report.md"), errors="replace").read() if os.path.isfile(os.path.join(d, "dev-report.md")) else ""
m = re.search(r"\*\*Declares:\*\*(.*)", plan)
if not m:
    print("check-dev-report: the plan has no **Declares:** line (pre-2026-11-04 plan) — Wiring / Statistical Risks not enforced"); sys.exit(0)
decl = {k: v for k, v in re.findall(r"([a-z-]+):\s*(yes|no)\b", m.group(1))}
def section(text, name):
    s = re.search(r"^##\s+" + re.escape(name) + r"\s*$(.*?)(?=^##\s|\Z)", text, re.M | re.S | re.I)
    if not s: return None
    body = re.sub(r"<!--.*?-->", "", s.group(1), flags=re.S)
    body = "\n".join(l for l in body.splitlines() if l.strip() and not re.fullmatch(r"\|?[\s|:-]*\|?", l.strip())
                     and "{" not in l and not re.match(r"\|\s*Mechanism\s*\|", l))
    return body.strip()
bad = []
for k in ("new-mechanisms", "measurements", "llm-stages"):
    if k not in decl: bad.append(f"the Declares line does not answer {k}: yes|no")
if decl.get("new-mechanisms") == "yes":
    w = section(rep, "Wiring")
    if not w: bad.append("dev-report.md: `## Wiring` is missing or empty — one row per new mechanism, WIRED (graph path) or UNWIRED")
    else:
        rows = [l for l in w.splitlines() if l.startswith("|")]
        unw = [l for l in rows if re.search(r"\bUNWIRED\b", l)]
        if rows and not all(re.search(r"\b(UN)?WIRED\b", l) for l in rows): bad.append("dev-report.md: a Wiring row is neither WIRED nor UNWIRED")
        if unw: print(f"check-dev-report: {len(unw)} mechanism(s) UNWIRED — name them in the decision (accepting unwired work is an explicit call)")
if decl.get("measurements") == "yes" and not section(rep, "Statistical Risks"):
    bad.append("dev-report.md: `## Statistical Risks` is missing or empty (the plan declares measurements)")
if decl.get("llm-stages") == "yes" and not section(plan, "LLM-Stage Budget"):
    bad.append("sprint-plan.md: `## LLM-Stage Budget` is missing or unfilled (the plan declares llm-stages)")
for b in bad: print("  " + b)
print("check-dev-report: " + ("ok" if not bad else f"{len(bad)} gap(s) — accept refuses until the dev-report says it"))
sys.exit(1 if bad else 0)
PY
