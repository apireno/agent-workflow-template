# The project layer

This directory is **yours** — the project's (`<cto-home>/.cto/project/`) or one repo's
(`<repo>/.claude/project/`). Template sync and `push-to-repos.sh` never write here; the template
team never edits it. It was seeded once by `scripts/agentic/project-layer.sh init <dir>`.

| File | Runs at | What happens |
|---|---|---|
| `standing-orders.md` | every session start (CTO preflight; lane SessionStart hook) and in every brief | each `## SO-…` heading is printed as a binding rule |
| `checklists/<moment>.md` | kickoff · handoff · landing · accept | each `- [ ]` item is printed; at accept the decision file answers every item |
| `checks/<moment>/*.sh` | preflight · landing · accept (kickoff / handoff too) | non-zero exit refuses the moment, with the check's output |
| `settings-overlay.json` | `push-to-repos.sh` | permission grants unioned into every lane's settings |

What belongs here: rules the CTO has had to repeat, the project's domain lints, its evaluation-
harness coverage pre-flights, its runner/lock numbers, its cost ceilings, its scanner's seam probes
— anything specific to this project. What does not: anything every project needs. That is a
mechanism request to the template team (a memo under `docs/memos/`), and when it ships as a check,
delete the standing order it replaces.

Commented-out examples (`<!-- … -->`) are ignored; only live headings, items and executable checks count.
`bash scripts/agentic/project-layer.sh status` reports what the layer holds.
