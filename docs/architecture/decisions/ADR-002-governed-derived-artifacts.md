# ADR-002: Governed Derived Artifacts — regenerate-on-change hygiene for code-derived graphs and registries

**Status:** Accepted (CEO "proceed", 2026-09-06) · companion to ADR-001; backs the `reindex` contract and the "UML is derived from the AST" clause that ADR-001 and the VP-Eng persona promised in June and nothing shipped.
**Author:** CTO (template) · **Created:** 2026-09-06 · **Deciders:** CEO, CTO, VP Eng
**Origin:** a project CTO's feature request of 2026-09-06 and the RCA behind it (project-local; summarized in Context with names removed).

> **Directional, not prescriptive.** The template ships the mechanism, the hygiene guideline,
> and the reminders at the moments where the right party can still act. **Rigor is the project
> CTO's and architects' call**: blocking vs. advisory, typing on boundaries, how strict the
> cross-repo join is. Every such choice is a per-repo knob with a documented default, on the
> same pattern as the review engine (`resolve-review-engine.sh`: template ships the menu and
> the default; the project sets the value).

---

## RICE Score

| Factor | Value | Rationale |
|---|---|---|
| **Reach** | 8 | Every repo with a generated artifact; every persona and template that names deliverables; verify, accept, session start. |
| **Impact** | 4 | A stale code graph misdirects planning silently — nothing fails, the wrong picture is consulted. Same family as a dead review engine's empty verdict reading as PASS. |
| **Confidence** | 0.8 | The stamp mechanism is trivial and generic. Closure walkers are per-repo and one project already has two. |
| **Effort** | M | Template mechanism: S. First adopter's generator conformance: M. |
| **RICE** | **12.8** | |

---

## Context

**What happened (genericized).** A project's canonical data-flow graph went 3.5 weeks and ~100 commits stale. The only enforcement was a pull-request-triggered CI workflow, in a fleet that lands every sprint by direct CTO commit and never opens a PR. That was known months earlier and the symptom was fixed with a catch-up sprint, not the trigger. No persona, dev-team contract, handoff brief, or verify/accept skill carried the obligation, so dev lanes never saw it. Worse, the graph's roots were a hand-kept list of entry points that pointed at an engine the product had since retired: a faithful regeneration would still have described the wrong thing. A second, per-sprint generated artifact answered the real question but discarded the one flag that mattered, and nobody owned joining it to the first. Three graphs, no owner of the join.

**What the template already has, and does not.** `.claude/generated-paths` plus the `deny-generated-edit` PreToolUse hook govern the **hand-edit direction**: a declared build output may only change through its generator. Nothing governs the **staleness direction**: a build output whose inputs changed and whose generator was not re-run. This ADR is the second half of the same declaration. ADR-001 promised a `reindex` hook contract and the VP-Eng persona (§8) claims to regenerate repo UML "from the AST" via a code-graph engine the template does not ship. This ADR is the concrete, per-repo form of both.

**The general unit.** The originating request asked for "code graphs." The RCA's own finding 4 shows four instances of one thing: a data-flow graph, a read-site registry, a capability matrix, a sensitivity registry. All are **derived artifacts**: committed files that must be a function of a computed input set and may change only by their generator. Governing "code graphs" alone leaves three of four ungoverned. The unit is the derived artifact; the code graph is the first instance.

---

## Decision

### 1. The manifest: `.claude/derived-artifacts.yaml` (per repo)

```yaml
# Derived artifacts this repo governs. Paths repo-relative. One entry per artifact.
artifacts:
  - name: dataflow-graph
    path: docs/architecture/dataflow-graph/     # file or directory; auto-protected from hand edits
    generator: scripts/graph/build.py           # must implement the generator contract (§2)
    mode: block                                 # block | warn   — rigor knob, default block
    # warn_until: 2026-10-01                    # optional: warn now, block after this date
  - name: read-site-registry
    path: docs/architecture/read-sites.json
    generator: scripts/graph/read_sites.py
    mode: warn

# Rigor knobs for cross-repo boundaries (§7). Defaults shown.
boundary:
  typing: advisory        # advisory | required — annotations on boundary functions
  join: advisory          # off | advisory | verify-row — how a join mismatch surfaces
```

- **Not a manifest of files.** Roots, seam kinds, and exclusion globs are the **generator's** configuration, kept wherever the generator likes. The manifest knows artifacts and generators, nothing else.
- Every `path` here is implicitly a `.claude/generated-paths` entry, so the existing hand-edit guard covers it. `generated-paths` stays for outputs that have no conforming generator yet.

### 2. The generator contract (repo-supplied, any language)

A generator is any executable the repo supplies. It must answer four subcommands; the template never reads the artifact itself.

| Subcommand | Prints | Contract |
|---|---|---|
| `closure` | repo-relative paths of the covered set, sorted, one per line | A **pure function of the tree**. No environment, no network, no timestamps. Walks from the declared roots through the call graph. |
| `seams` | `path:line:kind` for every seam site **anywhere in the repo**, honoring the generator's own excludes | A seam is a shape by which code reads a declared input or emits a declared output: a config read through a loader, a model call, a ledger write, a handler registration, an external call. Kinds are the generator's vocabulary. |
| `roots` | declared roots as `path[:symbol]`, one per line | Each must resolve. A root that does not exist is a defect, not a no-op. |
| `build` | writes the artifact | **The gate writes the stamp** (`derived-artifact-gate.sh --fix`, or `stamp <name>` after a hand-run build), so no generator has to know the hashing scheme. Stamp = `<artifact>/.stamp` (or `<artifact>.stamp` for a file): `closure=<sha256 over sorted (path, blob-sha) pairs>`, `generator=<blob-sha of the generator>`, then one `path blob` line per covered file so a STALE finding can name what moved. Changing the generator invalidates the artifact. |
| `boundary` (optional) | JSON: this repo's producers and consumers (§7) | Only for repos that participate in a cross-repo join. |

**Why a stamp and not a diff.** If the gate had to regenerate to detect staleness it would need deterministic output, the generator's full runtime at commit time, and would run in seconds to minutes inside a hook. A stamp check is a hash over the index and runs in milliseconds, needs nothing installed, and keeps the gate generic across every artifact and language. It also satisfies the VP-DevOps condition ADR-001 recorded: regeneration never runs in the hook; only a check does. The stamp is the provenance the fleet already requires of graph artifacts (code identity travels with the artifact).

### 3. The gate: `scripts/agentic/derived-artifact-gate.sh`

Generic, engine-independent, a sibling of `lane-boundary-lint.sh`. Sources: `--worktree` (default: the Stop hook, a human at the prompt, verify — the dev lane does not commit, so its work is on disk), `--staged` (the index; the commit path), `--head` (session start, CI). `--audit` reports only and exits 3 on any finding regardless of mode so callers can detect it; `--fix` runs `build` for each stale artifact, writes the stamp, and stages artifact + stamp with a scoped add. `--require` makes a missing manifest a configuration error (exit 4) for repos the registry flags required. Fixture test: `scripts/agentic/test-derived-artifact-gate.sh`.

Four checks per artifact, each with an actionable message naming the artifact, the offending path, and the exact fix command:

| # | Check | Refuses when |
|---|---|---|
| (a) | **Stale** | recomputed closure hash ≠ stamp. "The closure changed and `<name>` was not regenerated. Run `<generator> build` (or `derived-artifact-gate.sh --fix`) and stage the result." |
| (b) | **Seam leak** | a `seams` site lies outside `closure`. "`<path>:<line>` declares a `<kind>` seam outside the covered set — a root has leaked past the generator's config. Add the root, or add the path to the generator's excludes if it is a test/wrapper/adapter." **This is the dark-mechanism detector**: it catches a new path being built without the generator knowing. |
| (c) | **Dead root** | a `roots` entry does not resolve. "Root `<path:symbol>` no longer exists. The generator describes an engine the repo no longer has." This catches the originating failure's finding 3, which (a) and (b) cannot: a retired engine is neither a changed file nor a leaked seam. |
| (d) | **No generator** | `generator` is missing or not executable. A declared artifact with no generator **fails loudly, never passes**. A required artifact that silently passes is the exact failure class this ADR exists to end. |

`mode: warn` (or a live `warn_until`) turns a refusal into a printed warning with the same text. The check runs either way; only the exit code changes.

### 4. Enforcement points, ranked by when the right party can still act

The originating request ranks the commit gate first. This ADR ranks it **last**. The fleet's commits happen on the CTO's keyboard after the dev lane has closed; a refusal there arrives when the regeneration has become CTO work. The obligation should reach the dev lane while it is live and be **reminded often**. Each point below is the same script, no separate gates.

1. **Handoff brief, standing-deliverables block.** When the target repo has a manifest, `/handoff` renders, without the CTO adding it by hand: "This repo governs derived artifacts: `<names>`. If your changes touch the covered set, run `<generator> build` before `dev-report.md`; the verify row checks the stamp." (The reminder at the start.)
2. **Stop hook in the dev repo.** `derived-artifact-reminder.sh` (wired beside `check-complete.sh`) runs `--audit` at every turn end. A **new** finding is returned as `decision: block` with the gate's text as the reason, so the session sees it once and can act; every later turn with the same finding is a `systemMessage` only (visible to the human, not the model), and `stop_hook_active` is honoured. Advisory by construction: one reminder per distinct finding, never a loop. (The reminder in the middle.)
3. **`/sprint-verify` standing row.** For each declared artifact the verifier seeds a conformance criterion with an empirical signal (`derived-artifact-gate.sh --head` exit 0) and marks it MET / NOT-MET. `/sprint-accept` already requires every NOT-MET row to be named as an accepted known-issue or a blocker. (The reminder at the end, on the record.)
4. **Git pre-commit hook in the dev repo.** `.claude/githooks/pre-commit`, installed by `push-to-repos.sh` with the LOCAL `core.hooksPath = .claude/githooks` (untracked; upstream mode compatible; a repo that already routes hooks elsewhere is left alone and told). It chains a pre-existing `.git/hooks/pre-commit` first, so the `pre-commit` framework keeps working. Runs `--staged`. The backstop. Never auto-regenerates; prints the `--fix` command. A hook that silently mutates the index hides the regeneration from the committer and can loop. `DERIVED_ARTIFACT_GATE=skip` bypasses it for a deliberate, commit-message-recorded exception.
5. **CI.** The same script as a workflow step for projects that do use pull requests. Not a substitute for 4; a second run of the same check.
6. **CTO session start.** `preflight.sh` gains a section, on the pattern of the model-drift check: for each registry entry with `derived_artifacts: required`, run `--head --audit` and print a per-repo table (`REPO  ARTIFACT  STATE  DETAIL`), `<-- STALE` / `<-- LEAK` / `<-- DEAD-ROOT` / `<-- NO-GENERATOR`. Staleness surfaces the way an open sprint does.

### 5. The obligation in the text agents read

- `CLAUDE.devteam.md`: a "Derived artifacts" deliverable paragraph: any sprint touching a covered set regenerates through the generator and lists it in `dev-report.md`; never hand-edits.
- `docs/personas/vp-engineering.md` §6b item 8: a second automatic BLOCKER beside "hand-edited generated artifact": **"stale derived artifact"**, the gate's NOT-MET row unaddressed in the dev-report. §8's "UML on initiation" clause becomes regenerate-on-change, pointing here.
- `docs/personas/dev-team.md` "re-index changed modules" clause points here.
- `docs/personas/cto.md` session-start checklist: read the preflight table; a stale required artifact is raised to the CEO like an open sprint.
- `docs/sprints/_templates/sprint-plan.md` Definition of Done and `dev-report.md`: one line each.
- `.cto/projects.yaml.example`: `derived_artifacts: required | optional` per repo.

### 6. Ownership

| Thing | Owner | Changes when |
|---|---|---|
| Generator config: roots, seam kinds, excludes | VP of Engineering of the repo | a **new kind** of thing appears (a new stage, handler kind, config-read mechanism). Ordinary modules are picked up by the closure. |
| Manifest entries | VP of Engineering of the repo | an artifact is added or retired |
| Rigor knobs: `mode`, `warn_until`, `boundary.*` | Project CTO | by judgment; recorded in the manifest, reviewed at accept |
| The gate, hooks, persona text | Template | |
| Cross-repo join ledger (§7) | CTO home | regenerated at session start |

### 7. Cross-repo boundaries: black box on each side, the join in the CTO home

Where one repo's data path calls another's, **each repo's graph stops at its boundary**. The outside repo is a node with no interior: what this repo hands it and what it takes back. The other repo shows the same crossing from its side. Neither generator reads the other's code; the per-repo gate never depends on a sibling being checked out at any particular commit.

**Boundary declarations are derived, not hand-written.** "External call" and "external artifact read/write" are seam kinds. `boundary` emits:

- **producers**: for each function a sibling calls: qualified name, parameters (name, kind, default, annotation), return annotation.
- **consumers**: for each crossing call: callee qualified name, positional count, keyword names passed, best-effort the attributes read off the result.

With no schema file, **the signature is the contract and the signature hash is the version**. A shape change changes the producer's stamp; there is no version number to forget.

**The join is consumer-driven, not equality.** The CTO home checks, per callee, that the consumer's needs are a subset of what the producer emits: (1) callee exists, (2) every keyword passed exists or the producer takes `**kwargs`, (3) every producer parameter without a default is supplied, (4) every attribute read off the result exists on the return annotation **where annotated**; otherwise that row is UNVERIFIED, never MET. Equality would flag every benign producer addition and train everyone to ignore the report.

**The join ledger is itself a derived artifact of the CTO home** (`scripts/cto/join-ledger.sh` → `.cto/join-ledger.md`, untracked; inputs: the repos' boundary declarations), regenerated at session start by preflight. Fixture test: `scripts/cto/test-join-ledger.sh`. A mismatch **never blocks a commit** in either repo. Under `join: verify-row` it lands as a NOT-MET row in the verify of the repo that moved the boundary; under `advisory` it is printed at session start. The CTO rules which side moves and where the contract change is recorded. That is the mitigation, and it sits with the integration authority CLAUDE.md already names.

**Where it degrades, visibly.** The producer side is solid. `**kwargs` pass-through hides keywords, dict returns hide attributes, dynamic dispatch hides the callee. Existence and arity are always checked; typed shape where annotated; everything else a named UNVERIFIED row. `boundary.typing: required` turns check (4) from best-effort into reliable by refusing an unannotated boundary function on the producer side; the template defaults it to `advisory` and leaves the call to the project.

### 8. Rollout

Per ADR-001's audit-then-block discipline, applied per repo by the project CTO: `mode: block` where the generator has passed the gate once; `mode: warn` with a `warn_until` date where it has not (a repo flagged required with no generator yet). The template does not choose which repos; it makes both states loud.

---

## Alternatives Considered

- **Regenerate-and-diff at commit.** Needs deterministic output, the full runtime in the hook, and takes seconds to minutes. Rejected for the stamp (§2).
- **PR-only CI gate.** Structurally dead where the fleet lands by direct commit; this is the originating failure. Kept only as point 5 of §4, the same script.
- **A manifest of covered files.** Goes stale on every move; the closure is derivable. Rejected; the manifest knows artifacts and generators only.
- **The fleet-wide index service (ADR-001 NAVIGATION) as the source of truth.** An L/XL Tier-1 service. This is a per-repo committed artifact checked by a hash. Complementary, not a replacement; a project that stands the service up can point its generator at it.
- **A narrow "code graph" feature.** Leaves the sibling artifacts in the same RCA ungoverned. Rejected for the general unit.
- **Auto-regenerate in the hook.** Hides the regeneration, mutates the index, can loop. Rejected; the hook prints the `--fix` command.

## Consequences

**Positive.** Staleness cannot report success: a required artifact is stale, leaked, dead-rooted, or has no generator, and each says so in the commit path, the verify row, the Stop hook, and the CTO's session start. The dev lane is reminded three times before the CTO's keyboard sees it. Two June promissory notes get a mechanism. Cross-repo drift has an owner and a ledger. Rigor stays with the architects.

**Negative.** The closure walker is real per-repo engineering and dynamic dispatch bounds its precision. Seam-leak has false positives until excludes are tuned. A git hook is a new surface in dev repos (untracked; upstream mode unaffected). A regenerate-then-edit loop is possible; `--fix` and the Stop-hook reminder mitigate. The join's consumer side is best-effort and says so.

## Acceptance (template)

Tested against a fixture repo with a toy generator:

1. A commit touching a covered file without regeneration is refused, naming the artifact and printing the fix command; after `--fix` the same commit passes.
2. A commit adding a seam in a file outside the closure is refused, file and line named.
3. A declared root that no longer resolves is refused, root named.
4. A required artifact with no generator fails loudly at commit, at verify, and at CTO session start.
5. `/handoff` for a repo with a manifest renders the standing-deliverables block with no CTO edit.
6. `/sprint-verify` seeds one row per artifact and marks it from the gate's exit code.
7. CTO session start prints the per-repo staleness table for every `derived_artifacts: required` entry.
8. `mode: warn` and `warn_until` downgrade every refusal above to a warning with identical text.
9. Two fixture repos with `boundary` output: a renamed keyword on the producer produces a join mismatch in the CTO home ledger; a producer adding an optional parameter does not.

## Implementation plan

**Template (S) — SHIPPED 2026-09-06.** Manifest schema + `.claude/derived-artifacts.yaml.example`; `scripts/agentic/derived-artifact-gate.sh` + `test-derived-artifact-gate.sh` (35 assertions); `.claude/hooks/derived-artifact-reminder.sh` (Stop) wired in `settings.devteam.json.template`, `/handoff` self-heal and `push-to-repos.sh`; `.claude/githooks/pre-commit` + `core.hooksPath` install; `preflight.sh` §9 (per-repo staleness table + join ledger); `/sprint-verify` standing rows; `/handoff` standing-deliverable block; persona and template text (§5); `.cto/projects.yaml.example` flag; `scripts/cto/join-ledger.sh` + `test-join-ledger.sh` (checks 1–3 blocking-as-mismatch, check 4 verified only where `returns_fields` is declared, else UNVERIFIED).

**Adopting project (M, per repo).** Point the existing builder at the shipping engine's roots, add `closure` / `seams` / `roots` / `build`, tune excludes until (b) is clean, set `mode`. The read-site registry publishes the flag it currently discards. Any other generated registry joins the manifest on the same contract.

— CTO
