#!/usr/bin/env bash
# test-derived-artifact-gate.sh — fixture test for the governed-derived-artifact gate (ADR-002).
#
# Builds a throwaway git repo with a TOY generator (a call-graph walker over `import` lines
# from declared roots; seams = `read_config(` sites; excludes tests/ and scripts/) and drives
# every acceptance item the template owns:
#   1  a commit touching a covered file without regeneration is REFUSED naming the fix; --fix passes it
#   2  a seam added in a file outside the closure is REFUSED, file:line named; an excluded path is not
#   3  a declared root that no longer resolves is REFUSED, root named
#   4  a required artifact with no generator fails loudly (commit + --require without a manifest)
#   8  mode: warn and a live warn_until downgrade to a warning with identical text; an expired one blocks
#   +  the pre-commit backstop refuses and then accepts through core.hooksPath, chaining a legacy hook
#
# Runs entirely offline in a temp dir. Exit 0 all pass · 1 a guard has regressed.

set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GATE="$T/scripts/agentic/derived-artifact-gate.sh"
HOOK="$T/.claude/githooks/pre-commit"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }
expect_rc() { # expect_rc <desc> <want> <got> [output]
  if [ "$2" -eq "$3" ]; then ok "$1 (exit $3)"; else fail "$1 (want exit $2, got $3)" "${4:-}"; fi
}
expect_grep() { if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else fail "$1 (missing /$2/)" "$3"; fi; }
expect_nogrep() { if printf '%s' "$3" | grep -qE -- "$2"; then fail "$1 (unexpected /$2/)" "$3"; else ok "$1"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/dag-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
R="$W/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t; git config commit.gpgsign false
mkdir -p src/engine src/other tests scripts/graph scripts/agentic .claude/githooks docs/graph
cp "$GATE" scripts/agentic/; cp "$HOOK" .claude/githooks/; chmod +x scripts/agentic/*.sh .claude/githooks/pre-commit

cat > scripts/graph/config.json <<'J'
{"roots": ["src/engine/main.py:run"], "excludes": ["tests/*", "scripts/*"], "seam": "read_config\\("}
J
cat > scripts/graph/build.py <<'PYG'
#!/usr/bin/env python3
"""Toy generator honoring the ADR-002 contract: closure | seams | roots | build."""
import sys, os, re, json, fnmatch
CFG = json.load(open("scripts/graph/config.json"))
def mod_to_path(m):
    p = m.replace(".", "/") + ".py"
    return p if os.path.isfile(p) else None
def closure():
    seen = []; todo = [r.split(":")[0] for r in CFG["roots"]]
    while todo:
        f = todo.pop()
        if f in seen or not os.path.isfile(f): continue
        seen.append(f)
        for line in open(f):
            m = re.match(r"\s*(?:from\s+(\S+)\s+import\s+(\S+)|import\s+(\S+))", line)
            if m:
                cands = [m.group(3)] if m.group(3) else [m.group(1), m.group(1) + "." + m.group(2)]
                for c in cands:
                    p = mod_to_path(c)
                    if p: todo.append(p)
    return sorted(seen)
def seams():
    out = []
    for d, _, fs in os.walk("."):
        for fn in fs:
            if not fn.endswith(".py"): continue
            rel = os.path.normpath(os.path.join(d, fn))
            if any(fnmatch.fnmatch(rel, e) for e in CFG["excludes"]): continue
            for i, line in enumerate(open(rel), 1):
                if re.search(CFG["seam"], line): out.append(f"{rel}:{i}:config-read")
    return out
cmd = sys.argv[1]
if cmd == "closure": print("\n".join(closure()))
elif cmd == "seams": print("\n".join(seams()))
elif cmd == "roots": print("\n".join(CFG["roots"]))
elif cmd == "build":
    os.makedirs("docs/graph", exist_ok=True)
    json.dump({"closure": closure(), "seams": seams()}, open("docs/graph/graph.json", "w"), indent=1)
else: sys.exit(2)
PYG
cat > src/engine/main.py <<'P'
from src.engine import step
def run(): return step.go(read_config("k"))
P
cat > src/engine/step.py <<'P'
def go(x): return x
P
cat > tests/test_x.py <<'P'
def test(): read_config("k")   # a seam in an EXCLUDED path: not a leak
P
cat > .claude/derived-artifacts.yaml <<'Y'
artifacts:
  - name: graph
    path: docs/graph/
    generator: scripts/graph/build.py
    mode: block
Y

echo "== bootstrap: build + stamp + commit =="
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); RC=$?
expect_rc "unstamped artifact is a finding" 3 "$RC" "$OUT"; expect_grep "  names NO-STAMP + fix cmd" "NO-STAMP.*build" "$OUT"
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --fix 2>&1); RC=$?
expect_rc "--fix builds + stamps" 0 "$RC" "$OUT"; expect_grep "  reports FIXED" "FIXED" "$OUT"
[ -f docs/graph/.stamp ] && ok "stamp written at docs/graph/.stamp" || fail "stamp missing"
git add -A >/dev/null; git commit -qm "bootstrap" && ok "bootstrap commit"
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --head 2>&1); expect_rc "clean at HEAD" 0 "$?" "$OUT"

echo "== 1. covered file changed, not regenerated =="
echo "def go(x): return x + 1" > src/engine/step.py; git add src/engine/step.py
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --staged 2>&1); RC=$?
expect_rc "--staged refuses STALE" 3 "$RC" "$OUT"
expect_grep "  names the changed file" "1 changed: src/engine/step.py" "$OUT"
expect_grep "  prints the fix command" "Run: .*build.*stamp graph" "$OUT"
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --fix 2>&1); expect_rc "--fix clears it" 0 "$?" "$OUT"
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --staged 2>&1); expect_rc "--staged clean after fix (artifact+stamp staged)" 0 "$?" "$OUT"
git commit -qm "step change + regen"

echo "== pre-commit backstop via core.hooksPath (chains legacy hook) =="
mkdir -p .git/hooks; printf '#!/bin/sh\necho LEGACY-HOOK-RAN >&2\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
git config core.hooksPath .claude/githooks
echo "def go(x): return x + 2" > src/engine/step.py; git add src/engine/step.py
OUT=$(git commit -qm "stale attempt" 2>&1); RC=$?
expect_rc "hook refuses a stale commit" 1 "$RC" "$OUT"; expect_grep "  legacy hook still ran" "LEGACY-HOOK-RAN" "$OUT"; expect_grep "  says REFUSED" "commit REFUSED" "$OUT"
bash scripts/agentic/derived-artifact-gate.sh --fix >/dev/null 2>&1
OUT=$(git commit -qm "after fix" 2>&1); expect_rc "hook accepts after --fix" 0 "$?" "$OUT"
OUT=$(DERIVED_ARTIFACT_GATE=skip git commit -q --allow-empty -m "skip" 2>&1); expect_rc "explicit skip works and says so" 0 "$?" "$OUT"; expect_grep "  skip is announced" "SKIPPED" "$OUT"

echo "== 2. seam leak outside the closure =="
printf 'def dark(): return read_config("hidden")\n' > src/other/dark.py
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); RC=$?
expect_rc "leak refuses" 3 "$RC" "$OUT"; expect_grep "  names file:line" "src/other/dark.py:1 declares a 'config-read' seam" "$OUT"
expect_nogrep "  excluded tests/ seam is NOT reported" "tests/test_x" "$OUT"
rm src/other/dark.py

echo "== 3. dead root =="
cp scripts/graph/config.json "$W/config.good"
sed -i.bak 's#src/engine/main.py:run#src/engine/gone.py:run#' scripts/graph/config.json
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); RC=$?
expect_rc "dead root refuses" 3 "$RC" "$OUT"; expect_grep "  names the root" "DEAD-ROOT.*src/engine/gone.py:run" "$OUT"
sed -i.bak 's#src/engine/gone.py:run#src/engine/main.py:nope#' scripts/graph/config.json
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); expect_grep "dead SYMBOL refuses too" "DEAD-ROOT.*symbol 'nope'" "$OUT"
cp "$W/config.good" scripts/graph/config.json; rm -f scripts/graph/config.json.bak
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); expect_rc "clean after restoring root" 0 "$?" "$OUT"

echo "== 4. no generator / no manifest =="
cp .claude/derived-artifacts.yaml /tmp/dag-manifest.bak.$$
sed -i.bak 's#scripts/graph/build.py#scripts/graph/missing.py#' .claude/derived-artifacts.yaml
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); RC=$?
expect_rc "missing generator refuses" 3 "$RC" "$OUT"; expect_grep "  says NO-GENERATOR" "NO-GENERATOR" "$OUT"
mv /tmp/dag-manifest.bak.$$ .claude/derived-artifacts.yaml; rm -f .claude/derived-artifacts.yaml.bak
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --require --repo "$W" 2>&1); RC=$?
expect_rc "--require with no manifest is a config error" 4 "$RC" "$OUT"
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --repo "$W" 2>&1); expect_rc "no manifest without --require is inert" 0 "$?" "$OUT"

echo "== 8. rigor knobs: warn / warn_until =="
echo "def go(x): return x + 3" > src/engine/step.py
sed -i.bak 's/mode: block/mode: warn/' .claude/derived-artifacts.yaml
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); RC=$?
expect_rc "mode: warn exits 0" 0 "$RC" "$OUT"; expect_grep "  same STALE text, as WARN" "STALE.*closure changed" "$OUT"; expect_grep "  summary says WARN" "^WARN:" "$OUT"
OUT=$(bash scripts/agentic/derived-artifact-gate.sh --audit 2>&1); expect_rc "--audit still exits 3 in warn mode" 3 "$?" "$OUT"
sed -i.bak 's/mode: warn/mode: block/' .claude/derived-artifacts.yaml
printf '    warn_until: 2099-01-01\n' >> .claude/derived-artifacts.yaml
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); expect_rc "live warn_until downgrades block to warn" 0 "$?" "$OUT"
sed -i.bak 's/2099-01-01/2000-01-01/' .claude/derived-artifacts.yaml
OUT=$(bash scripts/agentic/derived-artifact-gate.sh 2>&1); expect_rc "expired warn_until blocks" 3 "$?" "$OUT"

echo ""
echo "derived-artifact-gate tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
