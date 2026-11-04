# Project checks

Executable scripts, one directory per moment (`preflight/`, `landing/`, `accept/`; `kickoff/` and
`handoff/` work too). Each runs from the repo root with:

- `PROJECT_LAYER_REPO`   — absolute repo path
- `PROJECT_LAYER_MOMENT` — the moment
- `PROJECT_LAYER_HOME`   — the CTO home

Exit 0 passes (the last line of output is shown as a summary). Any other exit REFUSES the moment
(landing stops, accept refuses) and the output is shown. A check that is not executable is reported
as a refusal, never skipped. Keep checks fast and offline; put project IP here, not in the template.

Typical contents: a coverage pre-flight for an evaluation harness, a domain lexicon lint, a
scanner-blindness probe for a code-graph engine, a runner/lock sanity check.
