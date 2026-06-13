# Agent Workflow Template

A structured multi-agent development workflow using AI agents as VP of Engineering, VP of Product, VP of Security, VP of Compliance, VP of DevOps, and Dev Team. Designed for solo developers or small teams who use Claude Code + Gemini CLI to simulate a full engineering org — with support for parallel initiatives and multiple contributors.

## What Problem This Solves

When you use AI agents for development, the hardest problems aren't technical — they're process. Agents skip steps, drift from scope, produce inconsistent artifacts, and don't coordinate well across branches. This template encodes your entire engineering workflow into files that ship with the repo. Every contributor's agent reads the same instructions, follows the same lifecycle, and gets reviewed against the same standards.

The process is the repo. Clone it and the engineering culture comes with it.

## Quick Start

```bash
# Clone into your project (or use as a GitHub template)
git clone https://github.com/YOUR_USERNAME/agent-workflow-template.git
cd agent-workflow-template

# Run setup
chmod +x setup.sh
./setup.sh "My Project Name"

# Customize the persona files (see setup output for guidance)
```

### Prerequisites

- **At least one LLM CLI** (for automated VP reviews):
  - [Gemini CLI](https://github.com/google-gemini/gemini-cli) — `gemini --version`
  - [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) — `claude --version`
  - Or both (for dual-engine mode)
- **A dev session tool** (where the Dev Team agent runs):
  - Claude Code (VS Code extension or CLI)
  - Gemini in VS Code (Antigravity extension)
  - Any AI coding assistant that reads CLAUDE.md / follows markdown instructions
- Git

## Architecture

### Three-Tier Development Lifecycle

```
┌──────────────────────────────────────────────────────┐
│  TIER 1: INITIATIVE                                   │
│  CEO + VP define a bounded piece of work.             │
│  Creates a feature branch + initiative brief.         │
│  → ./scripts/agentic/start-initiative.sh              │
│                                                       │
├──────────────────────────────────────────────────────┤
│  TIER 2: SPRINT (one or more per initiative)          │
│  Dev Team agent executes on the feature branch.       │
│  Plan → VP Review → CEO Approval → Code → Eval       │
│  → ./scripts/agentic/start-sprint.sh                  │
│                                                       │
├──────────────────────────────────────────────────────┤
│  TIER 3: MERGE GATE                                   │
│  All 5 VPs review cumulative changes before merge.    │
│  CEO gives final merge approval.                      │
│  → ./scripts/agentic/request-merge.sh                 │
└──────────────────────────────────────────────────────┘
```

### Six Agents, Strict Boundaries

| Role | Signature | Engine | Does | Doesn't |
|------|-----------|--------|------|---------|
| **VP of Engineering** | `— Eng` | Gemini CLI or Claude | Reviews plans, writes ADRs, evaluates tests, does RCAs | Write code, fix bugs, author PRDs |
| **VP of Product** | `— Prod` | Gemini CLI or Claude | Writes PRDs, owns roadmap, scopes sprints, writes initiative briefs | Write code, make architecture decisions |
| **VP of Security** | `— Sec` | Gemini CLI or Claude | Threat models, security reviews, audit reports | Write code, implement security controls |
| **VP of Compliance** | `— Comp` | Gemini CLI or Claude | Regulatory reviews, ToS compliance checks | Write code, provide legal advice |
| **VP of DevOps** | `— DevOps` | Gemini CLI or Claude | Infra reviews, runbooks, monitoring recs, deployment readiness | Write code, write IaC or CI/CD YAML |
| **Dev Team** | `— Dev` | Claude Code | Writes code, tests, sprint plans, dev reports | Write PRDs, ADRs, create initiatives |

### Configurable Review Engine

VP reviews are automated via CLI. Choose your engine:

| Engine | What Runs Reviews | Set Up |
|--------|-------------------|--------|
| `gemini` | Gemini CLI | Install [Gemini CLI](https://github.com/google-gemini/gemini-cli) |
| `claude` | Claude CLI (`claude -p`) | Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |
| `dual` | Both (two independent reviews) | Install both |

Configure by creating `.review-engine` in the repo root:

```bash
echo "claude" > .review-engine   # Pure Claude
echo "gemini" > .review-engine   # Pure Gemini
echo "dual" > .review-engine     # Both engines
```

Or set per-command: `REVIEW_ENGINE=claude ./scripts/agentic/vp-review.sh ...`

If not configured, auto-detects whichever CLI is installed.

**Why `claude -p` works for reviews:** It spawns a fresh CLI process with zero shared context from your VS Code session. The review process only sees the persona + concerns + artifact piped in — same separation of concerns as calling a different model.

**In-conversation personas** are also available via Claude Skills for interactive discussion.

## How It Works

### Starting an Initiative

An initiative is a bounded piece of work: a feature, tech debt paydown, experiment, bug fix, or hardening effort. The CEO and a VP define it together.

```bash
# Create the feature branch and scaffold the initiative
./scripts/agentic/start-initiative.sh INIT-001 feature/tuner-v2 "Tuner V2 Overhaul"
```

This creates:
- A feature branch (`feature/tuner-v2`)
- An initiative directory (`docs/initiatives/INIT-001/`) with a brief template, amendments folder, sprint folder, and merge review folder

Fill in the initiative brief with the VP, get CEO approval, then start sprinting.

### Running Sprints

Each sprint follows a mandatory 3-phase sequence enforced by CLAUDE.md:

```bash
# Scaffold a sprint within the initiative
./scripts/agentic/start-sprint.sh INIT-001 sprint-01
```

**Phase 1: Planning** — Dev writes sprint plan → VP Prod + VP Eng review via Gemini CLI → Dev addresses feedback → CEO approves.

**Phase 2: Execution** — Dev implements → runs tests → writes dev report with demo steps → runs [AUTO] demos.

**Phase 3: Evaluation** — VP Prod + VP Eng evaluate delivery via Gemini CLI → Dev presents results → CEO gives verdict.

The agent cannot skip steps. CLAUDE.md contains explicit VERIFY steps, mandatory bash commands, and a COMMON MISTAKES section based on observed agent failures.

### Merging to Main

When all initiative exit criteria are met:

```bash
# Run Tier 3 merge review with ALL 5 VPs
./scripts/agentic/request-merge.sh INIT-001
```

This generates a diff summary and runs comprehensive reviews:
- **VP Engineering** — architecture coherence across all sprints
- **VP Product** — feature acceptance against initiative brief
- **VP Security** — cumulative security review of all changes
- **VP Compliance** — regulatory and licensing review
- **VP DevOps** — deployment readiness and operational review

Nothing merges to main without passing all five VP gates and CEO approval.

### Parallel Work

Multiple initiatives can run simultaneously on separate branches. Each contributor:
1. Checks out or creates their initiative branch
2. Opens Claude Code — the agent reads CLAUDE.md and follows the protocol
3. Runs sprints independently

No real-time coordination needed. The merge gate handles integration.

### Bug Handling

When a dev team discovers a bug during a sprint:

| Situation | Action |
|-----------|--------|
| Bug is within this initiative's scope | Fix it, note in dev report |
| Bug is unrelated to this initiative | File `docs/backlog/bugs/BUG-XXX.md`, don't fix it here |
| Bug blocks this initiative | File bug report AND escalate to CEO |

### Scope Changes

If new work is discovered that isn't in the initiative brief:
1. Dev team writes a scope amendment (`docs/initiatives/INIT-XXX/amendments/NNN-description.md`)
2. VP reviews the amendment
3. CEO approves or rejects
4. Amendment is logged in the initiative brief — no silent scope changes

### IDEO Ideation Sprints

Before defining an initiative, run a structured ideation session to explore the solution space. Based on the IDEO sprint methodology, adapted for AI personas:

```bash
# Write a goal file, then run the ideation sprint
./scripts/agentic/ideo-sprint.sh docs/ideation/2025-01-15-caching/goal.md docs/ideation/2025-01-15-caching/
```

The script orchestrates four phases across all VP personas:

| Phase | What Happens | Output |
|-------|-------------|--------|
| **1. Ideate** | Each VP independently generates 8-15+ ideas | `phase1-ideas-{persona}.md` per VP |
| **2. Vote** | Each VP reviews others' ideas, votes with improvement suggestions | `phase2-votes-{persona}.md` per VP |
| **3. Merge** | Facilitator consolidates similar ideas, tallies votes | `phase3-merged-results.md` |
| **4. Produce** | VP Prod drafts PRDs/ADRs from top-voted ideas | `phase4-prds.md` |

Each persona runs as a separate CLI process with zero shared context — ensuring truly independent creative thinking. The voting rule (you can't vote for your own ideas + every vote requires an improvement suggestion) drives cross-pollination.

Top-voted PRD drafts go to the CEO for approval. Approved PRDs seed new initiatives.

## What's Included

```
CLAUDE.md                                    # Claude Code config — loaded automatically
scripts/agentic/
  vp-review.sh                               # Configurable VP review engine
  start-initiative.sh                        # Create branch + scaffold initiative
  start-sprint.sh                            # Scaffold sprint within initiative
  request-merge.sh                           # Run Tier 3 merge reviews
  ideo-sprint.sh                             # IDEO-style ideation sprint
docs/
  personas/                                  # Agent persona definitions
    PROTOCOL.md                              # Three-tier lifecycle (v3)
    vp-engineering.md                        # VP of Engineering persona
    vp-product.md                            # VP of Product persona
    vp-security.md                           # VP of Security persona
    vp-compliance.md                         # VP of Compliance persona
    vp-devops.md                             # VP of DevOps persona
    dev-team.md                              # Dev Team persona
    context/                                 # Private domain context (gitignored)
      README.md
    concerns/                                # Project-specific concerns (committed)
      security.md                            # Security posture and attack surface
      compliance.md                          # Regulatory landscape and ToS
      devops.md                              # Infrastructure inventory and gaps
  initiatives/
    _templates/
      initiative-brief.md                    # Initiative brief template
      amendments/
        scope-amendment.md                   # Scope change template
      merge-review/
        merge-checklist.md                   # Merge gate checklist template
  sprints/
    _templates/                              # Sprint artifact templates (8 files)
  ideation/
    _templates/
      ideation-goal.md                       # IDEO sprint goal template
  backlog/
    bugs/
      bug-report-template.md                 # Bug report template
    ideas/                                   # Future initiative ideas
.agents/workflows/                           # Antigravity adapter files (5 VPs)
.claude/settings.json                        # Claude Code permissions
```

## Customization

After running `setup.sh`, customize:

1. **Initiative Brief** — The template at `docs/initiatives/_templates/initiative-brief.md` defines what information you require for every new piece of work. Adjust the sections to match your team's planning style.

2. **Persona Domain Knowledge** — Fill in the `<!-- CUSTOMIZE -->` sections in each persona file with project-specific knowledge.

3. **Project Concerns** — Fill in `docs/personas/concerns/security.md`, `compliance.md`, and `devops.md` with your project's actual security posture, regulatory landscape, and infrastructure inventory.

4. **Private Context** — Create `docs/personas/context/vp-eng-context.md` and `vp-product-context.md` for deep project-specific knowledge (gitignored — won't leak to public repos).

5. **Technical Standards** — Add your coding standards to the Technical Standards section in `CLAUDE.md`.

6. **Anti-Pattern Watchlist** — Customize the watchlist table in `vp-engineering.md` with your project's specific anti-patterns.

## Branch Naming Conventions

| Initiative Type | Branch Prefix | Example |
|----------------|--------------|---------|
| Feature | `feature/` | `feature/tuner-v2` |
| Tech Debt | `debt/` | `debt/test-coverage` |
| Experiment | `experiment/` | `experiment/llm-caching` |
| Bug Fix | `fix/` | `fix/graph-corruption` |
| Hardening | `harden/` | `harden/api-security` |

## Dev Session + Review Engine Combinations

The template separates two concerns: **who writes the code** (dev session) and **who reviews it** (review engine). Mix and match:

| Dev Session (writes code) | Review Engine (reviews artifacts) | Notes |
|---------------------------|----------------------------------|-------|
| Claude Code (VS Code) | Gemini CLI | Original dual-engine model |
| Claude Code (VS Code) | Claude CLI (`claude -p`) | Pure Claude — review is a fresh process, no shared context |
| Claude Code (VS Code) | Both (dual) | Two independent reviews per artifact |
| Gemini (Antigravity/VS Code) | Claude CLI | Gemini writes code, Claude reviews |
| Gemini (Antigravity/VS Code) | Gemini CLI | Pure Gemini — review is a fresh CLI invocation, stateless |
| Any AI coding tool | Any CLI | Works if the tool reads CLAUDE.md-style instructions |

The `CLAUDE.md` file is named for Claude Code (which auto-reads it), but the content is model-agnostic structured instructions. Gemini's Antigravity extension can also be pointed at this file for project instructions.

## For New Contributors

1. Clone the repo and pull latest main
2. Ask the CEO which initiative to work on (or create one together)
3. Check out the initiative's feature branch
4. Open Claude Code — the agent reads CLAUDE.md and knows the workflow
5. Start sprinting

You don't need to learn the workflow — your agent knows it. The VP reviews enforce quality. The protocol handles consistency.

## License

MIT
