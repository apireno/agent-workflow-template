#!/usr/bin/env bash
# test-vp-review-guards.sh — regression guard for the /vp-review output contract.
#
# Covers the 2026-08-13 field failure: the skill shell hit its 2-minute budget, SIGTERMed the
# review children, and left ZERO-BYTE <vp>.md files on disk. A 0-byte verdict is worse than a
# missing one — it reads downstream as "the review ran and had nothing to say", and a VP
# review flagged exactly such an artifact as a completed review missing its content.
#
# THE INVARIANT: <vp>.md exists only if it has a body. Every abnormal exit — timeout, kill,
# empty engine response, rate limit — must leave no file at all.
#
# No network, no API spend: uses VP_REVIEW_DRY_RUN.
#
# Usage: bash scripts/agentic/test-vp-review-guards.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPSH="$HERE/vp-review.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
ART="$TMPD/artifact.md"; printf '# artifact\n\nsome content\n' > "$ART"
PASS=0; FAIL=0

check() { # <name> <expected: exists|absent> <file>
    local name="$1" want="$2" f="$3" got
    if [ -e "$f" ]; then got="exists ($(wc -c < "$f" | tr -d ' ') bytes)"; else got="absent"; fi
    case "$want:$(if [ -s "$f" ]; then echo exists; elif [ -e "$f" ]; then echo empty; else echo absent; fi)" in
        exists:exists|absent:absent) echo "  PASS  $name  ($got)"; PASS=$((PASS+1)) ;;
        *) echo "  FAIL  $name — wanted $want, got $got"; FAIL=$((FAIL+1)) ;;
    esac
}

echo "vp-review output-contract guards"

OUT="$TMPD/vp-eng.md"
VP_REVIEW_DRY_RUN=empty bash "$VPSH" vp-eng "$ART" "$OUT" >/dev/null 2>&1
check "empty engine response leaves no file" absent "$OUT"

OUT="$TMPD/vp-prod.md"
VP_REVIEW_DRY_RUN=429 bash "$VPSH" vp-prod "$ART" "$OUT" >/dev/null 2>&1
check "rate-limited response leaves no file" absent "$OUT"

OUT="$TMPD/vp-sec.md"
VP_REVIEW_DRY_RUN=ok bash "$VPSH" vp-security "$ART" "$OUT" >/dev/null 2>&1
check "good response is published" exists "$OUT"

# The one that actually regressed: killed mid-review.
OUT="$TMPD/vp-devops.md"
VP_REVIEW_DRY_RUN=hang bash "$VPSH" vp-devops "$ART" "$OUT" >/dev/null 2>&1 &
KILLPID=$!
sleep 2
kill -TERM "$KILLPID" 2>/dev/null
wait "$KILLPID" 2>/dev/null
sleep 1
check "SIGTERM mid-review leaves no 0-byte verdict" absent "$OUT"
check "…and no leftover .partial temp" absent "$(ls "$TMPD"/.vp-devops.md.partial.* 2>/dev/null | head -1)"

# SIGKILL cannot be trapped. The invariant has to hold WITHOUT a handler — it does, because
# the final path is only ever created by the rename, so there is nothing to leave behind.
OUT="$TMPD/vp-dba.md"
VP_REVIEW_DRY_RUN=hang bash "$VPSH" vp-dba "$ART" "$OUT" >/dev/null 2>&1 &
KILLPID=$!
sleep 2
kill -9 "$KILLPID" 2>/dev/null
wait "$KILLPID" 2>/dev/null
sleep 1
check "SIGKILL mid-review leaves no 0-byte verdict" absent "$OUT"

# Negative control: the pre-fix script (engine redirected straight at the final path, no
# cleanup trap) MUST fail the same assertion — otherwise the guard proves nothing.
NOFIX="$TMPD/vp-review-prefix.sh"
# Reproduce the pre-fix shape exactly: no cleanup trap, and the engine's stdout redirected
# straight at the final path — which CREATES it empty before the first byte of the body.
sed -e 's|^trap _vp_cleanup EXIT|: # trap removed (pre-fix)|' \
    -e "s|^trap '_vp_cleanup; exit 143' TERM|: # trap removed (pre-fix)|" \
    -e '/partial review, engine still writing/s|.*|: > "$OUTPUT_FILE"|' \
    "$VPSH" > "$NOFIX"
grep -q ': > "$OUTPUT_FILE"' "$NOFIX" || echo "  WARN  negative control did not patch — check the sed"
OUT="$TMPD/vp-legacy.md"
VP_REVIEW_DRY_RUN=hang bash "$NOFIX" vp-eng "$ART" "$OUT" >/dev/null 2>&1 &
KILLPID=$!
sleep 2
kill -TERM "$KILLPID" 2>/dev/null
wait "$KILLPID" 2>/dev/null
sleep 1
if [ -e "$OUT" ] && [ ! -s "$OUT" ]; then
    echo "  PASS  negative control: pre-fix code DOES leave a 0-byte verdict (guard is meaningful)"
    PASS=$((PASS+1))
else
    echo "  FAIL  negative control: pre-fix code left no empty file — the guard may be vacuous"
    FAIL=$((FAIL+1))
fi

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
