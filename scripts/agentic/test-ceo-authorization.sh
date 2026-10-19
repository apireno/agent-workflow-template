#!/usr/bin/env bash
# test-ceo-authorization.sh — ceo-authorize.sh + check-authorization.sh. The success path needs a
# terminal; the test supplies one with `script` (a pty). That is the deliberate workaround the
# recorder's header names — used here only so the happy path can be tested at all.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; A="$T/scripts/agentic/ceo-authorize.sh"; C="$T/scripts/agentic/check-authorization.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/auth.XXXXXX")"; trap 'rm -rf "$W"' EXIT; D="$W/sprint"; mkdir -p "$D"
bash "$A" "$D" fill-B "go" </dev/null >/dev/null 2>&1; [ $? -eq 4 ] && [ ! -f "$D/CEO-AUTHORIZATION.md" ] && ok "no terminal (an agent's shell) -> refused, nothing written" || fail "no-tty refusal"
bash "$C" "$D" fill-B >/dev/null 2>&1; [ $? -eq 1 ] && ok "unauthorized gate -> check exits 1" || fail "check before auth"
OUT=$(bash "$C" "$D" fill-B 2>&1); echo "$OUT" | grep -q "ceo-authorize.sh '$D' fill-B" && ok "refusal prints the exact command for the CEO" || fail "refusal text: $OUT"
( sleep 1; printf 'wrong\n' ) | script -q /dev/null bash "$A" "$D" fill-B 'Go ahead with stage B, "all of it".' >/dev/null 2>&1
[ ! -f "$D/CEO-AUTHORIZATION.md" ] && ok "mistyped confirmation -> nothing recorded" || fail "recorded without confirmation"
( sleep 1; printf 'fill-B\n' ) | script -q /dev/null bash "$A" "$D" fill-B 'Go ahead with stage B, "all of it".' >/dev/null 2>&1
grep -q '^## fill-B' "$D/CEO-AUTHORIZATION.md" 2>/dev/null && ok "confirmed in a terminal -> section recorded" || fail "not recorded"
OUT=$(bash "$C" "$D" fill-B 2>&1); [ $? -eq 0 ] && echo "$OUT" | grep -q 'Go ahead with stage B, "all of it"' && ok "check passes and quotes the CEO's words verbatim (quotes intact)" || fail "check after auth: $OUT"
bash "$C" "$D" other-gate >/dev/null 2>&1; [ $? -eq 1 ] && ok "authorization is per gate, not blanket" || fail "other gate passed"
sed -i.bak 's/stage B/stage C/' "$D/CEO-AUTHORIZATION.md"
OUT=$(bash "$C" "$D" fill-B 2>&1); [ $? -eq 1 ] && echo "$OUT" | grep -q "seal mismatch" && ok "words edited after recording -> seal mismatch, not authorized" || fail "tamper: $OUT"
mv "$D/CEO-AUTHORIZATION.md.bak" "$D/CEO-AUTHORIZATION.md"
echo "VP-SECURITY-SIGN-OFF: GRANTED stages=B" > "$D/security-signoff.md"
OUT=$(bash "$C" "$D" vp-sec --token "VP-SECURITY-SIGN-OFF: GRANTED stages=B" 2>&1); [ $? -eq 0 ] && echo "$OUT" | grep -q "token line" && ok "the existing literal token still satisfies its gate" || fail "token path: $OUT"
echo ""; echo "ceo-authorization tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
