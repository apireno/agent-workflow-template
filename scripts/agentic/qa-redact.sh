#!/usr/bin/env bash
# qa-redact.sh — secret/PII scrubber for QA-UX artifacts (VP-Security CRITICAL).
#
# Redaction is a HARNESS control, not an agent courtesy: every transcript, log, and
# qa-report.md passes through this BEFORE it is written into a sprint's assets/ dir.
# Screenshots rely on UI-level masking at capture; this covers the text/markdown side.
#
# Usage:
#   qa-redact.sh <file> [file2 ...]          # scrub to stdout (concatenated)
#   qa-redact.sh --in-place <file> [file2]   # scrub each file in place
#   cat foo | qa-redact.sh                    # scrub stdin -> stdout
#
# Exit non-zero if, after scrubbing, a high-confidence secret pattern still remains
# (defense against a regex miss) so a leak fails loudly instead of silently shipping.

set -uo pipefail

IN_PLACE=0
FILES=()
for a in "$@"; do
  case "$a" in
    --in-place) IN_PLACE=1 ;;
    *)          FILES+=("$a") ;;
  esac
done

# Perl scrubber: each pattern -> a typed [REDACTED:*] token. Order matters
# (structured tokens before the generic key=value catch-all).
scrub() {
  perl -pe '
    s/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED:JWT]/g;
    s/\bAKIA[0-9A-Z]{16}\b/[REDACTED:AWS_KEY]/g;
    s/\bgh[pousr]_[A-Za-z0-9]{30,}\b/[REDACTED:GH_TOKEN]/g;
    s/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/[REDACTED:SLACK_TOKEN]/g;
    s/\bsk-[A-Za-z0-9]{20,}\b/[REDACTED:API_KEY]/g;
    s/(?i)\b(bearer)\s+[A-Za-z0-9._\-]{12,}/$1 [REDACTED:TOKEN]/g;
    s/(?i)(authorization|cookie|set-cookie)(\s*[:=]\s*).*/$1$2\x5bREDACTED:HEADER\x5d/g;
    s/(?i)\b(api[_-]?key|secret|token|password|passwd|pwd|client[_-]?secret)\b([\x22\x27]?\s*[:=]\s*[\x22\x27]?)[A-Za-z0-9._\-\/+]{8,}/$1$2\x5bREDACTED:SECRET\x5d/g;
    s/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/[REDACTED:EMAIL]/g;
    s/\b[0-9a-fA-F]{40,}\b/[REDACTED:HEX]/g;
  '
}

# After-scrub guard: structured secrets that should NEVER survive.
LEAK_RE='eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}'

rc=0
check_leak() { grep -Eq "$LEAK_RE" && { echo "qa-redact: LEAK STILL PRESENT after scrub" >&2; rc=2; } || true; }

if [ "${#FILES[@]}" -eq 0 ]; then
  scrub | tee >(check_leak)
  exit $rc
fi

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "qa-redact: no such file: $f" >&2; rc=1; continue; }
  if [ "$IN_PLACE" -eq 1 ]; then
    tmp="$(mktemp)"; scrub < "$f" > "$tmp" && mv "$tmp" "$f"
    grep -Eq "$LEAK_RE" "$f" && { echo "qa-redact: LEAK STILL PRESENT in $f" >&2; rc=2; }
    echo "scrubbed (in place): $f"
  else
    scrub < "$f"
    grep -Eq "$LEAK_RE" "$f" && rc=2
  fi
done
exit $rc
