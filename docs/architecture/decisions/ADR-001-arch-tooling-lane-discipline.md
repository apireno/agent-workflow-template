# ADR-001 — Architecture-tooling for lane-discipline + cross-repo navigation

**Status:** **Accepted** — mechanism design. Round 1 (2026-06-17): RICE added, phasing reordered INTENT→ENFORCEMENT→NAVIGATION, async re-index. Round 2 (2026-06-17, after the engine/generic-consumer seam was codified): **both vp-eng + vp-devops APPROVE**; folded in lint-DX actionable errors, audit-mode-then-blocking rollout, NAVIGATION owner/budget + Tier-1 reliability. The project ADOPTION (engine retrieval extension + RACI content) is a separate project FLEET-ADR.
**Author:** CTO (template) · **Date:** 2026-06-17
**Origin:** kgspin CTO memo `MEMO-template-cto-arch-tooling-raci-uml-codegram-20260617.md`
**Scope:** the **portable mechanism** the template ships. Project-specific *engines* (a code-index tool) and *content* (the actual RACI, per-repo boundary rules) are out of scope — they live in each project's repos.

---

## RICE (for the portable mechanism — INTENT + ENFORCEMENT layers)

| Factor | Value | Rationale |
|--------|-------|-----------|
| **Reach** | 8 | Every multi-repo project on the template + all fleet repos' CI. |
| **Impact** | 4 | Prevents lane drift / duplicated logic — a structural, post-hoc-catastrophic class (each instance has needed a FLEET-ADR to unwind). |
| **Confidence** | 0.85 | ENFORCEMENT is proven (a project already ships a `test_no_X_import`); the RACI-validator is a thin diff over the index. |
| **Effort** | **M** (template mechanism) | Personas + skills + `lane-boundary-lint` + RACI template ≈ 1–2 sprints. |
| **RICE** | **~13.6** | 8 × 4 × 0.85 / 2 |

> **NAVIGATION is scored separately and is NOT this number.** The fleet-wide code-index engine is a **project-owned L/XL** multi-sprint/quarter production service (vp-eng MINOR + vp-devops HIGH) — budget it as a foundational capability, not a one-off tool, and **prefer a managed/OSS engine** that meets the contract over build-from-scratch (vp-devops).

---

## Context / problem

Two structural failure modes recur in multi-repo projects:
1. **Lane drift / duplicated logic** — two repos independently grow the same responsibility (e.g. each builds its own persistence layer), a boundary violation nothing flags until a human notices.
2. **Cross-repo navigation by grep is slow + lossy** — parallel-built seams (a method in repo A vs its consumer in repo B) and cross-repo collisions (e.g. duplicate ADR numbers) surface only by hand-inspection.

We want tooling that makes *who-owns-what / don't-dupe / stay-in-lane* explicit, and connects object↔object across repos faster than grep.

## Decision — three layers (intent ≠ reality ≠ enforcement)

| Layer | What | Property |
|---|---|---|
| **INTENT** | A project **RACI + C4 component map**: which repo owns what + the contracts crossing each boundary. | **Hand-curated, ADR-gated, stable.** Normative (what *should* be) — not derivable from code. |
| **NAVIGATION** | A **code-derived cross-repo index** (symbol / call / import graph), always-current, queryable by any agent. Derived UML (class/sequence) is **generated from it**, never hand-drawn. | **Always-current, engine-pluggable** (codegram is one impl; Sourcegraph/Glean/a language-server are others). |
| **ENFORCEMENT** | **Import-boundary tests as definition-of-done** — a repo declares its forbidden cross-lane imports; a lane violation **fails CI**. | **Ratchets.** Docs describe; tests enforce. |

**Keystone:** the RACI is **validated against the navigation engine's actual import graph** — a lint that fails when reality diverges from declared intent. INTENT declares the line, NAVIGATION supplies reality, ENFORCEMENT fails the build on the diff. This is the *general* form of a single hardcoded `test_no_X_import`: derive **all** forbidden edges from the RACI and check them. The RACI therefore can't silently drift.

## Portable mechanism (what the template ships) vs project-specific

**Portable (this template) — the engine-agnostic logic + contracts (the reusable "HOW to build the artifacts"):**
- **Personas:** CTO owns + maintains the RACI/component map and **consults the cross-repo graph at decomposition** to prevent dupes *before* firing teams; dev-team **definition-of-done** adds (a) import-boundary tests for the repo's lane, (b) a code-index re-index of changed modules, (c) a "checked the RACI — in my lane" gate; VP-Eng reviews lane adherence + boundary-test coverage at accept.
- **Skills (interfaces):** `/arch-map` (render/refresh the RACI + C4 map), `/codegram` (cross-repo symbol/dependency query *over the engine interface* — engine pluggable), `/lane-check` (run the boundary lint).
- **Scripts — the generic *consumers* of the engine interface (built once, work against any repo/engine):** the `lane-boundary-lint` harness (reads RACI-derived rules; fails CI on violation) — every violation must emit an **actionable error** naming the forbidden import, the offending repo's lane, the target lane, and the **RACI rule it breaks** (a bare "forbidden import" fails developer adoption — VP-Eng, hard requirement); the **RACI-validator** (diffs the RACI against the engine's import edges); and the **derived-UML renderer** (a graph → Mermaid/PlantUML *transform*). Plus the `reindex` hook *contract*.
- **Templates:** a RACI / C4 component-map template (`docs/architecture/_templates/`), like the QA baseline template.

**Project-specific (each project's repos) — ONLY the engine's interface impl + the content:**
- The NAVIGATION engine's **implementation of the query interface** — for a project already running a code-graph engine (e.g. codegram), a **minimal retrieval extension**: index **fleet-wide** + answer **cross-repo symbol/import-edge** queries. Nothing more.
- The **RACI content** + the per-repo **forbidden-import rules**.
- **Generic concerns — RACI-validation, UML-rendering, the lane-lint — do NOT live inside the engine.** Baking them into a project product is exactly the lane-violation this ADR exists to prevent; they are the template's generic consumers above. The engine exposes data; the template's generic layer interprets it.

## The NAVIGATION-engine contract (what any engine must expose)

So the RACI-validator and `/codegram` skill are engine-agnostic, a conforming engine MUST expose, fleet-wide:
1. **Symbol lookup** — given a symbol/method, where it's defined + every cross-repo consumer.
2. **Import/dependency edges** — per module, its imports, **including cross-repo edges** (the input the RACI-validator diffs against intent).
3. **Always-current via ASYNCHRONOUS, NON-BLOCKING re-index** (vp-devops CRITICAL) — CI/commit fires a `reindex-needed` event and does **not** wait; an indexing failure must **never** block a merge. **Incremental** (changed modules only), never a full re-index per commit. Instrumented (index freshness/staleness, query latency, error rate) — an engine outage is a developer-productivity incident, not a silent degradation.
4. *(Optional)* a raw graph export (nodes/edges) the template's UML-renderer transforms into a diagram. The engine does **not** render diagrams itself.

**The engine's responsibility ends at this interface** — it indexes and answers queries. It does **not** validate the RACI, render UML, or run the lint; those are the template's **generic consumers** of the interface (so they work against *any* engine and any project). For a project already running a code-graph engine, satisfying this interface is a **minimal retrieval extension**, not a new product — but it is still a **production service** (HA hosting, monitoring/alerting on index freshness/latency/errors, a recovery runbook), stood up + budgeted *before* any CI gate or persona DoD makes it a hard dependency. Prefer a managed/OSS engine that meets the contract over build-from-scratch.

## Phasing (revised per VP review — INTENT before generic ENFORCEMENT)

vp-eng correctly flagged the original order: you **cannot lint a boundary you haven't declared**. Reconciled with vp-devops's "cheapest control first":

1. **INTENT (first).** Author the RACI + C4 component-map (declare "who owns what" + the crossing contracts). *Cheap-first exception:* a project may ship a handful of **known** hardcoded forbidden-import tests immediately (e.g. an existing `test_no_X_import`) for instant value while the full RACI is authored — these are the seed the generic lint later subsumes.
2. **ENFORCEMENT.** The generic `lane-boundary-lint` reads the RACI and **fails per-repo CI (blocking)** on a violation (both VPs: per-repo CI, not a fleet gate — fast, local, no cross-fleet single-point-of-failure; a fleet pipeline may re-run it **non-blocking** for a health dashboard only). The RACI-validator (the keystone) diffs the RACI against the engine's import edges.
3. **NAVIGATION.** The code-index engine extended fleet-wide — an **L/XL production-grade service** (see the contract below): HA hosting, observability (index freshness/staleness, queue depth, query latency p95/p99, error rate — with **alerting** on thresholds, e.g. staleness >15min; an outage is a dev-productivity incident), incremental indexing, and a **disaster-recovery runbook** (incl. how to force a full fleet re-index). It is **minimal in *scope*** (retrieval only — no generic concerns) but **Tier-1 in *reliability*** — do not undersell the "minimal retrieval extension" framing (VP-Eng): a stale/incomplete index gives false security, worse than none. A **clear owner team + budget + resourcing plan** must exist *before* this work starts (VP-DevOps). Prefer managed/OSS over build-from-scratch.

**Rollout discipline (VP-DevOps HIGH):** do NOT make the RACI-validator a *blocking* CI gate until the NAVIGATION engine is deployed, stable, and meeting freshness/availability SLOs. Sequence: (1) engine deployed + monitored → (2) `lane-boundary-lint` runs in **audit mode** (logs violations, non-blocking) → (3) flip to **blocking** once the engine is proven. Premature blocking on a flaky index erodes developer trust. Each phase has explicit success criteria before committing to the next.

## Open questions for the VPs

- **vp-eng:** Is the RACI-validator-against-import-graph the right keystone, or does it over-trust the index? Is "hand-curate intent + machine-check drift" the correct split, or should more be derived? Does the boundary-lint belong in per-repo CI or a fleet gate?
- **vp-devops:** Where does `lane-boundary-lint` run (per-repo CI vs a fleet pipeline)? How does the re-index-on-commit hook stay cheap + not flake? How is the always-current index hosted/served fleet-wide?

## Consequences

- **Positive:** lane drift fails the build; the CTO catches dupes at decomposition; navigation is by symbol not grep; diagrams never rot (derived).
- **Negative / risks:** the RACI-validator is only as good as the index's cross-repo edge coverage; a curated RACI is a maintenance surface (mitigated: ADR-gated + drift-validated); the NAVIGATION engine is real engineering (project-owned, not template).

## Division of labor

- **Template CTO** builds the **engine-agnostic logic** (the RACI-validator, the `lane-boundary-lint`, the UML-renderer, the `/arch-map` + `/codegram` + `/lane-check` interfaces, the RACI/C4 template) + this design. This *is* the reusable "how to build the artifacts" — it works against any repo, current or future, via the engine interface. **It is the bulk of the work, and it is the template's.**
- **Project CTO + dev team** own only: (a) the engine's **interface implementation** — for a project on a code-graph engine (e.g. codegram), a *minimal* fleet-wide + cross-repo retrieval extension; and (b) the **RACI content** + per-repo rules. The project CTO authors a project FLEET-ADR adopting this and fires the retrieval extension as a small dev-team sprint scoped to the interface above.
- **Self-referential guardrail:** generic concerns (validation / UML / lint) never live inside the engine — a project product owning generic logic is the duplication this ADR prevents. The engine exposes data; the template interprets it.
