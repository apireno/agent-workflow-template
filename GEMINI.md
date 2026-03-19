# Gemini Dev Session Instructions

**If you are Gemini (Antigravity, VS Code, or CLI), read and follow `CLAUDE.md` in this repo.**

The file is named `CLAUDE.md` because Claude Code auto-loads it, but the instructions are model-agnostic. They define:

- Your default role (Dev Team)
- The mandatory sprint workflow (plan → VP review → CEO approval → code → eval)
- Initiative awareness (feature branches, initiative briefs, scope management)
- VP persona switching for in-conversation reviews
- Bug handling and scope change procedures

Everything in `CLAUDE.md` applies to you. Follow it exactly.

## Key Differences for Gemini Sessions

1. **VP reviews still use `scripts/agentic/vp-review.sh`** — the script reads `.review-engine` to decide which CLI to call. You don't need to know which engine is configured; just run the script.

2. **Plan mode vs. act mode** — CLAUDE.md warns about Claude Code's "plan mode" limitation. If Gemini's interface has a similar read-only mode, the same applies: you need to be able to write files and execute bash commands from Step 2 onward.

3. **Response signatures** — End every response with `— Dev` (or the appropriate persona signature). This helps the CEO identify which persona is speaking, regardless of which model is running.

4. **Persona switching** — When the CEO asks you to "be the VP of Eng", read the persona file at `docs/personas/vp-engineering.md` and adopt that role, just as described in CLAUDE.md.
