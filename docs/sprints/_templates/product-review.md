# Product Review: Sprint XX

**Reviewer:** VP of Product
**Date:** {date}
**Verdict:** ACCEPTED | ACCEPTED WITH FOLLOW-UPS | NEEDS REWORK

---

## Requirements Checklist

| Requirement | Met? | Notes |
|-------------|------|-------|
| PRD-XXX Req 1.1 | YES | — |
| PRD-XXX Req 1.3 | PARTIAL | {what's missing} |
| PRD-YYY Req 2.1 | YES | Exceeded expectations |

## Demo Impact
{How does this sprint's output affect the demo narrative?}

## Follow-Up PRDs
{New PRDs or PRD amendments needed based on what was learned}

## Roadmap Implications
{Does this sprint's outcome change priorities for next sprint?}

---

## MANDATORY: Document Status Updates

After every sprint review, the VP of Product MUST update the following documents to reflect current reality. Stale documents erode trust and cause duplicated work.

### PRD Status Updates
{List every PRD touched by this sprint. Update their Status and Last Updated fields.}

| PRD | Previous Status | New Status | Notes |
|-----|----------------|------------|-------|
| PRD-XXX | In Progress | Complete | All requirements met |
| PRD-YYY | In Progress | In Progress | Req 2.3 deferred to next sprint |

**Action:** After writing this review, open each PRD listed above and update:
- `**Status:**` field to the new status
- `**Last Updated:**` field to today's date
- Add a Changelog entry if the PRD has one

### ADR Status Updates
{Were any architectural decisions validated, invalidated, or superseded by this sprint's work?}

| ADR | Current Status | Change Needed? | Notes |
|-----|---------------|----------------|-------|
| ADR-XXX | Accepted | No change | Validated by implementation |
| ADR-YYY | Proposed | → Accepted | Sprint proved the approach works |

**Action:** Update any ADR whose status changed.

### Roadmap Updates
{Does the roadmap need to change based on this sprint?}

- [ ] Update milestone status (Not Started → In Progress → Complete)
- [ ] Re-score RICE if new information changes Confidence or Effort
- [ ] Archive completed milestones
- [ ] Add new milestones discovered during sprint
- [ ] Update `**Last Updated:**` and `**Current Sprint:**` in roadmap header

**Action:** Open `docs/roadmap/ROADMAP.md` and apply the changes checked above.

---

*This review is incomplete until all document status updates above are applied. The VP of Product owns document freshness.*
