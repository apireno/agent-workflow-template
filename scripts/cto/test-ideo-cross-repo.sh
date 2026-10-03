#!/usr/bin/env bash
# test-ideo-cross-repo.sh — Phase 5 of ideo-cross-repo.sh must never reach the metered
# `claude -p` path except behind REVIEW_ALLOW_METERED=1, and must route through the shared
# review-engine resolver like every other fleet script.
#
# Builds a scratch CTO home (a copy of scripts/) with: a stub ideo-sprint.sh that writes a
# phase3 result instantly (so phases 1-4 cost nothing), a stub openrouter-chat.sh that
# records its stdin, and a stub `claude` on PATH that records any call and exits 99.
# Nothing here touches a real engine, an API, or a real repo.
#
# Cases (each one FAILED against the pre-fix script, which piped Phase 5 into `claude -p`):
#   1 default engine (no REVIEW_ENGINE, no .review-engine) -> claude never invoked
#   2 REVIEW_ENGINE=kimi  -> openrouter-chat.sh gets the aggregate prompt; synthesis written
#   3 REVIEW_ENGINE=claude-p without REVIEW_ALLOW_METERED=1 -> standard quarantine refusal
#   4 subagent -> exit 0, SYNTHESIS=deferred-to-orchestrator, prompt kept, no synthesis file,
#                 no routing plan
#   5 --engine kimi overrides a subagent .review-engine
#   6 claude-p WITH REVIEW_ALLOW_METERED=1 reaches the (stub) claude exactly once; its failure
#     exits 3 and writes neither a synthesis nor a routing plan
# Exit: 0 all pass · 1 a guard regressed
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -6 | sed 's/^/       | /'; return 0; }
has(){ printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || fail "$1 (missing /$2/)" "$3"; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ideo-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
H="$W/acme-cto"; mkdir -p "$H/.cto" "$W/bin" "$W/acme-a" "$W/acme-b"
cp -R "$T/scripts" "$H/scripts"
git -C "$H" init -q; git -C "$W/acme-a" init -q; git -C "$W/acme-b" init -q
printf 'projects:\n  - name: acme-a\n    path: %s/acme-a\n    active: true\n  - name: acme-b\n    path: %s/acme-b\n    active: true\n' "$W" "$W" > "$H/.cto/projects.yaml"
printf '# Goal\nMake onboarding faster.\n' > "$W/goal.md"
cat > "$H/scripts/agentic/ideo-sprint.sh" <<'STUB'
#!/usr/bin/env bash
# stub: phases 1-4 instantly
mkdir -p "$2"; printf '## Phase 3 merged\n| idea | votes |\n|---|---|\n| faster setup (%s) | 3 |\n' "$(basename "$REPO_ROOT")" > "$2/phase3-merged-results.md"
STUB
cat > "$H/scripts/agentic/openrouter-chat.sh" <<STUB
#!/usr/bin/env bash
cat > "$W/kimi-stdin.txt"; echo "| 1 | faster setup | acme-a, acme-b | 6 | yes | merged |"; echo SYNTHESIS_COMPLETE
STUB
cat > "$W/bin/claude" <<STUB
#!/usr/bin/env bash
echo "claude \$*" >> "$W/claude-calls.txt"; exit 99
STUB
chmod +x "$H/scripts/agentic/ideo-sprint.sh" "$H/scripts/agentic/openrouter-chat.sh" "$W/bin/claude"
run(){ # run <outdir> [extra args...]; env passed by caller
  local out="$1"; shift
  rm -f "$W/claude-calls.txt" "$W/kimi-stdin.txt"
  PATH="$W/bin:$PATH" bash "$H/scripts/cto/ideo-cross-repo.sh" --goal "$W/goal.md" --output-dir "$W/$out" --timeout 30 "$@" 2>&1
}
called_claude(){ [ -s "$W/claude-calls.txt" ]; }

echo "== 1. default engine never invokes claude =="
rm -f "$H/.review-engine"
OUT=$(env -u REVIEW_ENGINE -u REVIEW_ALLOW_METERED bash -c "$(declare -f run); W='$W' H='$H'; run o1")
called_claude && fail "claude was invoked under the default engine: $(cat "$W/claude-calls.txt")" "$OUT" || ok "claude never invoked (default engine = subagent)"

echo "== 2. kimi routes Phase 5 through openrouter-chat.sh =="
OUT=$(REVIEW_ENGINE=kimi run o2); RC=$?
called_claude && fail "claude invoked under kimi" "$OUT" || ok "claude not invoked under kimi"
[ -s "$W/kimi-stdin.txt" ] && grep -q "PER-REPO PHASE 3 RESULTS" "$W/kimi-stdin.txt" && grep -q "faster setup (acme-b)" "$W/kimi-stdin.txt" && ok "openrouter-chat.sh received the aggregate prompt" || fail "openrouter-chat.sh did not receive the aggregate prompt" "$OUT"
grep -q "SYNTHESIS_COMPLETE" "$W/o2/phase5-cross-repo-synthesis.md" 2>/dev/null && ok "synthesis file written from the engine's output" || fail "synthesis file missing or empty" "$OUT"
[ -f "$W/o2/phase5-routing.md" ] && ok "routing plan written after a real synthesis" || fail "routing plan missing" "$OUT"
[ $RC -eq 0 ] && ok "exit 0" || fail "kimi run exit $RC" "$OUT"

echo "== 3. claude-p without REVIEW_ALLOW_METERED is refused =="
OUT=$(env -u REVIEW_ALLOW_METERED REVIEW_ENGINE=claude-p bash -c "$(declare -f run); W='$W' H='$H'; run o3"); RC=$?
called_claude && fail "claude invoked despite the quarantine" "$OUT" || ok "claude not invoked"
has "standard quarantine message" "engine 'claude-p' is the METERED Anthropic API path" "$OUT"
[ $RC -ne 0 ] && ok "non-zero exit on refusal ($RC)" || fail "refusal exited 0" "$OUT"
[ ! -s "$W/o3/phase5-cross-repo-synthesis.md" ] && ok "no synthesis file on refusal" || fail "synthesis file written on refusal" "$OUT"

echo "== 4. subagent defers to the orchestrator =="
OUT=$(REVIEW_ENGINE=subagent run o4); RC=$?
[ $RC -eq 0 ] && ok "exit 0" || fail "subagent run exit $RC" "$OUT"
has "prints SYNTHESIS=deferred-to-orchestrator with the prompt path" "SYNTHESIS=deferred-to-orchestrator prompt=.*/o4/phase5-synthesis-prompt.md" "$OUT"
[ -s "$W/o4/phase5-synthesis-prompt.md" ] && ok "prompt file kept" || fail "prompt file missing"
[ ! -e "$W/o4/phase5-cross-repo-synthesis.md" ] && ok "no (empty) synthesis file" || fail "a synthesis file was written"
[ ! -e "$W/o4/phase5-routing.md" ] && ok "no routing plan" || fail "routing plan written from nothing"
has "routing skip is announced" "Phase 6: skipped" "$OUT"
called_claude && fail "claude invoked under subagent" || ok "claude not invoked"

echo "== 5. --engine overrides .review-engine =="
printf 'subagent\n' > "$H/.review-engine"
OUT=$(env -u REVIEW_ENGINE bash -c "$(declare -f run); W='$W' H='$H'; run o5 --engine kimi")
[ -s "$W/kimi-stdin.txt" ] && ok "--engine kimi used openrouter-chat.sh over a subagent .review-engine" || fail "--engine override ignored" "$OUT"
rm -f "$H/.review-engine"

echo "== 6. claude-p WITH the opt-in reaches claude once; a failing engine leaves no synthesis =="
OUT=$(REVIEW_ENGINE=claude-p REVIEW_ALLOW_METERED=1 run o6); RC=$?
[ "$(grep -c -- '-p' "$W/claude-calls.txt" 2>/dev/null)" = "1" ] && ok "stub claude called exactly once with -p (opt-in honoured)" || fail "claude call count wrong: $(cat "$W/claude-calls.txt" 2>/dev/null)" "$OUT"
[ $RC -eq 3 ] && ok "failed synthesis exits 3" || fail "failed synthesis exit $RC" "$OUT"
[ ! -e "$W/o6/phase5-cross-repo-synthesis.md" ] && ok "no synthesis file from a failed engine" || fail "synthesis file written from a failed engine"
[ ! -e "$W/o6/phase5-routing.md" ] && ok "no routing plan after a failed synthesis" || fail "routing plan written after failure"

echo ""; echo "ideo-cross-repo tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
