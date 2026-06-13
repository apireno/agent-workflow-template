# Inter-Agent Communication Protocol

**Version:** 4.0.0
**Last Updated:** YYYY-MM-DD

---

## Overview

This protocol defines the sprint-based development lifecycle for multi-contributor, multi-agent projects. Each contributor runs their own Claude Code session (Dev Team agent) on a feature branch. VP reviews are automated via LLM CLI. The CEO is the human-in-the-loop at all approval gates. All handoffs pass through structured markdown files in the repo — never through conversation.

### Why File-Based Handoffs

When handoffs are conversational, context degrades at every hop. Files in the repo are the single source of truth. Every agent reads the same CLAUDE.md, follows the same sprint lifecycle, and gets reviewed by the same VP personas with the same standards. **The process is the repo.**

---

## Agent Roster

| Role | Signature | Engine | Invocation |
|---|---|---|---|
| **VP of Engineering** | `— Eng` | LLM CLI or Claude (skill) | `vp-review.sh vp-eng` or `/vp-eng` |
| **VP of Product** | `— Prod` | LLM CLI or Claude (skill) | `vp-review.sh vp-prod` or `/vp-prod` |
| **VP of Security** | `— Sec` | LLM CLI or Claude (skill) | `vp-review.sh vp-security` or `/vp-security` |
| **VP of Compliance** | `— Comp` | LLM CLI or Claude (skill) | `vp-review.sh vp-compliance` or `/vp-compliance` |
| **VP of DevOps** | `— DevOps` | LLM CLI or Claude (skill) | `vp-review.sh vp-devops` or `/vp-devops` |
| **VP of Data Science** | `— Data` | LLM CLI or Claude (skill) | `vp-review.sh vp-datascience` or `/vp-datascience` |
| **Dev Team** | `— Dev` | Claude Code (VS Code) | Default role in CLAUDE.md |
| **CEO** | — | Human | All approval gates |

### Review Engine Model

VP reviews are automated via CLI tools. Configure once — all scripts use it.

| Engine | CLI Used | Best For |
|--------|----------|----------|
| `gemini` | Gemini CLI | Claude for dev, Gemini for independent reviews |
| `claude` | `claude -p` | Claude only — review runs as a fresh process, no shared context |
| `dual` | Both | Maximum coverage — two independent reviews per artifact |

**Configure:** Create `.review-engine` in repo root with one word: `gemini`, `claude`, or `dual`.  
**Override:** `REVIEW_ENGINE=claude ./scripts/agentic/vp-review.sh ...`  
**Auto-detect:** If neither is set, script finds whichever CLI is installed.

---

## Sprint Lifecycle

```
┌─────────────────────────────────────────┐
│  PHASE 1: PLANNING                      │
│  Dev writes sprint plan                 │
│  → vp-review.sh (VP Prod + VP Eng)      │
│  → Dev addresses feedback               │
│  → CEO approves                         │
├─────────────────────────────────────────┤
│  PHASE 2: EXECUTION                     │
│  Dev implements + tests                 │
│  → Dev writes dev report + demo output  │
├─────────────────────────────────────────┤
│  PHASE 3: EVALUATION                    │
│  → vp-review.sh (VP Prod + VP Eng)      │
│  → CEO gives verdict                    │
└─────────────────────────────────────────┘
```

All sprint artifacts live at `docs/sprints/sprint-XX/`:

| Artifact | Author | Phase |
|----------|--------|-------|
| `scope.md` | VP of Product | Before sprint |
| `sprint-plan.md` | Dev Team | Phase 1 |
| `product-review.md` | VP of Product (auto) | Phase 1 + 3 |
| `vp-eng-review.md` | VP of Engineering (auto) | Phase 1 |
| `security-review.md` | VP of Security (auto) | Phase 1 (if needed) |
| `infra-review.md` | VP of DevOps (auto) | Phase 1 (if needed) |
| `vp-datascience-review.md` | VP of Data Science (auto) | Phase 1 + 3 (if sprint involves training, evaluation, A/B tests, gold corpus changes, or any statistical claim) |
| `test-results.md` | Dev Team | Phase 2 |
| `dev-report.md` | Dev Team | Phase 2 |
| `demo-output.md` | Dev Team | Phase 2 |
| `test-eval.md` | VP of Engineering (auto) | Phase 3 |

---

## Bug and Scope Handling

| Situation | Action |
|-----------|--------|
| Bug is in scope for this sprint | Fix it. Note in dev report under Deviations. |
| Bug is out of scope | File `docs/backlog/bugs/BUG-XXX.md`. Don't fix here. |
| Out-of-scope bug blocks sprint | File bug report AND escalate to CEO. |
| New work needed outside sprint scope | Stop. Present to CEO before doing anything. |

---

## Parallel Work

Multiple contributors can run sprints simultaneously on separate feature branches. Each has their own Claude Code session reading the same CLAUDE.md. No real-time coordination needed — branches merge when ready.

---

## Tier 2 Reviews (Per Sprint)

VP Eng and VP Prod review every sprint in two passes:

- **Pre-sprint (plan review):** Evaluate the sprint plan before work begins. Catch scope creep, missing dependencies, and unambiguous acceptance criteria.
- **Post-sprint (evaluation):** Evaluate what was built. Assess against requirements, test coverage, and architectural standards.

Security and DevOps review sprints that touch their domains.

---

## Artifact Directory Structure

```
docs/
  roadmap/
    ROADMAP.md                     # VP of Product owns; always current
    prds/
      PRD-XXX-{slug}.md            # One per feature; RICE-scored
      _templates/prd-template.md
    competitive/                   # Competitive briefs
  architecture/
    decisions/
      ADR-XXX-{slug}.md            # One per architectural decision; RICE-scored
      _templates/adr-template.md
  sprints/
    sprint-XX/                     # All sprint artifacts — committed, not gitignored
    _templates/                    # Sprint document templates
  ideation/
    YYYY-MM-DD-{slug}/             # IDEO sprint outputs
    _templates/ideation-goal.md
  backlog/
    bugs/                          # Out-of-scope bugs filed during sprints
  personas/
    PROTOCOL.md                    # This file
    vp-engineering.md
    vp-product.md
    vp-security.md
    vp-compliance.md
    vp-devops.md
    vp-datascience.md
    dev-team.md
    concerns/                      # Project-specific concern files (committed)
    context/                       # Private deep context (gitignored)
```

---

## Document Freshness Rules

These documents must always reflect current reality:

| Document | Owner | When to Update |
|----------|-------|---------------|
| `ROADMAP.md` | VP of Product | After every sprint review |
| `PRD-XXX.md` Status fields | VP of Product | When requirements complete, defer, or cancel |
| `ADR-XXX.md` Status fields | VP of Engineering | When decisions are validated, superseded, or deprecated |

A stale roadmap or PRD is a broken contract. VP of Product is responsible for freshness after every product review.
