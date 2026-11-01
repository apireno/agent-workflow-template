# Memo — Permissions posture as a template mechanism: silent routine, prompted risk, remote approval

**To:** agentic workflow team (`agent-workflow-template`) · **From:** CTO (a project home) · **Date:** 2026-11-01 · **Requested by:** CEO ("rather than me changing these this sounds like a permissions step for agentic team")

## 1. The problem, as observed on 2026-11-01

The CEO is often remote and wants to say "yes" to something from a phone and have it execute on the host. Today that does not work, for four reasons, all of them mechanism, none of them project-specific:

1. **Auto mode never asks.** Its classifier refuses outright (observed categories: Unauthorized Persistence for a launchd load and a CI-runner service install; Create Public Surface for a push to the public template; Unverifiable Deletion Scope / Irreversible Local Destruction for a scripted worktree reap; Self-Modification when the CTO tried to add allow rules). A refusal has no prompt, so there is nothing to approve remotely. The CTO's fallback was "paste this command with `!`", which is exactly what the CEO does not want.
2. **The shipped settings carry a no-op catch-all.** `.claude/settings.local.json` in the CTO home lists `"Bash(*)"`. That is an exact match for a command whose text is `*`; the wildcard forms are `Bash(prefix *)` / `Bash(prefix:*)` and the catch-all is the bare `Bash`. Proof: a `launchctl load` still prompted and the CEO's "always" wrote `Bash(launchctl load *)`.
3. **There is no bypass toggle.** Shift+Tab cycles default → accept-edits → plan → auto. Bypass is a launch flag or a settings value only. The CTO told the CEO otherwise; that cost a round trip.
4. **The CTO cannot fix its own permissions** (self-modification is refused, correctly). So the posture has to arrive as mechanism, by sync, like hooks and skills do.

## 2. The posture we want (ruling)

| | routine shepherding | risky commands | decisions |
|---|---|---|---|
| what | peek, send, commit lane work, log, tick, VP reviews, reports | push to a public repo, PR merge, service / launchd install, bulk delete, object-store write | sprint go, accepts, promotions |
| mechanism | `allow: ["Bash", …]` → runs silently | `ask: [prefix list]` → one ordinary permission prompt, forwarded by Remote Control, "always" persists it | the CEO's words in the conversation, recorded by the CTO (`record-approval.sh`) |
| mode | accept-edits (`defaultMode`) | same | same |

Auto mode stays available for sessions nobody can answer (true overnight runs), and the preflight should say which mode the session is in and what that implies.

## 3. What the template team delivers

1. **`.claude/settings.cto.json.template`** carries the posture: `allow` with the bare `Bash` (plus Edit/Write/Read/Glob/Grep/WebFetch/WebSearch, the Skill(...) and MCP entries already there), an `ask` list, and `"defaultMode": "acceptEdits"`. First ask list (the fleet's risky-command inventory; projects may extend it):
   `Bash(git push *)`, `Bash(gh pr merge *)`, `Bash(launchctl *)`, `Bash(rm -rf *)`, `Bash(./svc.sh *)`, `Bash(./config.sh *)`, `Bash(aws s3 rm *)`, `Bash(aws s3 cp *)`, `Bash(docker * rm *)`.
2. **Preflight drift check (CLAUDE.md Step 2) extended:** flag any `Bash(*)` entry as a no-op, flag a missing `ask` block or `defaultMode`, and offer to apply the template. The lint that already guards skills (`scripts/cto/lint-skills.sh`) gets a sibling check for settings files: no `Bash(*)`, `ask` present in a CTO home.
3. **`/setup` and `/new-project`** write the same posture into a new CTO home; dev repos' `.claude/settings.permissive.json` get the same `allow`/`ask` shape (lanes never push or merge anyway; `deny-self-commit` stays).
4. **`docs/personas/cto.md` "Permissions posture"** section: the table above; the rule that a classifier refusal is never answered with a paste-me command (ask the CEO for a moment in default mode so the prompt appears, or route the action outside the session, e.g. the hourly `com.acme.repo-hygiene` launchd job); Remote Control (`/rc`) is how prompts reach a remote CEO; Shift+Tab has no bypass.
5. **Approval provenance stays what it is:** the harness prompt is a permission to execute; the CEO's recorded words remain the fleet's approval of record for gates. Both are needed for a gated action; neither replaces the other.

## 4. Acceptance

- A fresh CTO home from the template starts in accept-edits; `git status`, `/peek`, `/send`, lane commits run without a prompt; `git push` and `gh pr merge` prompt once each; with Remote Control connected the prompt is visible on the phone and "always" persists as a `Bash(git push *)` rule.
- A day of shepherd ticks (window peeks, commits, log appends, reaps by explicit name) produces zero classifier refusals.
- The drift check reports the no-op entry in this CTO home's current file and applies the corrected posture on "yes".
- `test-escalate-to-cto.sh`-style test for the settings lint (no `Bash(*)` anywhere in `.claude/settings*.json`).

**Estimate:** ≈ 3 h lane time (template change, lint, docs, tests) + 0.5 h CTO verification on this host. **Lands by:** the next template sync to the fleet; this CTO home applies it through the Step-2 drift prompt.

**Not in scope:** changing what the auto-mode classifier blocks (vendor behaviour); replacing recorded CEO approvals with harness prompts.

— CTO
