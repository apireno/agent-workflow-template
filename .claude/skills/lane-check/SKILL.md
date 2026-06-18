---
name: lane-check
description: Run the lane-boundary-lint (ADR-001 ENFORCEMENT) — checks a repo's declared forbidden cross-lane imports and reports any violation with an actionable error (file:line, lane, RACI rule). Runs for the current repo, a given repo, or fans across every active project repo. Use before a sprint accept, or to audit lane discipline fleet-wide.
allowed-tools: Bash(*) Read
argument-hint: [repo-path] [--all] [--audit]
---

# Lane check: $ARGUMENTS

Runs `scripts/agentic/lane-boundary-lint.sh` per ADR-001. Engine-independent (pattern-based over each repo's declared `docs/architecture/lane-rules.txt`).

## Run

```!
set -uo pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ARGS="$ARGUMENTS"; ALL=0; AUDIT=""; TARGET=""
for tok in $ARGS; do
  case "$tok" in
    --all) ALL=1 ;;
    --audit) AUDIT="--audit" ;;
    --*) ;;
    *) TARGET="$tok" ;;
  esac
done

run_one() {
  local repo="$1" lint
  lint="$repo/scripts/agentic/lane-boundary-lint.sh"
  [ -x "$lint" ] || lint="$ROOT/scripts/agentic/lane-boundary-lint.sh"
  echo "=== $(basename "$repo") ==="
  ( cd "$repo" && bash "$lint" $AUDIT --rules "$repo/docs/architecture/lane-rules.txt" )
  echo ""
}

if [ "$ALL" -eq 1 ] && [ -f "$ROOT/.cto/projects.yaml" ]; then
  python3 - "$ROOT/.cto/projects.yaml" <<'PY' | while IFS= read -r p; do [ -d "$p" ] && run_one "$p"; done
import re,sys
t=open(sys.argv[1]).read()
for b in re.split(r'(?=- name:)',t):
    p=re.search(r'path:\s*(\S+)',b); a=re.search(r'active:\s*(\S+)',b)
    if p and ((a is None) or a.group(1).lower() not in ('false','no','0')): print(p.group(1))
PY
else
  run_one "${TARGET:-$ROOT}"
fi
```

## Your task as CTO

Summarize the lint output: which repos are clean vs. which have lane violations. For each violation, **route it to the owning dev team** (it's their lane-DoD to fix the import or — if the dependency is legitimate — open a CTO/ADR conversation to move the boundary). Lane-creep is never silently accepted. Sign `— CTO`.
