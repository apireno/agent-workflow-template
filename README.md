# Agent Workflow Template

A structured multi-agent development workflow using AI agents as VP of Engineering, VP of Product, and Dev Team. Designed for solo developers or small teams who use Claude Code + Antigravity (Gemini) to simulate a full engineering org.

## Quick Start

```bash
# Clone into your project (or use as a GitHub template)
git clone https://github.com/YOUR_USERNAME/agent-workflow-template.git
cd agent-workflow-template

# Run setup
chmod +x setup.sh
./setup.sh "My Project Name"

# Customize the persona files (see setup output for guidance)
```

## What's Included

```
docs/
  personas/               # Canonical agent persona definitions
    README.md             # System overview
    PROTOCOL.md           # Inter-agent communication rules
    vp-engineering.md     # VP of Engineering persona
    vp-product.md         # VP of Product persona
    dev-team.md           # Dev Team persona
  architecture/
    decisions/            # ADR directory (VP of Eng writes here)
  roadmap/
    prds/                 # PRD directory (VP of Product writes here)
    ROADMAP.md            # Product roadmap
  sprints/
    _templates/           # 8 artifact templates for the sprint lifecycle
      scope.md            # VP Product → sprint scope
      tech-review.md      # VP Eng → PRD feasibility review
      sprint-plan.md      # Dev Team → implementation plan
      vp-eng-review.md    # VP Eng → plan review
      dev-report.md       # Dev Team → sprint results
      product-review.md   # VP Product → requirements check
      test-eval.md        # VP Eng → test quality review
      rca.md              # VP Eng → root cause analysis

.agents/workflows/        # Antigravity adapter files
  vp_engineering_persona.md
  vp_product_persona.md
```

## How It Works

Three AI agents, each with strict role boundaries and output contracts:

| Role | Tool | Does | Doesn't |
|------|------|------|---------|
| **VP of Engineering** | Antigravity (Gemini) | Reviews plans, writes ADRs, evaluates tests, does RCAs | Write code, fix bugs, author PRDs |
| **VP of Product** | Antigravity (Gemini) | Writes PRDs, owns roadmap, scopes sprints | Write code, make architecture decisions |
| **Dev Team** | Claude Code (Claude) | Writes code, tests, sprint plans, dev reports | Write PRDs, ADRs, or roadmap updates |

The CEO (you) routes between agents by pointing them at each other's artifacts in the repo.

## Customization

After cloning, customize these sections in each persona file:

- **VP of Engineering** → `Domain Knowledge` section + `Anti-Pattern Watchlist` table
- **VP of Product** → `Domain Knowledge` section
- **Dev Team** → Adjust permitted output directories for your project structure

## License

MIT
