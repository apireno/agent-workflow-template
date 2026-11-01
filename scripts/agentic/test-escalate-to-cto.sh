#!/usr/bin/env bash
# test-escalate-to-cto.sh — escalate-to-cto.sh, offline fixture (scratch repo + scratch inbox).
# Never calls a model: the default path is the inbox memo; --sync is exercised only with a
# stub CLAUDE_BIN to prove it is opt-in.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; X="$T/scripts/agentic/escalate-to-cto.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/escalate.XXXXXX")"; trap 'rm -rf "$W"' EXIT
R="$W/my-repo"; mkdir -p "$R/docs/sprints/sprint-feature-x-s1-20260101" "$R/docs/sprints/sprint-08" "$W/bin"
echo "plan body" > "$R/docs/sprints/sprint-feature-x-s1-20260101/sprint-plan.md"
# A claude stub that records it was called. The default path must never reach it.
printf '#!/bin/sh\ntouch "%s/claude-called"\necho stub-response\n' "$W" > "$W/bin/claude"; chmod +x "$W/bin/claude"
export REPO_ROOT="$R" CTO_INBOX="$W/inbox" CLAUDE_BIN="$W/bin/claude" HOME="$W/home"
unset CTO_REPO
memos(){ find "$W/inbox" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort; }
memo_of(){ sed -n "s#^   Memo: *##p" <<<"$1" | head -1; }

out="$(bash "$X" --issue "slug sprint" --sprint feature-x-s1-20260101 2>&1)"; rc=$?
[ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q 'invalid number' && ok "a slug --sprint is accepted (no printf number error)" || fail "slug sprint: rc=$rc $out"
grep -q "Response:.*docs/sprints/sprint-feature-x-s1-20260101/cto-escalation-" <<<"$out" && ok "slug resolves to the existing sprint-<slug> dir" || fail "slug dir: $out"
[ ! -e "$W/claude-called" ] && ok "default path never invokes claude" || fail "claude was called on the default path"
m="$(memo_of "$out")"; [ -f "$m" ] && case "$(basename "$m")" in my-repo-*.md) true;; *) false;; esac && ok "memo lands in the inbox as <project>-<ts>.md" || fail "memo name: $m"
grep -q '^\*\*Sprint:\*\* feature-x-s1-20260101' "$m" && grep -q '^\*\*CTO response should land at:\*\*' "$m" && grep -q 'slug sprint' "$m" && ok "memo carries sprint, response path and issue" || fail "memo body"

out="$(bash "$X" --issue "full name" --sprint sprint-feature-x-s1-20260101 2>&1)"
grep -q "Response:.*/docs/sprints/sprint-feature-x-s1-20260101/cto-escalation-" <<<"$out" && ok "a full sprint-<slug> dir name resolves as-is" || fail "full name: $out"

out="$(bash "$X" --issue "octal" --sprint 08 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q "Response:.*/docs/sprints/sprint-08/cto-escalation-" <<<"$out" && ok "numeric 08 -> sprint-08 (no octal error)" || fail "numeric 08: rc=$rc $out"

out="$(bash "$X" --issue "pad" --sprint 5 2>&1)"
grep -q "Response:.*/docs/sprints/sprint-05/cto-escalation-" <<<"$out" && ok "numeric 5 -> sprint-05" || fail "numeric 5: $out"
[ ! -d "$R/docs/sprints/sprint-05" ] && ok "default path creates no sprint dir" || fail "sprint dir created"

out="$(bash "$X" --issue "auto" --context "$R/docs/sprints/sprint-feature-x-s1-20260101/sprint-plan.md" 2>&1)"
grep -q "Sprint:   sprint-feature-x-s1-20260101" <<<"$out" && grep -q 'plan body' "$(memo_of "$out")" && ok "sprint auto-detected from a slug context path; context inlined" || fail "auto-detect: $out"

out="$(bash "$X" --issue "no sprint" 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q "Response:.*cto-escalation-my-repo-" <<<"$out" && ok "no --sprint, no CTO repo configured -> memo still dropped (exit 0)" || fail "no sprint: rc=$rc $out"

bash "$X" --issue "bad" --sprint ../etc >/dev/null 2>&1; [ $? -eq 2 ] && ok "a path-like --sprint is refused (exit 2)" || fail "path sprint accepted"
bash "$X" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --issue -> exit 2" || fail "missing issue"

n_before="$(memos | wc -l | tr -d ' ')"
for i in 1 2 3; do bash "$X" --issue "burst $i" >/dev/null 2>&1 & done; wait
[ "$(memos | wc -l | tr -d ' ')" -eq $((n_before + 3)) ] && ok "same-second escalations never overwrite each other" || fail "burst collision"

( cd "$W" && bash "$X" --issue "sync" --sync --non-interactive >/dev/null 2>&1 ); [ $? -eq 2 ] && [ ! -e "$W/claude-called" ] && ok "--sync without REVIEW_ALLOW_METERED=1 -> usage error (exit 2), claude not called" || fail "--sync unmetered"
( cd "$W" && REVIEW_ALLOW_METERED=1 bash "$X" --issue "sync" --sync --non-interactive >/dev/null 2>&1 ); [ $? -eq 1 ] && [ ! -e "$W/claude-called" ] && ok "--sync without a CTO repo -> exit 1, claude not called" || fail "--sync unconfigured"
mkdir -p "$W/cto"; out="$(CTO_REPO="$W/cto" REVIEW_ALLOW_METERED=1 bash "$X" --issue "sync" --sprint 08 --sync 2>&1)"
[ -e "$W/claude-called" ] && grep -q stub-response <<<"$out" && ok "--sync is the only path that reaches claude (opt-in)" || fail "--sync: $out"

echo ""; echo "escalate-to-cto tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
