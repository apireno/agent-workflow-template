# Test Evaluation: Sprint XX

**Reviewer:** VP of Engineering
**Date:** {date}

---

## Test Run Summary

| Metric | Value |
|--------|-------|
| Total tests | {count} |
| Passing | {count} |
| Failing | {count} |
| New this sprint | {count} |
| Coverage delta | {+/- %} |

## Quality Assessment

### Coverage Gaps
{Areas where tests are missing or insufficient. Reference specific requirements from scope.md.}

### Test Quality Concerns
- **Flaky tests:** {any tests with non-deterministic behavior}
- **Trivial assertions:** {tests that pass but don't assert meaningful invariants}
- **Missing edge cases:** {specific scenarios that should be tested}

### Regression Safety
{Are regression tests in place for all bug fixes? Any existing tests that broke and why?}

## Verdict
{PASS — tests are adequate | PASS WITH NOTES — adequate but improvements needed | FAIL — critical gaps must be addressed}

## Required Follow-Ups
{Specific tests or test improvements the dev team must add}
