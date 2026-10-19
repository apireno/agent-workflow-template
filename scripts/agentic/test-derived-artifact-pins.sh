#!/usr/bin/env bash
# test-derived-artifact-pins.sh — `--fix` rebuilds a sibling-measuring artifact at the PINNED sha,
# never from the sibling's working tree; `repin` is the only way to move the pin; an external
# artifact with no pin is refused. Offline: two scratch git repos.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; G="$T/scripts/agentic/derived-artifact-gate.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -4 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/pins.XXXXXX")"; trap 'rm -rf "$W"' EXIT
S="$W/sibling"; R="$W/repo"; mkdir -p "$S" "$R/gen" "$R/docs/m" "$R/.claude"
g(){ git -C "$1" "${@:2}"; }
g "$S" init -q; g "$S" config user.email t@t; g "$S" config user.name t
echo "engine v1" > "$S/engine.txt"; g "$S" add -A; g "$S" commit -qm v1; V1=$(g "$S" rev-parse HEAD)
echo "engine v2" > "$S/engine.txt"; g "$S" commit -qam v2; V2=$(g "$S" rev-parse HEAD)
echo "engine DIRTY (uncommitted)" > "$S/engine.txt"
g "$R" init -q; g "$R" config user.email t@t; g "$R" config user.name t
cat > "$R/gen/matrix.py" <<PY
import sys, json, subprocess, os
SIB="$S"
cmd=sys.argv[1]; args=sys.argv[2:]
if cmd=="closure": print("gen/matrix.py")
elif cmd in ("seams","roots"): pass
elif cmd=="build":
    rev=args[args.index("--rev")+1] if "--rev" in args else None
    text=(subprocess.run(["git","-C",SIB,"show",rev+":engine.txt"],capture_output=True,text=True).stdout if rev
          else open(os.path.join(SIB,"engine.txt")).read())
    open("docs/m/matrix.md","w").write("measured: "+text)
    if rev: json.dump({"sibling_sha": rev}, open("docs/m/sibling.lock","w"))
PY
printf '{"sibling_sha": "%s"}\n' "$V1" > "$R/docs/m/sibling.lock"
cat > "$R/.claude/derived-artifacts.yaml" <<Y
artifacts:
  - name: matrix
    path: docs/m/matrix.md
    generator: gen/matrix.py
    mode: block
    external: true
    pin_lock: docs/m/sibling.lock
    pin_key: sibling_sha
Y
g "$R" add -A; g "$R" commit -qm init
echo "== --fix rebuilds at the pin, not the sibling's dirty working tree =="
OUT=$(bash "$G" --repo "$R" --fix 2>&1)
grep -q "measured: engine v1" "$R/docs/m/matrix.md" 2>/dev/null && ok "artifact describes the PINNED commit (v1)" || fail "artifact: $(cat "$R/docs/m/matrix.md" 2>/dev/null)" "$OUT"
grep -q DIRTY "$R/docs/m/matrix.md" && fail "sibling working-tree dirt leaked in" || ok "sibling's uncommitted change did not leak"
echo "$OUT" | grep -q "rebuilt at pin ${V1:0:12}" && ok "--fix reports the pin it built at" || fail "fix report" "$OUT"
grep -q "$V1" "$R/docs/m/sibling.lock" && ok "--fix did NOT move the pin" || fail "pin moved by --fix"
echo "== repin is the explicit act of moving it =="
OUT=$(bash "$G" --repo "$R" repin matrix "$V2" 2>&1); RC=$?
[ $RC -eq 0 ] && grep -q "measured: engine v2" "$R/docs/m/matrix.md" && grep -q "$V2" "$R/docs/m/sibling.lock" && ok "repin rebuilds at the new sha and the lock follows" || fail "repin rc=$RC" "$OUT"
echo "$OUT" | grep -q "repinned matrix: ${V1:0:12} -> ${V2:0:12}" && ok "repin reports old -> new" || fail "repin report" "$OUT"
g "$R" diff --cached --name-only | grep -q "docs/m/sibling.lock" && ok "the moved lock is staged with the artifact" || fail "lock not staged"
echo "== external with no pin is refused =="
sed -i.bak '/pin_lock:/d; /pin_key:/d' "$R/.claude/derived-artifacts.yaml"; echo "# changed" >> "$R/gen/matrix.py"
cp "$R/docs/m/matrix.md" "$W/before.md"
OUT=$(bash "$G" --repo "$R" --fix 2>&1); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "UNPINNED" && ok "refused as UNPINNED (exit $RC)" || fail "unpinned rc=$RC" "$OUT"
cmp -s "$W/before.md" "$R/docs/m/matrix.md" && ok "artifact untouched — no working-tree build" || fail "artifact was rebuilt unpinned"
echo "== a pin that names no sha is an error, not a silent unpinned build =="
mv "$R/.claude/derived-artifacts.yaml.bak" "$R/.claude/derived-artifacts.yaml"; echo '{"sibling_sha": ""}' > "$R/docs/m/sibling.lock"
OUT=$(bash "$G" --repo "$R" --fix 2>&1); echo "$OUT" | grep -q "no sha found in pin_lock" && ok "empty pin -> named error" || fail "empty pin" "$OUT"
echo ""; echo "derived-artifact-pins tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
