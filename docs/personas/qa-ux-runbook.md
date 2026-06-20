# QA-UX Browser-Drive Runbook (DOMShell)

> **⚠️ ENGINE CHANGE 2026-06-19 — the gemini engine is DEAD.** Google removed the gemini-CLI
> free tier (`IneligibleTierError` / `UNSUPPORTED_CLIENT`, "migrate to Antigravity"); gemini can
> no longer authenticate. **The Claude engine (`qa-drive-claude.sh`) is now the default + only
> drive path** and is fully zero-touch (launches an interactive session, records the window id,
> auto-sends the "go" kickoff, pre-authorizes trust+MCP+permissions). The orphan-lane janitor
> (`qa-cleanup-groups.sh`) now talks to DOMShell over a **direct curl JSON-RPC client** (no gemini).
> Sections below that say "fanned to gemini / engine=gemini (default)" are **historical** — read
> them as the Claude engine. The same gemini death also disables `/vp-review` + `/sprint-fanout`
> fleet-wide (separate CTO/CEO engine decision).

**Companion to** `docs/personas/qa-ux.md`. This is the operational setup + troubleshooting guide for the **browser** surface (the CLI and MCP surfaces need no DOMShell). It captures the hard-won gotchas so a new project doesn't rediscover them.

**The model in one paragraph:** QA-UX drives the live app as a skeptical user. The browser surface uses **DOMShell** (a browser-as-filesystem MCP) as its driver, via an **interactive Claude session** (`qa-drive-claude.sh` — subscription pool, no `claude -p`). DOMShell is provisioned into the **UX-focused repos** under test (never the CTO home or backend/data repos). The `/qa-ux` skill self-orchestrates the whole drive; you mostly just supply a clean token and a connected Chrome.

---

## 1. One-time DOMShell setup (per machine / UX repo)

1. **Run the DOMShell server** — ToolHive/Docker (recommended; owns `:3001` MCP + `:9876` extension socket) or native `npx @apireno/domshell --allow-write`. Confirm: `thv list` shows `domshell-mcp-server` *running*, or `:3001/mcp` answers (a `401` means up-but-needs-token — that's expected).
2. **Connect the Chrome extension** — open the DOMShell side panel → start session → `connect <token>`.
3. **Make the token available** — `DOMSHELL_TOKEN` must be a **clean hex string in the env the launching session inherits**. `scripts/agentic/ensure-domshell-token.sh` checks env → local token files → the live proxy's `--token` arg, and rejects banner-contaminated values. **Never read the token via a login shell** (`zsh -lic` picks up "Restored session" banners → a bad token → `Disconnected`).
4. **Registration is automatic** — you do *not* hand-edit config:
   - For an **interactive Claude** session: `qa-standup.sh` self-provisions the **proxy form** into the UX repo's `.mcp.json` (`domshell-proxy --port 3001 --token ${DOMSHELL_TOKEN}`) and tells you to restart (MCP loads at session start).
   - For the **gemini** engine: `qa-drive-gemini.sh` registers it via `gemini mcp add --scope user --trust …`.

> **Why the proxy form, not a spawn or a direct URL:** when DOMShell already runs (Docker/ToolHive), a `--allow-write` *spawn* conflicts on `:3001`/`:9876`, and a direct `type:http` URL `401`s without the token. The `domshell-proxy` stdio entry **connects to** the running server and controls its existing instances — the only form that works against a running server.

### 1b. Using DOMShell (or any stdio MCP server) from a non-Claude agent (gemini / Antigravity / Cursor)

DOMShell and other stdio MCP servers are **client-agnostic** — the same launch command works in any MCP-capable agent; only the *config file location* differs. To wire DOMShell into another agentic client, add the **identical proxy entry** to that client's MCP config:

- **Antigravity (Google's agentic IDE):** `~/.gemini/antigravity/mcp_config.json`
- **gemini-CLI:** `~/.gemini/settings.json` (note: the CLI free tier is deprecated, but the MCP-config shape is the same)
- **Cursor / others:** their respective `mcp.json`

```json
{
  "mcpServers": {
    "domshell": {
      "command": "npx",
      "args": ["-y", "-p", "@apireno/domshell", "domshell-proxy", "--port", "3001", "--token", "${DOMSHELL_TOKEN}"]
    }
  }
}
```

> ⚠️ **Common mistake:** there is **no** `@anthropic-ai/domshell-mcp` package — DOMShell is `@apireno/domshell`, driven via the **`domshell-proxy`** form with the **`--token`**. A bare `npx … domshell-mcp` will not connect.
>
> ⚠️ **Env-var interpolation:** Claude Code expands `${DOMSHELL_TOKEN}` from the env; **not every client does.** If the agent reports a `401`/`Unauthorized`, the client isn't substituting the var — replace `${DOMSHELL_TOKEN}` with the **literal token value** (`echo $DOMSHELL_TOKEN`). These per-client config files are **local, not committed**, so an inlined token is acceptable there — but **never commit a file containing the literal token**.

Same prerequisites as Claude: the DOMShell server on `:3001` running + the Chrome extension connected. The non-Claude agent then drives the **same real Chrome** under the same lane protocol. (Project-specific MCP servers — e.g. a code/decision-graph server — register the same way: copy that server's stdio command from the repo's `.mcp.json` into the agent's MCP config.)

---

## 2. Author the plan (shift-left, before the drive)

```
/qa-ux <sprint-dir> --mode plan
```
Writes/seeds `qa-plan.md`: in-scope surfaces, journeys with **HARD** (exact string/selector) vs **SOFT** (judgment) assertions, hero shots, fault-domain routing, PRD/RICE links. Then `/vp-review <sprint-dir>/qa-plan.md` (vp-prod + vp-eng).

## 3. Run the drive (accept-time gate)

```
/qa-ux <sprint-dir> --mode drive --url <non-prod-url>      # engine=gemini (default)
```
This **self-orchestrates**: resolves the token, registers DOMShell for gemini, runs the standup guard (prod-guard + reachability + provenance), then drives via `gemini --yolo --allowed-mcp-server-names domshell` under the **single-lane protocol**, writing `qa-report.md`, `flow-graph.json`/`.md`, and provenance-stamped (redacted) hero assets to `assets/`. **One drive at a time** against a shared Chrome.

- Browser-QA runs from a session **rooted in the UX repo** (where DOMShell + the live app are). The CTO home stays DOMShell-free.

### Engines: gemini (default) vs claude

| | `--engine gemini` (default, recommended) | `--engine claude` |
|---|---|---|
| How | `qa-drive-gemini.sh` fans the persona+plan to `gemini --yolo --allowed-mcp-server-names domshell` in-process | `qa-drive-claude.sh` **launches an interactive Claude session** (reuses `/handoff` machinery) to drive |
| Setup the CTO does | none — self-orchestrated | none — the skill writes the brief to `docs/`, writes `.claude/pending-prompt.md` itself, pre-trusts the workspace (CTO **never** hand-edits `.claude/`) |
| Manual step | none | **press Enter once** in the launched tab (Claude-Code limitation: the brief auto-pastes but doesn't auto-submit) |
| Cost | $0 | subscription pool (interactive; never `claude -p`) |

`--handover <path>` (both engines, primarily claude) drives from an **existing brief/handover doc** instead of the synthesized default — briefs always live in `docs/`, never `.claude/`. **Prefer gemini**: it's proven, $0, and avoids the press-Enter step; reach for claude only when you specifically need it.

> **Drive-prompt hygiene baked into both engines:** wait for async/loading states to settle before asserting (a mid-flight DOM is not a defect — this caused false "search broken" findings); **update** `qa-report.md` preserving the prior backend audit (don't overwrite); and verify artifacts/hero-shots actually exist before reporting success.

## 4. Tab-group lifecycle (cleanup)

> **DOMShell #53 / ext ≥1.3.2 (the connection-lane fix):** the generic `agent` connection-default
> lane is **no longer created** (the maintainers deleted the eager `groupNew(["agent"])` rather than
> name/reap it). Two consequences: (a) the janitor's self-reap becomes a harmless no-op (kept for
> older extensions); (b) **`group_id:"shared"` / omitted now means "the user's REAL browser, no
> isolated lane"** — only ever use it for a read-only `group list`; **never** for a write op (that
> hits real tabs). MCP server `2.0.6` (npm) ships only forward-compat `[DEPRECATION]` messaging.
> The separate `domshell-proxy` orphan-process bug is DOMShell #47 (same 1.3.2 bundle).

- **Single-lane protocol** — the drive opens ONE lane (`group_id:"new"`), reuses its id for every call, and `group close`s it at the end. DOMShell leaves lanes *open* on disconnect, so unclosed lanes orphan.
- **Harness sweep** — `qa-drive-gemini.sh` traps EXIT and closes the recorded lane (`.qa-lane`, gitignored) even on crash. Idempotent.
- **CTO janitor** (`scripts/agentic/qa-cleanup-groups.sh`) — for orphans the trap can't catch (an LLM driver that spawned *extra* groups, or a hard-killed drive): `--list` (inspect, default) · `--close <ids>` (targeted) · `--all-agent` (sweep every agent lane — loud, also affects other windows/Cowork). Timeout-guarded so it can't hang.

---

## 5. Scripts reference (`scripts/agentic/`)

| Script | Role |
|---|---|
| `qa-standup.sh` | Pre-drive guard: prod-endpoint refusal, reachability, provenance env, self-provision DOMShell (proxy form) into the UX/target repo's `.mcp.json`, flag a wrong-form entry. |
| `qa-drive-gemini.sh` | The drive engine: register DOMShell for gemini (`--scope user --trust`), single-lane protocol prompt, drive, on-exit lane sweep. |
| `ensure-domshell-token.sh` | Resolve + **validate** `DOMSHELL_TOKEN` (clean hex; env → files → live proxy arg); guide first-time setup. |
| `qa-redact.sh` | Strip secrets/PII from transcripts/reports **before** they land in `assets/` (harness control, not agent courtesy). |
| `qa-cleanup-groups.sh` | CTO janitor for orphan DOMShell tab groups: `--list` / `--close <ids>` / `--all-agent`. |

**CTO monitoring/keystroke helpers** (`scripts/cto/`, CTO-home only) — use these instead of inline one-liners:

| Script | Role |
|---|---|
| `qa-send.sh <window-id> <message-file> [--no-return]` | Inject a message (read from a file) as keystrokes into a Terminal window. |
| `wait-for-artifact.sh <session-jsonl> <target-file> [idle-ready] [idle-ceiling]` | Watch a session's idle time + a target file; exit `READY` when it settles or `CEILING` when stuck. |

> **Do NOT hand-roll inline `osascript`/monitor one-liners.** Claude Code prompts on any command line that combines **braces with quoted strings** ("Contains brace with quote character (expansion obfuscation)") — it fires *regardless of `permissions.allow`*, by design, so no allow-rule suppresses it. Inline `osascript <<HEREDOC … "$MSG"` injection and `while true; do … && { … "…"; break; } done` monitor loops trip it every time. The fix is to put that logic in **script files** and invoke them with **plain positional args** — only the invoking command line is scanned, and `bash scripts/cto/qa-send.sh <id> <file>` is clean. The `--engine claude` launch (`qa-drive-claude.sh`) and these two helpers exist precisely so keystroke-injection / window-targeting / monitoring are skill-owned, never improvised at the prompt.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Browser surface reported `BLOCKED`; only API/DB findings | `domshell_execute` not in the session's tool list | DOMShell not registered, or the session wasn't restarted after registering. Re-run standup, **restart the session**, re-drive. A server on `:3001` ≠ a wired tool. |
| `401` / `Disconnected` | Missing or **contaminated** token | Export a clean hex `DOMSHELL_TOKEN` (not via a login shell); `ensure-domshell-token.sh` extracts the hex. |
| Wrong-form `.mcp.json` (`type:http` url, or `--allow-write` spawn) | Direct URL `401`s; spawn conflicts on `:3001`/`:9876` | Use the **proxy form**; `qa-standup.sh` flags this (`PRESENT_WRONG`) and prints the correct block. |
| `gemini mcp list` shows domshell missing intermittently | `mcp list` re-spawns/reconnects every server per call (slow/non-deterministic) | **Never gate on `mcp list`**; register idempotently with `--scope user --trust` and let gemini connect at drive-time. |
| Lots of spawned tab groups | LLM driver violated the single-lane protocol, or a drive was hard-killed | Run `qa-cleanup-groups.sh --list` then `--close`/`--all-agent`. The protocol + on-exit sweep reduce but don't eliminate this. |
| Standup aborts with "prod-guard tripped" | The `--url` looks like production | Point at a preview/ephemeral non-prod env. QA never drives prod. |

---

## 7. The living baseline + per-sprint regression subset

Three QA artifacts at three scopes:

| Artifact | Scope | Path | Owner / approver |
|---|---|---|---|
| **Master baseline** | repo-level, durable acceptance bar (all features + coverage matrix + code-touchpoints) | `docs/qa/ux-baseline-test-plan.md` (template: `docs/qa/_templates/`) | QA-UX authors/amends · **VP-Product approves** |
| **Sprint `qa-plan.md`** | this sprint's **regression subset** (impacted baseline IDs) + any new tests | `docs/sprints/sprint-XX/qa-plan.md` | QA-UX |
| **`qa-report.md` + flow-graph** | what this drive actually found | `docs/sprints/sprint-XX/` | QA-UX |

**Workflow:** author a comprehensive baseline → VP-Product approves → promote to `docs/qa/` (living, monotonic). At **planning**, the CTO maps the sprint's code touchpoints to a **subset** of baseline test IDs (the sprint's regression gate). At **accept**, drive that subset + any newly-amended tests; the **full** baseline is re-driven only on cadence (release / major refactor). A sprint that changes a feature **amends** the baseline (VP-Product-approved) as a deliverable — silent drift is an incomplete sprint.

---

## 8. Bright-line + safety (always)

- **Engine:** gemini-CLI or interactive Claude only — **never `claude -p`** / direct Anthropic API.
- **Target:** a preview/ephemeral **non-prod** env, sandboxed browser profile, stripped creds.
- **Output:** files only — `qa-report.md`, `flow-graph.json`, `assets/`. **Never a database.**
- **Redaction:** secrets/PII scrubbed by the harness before any asset persists; an authenticated-session capture is not marketing-safe until scrubbed.
- **Lane isolation:** one named lane per drive; close it; sweep orphans.
