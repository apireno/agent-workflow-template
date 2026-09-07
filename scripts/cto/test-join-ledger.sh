#!/usr/bin/env bash
# test-join-ledger.sh — fixture test for the cross-repo join (ADR-002 §7, acceptance item 9).
# Two throwaway repos: `engine` produces run(doc, *, mode="fast", **opts) and ledger_write(path, rows);
# `tuner` consumes both. Asserts: a renamed keyword and a missing required arg are MISMATCHES,
# a producer adding an optional parameter is NOT, an unannotated result read is UNVERIFIED,
# `join: off` skips the repo, and --quiet prints only findings.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
JL="$T/scripts/cto/join-ledger.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }
expect_rc(){ [ "$2" -eq "$3" ] && ok "$1 (exit $3)" || fail "$1 (want $2, got $3)" "${4:-}"; }
expect_grep(){ printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || fail "$1 (missing /$2/)" "$3"; }
expect_nogrep(){ printf '%s' "$3" | grep -qE -- "$2" && fail "$1 (unexpected /$2/)" "$3" || ok "$1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/jl-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mk_repo(){ # mk_repo <name> <boundary-json-file> [join-mode]
  local d="$W/$1"; mkdir -p "$d/.claude" "$d/gen"
  cat > "$d/gen/b.py" <<PYG
import sys, json
cmd = sys.argv[1]
if cmd == "boundary": print(open("gen/boundary.json").read())
elif cmd in ("closure","seams","roots"): print("")
elif cmd == "build": pass
PYG
  cp "$2" "$d/gen/boundary.json"
  printf 'artifacts:\n  - name: g\n    path: docs/g.json\n    generator: gen/b.py\nboundary:\n  join: %s\n' "${3:-advisory}" > "$d/.claude/derived-artifacts.yaml"
}
cat > "$W/engine.json" <<'J'
{"producers":[
  {"name":"engine.run","params":[{"name":"doc","kind":"positional","default":false,"annotation":"str"},
                                  {"name":"mode","kind":"keyword","default":true,"annotation":"str"},
                                  {"name":"opts","kind":"var_keyword","default":true}],
   "returns":"Result","returns_fields":["graph","ledger"]},
  {"name":"engine.ledger_write","params":[{"name":"path","kind":"positional","default":false},
                                           {"name":"rows","kind":"positional","default":false}],
   "returns":"None"},
  {"name":"engine.score","params":[{"name":"g","kind":"positional","default":false}],"returns":"float"}
],"consumers":[]}
J
cat > "$W/tuner.json" <<'J'
{"producers":[],"consumers":[
  {"callee":"engine.run","positional":1,"keywords":["mode"],"reads":["graph"]},
  {"callee":"engine.run","positional":1,"keywords":["mode"],"reads":["confidence"]},
  {"callee":"engine.ledger_write","positional":1,"keywords":[],"reads":[]},
  {"callee":"engine.score","positional":1,"keywords":[],"reads":["value"]},
  {"callee":"engine.retired","positional":0,"keywords":[],"reads":[]}
]}
J
mk_repo engine "$W/engine.json"; mk_repo tuner "$W/tuner.json"
mkdir -p "$W/home/.cto"; printf 'projects:\n  - name: engine\n    path: %s/engine\n    active: true\n  - name: tuner\n    path: %s/tuner\n    active: true\n' "$W" "$W" > "$W/home/.cto/projects.yaml"

echo "== join: mismatches + subset semantics =="
OUT=$(bash "$JL" --registry "$W/home/.cto/projects.yaml" 2>&1); RC=$?
expect_rc "mismatches exit 3" 3 "$RC" "$OUT"
expect_grep "  call with a known keyword + verified field is OK" "engine.run +OK +producer engine; fields verified" "$OUT"
expect_grep "  unknown result field is UNKNOWN-FIELD" "UNKNOWN-FIELD.*confidence" "$OUT"
expect_grep "  missing required positional is MISSING-ARG" "ledger_write +MISSING-ARG.*requires .rows." "$OUT"
expect_grep "  unannotated fields read is UNVERIFIED" "engine.score +UNVERIFIED" "$OUT"
expect_grep "  retired callee is MISSING-CALLEE" "engine.retired +MISSING-CALLEE" "$OUT"
[ -f "$W/home/.cto/join-ledger.md" ] && ok "ledger written next to the registry" || fail "ledger missing"
expect_grep "  ledger has the summary line" "Mismatches:\*\* 3" "$(cat "$W/home/.cto/join-ledger.md")"

echo "== producer adds an OPTIONAL param: not a mismatch =="
python3 - "$W/engine/gen/boundary.json" <<'PYP'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["producers"][1]["params"].append({"name":"fsync","kind":"keyword","default":True})
json.dump(d,open(p,"w"))
PYP
OUT=$(bash "$JL" --registry "$W/home/.cto/projects.yaml" 2>&1)
expect_grep "still exactly the 3 prior mismatches" "3 mismatch" "$OUT"

echo "== producer RENAMES a keyword: new mismatch =="
python3 - "$W/engine/gen/boundary.json" <<'PYP'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["producers"][0]["params"][1]["name"]="profile"; d["producers"][0]["params"]=[x for x in d["producers"][0]["params"] if x["kind"]!="var_keyword"]
json.dump(d,open(p,"w"))
PYP
OUT=$(bash "$JL" --registry "$W/home/.cto/projects.yaml" 2>&1)
expect_grep "renamed keyword is UNKNOWN-KEYWORD naming both sides" "UNKNOWN-KEYWORD +passes .mode=.; engine has no such parameter" "$OUT"

echo "== --quiet prints findings only; join: off skips =="
OUT=$(bash "$JL" --quiet --registry "$W/home/.cto/projects.yaml" 2>&1)
expect_nogrep "quiet hides OK rows" " OK " "$OUT"; expect_grep "quiet keeps mismatches" "MISSING-CALLEE" "$OUT"
sed -i.bak 's/join: advisory/join: off/' "$W/tuner/.claude/derived-artifacts.yaml"
OUT=$(bash "$JL" --registry "$W/home/.cto/projects.yaml" 2>&1); RC=$?
expect_rc "join: off consumer → no mismatches" 0 "$RC" "$OUT"; expect_grep "  ledger notes the skip" "Skipped \(join: off\):\*\* tuner" "$(cat "$W/home/.cto/join-ledger.md")"
echo ""; echo "join-ledger tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
