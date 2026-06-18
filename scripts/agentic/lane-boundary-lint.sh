#!/usr/bin/env bash
# lane-boundary-lint.sh [--audit] [--rules <file>]
#
# The generic ENFORCEMENT consumer from ADR-001: reads a repo's declared forbidden
# cross-lane imports and FAILS CI on a violation, with an ACTIONABLE error (file:line,
# the forbidden import, this repo's lane, and the RACI rule it breaks). Engine-independent
# (pattern-based over the tracked source) — the RACI-validator (deriving rules from the
# RACI + diffing the NAVIGATION engine's import graph) is the Phase-2 keystone layered on top.
#
# Runs in PER-REPO CI as a BLOCKING step (vp-eng + vp-devops). Use --audit during the
# rollout (logs violations, exit 0) and flip to blocking once the rules are trusted.
#
# Rules file (default: docs/architecture/lane-rules.txt); one rule per non-# line:
#   <forbidden-import-regex>|||<this-repo's-lane>|||<RACI-rule-id>|||<message>

set -uo pipefail
AUDIT=0; RULES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --audit)  AUDIT=1; shift ;;
    --rules)  RULES="${2:-}"; shift 2 ;;
    --rules=*) RULES="${1#--rules=}"; shift ;;
    *) shift ;;
  esac
done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RULES="${RULES:-$ROOT/docs/architecture/lane-rules.txt}"

if [ ! -f "$RULES" ]; then
  echo "lane-lint: no rules file at $RULES — nothing to enforce."
  echo "  Declare this repo's forbidden cross-lane imports there (see docs/architecture/_templates/raci-component-map.md)."
  exit 0
fi

violations=0
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  rx="${line%%|||*}";  rest="${line#*|||}"
  lane="${rest%%|||*}"; rest="${rest#*|||}"
  rule="${rest%%|||*}"; msg="${rest#*|||}"
  [ -n "$rx" ] || continue
  # git grep uses POSIX ERE (no \s/\d/\w). Translate the common Perl shorthands so rules
  # can still be written with them.
  rxp="$(printf '%s' "$rx" | sed -e 's/\\s/[[:space:]]/g' -e 's/\\S/[^[:space:]]/g' -e 's/\\d/[[:digit:]]/g' -e 's/\\w/[[:alnum:]_]/g')"
  # Scan tracked source (git grep respects .gitignore; skip tests).
  hits="$(git -C "$ROOT" grep -nE "$rxp" -- '*.py' '*.js' '*.ts' '*.tsx' '*.jsx' '*.go' '*.rs' '*.java' '*.rb' '*.php' 2>/dev/null | grep -vE '(^|/)(tests?|spec|__tests__)/' || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | while IFS= read -r h; do
      file="${h%%:*}"; rest2="${h#*:}"; ln="${rest2%%:*}"
      echo "LANE VIOLATION — forbidden import /$rx/"
      echo "  at:   $file:$ln"
      echo "  lane: this repo is in lane '$lane' — $msg"
      echo "  rule: RACI $rule"
      echo ""
    done
    violations=$((violations + 1))
  fi
done < "$RULES"

if [ "$violations" -gt 0 ]; then
  echo "lane-lint: $violations forbidden-import rule(s) violated."
  if [ "$AUDIT" -eq 1 ]; then echo "(--audit: not failing CI — flip to blocking once rules are trusted)"; exit 0; fi
  exit 1
fi
echo "lane-lint: clean — no lane violations."
exit 0
