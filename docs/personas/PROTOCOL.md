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
| **QA-UX** | `— QA` | Claude/MCP-enabled (drives live app) + gemini for SOFT judgment | `/qa-ux <sprint-dir> --mode plan\|drive` |
| **CEO** | — | Human | All approval gates |

> **QA-UX artifacts** live in the sprint dir: `qa-plan.md` (authored at planning — HARD vs SOFT
> assertions, in-scope surfaces, hero shots), `qa-report.md` (the accept-time defect report by
> severity + fault-domain), `flow-graph.json`/`flow-graph.md` (derived UX state-graph, sprint-scoped),
> and `assets/` (provenance-stamped, redacted hero shots). Unlike VP reviews, QA-UX **drives the
> running app** (DOMShell MCP / CLI / the repo's own MCP) — it is not a text review.

### Review Engine Model

VP reviews are automated via CLI tools. Configure once — all scripts use it.

| Engine | CLI Used | Best For |
|--------|----------|----------|
| `subagent` | Claude Code Agent tool, in-session | **DEFAULT.** Subscription pool, no API key, no external CLI |
| `kimi` | OpenRouter (`moonshotai/kimi-k2.6`) | Cross-FAMILY independent reviewer. Metered but non-Anthropic (pennies). Needs `OPENROUTER_API_KEY` |
| `codex` | OpenAI Codex CLI (`codex exec`) | A second cross-family reviewer. ⚠️ untested |
| `handoff` | Interactive Claude window | Subscription pool; the review runs in its own Terminal session |
| ~~`gemini`~~ | ~~Gemini CLI~~ | ⛔ UNAVAILABLE — no CLI access on this plan since 2026-06-19, API path unused. Resolves to `subagent` with a warning |
| ~~`claude-p`~~ | ~~`claude -p`~~ | ⛔ METERED Anthropic API. Quarantined: needs `REVIEW_ALLOW_METERED=1` per invocation |

**Configure:** Create `.review-engine` in the **repo root** — not under `.claude/`, which nothing reads — containing one word: `subagent`, `kimi`, `codex`, or `handoff`.  
**Override:** `REVIEW_ENGINE=kimi ./scripts/agentic/vp-review.sh ...`  
**Default:** if neither is set, `subagent`. Full precedence and aliases: `scripts/agentic/resolve-review-engine.sh`.

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
