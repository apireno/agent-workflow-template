# Sprint XX Plan

**Author:** Dev Team
**Goal:** {from scope.md}
**Duration:** {estimated days}
**Branch:** feature/{branch-name}
**Declares:** new-mechanisms: {yes|no} · measurements: {yes|no} · llm-stages: {yes|no}
<!-- The Declares line is read at accept (scripts/agentic/check-dev-report.sh): new-mechanisms: yes
     makes the dev-report's Wiring section mandatory; measurements: yes makes Statistical risks
     mandatory; llm-stages: yes requires the LLM-stage budget section below. Answer all three. -->

---

## Task Breakdown

### Task 1: {description}
- **Files:** {list of files to create/modify}
- **Approach:** {brief technical approach}
- **Tests:** {what tests will be written}
- **Acceptance:** {from scope.md}
- **Effort:** {hours or T-shirt size}

### Task 2: {description}
- **Files:** {list of files to create/modify}
- **Approach:** {brief technical approach}
- **Tests:** {what tests will be written}
- **Acceptance:** {from scope.md}
- **Effort:** {hours or T-shirt size}

## Sequencing
{Which tasks depend on which. What can be parallelized.}

## Risk Mitigation
{Known risks from tech review and how we'll handle them}

## Verification Plan
1. **Run tests:** {test command} — all existing tests pass + new tests
2. **Smoke/e2e test:** {describe the integration or smoke test}
3. **Save results:** Write test output to `docs/sprints/sprint-XX/test-results.md`

## LLM-Stage Budget (only when `llm-stages: yes`)
<!-- Fleet report 2026-11-04: "< $5" from a short-article smoke became ~$89 on dense text — cost
     scales with completion length, and short documents produce short replies. -->
- **Smoke document:** {the LONGEST / densest document in the run set — never the shortest}
- **Projected cost per stage:** {smoke tokens x documents x price}, ceiling {USD} per stage — checked BEFORE each launch
- **Resumable:** {how a stopped run continues without redoing finished items}
- **Readout header names:** model · endpoint · quantization

## Definition of Done
- [ ] All acceptance criteria from scope.md pass
- [ ] Tests written and passing
- [ ] No regressions in existing test suite
- [ ] Code follows established patterns (no domain leakage, lineage preserved)
- [ ] Governed derived artifacts regenerated if a covered file changed (`derived-artifact-gate.sh` exits 0 — ADR-002)
- [ ] Test results saved to `test-results.md`
- [ ] Dev report written to `dev-report.md`
- [ ] `dev-report.md` ends with `Phase-3 reviews pending: CTO` (the CTO runs Phase-3 VP reviews; see Phase 3 in CLAUDE.md)
- [ ] CEO verdict received
