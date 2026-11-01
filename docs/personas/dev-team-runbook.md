# Dev Team Runbook — environment troubleshooting

Operational notes for dev lanes. Persona and workflow rules live in `docs/personas/dev-team.md`
and `CLAUDE.devteam.md`; this file is for "the tooling did something surprising" entries.

---

## `uv run` fails in a fresh worktree: "your project requires `<pkg>[dev]` … unsatisfiable"

### Symptom

In a new git worktree (or any clean clone), `uv run …` aborts before running anything:

```
× No solution found when resolving dependencies:
╰─▶ Because acme-errors was not found in the package registry and your
    project depends on acme-errors>=0.1.0, we can conclude that your
    project's requirements are unsatisfiable.
    And because your project requires acme-lib[dev], we can conclude that your
    project's requirements are unsatisfiable.
```

The same command "works" in the main checkout, which makes it look worktree-specific.

### Cause

The `<pkg>[dev]` line is a red herring. `uv run` first locks the project, and `uv lock` resolves
**every** extra at once (a universal lock), so uv's error derivation always ends with "your project
requires `<pkg>[<extra>]`" — whether or not that extra references the project itself. The real
cause is the first sentence: a dependency (typically a private sibling package of the same project)
**is not on any index uv can see and the pyproject declares no `[tool.uv.sources]` entry for it.**
With no `uv.lock` on disk (gitignored / never committed), uv must resolve from scratch and fails.

The main checkout only appears healthy because its `.venv` was hand-built (`uv pip install -e
../sibling`, `pip install -e …`) and is used via `.venv/bin/python`, `uv run --no-sync`, or a
previously generated local `uv.lock`. A fresh worktree has none of those, so it hits the real
resolution path.

Reproduced with uv 0.7.19 (scratch project `app` → private sibling `lib`; outputs abridged):

| Case | Result |
|---|---|
| A. private dep, no `[tool.uv.sources]`, no lock, `dev = ["app[extra-a]", …]` | **fails** — "was not found in the package registry … your project requires app[dev]" |
| A2. same, but `dev` has **no** self-reference | **fails identically** — the self-referential extra is not the cause |
| B. add `[tool.uv.sources] lib = { path = "../lib", editable = true }` — main checkout | ok |
| B2. same — sibling worktree `../app-wt-x` | ok |
| B3. same — worktree nested inside the repo (`.worktrees/x`) | **fails** — `Distribution not found at: file:///…/app/.worktrees/lib` (relative path now points elsewhere) |
| D1. no sources, hand-built `.venv` (`uv pip install -e ../lib`), plain `uv run` | **fails** — `uv run` still locks |
| D2. same, `uv run --no-sync` | ok (uses the existing env, skips locking) |

A self-referential extra (`dev = ["app[extra-a]"]`) is valid and resolves fine on its own.

### Fix pattern

1. **Declare where private dependencies come from** — the actual fix. In the repo that owns the
   pyproject (a dev-team change in that repo, through its normal sprint):
   ```toml
   [tool.uv.sources]
   acme-errors = { path = "../acme-errors", editable = true }   # sibling checkout
   # or: acme-errors = { git = "https://github.com/acme/acme-errors", tag = "v0.1.0" }
   # or: an [[tool.uv.index]] entry if the package is published to a private index
   ```
   A relative `path` source resolves only from worktrees that sit **beside** the repo (the
   `<repo>-wt-<name>` sibling convention). For worktrees nested inside the repo, use a `git`
   source or an index instead.
2. **Commit `uv.lock`** once (1) is in place, so a fresh worktree syncs from the lock instead of
   re-resolving. A lock alone does not fix (A): it cannot be generated while a dependency has no
   source.
3. **Dev-only tooling:** prefer PEP 735 `[dependency-groups]` (`dev = ["pytest", …]`, installed by
   `uv run` by default) over a `dev` extra in `[project.optional-dependencies]`. This is hygiene
   (dev tools stay out of the published metadata), not the fix for the error above.

### Lane workaround (until the pyproject is fixed)

Do not edit another team's pyproject from your lane, and do not commit a lock to work around it.
In your worktree:

```bash
uv venv && uv pip install -e ../<private-sibling> -e '.[dev]'   # explicit, no resolution of the universal lock
uv run --no-sync pytest                                         # or: .venv/bin/python -m pytest
```

and record the gap in `dev-report.md` under `Mechanism gaps` (repo, missing source, exact error line)
so the owning repo can land fix (1).
