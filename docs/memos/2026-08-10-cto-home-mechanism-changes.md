# Memo to the template team — mechanism changes made in a CTO home (2026-08-10)

**From:** a per-project CTO session · **Re:** four mechanism-file edits made in a private CTO
home that belong (genericized) in this template. Per ADR-001 lane discipline the template team
owns the reusable mechanism; these were applied downstream first under operational pressure and
need upstreaming so every other CTO home inherits them. No project IP below — all content is
already genericized.

## 1. `scripts/cto/qa-send.sh` — FOCUS GUARD (safety-critical; upstream verbatim)

**Defect class:** the script addresses a Terminal window by id, but macOS keystrokes go to the
*focused* app. When focus fails to land (operator using the machine, another app frontmost), the
ENTIRE message — including the trailing Return — types into whatever is focused. Observed
consequence: an orchestration instruction was typed into the operator's personal messaging app
and may have auto-sent.

**Fix (downstream commit `90c3d70`):** after `activate` + raise-window, and BEFORE any
keystroke: (a) System Events must report Terminal as the frontmost process; (b) Terminal's front
window id must equal the target id; otherwise `error` out loudly with "Nothing was sent."
Abort-on-mismatch, never retry-blind — a guard abort means the operator's machine is in use.

**Template action:** apply the same guard to every keystroke-emitting script in the template
(`qa-send`, any `/send` skill body, kickoff auto-typers). Any future keystroke tool MUST carry a
focus guard as a review requirement.

## 2. `CLAUDE.devteam.md` — two governance rules (genericize + upstream)

Added under Technical Standards (downstream commit `1e636a7`):

- **Generated-artifact lane rule (generic form):** artifacts produced by a build/derivation
  workflow (in our case: extraction-bundle content; generically: any generated config, compiled
  artifact, or model card) may only change THROUGH that workflow. A hand-edit diff to such an
  artifact is an automatic sprint REJECT **regardless of which persona made it or what ruling it
  implements** — the rule binds at the artifact path, not at the agent lane. Rationale: a
  downstream RCA showed a rule enforced only inside the generator's own lane is bypassed the
  moment another team touches the file.
- **Engine-purity rule (generic form):** in repos declared domain-agnostic, production code
  carries zero domain instances (names, IDs), zero embedded domain vocabularies, zero
  domain-literal branching; domain content is injected from config with empty defaults, and a
  repo-wide lint test enforces it (exempting files from the lint to get green is itself a
  violation).

## 3. `docs/personas/vp-engineering.md` — two checklist items (upstream with #2)

The VP-Eng review checklist gained matching automatic-BLOCKER checks: (a) generated-artifact
hand-edit detection; (b) domain-content-in-engine detection. Same genericization as above.

## 4. `docs/personas/qa-ux.md` — sanctioned-tooling standard (earlier this cycle)

Appended (CEO-ruled downstream): QA drives use the ONE provisioned browser-automation lane;
a perceived tool gap is an escalation with evidence, never a self-provisioned workaround; a
rendering anomaly is a product bug to RCA, never assumed to be tooling. Generic and
template-worthy as written.

## Suggested handling

Items 1 and 4 upstream near-verbatim. Items 2–3 need only s/bundle/generated-artifact/ naming.
Downstream diffs available on request from the CTO home; the focus guard is the urgent one —
every deployment using keystroke injection shares the WhatsApp failure mode until it lands.

— CTO
