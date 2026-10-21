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
#   8 BUG-717 (2026-10-20): agy silently truncates prompts above 191,392 bytes, so a 200 KB prompt is
#     refused (exit 2, PROMPT-TOO-LARGE, bytes + limit + remedies on stderr, nothing on stdout) with
#     agy never invoked — not even `agy models`; a prompt just under the limit still goes through
# Exit: 0 all pass · 1 a guard regressed
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/agy-exec.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; return 0; }
has(){ printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || fail "$1 (missing /$2/)" "$3"; }
W="$(mktemp -d "${TMPDIR:-/tmp}/agy-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cat > "$W/agy" <<STUB
#!/usr/bin/env bash
echo "\${1:-}" >> "$W/calls"
if [ "\$1" = "models" ]; then
  echo "Fetching available models..."
  printf '%s\t%s\n' gemini-4-argon-medium x gemini-4-argon-high x gemini-4-argon-low x gemini-3.8-flash-high x claude-opus-5-5-high x gpt-oss-120b-medium x
  exit 0
fi
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
export TMPDIR="$W" AGY_MODELS_NOCACHE=1
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
echo "== 7. model resolved from agy's live list, never hard-coded =="
OUT=$(run ok); grep -A1 -x -- '--model' "$W/args" | tail -1 | grep -qx 'gemini-4-argon-high' && ok "auto picks best Gemini: non-Flash, -high, newest (gemini-4-argon-high)" || fail "auto pick was $(grep -A1 -x -- '--model' "$W/args" | tail -1)"
has "auto pick announced on stderr" 'auto-selected gemini-4-argon-high' "$(cat "$W/stderr")"
OUT=$(AGY_MODEL="gemini-3.1-pro-high,gemini-3.8-flash-high" run ok); grep -A1 -x -- '--model' "$W/args" | tail -1 | grep -qx 'gemini-3.8-flash-high' && ok "preference list: first OFFERED model wins (retired id skipped)" || fail "preference list ignored"
rm -f "$W/args"; OUT=$(AGY_MODEL="gemini-3.1-pro-high" run ok); RC=$?
[ $RC -eq 2 ] && [ ! -f "$W/args" ] && ok "retired pin refused before any call (exit 2)" || fail "retired pin: exit $RC"
has "refusal lists what IS offered" 'gemini-4-argon-high' "$(cat "$W/stderr")"

echo "== 6. refusals before any call =="
rm -f "$W/args"; AGY_BIN="$W/agy" AGY_MODEL=claude-opus-5-5-high bash "$X" <<<"x" 2>/dev/null; RC=$?
[ $RC -eq 2 ] && [ ! -f "$W/args" ] && ok "non-Gemini model refused, agy not called" || fail "non-Gemini model: exit $RC"
head -c 950000 /dev/zero | tr '\0' 'a' | AGY_BIN="$W/agy" bash "$X" 2>/dev/null; RC=$?
[ $RC -eq 2 ] && [ ! -f "$W/args" ] && ok "oversize prompt refused, agy not called" || fail "oversize: exit $RC"

echo "== 8. BUG-717 silent-truncation guard =="
rm -f "$W/args" "$W/calls"; OUT=$(head -c 200000 /dev/zero | tr '\0' 'a' | AGY_BIN="$W/agy" bash "$X" 2>"$W/stderr"); RC=$?
[ $RC -eq 2 ] && ok "200 KB prompt refused (exit 2)" || fail "200 KB: exit $RC"
[ ! -f "$W/calls" ] && ok "agy never invoked (not even \`agy models\`)" || fail "agy was called: $(cat "$W/calls")"
[ -z "$OUT" ] && ok "nothing on stdout (no verdict-shaped output)" || fail "stdout not empty"
E="$(cat "$W/stderr")"
has "names PROMPT-TOO-LARGE" 'PROMPT-TOO-LARGE' "$E"
has "prints measured bytes and the limit" 'prompt bytes: 200[0-9]{3} .*limit: 181822' "$E"
has "cites the ceiling and BUG-717" 'agy truncates silently above 191,392 bytes \(kgspin-tuner BUG-717, 2026-10-20\)' "$E"
has "names the remedies" 'shorten the artifact.*kimi' "$(printf '%s' "$E" | tr '\n' ' ')"
rm -f "$W/args"; OUT=$(head -c 181000 /dev/zero | tr '\0' 'a' | AGY_BIN="$W/agy" STUB_MODE=ok bash "$X" 2>/dev/null); RC=$?
[ $RC -eq 0 ] && [ -f "$W/args" ] && ok "181,000-byte prompt (under the limit) still reaches agy" || fail "under-limit prompt: exit $RC"
echo ""; echo "agy-exec tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
