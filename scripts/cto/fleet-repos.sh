#!/usr/bin/env bash
# fleet-repos.sh — the absolute paths of the ACTIVE repos in <cto-home>/.cto/projects.yaml, one per
# line (CTO homes excluded). Shared by ci-watch.sh, lane-watch.sh and cto-heartbeat.sh.
#   fleet-repos.sh [<cto-home>]
set -uo pipefail
HOME_CTO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
python3 - "$HOME_CTO/.cto/projects.yaml" <<'PY'
import os, re, sys
try: text = open(sys.argv[1]).read()
except OSError: sys.exit(0)
rows, cur = [], None
for line in text.splitlines():
    m = re.match(r"\s*-\s*name:\s*(\S+)", line)
    if m: cur = {"name": m.group(1)}; rows.append(cur); continue
    m = re.match(r"\s+(path|active):\s*([^#]+)", line)
    if m and cur is not None: cur[m.group(1)] = m.group(2).strip().strip("'\"")
for r in rows:
    p = r.get("path")
    if not p or str(r.get("active", "true")).lower() == "false": continue
    if os.path.basename(p.rstrip("/")).endswith("-cto"): continue
    print(os.path.expanduser(p))
PY
