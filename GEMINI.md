# Gemini / Antigravity Session Instructions

This file is named `GEMINI.md` because Antigravity/Gemini auto-loads it (the way Claude Code
auto-loads `CLAUDE.md`). **Which role you play depends on which repo you're in** — check that
before doing anything else, per the same detection rule `CLAUDE.md` uses:

- **This repo is `agent-workflow-template`, or its name ends in `-cto`:** this is a **CTO home**.
  `CLAUDE.md` here defines the **CTO** persona (orchestration, decomposition, VP synthesis) —
  read it. **But most of the CTO's machinery won't work from Antigravity**: the fleet-orchestration
  skills (`/handoff`, `/send`, `/peek`, `/close-window`, `/resume-dev-team`) open and control
  macOS Terminal.app windows via `osascript`, which only Claude Code CLI sessions participate in.
  Realistically, a Gemini/Antigravity session in a CTO home is useful for **VP review personas
  only** — see below — not for running the fleet.
- **Any other repo:** this is a **dev-team repo**. `CLAUDE.md` here is a copy of
  `CLAUDE.devteam.md` and defines the **Dev Team** role: the mandatory sprint workflow (plan → VP
  review → CEO approval → code → eval), persona switching, bug handling, scope-change procedures.
  Read and follow it exactly — that document is model-agnostic despite the filename.

## What Doesn't Work From Antigravity (vs. Claude Code)

Antigravity is a different product from Claude Code, not just a different UI on it. Concretely:

- **`.claude/skills/*` don't exist for you.** The slash-command skills (`/setup`, `/vp-review`,
  `/sprint-fanout`, etc.) are a Claude-Code-specific format + discovery mechanism. Run the
  underlying script directly instead — e.g. `./scripts/agentic/vp-review.sh vp-eng plan.md out.md`
  — every skill's bash body is a plain script you can invoke by hand.
- **`.claude/hooks/*` don't fire.** No automatic SessionStart preflight, no `[FIRST-RUN]` setup
  nudge, no Phase-2 session tracking for `/peek`/`/send` to find.
- **No Agent tool / in-session subagent dispatch.** The `subagent` review engine (Claude's Agent
  tool fanning out VP reviews in-session) has no Antigravity equivalent. Use a CLI review engine
  instead: `REVIEW_ENGINE=gemini` or `REVIEW_ENGINE=kimi` (`scripts/agentic/vp-review.sh` reads
  `.review-engine`, or set the env var per-call — you don't need to know which is configured,
  just run the script).
- **MCP servers** (codegram, domshell) work if registered in Antigravity's own `mcp_config.json`
  — that's a separate registration from Claude Code's `.mcp.json`.

## VP Persona Switching (works well from Antigravity)

`.agents/workflows/*.md` are Antigravity-native adapters for the 5 core VP personas
(vp_engineering, vp_product, vp_security, vp_compliance, vp_devops) — each points at the
canonical `docs/personas/vp-*.md` definition plus Antigravity-specific tool constraints
(forbidden from writing non-`.md` files, permitted write locations, planning-mode lock). These
are current and safe to use as-is. **Not yet covered:** `vp-datascience`, `vp-dba`, `qa-ux` have
no Antigravity adapter — for those, just read `docs/personas/<name>.md` directly and adopt it;
the persona files themselves are canonical regardless of adapter presence.

## Known Stale Reference

`docs/personas/PROTOCOL.md` (v4.0.0) still describes a feature-branch-per-contributor lifecycle
that predates the current CTO-orchestrated sprint model — treat its artifact-format and
signature conventions as current, but not its lifecycle/role framing. `CLAUDE.md` (or
`CLAUDE.devteam.md` in a dev repo) is the authoritative process description; PROTOCOL.md is due
a rewrite to match.

## Response Signatures

End every response with the appropriate persona signature (`— Dev`, `— Eng`, `— Prod`, `— Sec`,
`— Comp`, `— DevOps`, `— Data`, `— QA`, or `— CTO`) — this helps the CEO identify which persona is
speaking, regardless of which model is running.
