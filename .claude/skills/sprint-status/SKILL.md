---
name: sprint-status
description: Show at-a-glance status of all per-repo Phase 2 dev-team sessions across the active acme-* fleet. Reports which repos are running, idle, crashed, or completed. Use when CEO asks "how are the dev teams doing", "what's the sprint status", "any crashes?", or wants a fleet snapshot.
allowed-tools: Bash(cat *) Bash(ls *) Bash(stat *) Bash(date *) Bash(test *) Bash(find *) Read
---

# Sprint Status Across Active Fleet

## Read the active repo registry

```!
CTO_HOME_REQUIRED=1
# >>> CTO-HOME ANCHOR (canonical — sync with: bash scripts/cto/lint-skills.sh --apply) >>>
# Fleet state lives in the CTO home, and neither obvious anchor is reliable alone:
# `git rev-parse` returns whatever repo the SHELL sits in, so one lingering cd into a dev
# repo silently retargets the skill; and $CLAUDE_PROJECT_DIR was observed EMPTY in skill
# shells (2026-08-13) — /handoff then resolved the registry against kgspin-tuner and refused
# with an error that blamed the registry rather than the anchoring. So: try every anchor,
# VALIDATE each candidate before accepting it, and when none holds either fail naming the
# real cause or fall back explicitly and say so.
# Skills that read the fleet registry set CTO_HOME_REQUIRED=1 before this block.
_CTO_REJECTED=""
_cto_is_home() {
  [ -n "$1" ] && [ -f "$1/.cto/projects.yaml" ] || return 1
  # The PUBLIC template ships a placeholder registry (/Users/yourname/repos/my-project).
  # Accepting it resolves cleanly and then reports a fleet of repos that do not exist —
  # a confident wrong answer, which is worse than the error it replaced. Observed live:
  # four dev repos still point .cto-path at the template, so this is the real path.
  if grep -q '/Users/yourname/' "$1/.cto/projects.yaml" 2>/dev/null; then
    _CTO_REJECTED="$_CTO_REJECTED  $1 (placeholder registry — the unconfigured template)"
    return 1
  fi
  return 0
}
# Sets _CTO_FOUND rather than printing: a $(…) capture runs in a SUBSHELL, so the rejected-
# candidate diagnostics collected by _cto_is_home would be discarded exactly when they are
# needed — on the failure path.
_CTO_FOUND=""
_cto_walk() {
  _d="$1"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    _cto_is_home "$_d" && { _CTO_FOUND="$_d"; return 0; }
    if [ -f "$_d/.cto-path" ]; then
      _p="$(tr -d '[:space:]' < "$_d/.cto-path")"
      _cto_is_home "$_p" && { _CTO_FOUND="$_p"; return 0; }
    fi
    _d="$(dirname "$_d")"
  done
  return 1
}
ROOT=""
for _c in "${CTO_HOME:-}" "${CTO_REPO:-}" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$_c" ] && _cto_is_home "$_c" && { ROOT="$_c"; break; }
done
if [ -z "$ROOT" ]; then if _cto_walk "$PWD"; then ROOT="$_CTO_FOUND"; fi; fi
if [ -z "$ROOT" ] && [ -f "$HOME/.cto/home" ]; then
  _p="$(tr -d '[:space:]' < "$HOME/.cto/home")"; _cto_is_home "$_p" && ROOT="$_p"
fi
if [ -z "$ROOT" ]; then
  if [ "${CTO_HOME_REQUIRED:-0}" = "1" ]; then
    echo "ERROR: no CTO home found — no directory containing .cto/projects.yaml." >&2
    echo "  \$CTO_HOME='${CTO_HOME:-}'  \$CTO_REPO='${CTO_REPO:-}'  \$CLAUDE_PROJECT_DIR='${CLAUDE_PROJECT_DIR:-}'" >&2
    echo "  walked up from: $PWD" >&2
    [ -n "$_CTO_REJECTED" ] && { echo "  rejected candidates:" >&2; printf '%s\n' "$_CTO_REJECTED" >&2; }
    echo "  This is an ANCHORING failure, not a missing registry. Run the skill from the CTO" >&2
    echo "  home, or fix it permanently:  echo /path/to/<project>-cto > ~/.cto/home" >&2
    exit 1
  fi
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "NOTE: no CTO home found; using the current repo ($ROOT)." >&2
fi
CTO_REGISTRY="$ROOT/.cto/projects.yaml"
cd "$ROOT" || { echo "ERROR: cannot enter $ROOT" >&2; exit 1; }
# <<< CTO-HOME ANCHOR <<<
if [ ! -f "$CTO_REGISTRY" ]; then
  echo "ERROR: fleet registry not found at $CTO_REGISTRY — run this from the CTO home."
  exit 1
fi
ART=.cto/projects.yaml
if [ ! -f "$ART" ]; then
  echo "ERROR: .cto/projects.yaml not found at $ART"
  exit 1
fi

python3 - "$CTO_REGISTRY" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    text = f.read()
blocks = re.split(r'(?=- name:)', text)
active = []
for b in blocks:
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    a = re.search(r'active:\s*(\S+)', b)
    if not m or not p:
        continue
    is_active = (a is None) or a.group(1).lower() not in ('false','no','0')
    if is_active:
        active.append((m.group(1), p.group(1)))

print(f"Active repos: {len(active)}")
for name, path in active:
    print(f"  {name}  →  {path}")
PYEOF
```

## Per-repo Phase 2 session state

```!
CTO_HOME_REQUIRED=1
# >>> CTO-HOME ANCHOR (canonical — sync with: bash scripts/cto/lint-skills.sh --apply) >>>
# Fleet state lives in the CTO home, and neither obvious anchor is reliable alone:
# `git rev-parse` returns whatever repo the SHELL sits in, so one lingering cd into a dev
# repo silently retargets the skill; and $CLAUDE_PROJECT_DIR was observed EMPTY in skill
# shells (2026-08-13) — /handoff then resolved the registry against kgspin-tuner and refused
# with an error that blamed the registry rather than the anchoring. So: try every anchor,
# VALIDATE each candidate before accepting it, and when none holds either fail naming the
# real cause or fall back explicitly and say so.
# Skills that read the fleet registry set CTO_HOME_REQUIRED=1 before this block.
_CTO_REJECTED=""
_cto_is_home() {
  [ -n "$1" ] && [ -f "$1/.cto/projects.yaml" ] || return 1
  # The PUBLIC template ships a placeholder registry (/Users/yourname/repos/my-project).
  # Accepting it resolves cleanly and then reports a fleet of repos that do not exist —
  # a confident wrong answer, which is worse than the error it replaced. Observed live:
  # four dev repos still point .cto-path at the template, so this is the real path.
  if grep -q '/Users/yourname/' "$1/.cto/projects.yaml" 2>/dev/null; then
    _CTO_REJECTED="$_CTO_REJECTED  $1 (placeholder registry — the unconfigured template)"
    return 1
  fi
  return 0
}
# Sets _CTO_FOUND rather than printing: a $(…) capture runs in a SUBSHELL, so the rejected-
# candidate diagnostics collected by _cto_is_home would be discarded exactly when they are
# needed — on the failure path.
_CTO_FOUND=""
_cto_walk() {
  _d="$1"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    _cto_is_home "$_d" && { _CTO_FOUND="$_d"; return 0; }
    if [ -f "$_d/.cto-path" ]; then
      _p="$(tr -d '[:space:]' < "$_d/.cto-path")"
      _cto_is_home "$_p" && { _CTO_FOUND="$_p"; return 0; }
    fi
    _d="$(dirname "$_d")"
  done
  return 1
}
ROOT=""
for _c in "${CTO_HOME:-}" "${CTO_REPO:-}" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$_c" ] && _cto_is_home "$_c" && { ROOT="$_c"; break; }
done
if [ -z "$ROOT" ]; then if _cto_walk "$PWD"; then ROOT="$_CTO_FOUND"; fi; fi
if [ -z "$ROOT" ] && [ -f "$HOME/.cto/home" ]; then
  _p="$(tr -d '[:space:]' < "$HOME/.cto/home")"; _cto_is_home "$_p" && ROOT="$_p"
fi
if [ -z "$ROOT" ]; then
  if [ "${CTO_HOME_REQUIRED:-0}" = "1" ]; then
    echo "ERROR: no CTO home found — no directory containing .cto/projects.yaml." >&2
    echo "  \$CTO_HOME='${CTO_HOME:-}'  \$CTO_REPO='${CTO_REPO:-}'  \$CLAUDE_PROJECT_DIR='${CLAUDE_PROJECT_DIR:-}'" >&2
    echo "  walked up from: $PWD" >&2
    [ -n "$_CTO_REJECTED" ] && { echo "  rejected candidates:" >&2; printf '%s\n' "$_CTO_REJECTED" >&2; }
    echo "  This is an ANCHORING failure, not a missing registry. Run the skill from the CTO" >&2
    echo "  home, or fix it permanently:  echo /path/to/<project>-cto > ~/.cto/home" >&2
    exit 1
  fi
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "NOTE: no CTO home found; using the current repo ($ROOT)." >&2
fi
CTO_REGISTRY="$ROOT/.cto/projects.yaml"
cd "$ROOT" || { echo "ERROR: cannot enter $ROOT" >&2; exit 1; }
# <<< CTO-HOME ANCHOR <<<
python3 - "$CTO_REGISTRY" <<'PYEOF'
import os, re, json, time, sys
from pathlib import Path

with open(sys.argv[1]) as f:
    text = f.read()
blocks = re.split(r'(?=- name:)', text)
repos = []
for b in blocks:
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    a = re.search(r'active:\s*(\S+)', b)
    if not m or not p:
        continue
    is_active = (a is None) or a.group(1).lower() not in ('false','no','0')
    if is_active:
        repos.append((m.group(1), p.group(1)))

# Header
print(f"{'REPO':<32} {'STATE':<14} {'SESSION_ID':<14} {'LAST_ACTIVITY':<22} {'NOTES'}")
print('-' * 110)

now = time.time()
for name, path in repos:
    cdir = Path(path) / '.claude'
    sess_id_file = cdir / 'current-session.id'
    crashed = cdir / 'CRASHED'
    complete = cdir / 'COMPLETE'
    session_log = cdir / 'session.log'

    if not sess_id_file.exists():
        print(f"{name:<32} {'no-session':<14} {'-':<14} {'-':<22} no Phase 2 session tracked")
        continue

    session_id = sess_id_file.read_text().strip()[:13]

    # Find JSONL by session_id to get last activity time
    jsonl_pattern = Path(os.path.expanduser('~/.claude/projects')) / f"*{path.replace('/', '-').strip('-')}*" / f"{sess_id_file.read_text().strip()}.jsonl"
    jsonls = list(Path(os.path.expanduser('~/.claude/projects')).glob(f"*/{sess_id_file.read_text().strip()}.jsonl"))
    last_act = '-'
    if jsonls:
        mtime = jsonls[0].stat().st_mtime
        age_sec = int(now - mtime)
        if age_sec < 60:
            last_act = f"{age_sec}s ago"
        elif age_sec < 3600:
            last_act = f"{age_sec // 60}m ago"
        else:
            last_act = f"{age_sec // 3600}h ago"

    if complete.exists():
        state, notes = 'COMPLETE', 'dev-report.md present'
    elif crashed.exists():
        state, notes = 'CRASHED', '/resume-dev-team to recover'
    else:
        # Check if recent activity
        if last_act != '-' and ('s ago' in last_act or 'm ago' in last_act):
            state, notes = 'RUNNING', 'active session'
        else:
            state, notes = 'IDLE', 'session exists but no recent activity'

    print(f"{name:<32} {state:<14} {session_id:<14} {last_act:<22} {notes}")
PYEOF
```

## Your task as CTO

Read the table above. Present to the CEO in tight form:
1. **Headline:** "N of M repos are RUNNING / IDLE / CRASHED / COMPLETE / no-session"
2. **Crashed repos (if any):** name them and suggest `/resume-dev-team <repo>`
3. **Stalled IDLE sessions (no activity >30min):** flag them — may need attention or `/peek` to investigate
4. **Completed repos:** suggest `/sprint-accept <sprint-dir>` if not already done

If no Phase 2 sessions exist on any repo, just say so — that means we're between sprints or pre-rollout.

Sign as: — CTO
