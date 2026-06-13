# Architecture Decision Records — Numbering Convention

This template uses **two distinct ADR namespaces** so a decision's identifier is
unambiguous no matter which repo you read it in. The prefix is the disambiguator.

| Prefix | Scope | Lives in | Numbering |
|---|---|---|---|
| **`FLEET-ADR-NNN`** | Fleet-wide architectural decisions — anything that governs more than one repo (config patterns, the orchestration model, cross-repo standards) | the CTO home repo's `docs/architecture/decisions/` | One sequence, owned by the CTO |
| **`ADR-NNN`** | Repo-local architectural decisions — internal to a single repo (a service's internals, a registry design, etc.) | each repo's own `docs/architecture/decisions/` | Per-repo sequence, owned by that repo's VP of Engineering |

## Why two namespaces

If every repo runs an independent `ADR-NNN` sequence, a bare `ADR-043` resolves to
a different decision in each repo. The `FLEET-ADR-` prefix gives fleet-wide
decisions a single unambiguous identity, while repo-local `ADR-NNN` stays local.

## Rules

1. **A new fleet-wide architectural decision** → authored in the CTO home repo, `FLEET-ADR-NNN`, next free number in this directory.
2. **A new repo-local decision** → authored in that repo, plain `ADR-NNN`, next free number in *that repo's* decisions directory.
3. **Referencing a fleet ADR from anywhere** (persona doc, dev-report, sprint plan, code comment) → always `FLEET-ADR-NNN`. Never bare `ADR-NNN`.
4. **Referencing a repo-local ADR from outside that repo** → qualify it: "service-a ADR-040". Inside the owning repo, bare `ADR-NNN` is fine.
5. **The CTO may replicate a `FLEET-ADR-` file** into affected repos for visibility — but the number and prefix stay identical everywhere. A replicated copy is never renumbered.

## FLEET-ADR index (example)

Maintain a table of the fleet ADRs here as you author them, e.g.:

| ID | Title |
|---|---|
| FLEET-ADR-001 | Configuration File Pattern |
| FLEET-ADR-002 | Centralized LLM Alias Registry |
| FLEET-ADR-003 | … |

Use `docs/architecture/decisions/_templates/adr-template.md` for each new ADR.
