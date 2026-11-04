#!/usr/bin/env bash
# log-line.sh — append one line to a log, stamped from the CLOCK in UTC and the CEO's zone.
#
#   log-line.sh <log-file> <text…>          ->  - 2026-11-04T19:42Z (14:42 EST) <text>
#   log-line.sh --now                       ->  2026-11-04T19:42Z (14:42 EST)   (for CEO-facing times)
#
# WHY (fleet report 2026-11-04): overnight-log tick times were estimated and drifted up to 4 h, and
# CEO-facing times were quoted from memory. Times come from `date`, never from the model.
# Zone: $CEO_TZ, else the first line of <cto-home>/.cto/timezone (e.g. America/New_York), else the
# machine's zone.
set -uo pipefail
HOME_CTO="${CTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
Z="${CEO_TZ:-$(head -1 "$HOME_CTO/.cto/timezone" 2>/dev/null | tr -d '[:space:]')}"
stamp(){ printf '%s (%s)' "$(date -u +%Y-%m-%dT%H:%MZ)" "$( [ -n "$Z" ] && TZ="$Z" date '+%H:%M %Z' || date '+%H:%M %Z')"; }
if [ "${1:-}" = --now ]; then stamp; echo; exit 0; fi
F="${1:-}"; shift || true
[ -n "$F" ] && [ $# -gt 0 ] || { echo "usage: log-line.sh <log-file> <text…> | --now" >&2; exit 2; }
mkdir -p "$(dirname "$F")"
printf -- '- %s %s\n' "$(stamp)" "$*" >> "$F"
tail -1 "$F"
