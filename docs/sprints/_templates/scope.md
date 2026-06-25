# Sprint XX Scope

**Author:** VP of Product
**PRDs:** PRD-XXX, PRD-YYY
**Roadmap Phase:** {phase}
**Sprint Goal:** {one sentence — what can we demo at the end?}

---

## Sprint RICE Justification

{Why this sprint's work is the highest-priority thing to do right now. Reference PRD RICE scores.}

| PRD | RICE Score | Sprint Contribution |
|-----|-----------|-------------------|
| PRD-XXX | {score} | {which requirements this sprint addresses} |
| PRD-YYY | {score} | {which requirements this sprint addresses} |

**Combined Sprint Priority Rationale:** {Why these PRDs, in this order, now?}

---

## Deliverables

> **Every acceptance criterion MUST carry a concrete, independently-checkable Empirical signal**
> — a command + expected output, an exact string / `data-testid` / log line, or a named demo
> observation. **"Tests pass" is NOT an empirical signal** (it's the dominant claims-vs-reality
> failure). The signal is what `/sprint-verify` re-runs/re-observes to mark the criterion
> MET / NOT-MET / UNVERIFIED before `/sprint-accept`. A criterion with no empirical signal can
> only ever be marked UNVERIFIED — so authoring it here is required, not optional.

### From PRD-XXX: {title}
- [ ] Requirement 1.1: {description}
  - Acceptance: {testable criterion}
  - Empirical signal: {e.g. `cmd --flag` prints `EXPECTED_LINE` / DOM has `data-testid="x"` with text "Y" / demo step N shows Z}
- [ ] Requirement 1.3: {description}
  - Acceptance: {testable criterion}
  - Empirical signal: {concrete check — NOT "tests pass"}

### From PRD-YYY: {title}
- [ ] Requirement 2.1: {description}
  - Acceptance: {testable criterion}
  - Empirical signal: {concrete check}

## Out of Scope
{Explicitly list what we are NOT doing this sprint to prevent scope creep}

## Open Questions for VP of Eng
{Questions about feasibility, dependencies, or technical approach}

## Success Criteria
{How do we know the sprint succeeded? What does "done" look like from a product perspective?
Each success criterion also needs an Empirical signal — it will be verified the same way.}
