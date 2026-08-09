#!/usr/bin/env bash
# deny-generated-edit.sh — PreToolUse(Edit|Write|NotebookEdit) guard for generated artifacts.
#
# Some files are BUILD OUTPUTS: produced by a generator, a tuning/derivation workflow, a
# compiler, or a training run. They are only trustworthy if reproducible from that process, so
# they must change THROUGH it — never by hand.
#
# Documenting that rule is not enough. A downstream RCA found the rule already existed but was
# enforced only inside the generating team's own lane, so it was bypassed the moment another
# team edited the file. Enforcement has to bind at the ARTIFACT PATH, for every session, every
# persona. That is what this hook does.
#
# It discriminates cleanly: a generator writes its output by RUNNING (Bash), which this hook
# never sees. A hand-edit arrives as Edit/Write/NotebookEdit, which it blocks.
#
# OPT-IN AND INERT BY DEFAULT. It reads `.claude/generated-paths` — one glob per line, `#`
# comments and blank lines ignored, paths relative to the repo root. No such file (the default
# in a fresh repo) means no protected paths and the hook exits 0 immediately. A project turns
# the rule on by declaring what it generates:
#
#     # .claude/generated-paths
#     bundles/**            # extraction bundles — owned by the tuning workflow
#     schema/generated/*.py # generated clients — run `make codegen`
#
# Exit 2 = block, with stderr fed back to the model so it routes the change to the generator
# instead of retrying the edit.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DECL="$ROOT/.claude/generated-paths"
[ -f "$DECL" ] || exit 0

INPUT=$(cat)
TARGET=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")
[ -n "$TARGET" ] || exit 0

# Match the path relative to the repo root, so declared globs stay repo-relative regardless of
# where the session's cwd sits.
REL="$TARGET"
case "$TARGET" in "$ROOT"/*) REL="${TARGET#"$ROOT"/}" ;; esac

MATCHED=$(python3 - "$DECL" "$REL" <<'PY' 2>/dev/null || echo ""
import fnmatch, sys
decl, rel = sys.argv[1], sys.argv[2]
for line in open(decl):
    pat = line.split('#', 1)[0].strip()
    if not pat:
        continue
    # `bundles/**` should cover bundles/a.json and bundles/x/y.json alike; fnmatch's `*`
    # crosses separators, so a trailing `/**` is equivalent to a trailing `/*` here — but
    # normalise it so the declaration reads the way authors expect.
    cand = [pat, pat[:-1]] if pat.endswith('/**') else [pat]
    if any(fnmatch.fnmatch(rel, c) for c in cand):
        print(pat)
        break
PY
)

if [ -n "$MATCHED" ]; then
    echo "BLOCKED (generated-artifact policy): '$REL' matches '$MATCHED' in .claude/generated-paths." >&2
    echo "This file is a BUILD OUTPUT — it may only change by running the workflow that generates it." >&2
    echo "A hand-edit here is an automatic sprint REJECT, even when it implements a CEO/CTO ruling." >&2
    echo "Instead: run the generator, or route the change to the team that owns it and escalate to the CTO." >&2
    exit 2
fi

exit 0
