# Sprint XX Dev Report

**Author:** Dev Team
**Branch:** feature/{branch-name}
**Commits:** {count}
**Duration:** {actual days}

---

## Completed

| Task | Status | Files Changed | Tests Added |
|------|--------|--------------|-------------|
| Task 1 | DONE | 3 | 5 |
| Task 2 | DONE | 1 | 2 |
| Task 3 | PARTIAL — see notes | 2 | 0 |
| Derived artifacts regenerated (ADR-002) | DONE / N/A (no covered file changed) | `<artifact names>` | — |

## Test Results
- Total tests: {count}
- Passing: {count}
- Failing: {count}
- New tests this sprint: {count}

## What Was Built
{Brief narrative of what changed and why, aimed at VP of Eng and VP of Product}

## Demo Steps

**Purpose:** These steps let reviewers verify the sprint's output. Each step is tagged as either **[AUTO]** (the dev agent ran it and captured output in `demo-output.md`) or **[HITL]** (requires the CEO to run manually — e.g., checking a UI, browser, or visual output).

### Prerequisites
{Any setup needed: environment variables, data files, model downloads, etc.}

### Automated Verification [AUTO]
Steps the dev agent has already run. Output captured in `demo-output.md`.

1. {Exact CLI command}
   - **Expected:** {what the output should show}
2. {Next command}
   - **Expected:** {what to look for}

### Manual Verification [HITL]
Steps that require a human. **CEO: please run these to verify.**

1. {Action — e.g., "Open http://localhost:8080 and navigate to the Ticker Intelligence tab"}
   - **Expected:** {what you should see — e.g., "Entity count should be >0 with no ghost entities like 'adamczyk'"}
2. {Next action}
   - **Expected:** {what to observe}

*If there are no HITL steps this sprint, write "None — all verification is automated."*

### Expected vs. Before
{What was the behavior BEFORE this sprint? What is it NOW? Show the contrast so the reviewer understands the improvement.}

### Quick Verification
- **[AUTO]** {One-liner command with expected output — already captured in demo-output.md}
- **[HITL]** {One action for the CEO to do manually, if applicable}

## Wiring
<!-- MANDATORY when the plan declares new-mechanisms: yes (check-dev-report.sh refuses accept without it).
     One line per new mechanism: the path from a real entry point to it in the code graph, or UNWIRED.
     A mechanism nothing calls is not delivered, however green its unit tests are. -->
| Mechanism | Path from the entry point (graph) | Status |
|---|---|---|
| {name} | {entry → … → mechanism, with file:line} | WIRED / UNWIRED |

## Statistical Risks
<!-- MANDATORY when the plan declares measurements: yes. Sample size and how it was drawn; what is
     NOT measured (e.g. precision against sampled gold); confidence intervals or "n too small";
     leakage between tuning and evaluation sets; whether every graded item was actually graded
     (zero graded cells is UNVERIFIED, never a pass). Write "None — no measurement" otherwise. -->
{risks, or "None — no measurement"}

## Deviations from Plan
{Anything that changed from the sprint plan, and why}

## Known Issues
{Bugs, incomplete work, or tech debt introduced}

## Questions for VP of Eng
{Technical questions that came up during implementation}

## Questions for VP of Product
{Requirement clarifications or scope questions}

## Phase-3 Status
<!-- CTO 2026-10-31: Phase-3 VP reviews are the CTO's independent gate; lanes do not self-run them.
     Do not create product-review.md (Phase-3 pass), test-eval.md or phase3-review-*.md. Keep the line below. -->
Phase-3 reviews pending: CTO
