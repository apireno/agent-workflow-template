# Initiative: {INITIATIVE_NAME}

**ID:** {INIT-XXX}
**Type:** Feature | Tech Debt | Experiment | Bug Fix | Hardening
**Branch:** `{branch-type}/{slug}` (e.g., `feature/tuner-v2`, `fix/graph-corruption`, `experiment/llm-caching`)
**Author:** {VP who proposed — VP Eng or VP Prod}
**Created:** {YYYY-MM-DD}
**Status:** Active | On Hold | Completed | Abandoned

---

## Goal

{One paragraph — what does this initiative achieve and why does it matter? This is the elevator pitch.}

## Background & Motivation

{Why now? What problem exists, what opportunity are we capturing, or what debt are we paying down?}

## References

Link every item that motivates this initiative. The dev team traces sprint work back to these.

| Type | ID | Title | Relevance |
|------|----|-------|-----------|
| PRD | PRD-XXX | {title} | {which requirements this initiative addresses} |
| ADR | ADR-XXX | {title} | {architectural context} |
| Roadmap | Phase X | {milestone} | {where this fits in the roadmap} |
| Bug | BUG-XXX | {title} | {the defect being resolved} |
| RCA | RCA-XXX | {title} | {root cause this prevents} |
| Dependency | — | {description} | {external dependency or upstream change} |

## Scope

### In Scope

{Concrete, testable deliverables. Each item should be something the dev team can close out.}

1. {Deliverable 1 — with acceptance criterion}
2. {Deliverable 2 — with acceptance criterion}
3. {Deliverable 3 — with acceptance criterion}

### Explicitly Out of Scope

{What we are NOT doing. This is a contract — the dev team should push back if asked to do these.}

1. {Thing 1 — and why it's excluded}
2. {Thing 2 — and why it's excluded}

## Exit Criteria

{How do we know the initiative is done? These must ALL be true before the branch can merge to main.}

- [ ] {Exit criterion 1 — maps to an In Scope item}
- [ ] {Exit criterion 2}
- [ ] {Exit criterion 3}
- [ ] All sprint dev reports show passing tests with no regressions
- [ ] Tier 3 merge review completed (VP DevOps, VP Security, VP Compliance, VP Eng, VP Prod)
- [ ] CEO merge approval received

## Estimated Effort

**Sprint count:** {estimated number of sprints}
**Complexity:** Low | Medium | High
**Risk areas:** {what could go wrong — technical risk, dependency risk, scope risk}

## Sprint Log

{Append entries as sprints are completed. This is the initiative's audit trail.}

| Sprint | Goal | Status | Branch Commits | Notes |
|--------|------|--------|----------------|-------|
| sprint-XX | {goal} | {Completed/In Progress} | {count} | {any deviations or scope amendments} |

## Amendments

{Scope changes MUST be documented here. Never silently change the In Scope section — append an amendment.}

See `amendments/` folder for full amendment documents. Summary:

| # | Date | Description | Approved By |
|---|------|-------------|-------------|
| — | — | No amendments yet | — |
