# Private Domain Context

This directory contains project-specific domain knowledge files that are **gitignored** for public repos. These files are loaded by the persona system to give agents deep project context.

## How It Works

The canonical persona files in `docs/personas/` have a `Domain Knowledge` section with a comment:
```
<!-- CUSTOMIZE: Replace this section with project-specific context -->
```

Instead of putting sensitive content directly in the persona file (which is committed), you can:

1. Keep the persona file generic (committed, public)
2. Put domain-specific context in this directory (gitignored, private)
3. When invoking the agent, tell it to read both files

## Files

| File | Used By | Contains |
|------|---------|----------|
| `vp-eng-context.md` | VP of Engineering | Architecture details, anti-pattern watchlist, ADR summaries, tech stack specifics |
| `vp-product-context.md` | VP of Product | Competitive positioning, customer personas, strategic priorities, success metrics |

## Invocation Pattern

Instead of just:
```
Read docs/personas/vp-engineering.md
```

Use:
```
Read docs/personas/vp-engineering.md and docs/personas/context/vp-eng-context.md
```

The adapter files in `.agents/workflows/` can be updated to reference the context files automatically.

## Template

Create your context files using this structure:

```markdown
# VP of Engineering — Project Context

## Architecture Overview
{Your system's architecture, key modules, data flow}

## Anti-Pattern Watchlist (Project-Specific)
| Anti-Pattern | What to Watch For |
|---|---|
| {pattern} | {description} |

## ADR Summary
{Key architectural decisions and their rationale}

## Tech Stack
{Languages, frameworks, infrastructure, key dependencies}
```
