# Agent Workflow Template

A structured multi-agent development workflow using AI agents as VP of Engineering, VP of Product, VP of Security, VP of Compliance, VP of DevOps, and Dev Team. Designed for solo developers or small teams who use Claude Code + Gemini CLI to simulate a full engineering org.

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

### Prerequisites

- [Gemini CLI](https://github.com/google-gemini/gemini-cli) installed and authenticated (`gemini --version`)
- Claude Code (VS Code extension or CLI)

## What's Included

```
CLAUDE.md                         # Claude Code config (auto-loaded)
scripts/
  vp-review.sh                    # Gemini CLI wrapper for automated VP reviews
docs/
  personas/                       # Canonical agent persona definitions
    PROTOCOL.md                   # Inter-agent communication protocol (v2)
    vp-engineering.md             # VP of Engineering persona
    vp-product.md                 # VP of Product persona
    vp-security.md                # VP of Security persona
    vp-compliance.md              # VP of Compliance persona
    vp-devops.md                  # VP of DevOps persona
    dev-team.md                   # Dev Team persona
    context/                      # Private domain context (gitignored)
      README.md
    concerns/                     # Project-specific concerns (committed)
      security.md                 # Security posture and attack surface
      compliance.md               # Regulatory landscape and ToS
      devops.md                   # Infrastructure inventory and gaps
  sprints/
    _templates/                   # 8 artifact templates for sprint lifecycle
.agents/workflows/                # Antigravity adapter files (5 VPs)
.skills/                          # Claude skills for in-conversation personas
  vp-eng/SKILL.md
  vp-prod/SKILL.md
  vp-security/SKILL.md
  vp-compliance/SKILL.md
  vp-devops/SKILL.md
```

## How It Works

Six AI agents, each with strict role boundaries and output contracts:

| Role | Signature | Engine | Does | Doesn't |
|------|-----------|--------|------|---------|
| **VP of Engineering** | `— Eng` | Gemini CLI or Claude | Reviews plans, writes ADRs, evaluates tests, does RCAs | Write code, fix bugs, author PRDs |
| **VP of Product** | `— Prod` | Gemini CLI or Claude | Writes PRDs, owns roadmap, scopes sprints | Write code, make architecture decisions |
| **VP of Security** | `— Sec` | Gemini CLI or Claude | Threat models, security reviews, audit reports | Write code, implement security controls |
| **VP of Compliance** | `— Comp` | Gemini CLI or Claude | Regulatory reviews, ToS compliance checks | Write code, provide legal advice |
| **VP of DevOps** | `— DevOps` | Gemini CLI or Claude | Infra reviews, runbooks, monitoring recs | Write code, write IaC or CI/CD YAML |
| **Dev Team** | `— Dev` | Claude Code | Writes code, tests, sprint plans, dev reports | Write PRDs, ADRs, or roadmap updates |

### Dual-Engine Model

Each VP can be invoked two ways:
1. **Gemini CLI** — automated file-to-file reviews via `scripts/vp-review.sh`. Claude Code runs this as a bash command during sprint planning.
2. **Claude Skill** — Claude adopts the persona in-conversation when you want a second opinion.

### Automated Sprint Workflow

```
Dev writes sprint plan
  → Gemini CLI: VP Product review
  → Gemini CLI: VP Eng review
  → (optional) Gemini CLI: VP Security / DevOps / Compliance reviews
  → Dev reads feedback, revises plan
  → CEO approves
  → Dev implements + runs tests
  → Gemini CLI: VP Product evaluates delivery
  → Gemini CLI: VP Eng evaluates tests
  → CEO closes sprint
```

No copy-paste between tools. All handoffs are file-based.

## Customization

After running `setup.sh`, customize:

1. **Persona Domain Knowledge** — Fill in the `<!-- CUSTOMIZE -->` sections in each persona file
2. **Project Concerns** — Fill in `docs/personas/concerns/security.md`, `compliance.md`, and `devops.md`
3. **Private Context** — Create `docs/personas/context/vp-eng-context.md` and `vp-product-context.md` for deep project-specific knowledge (gitignored)
4. **Technical Standards** — Add coding standards in `CLAUDE.md`
5. **Anti-Pattern Watchlist** — Customize the watchlist table in `vp-engineering.md`

## License

MIT
