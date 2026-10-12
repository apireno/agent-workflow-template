#!/usr/bin/env bash
# test-agy-exec.sh — offline fixture test for agy-exec.sh (RCA 2026-10-12). A stub `agy` records how
# it was called and plays back each behaviour seen live. No model is called.
#   1 the no-tools preamble is the FIRST thing in the prompt, so it precedes any "read …" text
#   2 --mode plan is NOT passed (it was a silent no-op beside --disable-slash-commands); the
#     slash-command guard IS passed; the session runs in an empty scratch dir
#   3 the live failure — empty stdout + "jetski: no output produced … required the "read_file"
#     permission" — exits 3 and names TOOL-DENIED and the tool, never a quiet empty answer
#   4 an empty answer without that text still exits 3 (empty completion)
#   5 a normal answer passes through, exit 0
#   6 a non-Gemini model and an oversize prompt are refused before any call
# Exit: 0 all pass · 1 a guard regressed
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/agy-exec.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; return 0; }
has(){ printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || fail "$1 (missing /$2/)" "$3"; }
W="$(mktemp -d "${TMPDIR:-/tmp}/agy-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cat > "$W/agy" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$W/args"; pwd > "$W/cwd"; ls -A > "$W/cwd-listing"
for a in "\$@"; do case "\$a" in -p=*) printf '%s' "\${a#-p=}" > "$W/prompt";; esac; done
case "\${STUB_MODE:-ok}" in
  ok)     echo "# Review"; echo "MAJOR: something"; echo "— Eng" ;;
  denied) echo 'jetski: no output produced — a tool required the "read_file" permission that headless mode cannot prompt for, so it was auto-denied.' >&2 ;;
  empty)  : ;;
esac
exit 0
STUB
chmod +x "$W/agy"
run(){ AGY_BIN="$W/agy" STUB_MODE="$1" bash "$X" 2>"$W/stderr" <<<"Read docs/personas/vp-engineering.md and review /abs/path/dev-report.md"; }

echo "== 1-2. prompt + flags =="
OUT=$(run ok); RC=$?
head -c 22 "$W/prompt" | grep -q '^IMPORTANT: Everything' && ok "preamble is the first thing in the prompt" || fail "preamble not first: $(head -c 60 "$W/prompt")"
grep -q 'Do not call any tools' "$W/prompt" && grep -q 'Read docs/personas' "$W/prompt" && ok "preamble precedes the original prompt, which is intact" || fail "prompt mangled"
grep -qx -- '--mode' "$W/args" && fail "--mode is still passed" || ok "--mode plan not passed"
grep -qx -- '--disable-slash-commands' "$W/args" && ok "--disable-slash-commands passed" || fail "slash guard missing"
grep -qx -- '--dangerously-skip-permissions' "$W/args" && fail "tools auto-approved" || ok "tools never auto-approved"
[ ! -s "$W/cwd-listing" ] && ok "runs in an empty scratch dir" || fail "cwd not empty: $(cat "$W/cwd-listing")"
echo "== 3. tool denial is named =="
OUT=$(run denied); RC=$?
[ $RC -eq 3 ] && ok "exit 3" || fail "exit $RC"
has "TOOL-DENIED named with the tool" 'TOOL-DENIED .*\("read_file"\)' "$(cat "$W/stderr")"
[ -z "$OUT" ] && ok "nothing on stdout" || fail "stdout not empty"
echo "== 4. plain empty answer =="
OUT=$(run empty); RC=$?
[ $RC -eq 3 ] && ok "exit 3" || fail "exit $RC"
has "reported as empty completion" 'empty completion' "$(cat "$W/stderr")"
echo "== 5. normal answer =="
OUT=$(run ok); RC=$?
[ $RC -eq 0 ] && ok "exit 0" || fail "exit $RC"
has "verdict passed through" 'MAJOR: something' "$OUT"
echo "== 6. refusals before any call =="
rm -f "$W/args"; AGY_BIN="$W/agy" AGY_MODEL=claude-opus-5-5-high bash "$X" <<<"x" 2>/dev/null; RC=$?
[ $RC -eq 2 ] && [ ! -f "$W/args" ] && ok "non-Gemini model refused, agy not called" || fail "non-Gemini model: exit $RC"
head -c 950000 /dev/zero | tr '\0' 'a' | AGY_BIN="$W/agy" bash "$X" 2>/dev/null; RC=$?
[ $RC -eq 2 ] && [ ! -f "$W/args" ] && ok "oversize prompt refused, agy not called" || fail "oversize: exit $RC"
echo ""; echo "agy-exec tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
