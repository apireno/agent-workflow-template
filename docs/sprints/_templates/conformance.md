# Conformance Report — sprint-<slug>

**Verifier:** CTO (objective verification)
**Date:** <YYYY-MM-DD>
**Code SHA:** <short-sha>   **Evidence sources:** test-results.md · qa-report.md · demo-output.md · targeted checks

> **This report produces FACTS, not a ship decision.** It maps each PRD/sprint-plan acceptance
> criterion to evidence and marks it **MET / NOT-MET / UNVERIFIED**. It does NOT decide
> ship/no-ship — that is `/sprint-accept`'s job. NOT-MET and UNVERIFIED rows are inputs the
> accept decision must weigh, and may knowingly accept as documented known-issues.
>
> Verify **aggregates** existing evidence (it does not re-drive the product): it cites a line in
> `qa-report.md` / `test-results.md` / `demo-output.md`, or a targeted check it ran for a
> criterion nothing else covered. A criterion with no evidence is **UNVERIFIED**, never assumed MET.

## Criteria

| # | Acceptance criterion (from plan/PRD) | Declared empirical signal | Status | Evidence pointer |
|---|--------------------------------------|---------------------------|--------|------------------|
| 1 | <criterion, cite PRD-id/requirement> | <command+expected output / exact log line / data-testid / demo obs> | MET / NOT-MET / UNVERIFIED | qa-report.md:L?? · test-results.md · demo-output.md · `ran: <cmd>` → <result> |
| 2 | … | … | … | … |

## Summary

- **MET:** N / TOTAL
- **NOT-MET:** <list # + one-line why> (or "none")
- **UNVERIFIED:** <list # + why no evidence> (or "none")

## Plan-quality notes (for VP Product / next planning)

- Criteria that arrived with **no declared empirical signal** (a planning defect — they could only be
  marked UNVERIFIED): <list, or "none">.
- Any criterion whose signal was "tests pass" rather than a concrete check: <list, or "none">.

— CTO
