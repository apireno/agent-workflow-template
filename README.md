# Agent Workflow Template

A structured multi-agent development workflow using AI agents as CTO, VP of Engineering, VP of
Product, VP of Security, VP of Compliance, VP of DevOps, VP of Data Science, QA-UX, and Dev Team.
Orchestrates one or many repos from a single CTO session — built for solo developers or small
teams who want AI agents to simulate a full engineering org, with real process discipline instead
of ad-hoc prompting.

## What Problem This Solves

When you use AI agents for development, the hardest problems aren't technical — they're process.
Agents skip steps, drift from scope, produce inconsistent artifacts, and don't coordinate well
across repos. This template encodes an entire engineering workflow into files and Claude Code
**skills** that ship with the repo: plan → review → execute → verify → accept, enforced the same
way every time, across as many repos as you're running.

The process is the repo. Clone it and the engineering culture comes with it.

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/agent-workflow-template.git
cd agent-workflow-template
```

Open the folder in **Claude Code** (or Gemini's Antigravity extension) and say:

> **please set up my environment**

That's it. The agent checks prerequisites, asks the handful of setup questions it actually needs
answered, discovers any repos you've already cloned nearby and offers to register them, and writes
your project registry. This runs automatically on the very first session even if you don't type
the prompt — a `[FIRST-RUN]` notice fires before anything else happens.

Under the hood this invokes the **`/setup`** skill. Re-run it any time (just ask again) to add more
repos to an already-configured setup.

### Prerequisites

- **Git**, and `git config user.name`/`user.email` set.
- **A Claude Code (or Antigravity) session** — that's the only required "engine." No LLM CLI
  install is required: VP reviews run in-session by default (`subagent` engine, $0 incremental).
- **Optional:**
  - [`gh` CLI](https://cli.github.com/), authenticated — needed to publish new repos from `/new-project`.
  - An `OPENROUTER_API_KEY` — unlocks the `kimi` review engine (a genuinely independent,
    cross-model-family reviewer; useful when you want a second opinion that isn't the same model
    family as the one that wrote the code). Costs pennies per review; nothing works incorrectly
    without it.

## Architecture

### CTO Home + Dev-Team Fleet

This repo can operate two ways, and `/setup` asks which fits:

- **In place** — this clone itself becomes your CTO operating home. Simplest; fine for a personal
  setup or a private fork.
- **Spawn a private `<project>-cto` home** — keep this clone as a clean, reusable template (e.g.
  if it tracks a shared/public upstream) and scaffold a separate private repo that holds your
  actual project IP (PRDs, ADRs, decisions) plus a copy of the mechanism. See `/new-project`.

Either way, the CTO session orchestrates one or more **dev-team repos** registered in
`.cto/projects.yaml`. Each dev-team repo gets its own `CLAUDE.md` (from `CLAUDE.devteam.md`),
persona files, and `scripts/agentic/` — pushed there by `/setup` or `scripts/cto/push-to-repos.sh`.

### Sprint Lifecycle (per dev-team repo, CTO-orchestrated)

```
Phase 0  DECOMPOSITION     CEO + CTO scope the work, propose before firing dev teams.
Phase 1  SPRINT PLANNING   Dev team drafts sprint-plan.md -> VP review -> CEO approves.
Phase 2  EXECUTION         Dev team implements on a Terminal-tab session (/handoff).
Phase 3  EVALUATION        /sprint-verify (objective: did we build what the plan said?)
                            -> /sprint-accept (decision: ship, ship-with-known-issues, or revise).
```

Verification and acceptance are deliberately separate steps: `/sprint-verify` produces
`conformance.md` (facts — MET/NOT-MET/UNVERIFIED per acceptance criterion, no ship decision);
`/sprint-accept` reads it and makes the call. Accepting with documented known-issues is a valid,
explicit outcome — never a silent "all green."

### Agents, Strict Boundaries

| Role | Signature | Does | Doesn't |
|------|-----------|------|---------|
| **CTO** | `— CTO` | Orchestrates dev teams + VPs across repos, synthesizes decisions | Write code, write PRDs, review-and-not-orchestrate |
| **VP of Engineering** | `— Eng` | Reviews plans, writes ADRs, evaluates tests, does RCAs | Write code, fix bugs, author PRDs |
| **VP of Product** | `— Prod` | Writes PRDs, owns roadmap, scopes sprints | Write code, make architecture decisions |
| **VP of Security** | `— Sec` | Threat models, security reviews | Write code, implement controls |
| **VP of Compliance** | `— Comp` | Regulatory + ToS reviews | Write code, provide legal advice |
| **VP of DevOps** | `— DevOps` | Infra reviews, deployment readiness | Write code, write IaC/CI YAML |
| **VP of Data Science** | `— Data` | Statistical validity review, experiment design co-authorship | Write code, training scripts, author PRDs/ADRs solo |
| **QA-UX** | `— QA` | Drives the live product (browser/CLI/MCP) as a skeptical user, routes defects | Fix bugs, write code, write plans |
| **Dev Team** | `— Dev` | Writes code, tests, sprint plans, dev reports | Write PRDs, ADRs, create initiatives |

### Configurable Review Engine

VP reviews run through one of several engines — a per-repo `.review-engine` file (or the
`REVIEW_ENGINE` env var) picks which:

| Engine | What runs the review | Cost | Notes |
|--------|----------------------|------|-------|
| `subagent` (default) | Claude Code Agent tool, in-session | $0 incremental (subscription) | Bright-line clean; the safe default |
| `kimi` | `moonshotai/kimi-k2.6` via OpenRouter | ~pennies/review | Cross-model-family independent reviewer; needs `OPENROUTER_API_KEY` |
| `gemini` | Gemini CLI | Free tier (when available) | Selectable if/when access returns |
| `handoff` | A real interactive Claude window per reviewer | $0 incremental (subscription) | Heavier; rarely needed |
| `claude-p` | `claude -p` (metered Anthropic API) | ⚠️ Metered | Quarantined — requires explicit `REVIEW_ALLOW_METERED=1` opt-in, never a default |

```bash
echo "kimi" > .review-engine       # this repo's default going forward
REVIEW_ENGINE=subagent ./scripts/agentic/vp-review.sh vp-eng plan.md out.md   # one-off override
```

## Key Skills

Everything below is a Claude Code skill (`.claude/skills/`) — invoke by asking naturally, or with
the explicit slash command.

| Skill | What it does |
|-------|---------------|
| `/setup` | First-time onboarding — prerequisites, registry, repo deployment. Re-run to add repos. |
| `/new-project` | Scaffold a private `<project>-cto` home, greenfield or adopting an existing fleet. |
| `/vp-review` | Fan a sprint plan/ADR/dev-report out to VP personas in parallel, synthesize a verdict. |
| `/sprint-fanout` | Draft per-repo sprint plans from a shared PRD/goal. |
| `/handoff` | Launch a dev-team session per repo (Terminal tab, auto-briefed). |
| `/peek` / `/send` | Watch / message a running dev-team session without spawning a new tab. |
| `/sprint-status` | Fleet-wide at-a-glance: who's running, idle, crashed, or done. |
| `/sprint-verify` | Objective conformance check — did the sprint deliver what the plan said? |
| `/sprint-accept` | The ship decision — reads plan + report + reviews + `conformance.md`. |
| `/qa-ux` | Drive the live product as a skeptical user; produce a defect report. |
| `/close-window` / `/resume-dev-team` | Wind down a finished session / recover a crashed one. |
| `/arch-map` / `/lane-check` | RACI + component map; enforce declared cross-repo import boundaries. |
| `/digest` / `/escalate-drain` | Daily fleet status digest; drain pending escalations from dev teams. |

## What's Included

```
CLAUDE.md                     # CTO persona + orchestration protocol — loaded automatically
CLAUDE.devteam.md             # Dev-team persona, pushed into each registered repo
.claude/skills/               # Every skill listed above
.claude/hooks/                # SessionStart preflight, session tracking, auto-paste-brief
.cto/projects.yaml.example    # Copy to .cto/projects.yaml — your fleet registry (gitignored)
scripts/agentic/               # vp-review.sh, resolve-review-engine.sh, openrouter-chat.sh, ...
scripts/cto/                   # push-to-repos.sh, sync-cto-home.sh, orchestrate-sprint.sh, ...
docs/
  personas/                    # cto.md + every VP + dev-team + qa-ux persona definition
    context/                   # Private domain context (gitignored)
    concerns/                  # Project-specific concerns (security/compliance/devops)
  roadmap/prds/                # Your PRDs live here
  architecture/decisions/      # ADRs
  sprints/_templates/          # scope.md, conformance.md, and other sprint doc templates
  ideation/_templates/         # IDEO-sprint goal template
```

## Customization

1. **Project Concerns** — fill in `docs/personas/concerns/security.md`, `compliance.md`,
   `devops.md` with your actual security posture, regulatory landscape, and infra inventory.
2. **Persona Domain Knowledge** — fill in the `<!-- CUSTOMIZE -->` sections in each persona file.
3. **Private Context** — `docs/personas/context/*.md` for deep project knowledge (gitignored).
4. **VP Review Composition** — `docs/personas/cto.md` documents which VPs run by default vs. by
   content judgment (default is `vp-prod` + `vp-eng`; add `vp-security`/`vp-devops`/
   `vp-datascience` when the artifact touches their domain).

## IP Separation: Public Template vs. Private CTO Repo

If this clone tracks a public/shared template, keep it that way — mechanism only, no project IP.
Real project PRDs, ADRs, strategy docs, and decisions belong in a private `<project>-cto` repo
(see `/new-project`). `docs/personas/cto.md` has the full policy; the short version: a `git rm`
does not remove history from a public repo, so keep IP out from the start.

## License

MIT
