# QA Report — sprint-XX

**Author:** QA-UX
**Date:** YYYY-MM-DD
**Driven at:** accept-time (against `qa-plan.md`)
**Provenance:** code_sha=`<sha>` app_version=`<ver>` env=`<preview-url>` ts=`<UTC>`

## Verdict

**Recommended posture:** SHIP | SHIP-WITH-KNOWN-DEFECTS | NO-SHIP
*(Shipping with known defects is a CTO/CEO call — this is QA-UX's recommendation, not the decision.)*

## Surface-by-surface result

| Surface | HARD pass | SOFT judgment | BLOCKER | MAJOR | MINOR |
|---------|-----------|---------------|---------|-------|-------|
| browser | x/y | <summary> | n | n | n |
| CLI     | x/y | <summary> | n | n | n |
| MCP     | x/y | <summary> | n | n | n |

## Findings

### F1 — <title>
- **Severity:** BLOCKER | MAJOR | MINOR | NOTE
- **Fault-domain:** client | integration | server | data-quality | ux | unverified
- **Surface / journey:** <browser · J1>
- **Repro:** <exact steps>
- **Evidence:** <DOM grep output / CLI transcript line / MCP trace / `assets/F1-*.png`>
- **Routing:** <which lane fixes it — e.g. data-quality → VP-DS; do NOT band-aid in QA lane>

### F2 — ...

## UX flow-graph delta

- **This sprint:** N states, M transitions (`flow-graph.json` / `flow-graph.md`).
- **vs prior sprint:** +added / −removed / orphaned transitions (each orphan = a finding above).
- **Coverage:** <states-driven>/<states-discovered> ; un-driven surface logged: <list>.

## Hero assets (provenance-stamped, redacted)

| ID | Feature | File | Caption (marketing-ready) |
|----|---------|------|---------------------------|
| H1 | <feature> | `assets/H1-<slug>.png` | <caption> |

## Notes

- Telemetry/RCA depth: <Layer-1 CDP only | Layer-2 present>.
- Redaction: all transcripts/logs scrubbed via `qa-redact.sh` before persisting. ✓

— QA
