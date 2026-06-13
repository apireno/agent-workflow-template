---
name: sprint-status
description: Show at-a-glance status of all per-repo Phase 2 dev-team sessions across the active acme-* fleet. Reports which repos are running, idle, crashed, or completed. Use when CEO asks "how are the dev teams doing", "what's the sprint status", "any crashes?", or wants a fleet snapshot.
allowed-tools: Bash(cat *) Bash(ls *) Bash(stat *) Bash(date *) Bash(test *) Bash(find *) Read
---

# Sprint Status Across Active Fleet

## Read the active repo registry

```!
ART=/Users/apireno/repos/agent-workflow-template/.cto/projects.yaml
if [ ! -f "$ART" ]; then
  echo "ERROR: .cto/projects.yaml not found at $ART"
  exit 1
fi

python3 - <<'PYEOF'
import re
with open('/Users/apireno/repos/agent-workflow-template/.cto/projects.yaml') as f:
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
python3 - <<'PYEOF'
import os, re, json, time
from pathlib import Path

with open('/Users/apireno/repos/agent-workflow-template/.cto/projects.yaml') as f:
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
