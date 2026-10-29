#!/usr/bin/env bash
# test-agy-hard-timeout.sh — review engines can no longer become unkillable orphans (fleet RCA
# 2026-10-28). A fake agy that IGNORES TERM and sleeps forever stands in for a hung engine. Offline.
#   1 agy-exec.sh, run under INHERITED ignored TERM/HUP/INT (as the detach runs it), returns 124 at the
#     hard clock, names HARD-TIMEOUT, leaves no process and no pidfile
#   2 killing the supervisor mid-run takes the engine's whole process group with it
#   3 through vp-review-detach.sh: the launching shell is gone, the review still ends (failed) at the
#     hard clock, and no engine survives
#   4 vp-review-wait.sh on a stale "running" row reaps the recorded group and marks it
#     "failed: hard-timeout (reaped)"
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/agy-exec.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -5 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/agyhard.XXXXXX")"; W="$(cd "$W" && pwd -P)"
FAKE="$W/fake-agy-$$"
cleanup(){ pkill -9 -f "$FAKE" 2>/dev/null; pkill -9 -f "sleep 9$$" 2>/dev/null; rm -rf "$W"; }; trap cleanup EXIT
cat > "$FAKE" <<STUB
#!/usr/bin/env bash
[ "\$1" = models ] && { printf 'gemini-4-argon-high\tx\n'; exit 0; }
trap '' TERM HUP INT
sleep 9$$
STUB
chmod +x "$FAKE"
alive(){ pgrep -f "$FAKE" >/dev/null || pgrep -f "sleep 9$$" >/dev/null; }
export TMPDIR="$W" AGY_MODELS_NOCACHE=1 AGY_BIN="$FAKE" AGY_TIMEOUT=2 AGY_HARD_GRACE=2

echo "== 1. hard clock under inherited SIG_IGN =="
S=$(date +%s); OUT=$(echo p | AGY_PIDFILE="$W/1.pid" bash -c 'trap "" TERM HUP INT; bash "$0"' "$X" 2>&1); RC=$?; E=$(( $(date +%s)-S ))
[ $RC -eq 124 ] && ok "exit 124 at the hard clock (${E}s; clock 4s + 5s TERM grace)" || fail "rc=$RC after ${E}s" "$OUT"
echo "$OUT" | grep -q "HARD-TIMEOUT after 4s" && ok "failure is named HARD-TIMEOUT" || fail "message" "$OUT"
sleep 1; alive && fail "an engine process survived" || ok "no engine process survives"
[ ! -f "$W/1.pid" ] && ok "pidfile removed" || fail "pidfile left behind"

echo "== 2. killing the supervisor takes the engine group with it =="
( echo p | AGY_TIMEOUT=600 AGY_PIDFILE="$W/2.pid" bash "$X" >/dev/null 2>&1 ) & BG=$!
for _ in $(seq 1 20); do [ -s "$W/2.pid" ] && break; sleep 0.25; done
# The supervisor is EXACTLY the parent of the recorded engine group — never found by pattern: a
# pattern match (an earlier version used `pgrep -f 'perl -e'`) can signal an unrelated process.
PG=$(cat "$W/2.pid" 2>/dev/null); SUP=$( [ -n "$PG" ] && ps -o ppid= -p "$PG" | tr -d ' ')
[ -s "$W/2.pid" ] && ok "process group recorded while running" || fail "no pidfile while running"
if [ -n "$SUP" ] && ps -o command= -p "$SUP" | grep -q '^perl'; then kill -TERM "$SUP"; else fail "could not identify the supervisor exactly — not signalling anything"; fi
for _ in $(seq 1 16); do kill -0 "$SUP" 2>/dev/null || break; sleep 0.5; done
alive && fail "engine survived the supervisor's death (orphan)" || ok "supervisor TERMed -> engine group killed, no orphan"
wait $BG 2>/dev/null; [ $? -eq 143 ] && ok "agy-exec reports the kill (exit 143)" || fail "agy-exec exit after supervisor TERM"

echo "== 3. through vp-review-detach.sh, launching shell gone =="
OD="$W/od"; echo "# plan" > "$W/plan.md"
( cd "$T" && VP_REVIEW_MAX_ATTEMPTS=1 REVIEW_ENGINE_FALLBACK= bash scripts/agentic/vp-review-detach.sh "$W/plan.md" "$OD" vp-eng --engine agy >/dev/null 2>&1 ) &
DPID=$!; sleep 1; kill -9 $DPID 2>/dev/null
for _ in $(seq 1 30); do [ "$(cat "$OD/vp-eng.status" 2>/dev/null)" = running ] || break; sleep 1; done
ST=$(cat "$OD/vp-eng.status" 2>/dev/null)
[ "$ST" = failed ] && ok "review ended 'failed' at the hard clock despite its launcher dying" || fail "status '$ST'"
grep -q "HARD-TIMEOUT" "$OD"/vp-eng.md.agy-stderr.log 2>/dev/null && ok "the review's agy log names HARD-TIMEOUT" || fail "no HARD-TIMEOUT in the review log"
sleep 1; alive && fail "engine survived the detached review" || ok "no orphan after the detached review"

echo "== 4. vp-review-wait reaps a stale row =="
OD4="$W/od4"; mkdir -p "$OD4"
perl -e 'setpgrp(0,0); $SIG{$_}="IGNORE" for qw(TERM HUP INT); exec @ARGV' "$FAKE" run >/dev/null 2>&1 & EP=$!
sleep 1; echo "$EP" > "$OD4/vp-eng.agy.pid"; echo running > "$OD4/vp-eng.status"; touch -t 202601010000 "$OD4/vp-eng.status"
OUT=$(VP_REVIEW_REAP_AFTER=1 bash "$T/scripts/agentic/vp-review-wait.sh" "$OD4" --timeout 1 --quiet 2>&1); RC=$?
sleep 1; kill -0 "$EP" 2>/dev/null && fail "stale engine still alive after the wait gave up" "$OUT" || ok "the wait SIGKILLed the stale engine group"
[ "$(cat "$OD4/vp-eng.status")" = "failed: hard-timeout (reaped)" ] && ok "row marked 'failed: hard-timeout (reaped)'" || fail "status: $(cat "$OD4/vp-eng.status")"
echo "$OUT" | grep -q "hard-timeout (reaped)" && [ $RC -eq 1 ] && ok "table shows it as a failure (exit 1), not 'still running' (exit 3)" || fail "rc=$RC" "$OUT"
echo ""; echo "agy-hard-timeout tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
