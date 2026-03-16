# Inter-Agent Communication Protocol

**Version:** 2.0.0
**Last Updated:** YYYY-MM-DD

---

## Overview

This document defines how the agent roles communicate with each other. The CEO serves as the human-in-the-loop (HITL) for approval gates. All handoffs pass through structured artifacts (markdown files) in the repo. VP reviews are automated via Gemini CLI — the dev agent calls `scripts/vp-review.sh` to get reviews without manual copy-paste.

### Why File-Based Handoffs

When handoffs are conversational (copy-paste between tools), context degrades at each hop. Structured artifacts in the repo are the single source of truth. Each agent reads the other's output file directly. The Gemini CLI wrapper ensures VP personas receive full context every time.

---

## Agent Roster

| Role | Signature | Engine | Invocation |
|---|---|---|---|
| **VP of Engineering** | `— Eng` | Gemini CLI or Claude (skill) | `vp-review.sh vp-eng` or `/vp-eng` |
| **VP of Product** | `— Prod` | Gemini CLI or Claude (skill) | `vp-review.sh vp-prod` or `/vp-prod` |
| **VP of Security** | `— Sec` | Gemini CLI or Claude (skill) | `vp-review.sh vp-security` or `/vp-security` |
| **VP of Compliance** | `— Comp` | Gemini CLI or Claude (skill) | `vp-review.sh vp-compliance` or `/vp-compliance` |
| **VP of DevOps** | `— DevOps` | Gemini CLI or Claude (skill) | `vp-review.sh vp-devops` or `/vp-devops` |
| **Dev Team** | `— Dev` | Claude Code (VS Code) | Default role in CLAUDE.md |
| **CEO** | — | Human | HITL approval gates |

### Dual-Engine Model

Each VP persona can be invoked two ways:
1. **Gemini CLI** (`scripts/vp-review.sh`) — automated file-to-file reviews. Claude Code calls this as a bash command. Used for structured sprint reviews.
2. **Claude Skill** (`/vp-eng`, `/vp-prod`, etc.) — Claude adopts the persona in-conversation. Used when the CEO wants a second opinion or interactive discussion.

---

## The Sprint Lifecycle (Automated)

The dev agent orchestrates the planning phase by calling Gemini CLI for VP reviews. The CEO approves at two gates: before execution starts, and at sprint close.

```
┌─────────────────────────────────────────────────────────────┐
│  PHASE 1: PLANNING (Dev agent orchestrates)                  │
│                                                              │
│  1. Dev reads scope.md + any VP memos/ADRs/PRDs              │
│  2. Dev writes sprint-plan.md                                │
│  3. Dev calls: vp-review.sh vp-prod → product-review.md     │
│  4. Dev calls: vp-review.sh vp-eng → vp-eng-review.md       │
│  5. Dev calls: vp-review.sh vp-security → security-review.md│
│     (optional — for sprints with security implications)      │
│  6. Dev reads all reviews, revises sprint-plan.md            │
│  7. Dev presents revised plan + reviews to CEO               │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  >>> CEO APPROVAL GATE: approve to execute <<<      │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│  PHASE 2: EXECUTION (Dev agent implements)                   │
│                                                              │
│  8.  Dev implements the approved plan                        │
│  9.  Dev writes and runs tests (smoke or e2e per plan)       │
│  10. Dev saves test results to test-results.md               │
│  11. Dev writes dev-report.md                                │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│  PHASE 3: EVALUATION (Automated + CEO)                       │
│                                                              │
│  12. Dev calls: vp-review.sh vp-prod (input: dev-report +   │
│      test-results) → product-review.md                       │
│  13. Dev calls: vp-review.sh vp-eng (input: dev-report)     │
│      → test-eval.md                                          │
│  14. Dev calls: vp-review.sh vp-devops (if infra changes)   │
│      → infra-review.md                                       │
│  15. Dev presents all evaluations to CEO                     │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  >>> CEO APPROVAL GATE: accept / iterate <<<        │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│  PHASE 4: CLOSE                                              │
│                                                              │
│  16. VP Eng writes RCA if bugs found (via Gemini CLI)        │
│  17. CEO closes sprint                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Review Types by Persona

| Persona | Reviews | Input Artifact | Output Artifact |
|---|---|---|---|
| VP Product | Sprint plan review | `sprint-plan.md` | `product-review.md` |
| VP Product | Delivery evaluation | `dev-report.md` + `test-results.md` | `product-review.md` |
| VP Engineering | Sprint plan review | `sprint-plan.md` | `vp-eng-review.md` |
| VP Engineering | Test evaluation | `dev-report.md` | `test-eval.md` |
| VP Engineering | PRD tech review | PRD file | `tech-review-PRD-XXX.md` |
| VP Security | Security review | `sprint-plan.md` or feature PRD | `security-review.md` |
| VP Compliance | Compliance review | `sprint-plan.md` or feature PRD | `compliance-review.md` |
| VP DevOps | Infrastructure review | `sprint-plan.md` (if infra changes) | `infra-review.md` |
| VP DevOps | CI/CD review | `sprint-plan.md` (if pipeline changes) | `cicd-review.md` |

---

## Routing Rules for the CEO

1. **Two approval gates.** You approve before execution starts and at sprint close.
2. **VP reviews are automated.** The dev agent calls Gemini CLI for you. You read the reviews alongside the plan.
3. **Break loops.** If the dev agent iterates more than twice on a plan, make a decision and move forward.
4. **Escalate conflicts.** VP disagreements are your call.
5. **Security reviews are optional but recommended** for sprints that touch credentials, data flow, or external APIs.
6. **Compliance reviews are optional** — invoke for features that change data collection or third-party API usage.

---

## Gemini CLI Wrapper

```bash
# From repo root:
./scripts/vp-review.sh <persona> <input-file> <output-file>

# Personas: vp-eng, vp-prod, vp-security, vp-compliance, vp-devops
```

The wrapper:
1. Reads the persona definition md
2. Reads the project concerns file (if the persona has one)
3. Reads the private context file (if it exists)
4. Reads the protocol (this file)
5. Appends a mandatory anti-jailbreak suffix
6. Pipes everything to `gemini` CLI
7. Writes the response to the output file

---

## File Naming Conventions

```
docs/sprints/
  sprint-XX/
    scope.md                        # VP Product (manual or via Gemini)
    tech-review-PRD-XXX.md          # VP Eng (via Gemini CLI)
    sprint-plan.md                  # Dev Team
    vp-eng-review.md                # VP Eng (via Gemini CLI)
    product-review.md               # VP Product (via Gemini CLI)
    security-review.md              # VP Security (via Gemini CLI, optional)
    compliance-review.md            # VP Compliance (via Gemini CLI, optional)
    infra-review.md                 # VP DevOps (via Gemini CLI, optional)
    cicd-review.md                  # VP DevOps (via Gemini CLI, optional)
    dev-report.md                   # Dev Team
    test-results.md                 # Dev Team
    test-eval.md                    # VP Eng (via Gemini CLI)
    rca-{topic}.md                  # VP Eng (via Gemini CLI, if needed)
  _templates/
    (all templates)
```
