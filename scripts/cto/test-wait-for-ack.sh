#!/usr/bin/env bash
# test-wait-for-ack.sh — the ACK watcher's match rule against a synthetic transcript. Offline.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/cto/wait-for-ack.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ack.XXXXXX")"; trap 'rm -rf "$W"' EXIT; J="$W/s.jsonl"
u(){ python3 -c 'import json,sys; print(json.dumps({"type":"user","timestamp":"t","message":{"role":"user","content":sys.argv[1]}}))' "$1" >> "$J"; }
a(){ python3 -c 'import json,sys; print(json.dumps({"type":"assistant","timestamp":sys.argv[2],"message":{"role":"assistant","content":[{"type":"text","text":sys.argv[1]}]}}))' "$1" "${2:-t}" >> "$J"; }
a $'old work\nACK R17' t0       # an ack from BEFORE the watcher started
: # 1. pre-existing ack is ignored by default; noise only -> timeout
( sleep 1; u "CTO — reply ACK R17 when done"; a "I'll send ACK R17 once the suite is green."; a $'Working on R170.\nACK R170' ) &
OUT=$(bash "$X" "$J" R17 --timeout 8 2>&1); RC=$?; wait
[ $RC -eq 3 ] && ok "ignores: an ack from before it started, the CTO's prompt, a promise in prose, and ACK R170" || fail "false positive (rc=$RC): $OUT"
: # 2. a real ack on its own line, after start
( sleep 1; a $'Suite green, 412 passed.\n\nACK R17 — dev-report written' t9 ) &
OUT=$(bash "$X" "$J" R17 --timeout 20 2>/dev/null); RC=$?; wait
[ $RC -eq 0 ] && echo "$OUT" | grep -q "ACK R17 at t9: ACK R17 — dev-report written" && ok "matches an own-line ACK in an assistant message, with its note and time" || fail "missed real ack (rc=$RC): $OUT"
: # 3. --history sees the old one
OUT=$(bash "$X" "$J" R17 --history --timeout 3 2>/dev/null); [ $? -eq 0 ] && ok "--history matches an ack already in the transcript" || fail "--history"
: # 4. markdown-wrapped own-line ack
( sleep 1; a $'**ACK B2**' tb ) &
OUT=$(bash "$X" "$J" B2 --timeout 20 2>/dev/null); RC=$?; wait
[ $RC -eq 0 ] && ok "matches a bolded own-line ack (**ACK B2**)" || fail "bold ack (rc=$RC)"
bash "$X" "$W/nope.jsonl" R1 --timeout 1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "unresolvable target -> exit 2" || fail "bad target exit"
bash "$X" "$J" 'R1;rm' >/dev/null 2>&1; [ $? -eq 2 ] && ok "a tag with shell characters is refused" || fail "tag validation"
echo ""; echo "wait-for-ack tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
