# RCA — the CTO-home anchor never worked: skill argument rewriting eats positional parameters

**Date:** 2026-09-01 · **Author:** CTO (template) · **Class:** rendering defect in skill-embedded shell
**Severity:** HIGH — one skill hard-down, twelve silently degraded, for six weeks
**Reported by:** kgspin-cto, `INCIDENT-handoff-skill-arg-interpolation-20260901.md`
**Introduced by:** `ed27f56` (2026-08-14) — this template, fixing the *previous* anchoring defect

---

## 1. Verdict on the incident report

**Correct in root cause, correct in evidence, and it understates the impact.** No corrections.

The one detail that looks like a transcription error — `$1` rendering as the *second* token
(`--repos=…`) rather than the first — is real and reproducible. It was measured, not inferred:

| skill invoked with | `$ARGUMENTS` | `$1` | `$2` | `$3` |
|---|---|---|---|---|
| `alpha beta gamma delta` | `alpha beta gamma delta` | `beta` | `gamma` | `delta` |
| `<slug> --repos=<repo>` | both tokens | `--repos=<repo>` | *(empty)* | *(empty)* |

`$N` renders as token N+1. The report's verbatim evidence was accurate.

## 2. What is actually happening

The skill runtime rewrites argument placeholders in SKILL.md before the shell runs. The
substitution regex, from the CLI binary (2.1.252):

```
$ARGUMENTS[<digits>]  |  $ARGUMENTS  |  $<digits> not followed by a word character
```

Four properties, all measured against a probe skill, all of which matter:

1. **Document-wide.** No code-fence awareness. It rewrites inside ```` ```! ```` blocks, inside
   comments, and inside prose.
2. **No escape.** A backslash does not protect it — `\$1` renders **empty**, so the obvious
   workaround silently makes things worse.
3. **It beats the shell.** A function's own positional parameter is replaced by argument text
   *before* the shell ever runs, so the caller's real argument is discarded. Verified:
   `f() { echo "$1"; }; f REAL-ARG` printed the invocation argument, not `REAL-ARG`.
4. **With no arguments, it substitutes nothing** — the token renders as the empty string.

Property 4 is why the impact is larger than the report states, and it is the finding that
turns this from "broken with arguments" into "never worked at all".

## 3. Impact — the anchor was broken from the day it shipped

Rendered with no arguments, the anchor's first line becomes:

```sh
[ -n "" ] && [ -f "/.cto/projects.yaml" ] || return 1
```

`_cto_is_home` can therefore never return 0, for any candidate, under any invocation. Every
path through the block fails: the env-var candidates, the upward walk (`_d` starts empty, so
the loop never runs), and the `~/.cto/home` fallback. Reproduced by rendering the block and
executing it **while standing in the CTO home** — the case that cannot fail — where it still
printed `NOTE: no CTO home found; using the current repo`.

So for six weeks:

- **`/handoff` (sets `CTO_HOME_REQUIRED=1`)**: hard error on every invocation, blaming
  anchoring, recommending a remedy the same bug makes unreachable. The field CTO applied that
  remedy correctly and got the identical failure — the error message sent them down a blind
  alley, which is its own defect (fixed, §4).
- **The other eleven anchor-carrying skills**: fell back to `git rev-parse` **100% of the
  time**, printing the `NOTE:` line on every run. That fallback usually landed on the right
  repo because the CEO usually runs from the CTO home. The block exists precisely to stop
  relying on that luck. Any skill run during a cwd drift silently operated on the wrong tree.
- **`dirname: illegal option -- -`** was the same bug waving. Read as cosmetic noise for two
  weeks.

The anchor block was written to replace a confident wrong answer about which repo we are in.
It shipped as a confident wrong answer about which repo we are in.

## 4. Fix

| # | Change | Where |
|---|---|---|
| 1 | **Anchor block carries no positional parameters at all.** Candidates pass through named variables (`_CTO_CAND`, `_CTO_START`). Brace-wrapped positionals do survive the rewrite, and are deliberately **not** used: the next person to write the bare form reintroduces a silent bug. | `scripts/cto/_cto-home-anchor.sh`, synced to 10 skills |
| 2 | **Lint CHECK E** — any dollar-digit token anywhere in a SKILL.md is a finding. Whole-document, matching the runtime's own scope, so prose and comments are covered too. | `scripts/cto/lint-skills.sh` |
| 3 | **Four more offenders fixed**, found only because CHECK E looks at the whole class rather than the reported symptom: `digest` used `awk '{print $6,$7,$8,$9}'` (awk field references are dollar-digit tokens too), `lane-check` and `vp-review` had functions taking positionals, and three skills wrote `$0` in prose meaning *zero dollars* — rendered to the reader as argument text. | five skills |
| 4 | **`dirname -- "$_d"`** so a candidate beginning with a dash walks instead of erroring. | anchor block |
| 5 | **The error message no longer sends you down the blind alley.** When `~/.cto/home` is set, the failure prints its *content*, says the remedy is already applied and is not the fix, and points at skill rendering. | anchor block |
| 6 | **Comments in the block are written without literal placeholder tokens** — an example of the bug, written literally, would itself be rewritten. | anchor block |

Also fixed in passing, because it is the same lesson: `escalate-drain` used
`ls "$INBOX"/*.md`, and zsh errors on a non-matching glob rather than passing it through, so a
healthy empty inbox printed `no matches found` above the correct result. Noise on a healthy
path is how the anchor bug survived six weeks; it is now `find`.

## 5. Verification

- **Render-proof, all 18 skills.** Substituting argument text for every dollar-digit token in
  each SKILL.md is now a byte-for-byte no-op. That is the property that matters, and it is
  checked directly rather than by reading the code.
- **The anchor resolves.** Executed standalone from the CTO home (`ROOT` = CTO home) and from a
  drifted dev repo (`ROOT` = CTO home) — the cwd-drift case it was written for and has never
  actually handled.
- **CHECK E catches a regression.** A bare `$1` injected into a skill is reported; removing it
  returns the lint to clean.
- **Live end-to-end.** `/escalate-drain` invoked with the exact failing argument shape
  (`<slug> --repos=<repo>`) completed with no `NOTE:` line and no `dirname` error.

## 6. The lesson worth keeping

Two, and the second is the uncomfortable one.

**A template that embeds shell in a templating language inherits that language's rules.** The
anchor block was correct shell and correct nowhere else. Anything embedded in SKILL.md is
rendered first and executed second, and the reviewer has to read it in that order.

**The knowledge was already in the repo and did not travel.** `/handoff` carried a comment, at
the time the anchor was written, saying not to use awk field references *because the harness
substitutes them*. That is this exact defect, correctly diagnosed, sitting forty lines from
where the anchor block was pasted in. It was treated as a local quirk of one awk command
instead of a property of the rendering layer. A finding recorded as a workaround where it was
found, rather than as a rule about the mechanism, does not generalise — and the next author,
me, walked straight into it. CHECK E is that finding written down as a rule.

— CTO
