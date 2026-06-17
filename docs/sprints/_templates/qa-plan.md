# QA Plan — sprint-XX

**Author:** QA-UX
**Date:** YYYY-MM-DD
**Status:** Draft | Reviewed
**Authored at:** planning time (shift-left — before code)

> One row of journeys per in-scope surface. Every acceptance signal is classified **HARD**
> (exact string / pattern / `data-testid` / selector — deterministic, graduates to `tests/e2e/`)
> or **SOFT** (semantic judgment the agent evaluates while driving). HARD strings double as the
> flow-graph state fingerprint. See `docs/personas/qa-ux.md`.

## In-scope surfaces this sprint

- [ ] **browser** (DOMShell MCP) — app URL: `<preview/ephemeral env, never prod>`
- [ ] **CLI** — entrypoint: `<command>`
- [ ] **MCP (agentic)** — server: `<repo's own MCP>`

(Tick only what this sprint exposes. A surface not exposed is out of scope — say so.)

## Journeys

### J1 — <name> · verifies PRD-<id> (RICE <score>) · surface: <browser|cli|mcp>

**Steps:** <the user/agent actions, in order>

| # | Signal | HARD / SOFT | Assertion |
|---|--------|-------------|-----------|
| 1 | <e.g. results render> | HARD | DOM contains `[data-testid="result-row"]` (≥1) |
| 2 | <e.g. heading> | HARD | heading text == `Search Results` |
| 3 | <e.g. results relevant> | SOFT | the top results are genuinely relevant to the query |
| 4 | <e.g. empty state> | HARD | empty query → banner matches `/^No results/` |

**Fault-domain expectations:** <which failures map to client / integration / server / data-quality / ux>

### J2 — ...

## Hero shots (critical delivered features to capture)

- [ ] **H1** — <feature> on <screen/surface> → `assets/H1-<slug>.png|cast|txt` (provenance-stamped, marketing-captioned)
- [ ] **H2** — ...

## Authenticated-session note (if any surface needs login)

- Default **HITL**: a human establishes the session; QA-UX attaches. Name the manual standup step here.
- (Only if scoped + signed off) auth-as-target testing — otherwise auth is a gate to pass through.

## Out of scope this round

- <surfaces / journeys explicitly not covered, so coverage gaps are logged, not silent>

— QA
