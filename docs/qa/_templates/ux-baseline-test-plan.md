# UX Acceptance Baseline — {PROJECT_NAME}

> **Living document.** The canonical UX acceptance bar for the whole product. Promote here from a
> sprint dir once authored + VP-Product-approved. It grows **monotonically** and never silently
> drifts. Lives at `docs/qa/ux-baseline-test-plan.md`.

## Governance

| | |
|---|---|
| **Authors / amends** | QA-UX (`docs/personas/qa-ux.md`) |
| **Owns / approves** | VP-Product (`docs/personas/vp-product.md`) — every amendment, alongside the dev-report |
| **Full re-drive cadence** | release / major refactor only — NOT every sprint |
| **Per-sprint** | drive the **regression subset** whose features the sprint's code touches (see the code-touchpoints column) |
| **Last amended** | YYYY-MM-DD · sprint-XX · code_sha |
| **Coverage summary** | driven N / not-driven N / not-built N (of M features) |

## Feature inventory + coverage matrix

| Test ID | Feature | PRD / requirement | Surface | Coverage | Code touchpoints (module / route / `data-action`) | Assertion (HARD ref / `tests/e2e/`) | Last driven (sprint · sha) |
|---|---|---|---|---|---|---|---|
| UX-001 | <feature> | PRD-NN §x | browser | `driven` | `src/<module>` · `/route` · `[data-action=...]` | `tests/e2e/<name>` | sprint-XX · `<sha>` |
| UX-002 | <feature> | PRD-NN | cli | `not-driven` | `cli/<cmd>` | — | — |
| UX-003 | <feature> | (proposed) | browser | `not-built` | — | — | — |

**Coverage values:** `driven` (verified by a real drive / green e2e) · `not-driven` (exists but unverified — QA baseline debt) · `not-built` (planned, no implementation — VP-Product backlog input).

## Amendment protocol

1. A sprint that **adds or changes a feature** amends this baseline (new/changed `UX-###` rows + coverage status) **as a sprint deliverable**.
2. The amendment is **VP-Product-approved** at `/sprint-accept`, alongside the dev-report.
3. The **code-touchpoints** column is load-bearing: it lets the CTO mechanically resolve, at planning, which `UX-###` IDs a sprint touching a given module/route impacts → the sprint's regression subset.
4. Never delete a feature's tests silently — mark it `not-built`/deprecated with a note. Monotonic growth only.
