# Technical Review: PRD-XXX — {title}

**Reviewer:** VP of Engineering
**Date:** {date}
**PRD RICE Score:** {score from PRD}
**Verdict:** APPROVED | APPROVED WITH CONDITIONS | NEEDS REVISION

---

## Summary
{2-3 sentences on overall feasibility and approach}

## Requirement-Level Assessment

| Req | Feasibility | Effort | Risk | Notes |
|-----|-------------|--------|------|-------|
| 1.1 | Feasible | S | Low | — |
| 1.2 | Feasible with caveats | M | Medium | Depends on ADR-007 |
| 1.3 | Not feasible as written | — | High | See blocker below |

## RICE Confidence Adjustment

{Does the technical review change the PRD's RICE score? If the Confidence or Effort factor should change based on technical analysis, note it here.}

| Factor | PRD Value | Adjusted Value | Reason |
|--------|-----------|---------------|--------|
| Confidence | {original} | {adjusted or "No change"} | {reason} |
| Effort | {original} | {adjusted or "No change"} | {reason} |
| **Adjusted RICE** | {original score} | **{new score or "No change"}** | |

**Action for VP of Product:** If RICE changed, update the PRD and re-evaluate roadmap priority.

## Blockers
{BLOCKER severity items that must be resolved before work begins}

## Architectural Concerns
{MAJOR severity items — can proceed but must address within sprint}

## ADR Requirements
{Does this PRD require new ADRs? List the decisions that need to be made.}

| Decision Needed | Proposed ADR | Priority |
|----------------|-------------|----------|
| {decision topic} | ADR-XXX | {BLOCKER / Before sprint / During sprint} |

## Recommendations
{Suggested technical approach, alternative designs, or sequencing advice}

## Dependencies
{What must exist or be true before this work can begin}
