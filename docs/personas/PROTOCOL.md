# Inter-Agent Communication Protocol

**Version:** 1.0.0
**Last Updated:** YYYY-MM-DD

---

## Overview

This document defines how the three agent roles (VP of Engineering, VP of Product, Dev Team) communicate with each other. The CEO serves as the router — agents do not communicate directly. All handoffs pass through structured artifacts in the repo.

### Why Structured Artifacts, Not Conversations

When handoffs are conversational (copy-paste between tools), context degrades at each hop. Structured artifacts in the repo are the single source of truth. Each agent reads the other's output file directly.

---

## Agent Roster

| Role | Tool | Model | Primary Output Location |
|---|---|---|---|
| **VP of Engineering** | Antigravity | Gemini | `docs/sprints/`, `docs/architecture/` |
| **VP of Product** | Antigravity | Gemini | `docs/roadmap/prds/`, `docs/sprints/` |
| **Dev Team** | VS Code + Claude Code | Claude | `src/`, `tests/`, `docs/sprints/sprint-XX/sprint-plan.md` |
| **CEO** | All tools | Human | Final decisions, routing, approvals |

---

## The Sprint Lifecycle

Each sprint follows this sequence. Every step produces an artifact. No step is skipped.

```
┌─────────────────────────────────────────────────────────┐
│  PHASE 1: PLANNING                                       │
│                                                          │
│  1. VP Product  → scope.md          (what to build)      │
│  2. VP Eng      → tech-review.md    (feasibility check)  │
│  3. CEO         → approve/iterate                        │
│  4. Dev Team    → sprint-plan.md    (how to build it)    │
│  5. VP Eng      → vp-eng-review.md  (plan review)        │
│  6. CEO         → approve/iterate   (plan accepted)      │
│                                                          │
├─────────────────────────────────────────────────────────┤
│  PHASE 2: EXECUTION                                      │
│                                                          │
│  7. Dev Team    → implements + tests                     │
│  8. Dev Team    → dev-report.md     (what was built)     │
│                                                          │
├─────────────────────────────────────────────────────────┤
│  PHASE 3: EVALUATION                                     │
│                                                          │
│  9.  VP Eng     → test-eval.md      (test quality review)│
│  10. VP Product → product-review.md (requirements met?)  │
│  11. CEO        → accept/iterate                         │
│                                                          │
├─────────────────────────────────────────────────────────┤
│  PHASE 4: CLOSE                                          │
│                                                          │
│  12. VP Eng     → RCA (if bugs found)                    │
│  13. VP Product → roadmap update                         │
│  14. CEO        → sprint closed                          │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

---

## Routing Rules for the CEO

1. **Never summarize an artifact.** Point the next agent at the file path.
2. **Enforce the sequence.** Don't let the dev team code until the VP of Eng approves the plan.
3. **Break loops.** If VP of Eng and dev team iterate more than twice on a plan, make a decision and move forward.
4. **Escalate cross-role conflicts.** Product vs. Eng disagreements are your call.
5. **Close sprints explicitly.** Every sprint gets a verdict.

---

## File Naming Conventions

```
docs/sprints/
  sprint-XX/
    scope.md                        # VP Product
    tech-review-PRD-XXX.md          # VP Eng
    sprint-plan.md                  # Dev Team
    vp-eng-review.md                # VP Eng
    dev-report.md                   # Dev Team
    test-eval.md                    # VP Eng
    product-review.md               # VP Product
    rca-{topic}.md                  # VP Eng (if needed)
  _templates/
    (all templates)
```
