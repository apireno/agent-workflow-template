# QA-UX Browser-Drive Runbook (DOMShell + gemini)

**Companion to** `docs/personas/qa-ux.md`. This is the operational setup + troubleshooting guide for the **browser** surface (the CLI and MCP surfaces need no DOMShell). It captures the hard-won gotchas so a new project doesn't rediscover them.

**The model in one paragraph:** QA-UX drives the live app as a skeptical user. The browser surface uses **DOMShell** (a browser-as-filesystem MCP) as its driver, fanned to **gemini** by default (`$0`, no `claude -p`, no osascript). DOMShell is provisioned into the **UX-focused repos** under test (never the CTO home or backend/data repos). The `/qa-ux` skill self-orchestrates the whole drive; you mostly just supply a clean token and a connected Chrome.

---

## 1. One-time DOMShell setup (per machine / UX repo)

1. **Run the DOMShell server** — ToolHive/Docker (recommended; owns `:3001` MCP + `:9876` extension socket) or native `npx @apireno/domshell --allow-write`. Confirm: `thv list` shows `domshell-mcp-server` *running*, or `:3001/mcp` answers (a `401` means up-but-needs-token — that's expected).
2. **Connect the Chrome extension** — open the DOMShell side panel → start session → `connect <token>`.
3. **Make the token available** — `DOMSHELL_TOKEN` must be a **clean hex string in the env the launching session inherits**. `scripts/agentic/ensure-domshell-token.sh` checks env → local token files → the live proxy's `--token` arg, and rejects banner-contaminated values. **Never read the token via a login shell** (`zsh -lic` picks up "Restored session" banners → a bad token → `Disconnected`).
4. **Registration is automatic** — you do *not* hand-edit config:
   - For an **interactive Claude** session: `qa-standup.sh` self-provisions the **proxy form** into the UX repo's `.mcp.json` (`domshell-proxy --port 3001 --token ${DOMSHELL_TOKEN}`) and tells you to restart (MCP loads at session start).
   - For the **gemini** engine: `qa-drive-gemini.sh` registers it via `gemini mcp add --scope user --trust …`.

> **Why the proxy form, not a spawn or a direct URL:** when DOMShell already runs (Docker/ToolHive), a `--allow-write` *spawn* conflicts on `:3001`/`:9876`, and a direct `type:http` URL `401`s without the token. The `domshell-proxy` stdio entry **connects to** the running server and controls its existing instances — the only form that works against a running server.

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

## 7. Bright-line + safety (always)

- **Engine:** gemini-CLI or interactive Claude only — **never `claude -p`** / direct Anthropic API.
- **Target:** a preview/ephemeral **non-prod** env, sandboxed browser profile, stripped creds.
- **Output:** files only — `qa-report.md`, `flow-graph.json`, `assets/`. **Never a database.**
- **Redaction:** secrets/PII scrubbed by the harness before any asset persists; an authenticated-session capture is not marketing-safe until scrubbed.
- **Lane isolation:** one named lane per drive; close it; sweep orphans.
