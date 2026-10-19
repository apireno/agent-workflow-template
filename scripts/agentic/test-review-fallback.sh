#!/usr/bin/env bash
# test-review-fallback.sh — vp-review.sh's configured engine fallback (CEO 2026-10-19: "agy, but
# fall back to kimi with warnings"). Stub agy + stub openrouter-chat.sh in a scratch repo. Offline.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -5 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/rfb.XXXXXX")"; trap 'rm -rf "$W"' EXIT
R="$W/repo"; mkdir -p "$R/scripts" "$R/docs" "$W/bin"; git -C "$R" init -q
cp -R "$T/scripts/agentic" "$R/scripts/agentic"; cp -R "$T/docs/personas" "$R/docs/personas"
printf '# Plan\nDo a thing.\n' > "$R/plan.md"
cat > "$W/bin/agy" <<STUB
#!/usr/bin/env bash
[ "\$1" = models ] && { printf 'gemini-4-argon-high\tx\n'; exit 0; }
case "\${STUB_AGY:-deny}" in
  deny) echo 'jetski: no output produced — a tool required the "read_file" permission that headless mode cannot prompt for, so it was auto-denied.' >&2 ;;
  ok)   echo "# VP of Engineering review"; echo "MAJOR: from agy"; echo "— Eng" ;;
esac; exit 0
STUB
cat > "$R/scripts/agentic/openrouter-chat.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null; echo "# VP of Engineering review"; echo "MAJOR: from kimi"; echo "— Eng"
echo "openrouter-chat: model=stub prompt_tokens=1 completion_tokens=1" >&2
STUB
chmod +x "$W/bin/agy" "$R/scripts/agentic/openrouter-chat.sh"
export PATH="$W/bin:$PATH" AGY_BIN="$W/bin/agy" OPENROUTER_API_KEY=stub VP_REVIEW_MAX_ATTEMPTS=1 VP_REVIEW_BACKOFF_INITIAL_SEC=0 TMPDIR="$W" AGY_MODELS_NOCACHE=1
run(){ ( cd "$R" && REPO_ROOT="$R" REVIEW_ENGINE=agy bash scripts/agentic/vp-review.sh vp-eng plan.md "$R/out-$1.md" 2>&1 ); }
echo "agy" > "$R/.review-engine"

echo "== 1. agy fails, kimi fallback configured =="
echo kimi > "$R/.review-engine-fallback"
OUT=$(STUB_AGY=deny run 1); RC=$?
[ $RC -eq 0 ] && ok "exit 0: a review was published" || fail "exit $RC" "$OUT"
head -1 "$R/out-1.md" 2>/dev/null | grep -q 'Engine fallback:.*ran on \*\*kimi\*\* because \*\*agy\*\*.*TOOL-DENIED' && ok "verdict's first line names kimi, agy and the reason" || fail "stamp: $(head -1 "$R/out-1.md" 2>/dev/null)"
grep -q 'MAJOR: from kimi' "$R/out-1.md" && ok "the body is kimi's" || fail "body"
echo "$OUT" | grep -q "WARNING: FALLING BACK to 'kimi'" && ok "warning on stderr" || fail "no warning" "$OUT"
echo "$OUT" | grep -q "engine: kimi — FALLBACK from agy" && ok "the publish line names the engine that ran" || fail "publish line" "$OUT"
[ "$(wc -l < "$R/.claude/engine-fallbacks.log" 2>/dev/null | tr -d ' ')" = "1" ] && grep -q $'\tagy\tkimi\tvp-eng\t' "$R/.claude/engine-fallbacks.log" && ok "one row in .claude/engine-fallbacks.log" || fail "fallback log"

echo "== 2. agy fails, no fallback configured =="
rm -f "$R/.review-engine-fallback"
OUT=$(STUB_AGY=deny run 2); RC=$?
[ $RC -ne 0 ] && [ ! -e "$R/out-2.md" ] && ok "nothing published, non-zero exit (fail-loud unchanged)" || fail "exit $RC" "$OUT"
echo "$OUT" | grep -q "echo kimi > .review-engine-fallback" && ok "failure message names the fallback setting" || fail "hint" "$OUT"

echo "== 3. agy works =="
echo kimi > "$R/.review-engine-fallback"
OUT=$(STUB_AGY=ok run 3)
grep -q 'MAJOR: from agy' "$R/out-3.md" && ! grep -q 'Engine fallback' "$R/out-3.md" && ok "agy verdict, no stamp" || fail "agy path" "$OUT"
[ "$(wc -l < "$R/.claude/engine-fallbacks.log" | tr -d ' ')" = "1" ] && ok "no new log row" || fail "log grew"

echo "== 4. agy not installed =="
OUT=$( cd "$R" && AGY_BIN=/nonexistent REPO_ROOT="$R" REVIEW_ENGINE=agy bash scripts/agentic/vp-review.sh vp-eng plan.md "$R/out-4.md" 2>&1 ); RC=$?
[ $RC -eq 0 ] && grep -q 'ran on \*\*kimi\*\*' "$R/out-4.md" && ok "a missing CLI also falls back (stamped)" || fail "missing CLI: exit $RC" "$OUT"

echo "== 5. invalid fallback =="
echo subagent > "$R/.review-engine-fallback"
OUT=$(STUB_AGY=deny run 5); RC=$?
[ $RC -ne 0 ] && [ ! -e "$R/out-5.md" ] && ok "a non-CLI fallback (subagent) is ignored; fails loud" || fail "exit $RC" "$OUT"
echo ""; echo "review-fallback tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
