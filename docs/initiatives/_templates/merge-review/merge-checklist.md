# Merge Review — {INIT-XXX}: {initiative name}

**Branch:** `{branch-name}`
**Target:** `main`
**Date:** {YYYY-MM-DD}
**Sprints Completed:** {list}

---

## Pre-Merge Checklist

### Branch Health
- [ ] Branch is rebased onto current `main` (no merge conflicts)
- [ ] All tests pass on the rebased branch
- [ ] No regressions in existing test suite
- [ ] CI/CD pipeline passes (if configured)

### Initiative Completeness
- [ ] All exit criteria from `initiative-brief.md` are met (or CEO-approved exceptions documented)
- [ ] All scope amendments are documented and approved
- [ ] Sprint log in initiative brief is up to date

### Tier 3 VP Reviews (MANDATORY)
Each VP reviews the cumulative changes across ALL sprints in this initiative.

| VP | Review File | Verdict | Date |
|----|------------|---------|------|
| VP of Engineering | `merge-review/eng-review.md` | {APPROVED / CONDITIONAL / REJECTED} | |
| VP of Product | `merge-review/prod-acceptance.md` | {APPROVED / CONDITIONAL / REJECTED} | |
| VP of Security | `merge-review/security-review.md` | {APPROVED / CONDITIONAL / REJECTED} | |
| VP of Compliance | `merge-review/compliance-review.md` | {APPROVED / CONDITIONAL / REJECTED} | |
| VP of DevOps | `merge-review/devops-review.md` | {APPROVED / CONDITIONAL / REJECTED} | |

### VP Review Input
The merge review script feeds each VP:
- The initiative brief (scope, exit criteria, amendments)
- A diff summary of all changes (`git diff main...HEAD --stat`)
- The final sprint's dev report and test results
- Their persona-specific concerns file

### Blockers from VP Reviews
{List any BLOCKER items from VP reviews. All must be resolved before merge.}

1. {BLOCKER from VP X — resolution}

---

## CEO Merge Decision

**Decision:** {Merge Approved | Merge Rejected | Conditional — list conditions}
**Date:** {YYYY-MM-DD}
**Notes:** {CEO's comments}
