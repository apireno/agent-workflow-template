# Inter-Agent Communication Protocol

**Version:** 3.0.0
**Last Updated:** YYYY-MM-DD

---

## Overview

This protocol defines the three-tier development lifecycle for multi-contributor, multi-agent projects. Each contributor runs their own Claude Code session (Dev Team agent) on a feature branch. VP reviews are automated via Gemini CLI. The CEO serves as the human-in-the-loop at approval gates. All handoffs pass through structured artifacts (markdown files) in the repo.

### Why This Protocol Exists

When multiple contributors work on the same codebase — each with their own AI agent — consistency is the hardest problem. This protocol solves it by encoding the entire engineering workflow into files that ship with the repo. Every contributor's agent reads the same CLAUDE.md, follows the same sprint lifecycle, and gets reviewed by the same VP personas with the same standards. The process is the repo.

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

### Review Engine Model

VP reviews are automated via CLI tools. The engine is configurable — set it once and all scripts use it.

**Engine options:**

| Engine | CLI Used for Reviews | Best For |
|--------|---------------------|----------|
| `gemini` | Gemini CLI | Teams using Claude Code for dev + Gemini for independent reviews |
| `claude` | Claude CLI (`claude -p`) | Teams using Claude only — review runs as a fresh CLI process with no shared context from the dev session |
| `dual` | Both (Gemini primary, Claude secondary) | Maximum coverage — two independent reviews per artifact |

**How to set the engine:**

1. **Config file** (recommended): Create `.review-engine` in the repo root containing one word: `gemini`, `claude`, or `dual`
2. **Environment variable**: `REVIEW_ENGINE=claude ./scripts/agentic/vp-review.sh ...`
3. **Auto-detect**: If neither is set, the script finds whichever CLI is installed

**Why the Claude CLI engine works:** When `claude -p` is used for reviews, it spawns a fresh CLI process that has zero shared context with the VS Code session. It only sees the persona + concerns + artifact piped in. This gives the same separation of concerns as calling a different model entirely.

**In-conversation persona switching** is also available via Claude Skills (`/vp-eng`, `/vp-prod`, etc.) for when the CEO wants a second opinion or interactive discussion. This is separate from the automated review engine.

---

## The Three-Tier Development Lifecycle

```
┌─────────────────────────────────────────────────────────────────────┐
│  TIER 1: INITIATIVE (CEO + VP)                                      │
│                                                                     │
│  CEO and a VP define a bounded piece of work — feature, tech debt,  │
│  experiment, bug fix, or hardening effort. This creates the branch  │
│  and the initiative brief that governs all work on that branch.     │
│                                                                     │
│  Script: ./scripts/agentic/start-initiative.sh                      │
│  Artifact: docs/initiatives/INIT-XXX/initiative-brief.md            │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│  TIER 2: SPRINT (Contributor + Dev Team agent)                      │
│                                                                     │
│  One or more sprints execute on the feature branch. Each sprint     │
│  follows the mandatory 3-phase sequence (Plan → Execute → Eval).    │
│  Every sprint must trace to items in the initiative brief.          │
│                                                                     │
│  Script: ./scripts/agentic/start-sprint.sh                          │
│  Artifacts: docs/initiatives/INIT-XXX/sprints/sprint-YY/            │
│                                                                     │
│  Sprint VP reviews: VP Eng + VP Prod (mandatory)                    │
│  Sprint VP reviews: VP Security + VP DevOps (when relevant)         │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│  TIER 3: MERGE GATE (Full VP panel + CEO)                           │
│                                                                     │
│  When all initiative exit criteria are met, the branch goes through │
│  a comprehensive merge review with ALL five VPs before merging to   │
│  main. This is the quality gate that protects main.                 │
│                                                                     │
│  Script: ./scripts/agentic/request-merge.sh                         │
│  Artifacts: docs/initiatives/INIT-XXX/merge-review/                 │
│                                                                     │
│  Merge VP reviews: ALL VPs (mandatory)                              │
│  - VP Engineering: architecture coherence across all sprints        │
│  - VP Product: feature acceptance against initiative brief          │
│  - VP Security: cumulative security review                          │
│  - VP Compliance: cumulative compliance review                      │
│  - VP DevOps: deployment and operational readiness                  │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐      │
│  │  >>> CEO MERGE APPROVAL: merge to main or iterate <<<    │      │
│  └───────────────────────────────────────────────────────────┘      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Tier 1: Initiative Lifecycle

### Who Creates Initiatives

Only the CEO, VP of Engineering, or VP of Product can propose an initiative. The Dev Team does not create initiatives — they execute sprints within them.

### Initiative Types

| Type | Branch Prefix | Typical Duration | Example |
|------|--------------|------------------|---------|
| Feature | `feature/` | 2-5 sprints | `feature/tuner-v2` |
| Tech Debt | `debt/` | 1-3 sprints | `debt/test-coverage` |
| Experiment | `experiment/` | 1-2 sprints | `experiment/llm-caching` |
| Bug Fix | `fix/` | 1 sprint | `fix/graph-corruption` |
| Hardening | `harden/` | 1-3 sprints | `harden/api-security` |

### Initiative Brief

The initiative brief (`docs/initiatives/INIT-XXX/initiative-brief.md`) is the constitution for the branch. It contains:

- **Goal** — what and why
- **References** — linked PRDs, ADRs, bugs, roadmap items
- **Scope** — in-scope deliverables with acceptance criteria
- **Explicit exclusions** — what's out of scope (contract against scope creep)
- **Exit criteria** — what must be true before the branch can merge
- **Sprint log** — append-only record of sprints completed

### Scope Amendments

If scope needs to change during an initiative:

1. The dev team writes a scope amendment document (`docs/initiatives/INIT-XXX/amendments/NNN-description.md`)
2. The relevant VP reviews the amendment
3. The CEO approves or rejects
4. The amendment summary is appended to the initiative brief's Amendments table

Scope changes are NEVER made by silently editing the In Scope section. The amendment trail is the audit log.

---

## Tier 2: Sprint Lifecycle (within an initiative)

Sprints are the execution unit. They live within an initiative's folder and must reference the initiative brief.

### Sprint Folder Location

Sprints live at: `docs/initiatives/INIT-XXX/sprints/sprint-YY/`

### The Mandatory Sprint Sequence

```
┌─────────────────────────────────────────────────────────────┐
│  PHASE 1: PLANNING (Dev agent orchestrates)                  │
│                                                              │
│  1. Dev reads initiative-brief.md + sprint scope             │
│  2. Dev writes sprint-plan.md                                │
│  3. Dev calls: vp-review.sh vp-prod → product-review.md     │
│  4. Dev calls: vp-review.sh vp-eng → vp-eng-review.md       │
│  5. Dev calls: vp-review.sh vp-security → security-review.md│
│     (if sprint has security implications)                    │
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
│  9.  Dev writes and runs tests                               │
│  10. Dev saves test results to test-results.md               │
│  11. Dev writes dev-report.md with demo steps                │
│  12. Dev runs [AUTO] demo steps → demo-output.md             │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│  PHASE 3: EVALUATION (Automated + CEO)                       │
│                                                              │
│  13. Dev calls: vp-review.sh vp-prod (dev-report)            │
│      → product-review.md                                     │
│  14. Dev calls: vp-review.sh vp-eng (dev-report)             │
│      → test-eval.md                                          │
│  15. Dev presents all evaluations to CEO                     │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  >>> CEO APPROVAL GATE: accept / iterate <<<        │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│  PHASE 4: CLOSE                                              │
│                                                              │
│  16. Dev updates initiative brief sprint log                 │
│  17. VP Eng writes RCA if bugs found (via Gemini CLI)        │
│  18. CEO closes sprint                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Tier 3: Merge Gate

### When to Request a Merge

A merge review is triggered when:
- All exit criteria in the initiative brief are met, OR
- The CEO decides to ship what's done (with documented exceptions)

### Merge Review Process

1. Dev team runs `./scripts/agentic/request-merge.sh INIT-XXX`
2. The script generates a diff summary and runs all five VP reviews
3. Dev team reads all review files and addresses BLOCKER items
4. Dev team presents the merge review summary to the CEO
5. CEO gives merge approval or sends back for iteration

### Merge Review Artifacts

```
docs/initiatives/INIT-XXX/merge-review/
  diff-summary.md          # Auto-generated by request-merge.sh
  eng-review.md            # VP Engineering — architecture coherence
  prod-acceptance.md       # VP Product — feature acceptance
  security-review.md       # VP Security — cumulative security review
  compliance-review.md     # VP Compliance — cumulative compliance review
  devops-review.md         # VP DevOps — deployment readiness
  merge-checklist.md       # Checklist with VP verdicts and CEO decision
```

### Post-Merge

After the CEO approves and the branch is merged:
1. The initiative brief's Status changes to `Completed`
2. The branch can be deleted
3. Other active branches should rebase onto the updated main

---

## Bug and Scope Change Handling

### Bugs Discovered During a Sprint

| Situation | Action |
|-----------|--------|
| Bug is within this initiative's scope | Fix it in the current sprint. Note in dev report. |
| Bug is unrelated to this initiative | File a `docs/backlog/bugs/BUG-XXX.md`. Do NOT fix it on this branch. |
| Bug blocks this initiative's work | File the bug report AND escalate to CEO for triage. |

### Scope Creep Prevention

The dev team MUST NOT add work that doesn't trace to the initiative brief's In Scope section or an approved amendment. If new work is needed:

1. Write a scope amendment document
2. Get VP review and CEO approval
3. Only then add the work to a sprint

---

## Review Types by Persona and Tier

| Persona | Tier 2 (Sprint) Reviews | Tier 3 (Merge) Reviews |
|---|---|---|
| VP Product | Sprint plan review, delivery evaluation | Feature acceptance against initiative brief |
| VP Engineering | Sprint plan review, test evaluation | Architecture coherence, tech debt assessment |
| VP Security | Sprint plan review (if security implications) | Cumulative security review (MANDATORY) |
| VP Compliance | Sprint plan review (if compliance implications) | Cumulative compliance review (MANDATORY) |
| VP DevOps | Sprint plan review (if infra changes) | Deployment readiness (MANDATORY) |

---

## Routing Rules for the CEO

1. **Three approval gates.** Initiative brief approval (Tier 1), sprint plan approval (Tier 2), and merge approval (Tier 3).
2. **Bug triage.** When a dev team files a bug that's outside their initiative's scope, you decide: new initiative, add to existing initiative (via amendment), or backlog.
3. **Scope amendments.** Approve or reject scope changes. The amendment trail is your audit log.
4. **VP reviews are automated.** The dev agent calls Gemini CLI for you. You read the reviews alongside the plan.
5. **Break loops.** If a dev agent iterates more than twice on a plan, make a decision and move forward.
6. **Escalate conflicts.** VP disagreements across reviews are your call.
7. **Parallel initiatives.** Multiple branches can run simultaneously. Different contributors, different Claude Code sessions, same protocol.

---

## Parallel Work: Multiple Contributors

### How It Works

Each contributor:
1. Clones the repo (or pulls latest main)
2. Runs `start-initiative.sh` or checks out an existing initiative branch
3. Opens Claude Code — the agent reads CLAUDE.md and follows this protocol
4. Runs sprints independently on their feature branch

Contributors don't need to coordinate in real-time. The protocol and file-based artifacts handle consistency. The merge gate (Tier 3) is where integration happens.

### Conflict Management

When two initiative branches modify overlapping files:
1. The first branch to merge wins — its changes land on main
2. The second branch must rebase onto the updated main before merge
3. If rebase introduces conflicts, the dev team resolves them
4. After resolving conflicts, re-run tests and get a fresh VP Eng review
5. The merge checklist includes a "rebased onto current main" checkbox

---

## Gemini CLI Wrapper

```bash
# Sprint-level VP reviews (Tier 2):
./scripts/agentic/vp-review.sh <persona> <input-file> <output-file>

# Merge-level VP reviews (Tier 3):
./scripts/agentic/request-merge.sh <init-id>

# Personas: vp-eng, vp-prod, vp-security, vp-compliance, vp-devops
```

The `vp-review.sh` wrapper:
1. Reads the persona definition md
2. Reads the project concerns file (if the persona has one)
3. Reads the private context file (if it exists)
4. Reads the protocol (this file)
5. Appends a mandatory anti-jailbreak suffix
6. Pipes everything to `gemini` CLI
7. Writes the response to the output file

The `request-merge.sh` wrapper:
1. Generates a diff summary (main...HEAD)
2. Collects the initiative brief, latest dev report, and test results
3. Runs all five VP reviews with merge-specific prompts
4. Writes all review files to the initiative's merge-review/ folder

---

## File Naming Conventions

```
docs/
  initiatives/
    _templates/
      initiative-brief.md                # Initiative brief template
      amendments/
        scope-amendment.md               # Scope change template
      merge-review/
        merge-checklist.md               # Merge gate checklist template
    INIT-XXX/                            # One folder per initiative
      initiative-brief.md                # The constitution for this branch
      amendments/
        001-add-caching.md               # Scope amendments (numbered)
      sprints/
        sprint-01/
          scope.md                       # VP Product or Dev Team
          sprint-plan.md                 # Dev Team
          vp-eng-review.md               # VP Eng (via Gemini CLI)
          product-review.md              # VP Product (via Gemini CLI)
          security-review.md             # VP Security (optional per sprint)
          dev-report.md                  # Dev Team
          test-results.md                # Dev Team
          test-eval.md                   # VP Eng (via Gemini CLI)
          demo-output.md                 # Dev Team
        sprint-02/
          ...
      merge-review/
        diff-summary.md                  # Auto-generated
        eng-review.md                    # VP Eng
        prod-acceptance.md               # VP Product
        security-review.md               # VP Security
        compliance-review.md             # VP Compliance
        devops-review.md                 # VP DevOps
        merge-checklist.md               # Checklist with CEO decision
  backlog/
    bugs/
      BUG-XXX-description.md            # Bug reports filed by dev teams
    ideas/
      IDEA-XXX-description.md           # Feature ideas for future initiatives
  sprints/
    _templates/                          # Sprint artifact templates
```
