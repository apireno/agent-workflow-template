# Standing orders

Binding rules for this project (or repo), printed at every session start by
`scripts/agentic/project-layer.sh preflight`. They sit on top of the template's contract; they
never contradict it. One heading per order — the heading line is what gets printed, so make it
the whole rule:

    ## SO-001 — <the rule, one line, imperative>
    - why: <the incident or ruling it came from, with date>
    - since: <YYYY-MM-DD>
    - repeated: <how many times it has had to be repeated; bump it each time>

An order whose `repeated` count keeps climbing is a mechanism request: send it to the template
team (docs/memos/) so it becomes a check instead of a reminder. Delete an order once a check
enforces it.

<!-- Example (delete when you add your own):
## SO-001 — Times in logs and CEO-facing messages come from the clock (log-line.sh), never from memory
- why: tick times drifted up to 4 h when estimated
- since: 2026-11-04
- repeated: 1
-->
