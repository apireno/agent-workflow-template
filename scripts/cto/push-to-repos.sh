#!/bin/zsh
# push-to-repos.sh v2 — Minimal-scope distribution for the skills-driven architecture.
#
# Per ADR-046, the post-June-15 architecture moves orchestration into the CTO
# repo. Each acme-* repo no longer needs personas, scripts/agentic/, or
# PROTOCOL.md replicated. Each repo only needs the minimum infrastructure to
# act as a Phase 2 target:
#
#   1. CLAUDE.md (dev-team version, knows about the auto-paste pattern)
#   2. .claude/settings.json (SessionStart + SessionEnd hooks)
#   3. .claude/hooks/auto-paste-brief.sh (records session_id, auto-pastes brief)
#   4. .claude/hooks/session-end-record.sh (records exit, flags CRASHED/COMPLETE)
#
# Run from a CTO home (the template or any <project>-cto):
#   ./scripts/cto/push-to-repos.sh                # push to all active repos in projects.yaml
#   ./scripts/cto/push-to-repos.sh <repo-name>    # push to one repo
#   ./scripts/cto/push-to-repos.sh --dry-run      # show what would be pushed
#
# Repo list + paths come from .cto/projects.yaml (NOT hardcoded), so this same script is
# portable to any CTO home. CTO-home repos (name ends in -cto, or the template itself) get a
# MECHANISM sync via sync-cto-home.sh instead of the dev-team file copy.

set -euo pipefail

TEMPLATE="$(cd "$(dirname "$0")/../.." && pwd)"
REPOS_BASE="$(dirname "$TEMPLATE")"

# Active repos (name + path) read from .cto/projects.yaml — no hardcoded names.
typeset -A REPO_PATH_MAP
typeset -a ACTIVE_REPOS
while IFS=$'\t' read -r _nm _pth; do
  [ -n "$_nm" ] || continue
  ACTIVE_REPOS+=("$_nm"); REPO_PATH_MAP[$_nm]="$_pth"
done < <(python3 - "$TEMPLATE/.cto/projects.yaml" <<'PY'
import re, sys, os
p = sys.argv[1]
if not os.path.exists(p): sys.exit(0)
for b in re.split(r'(?=- name:)', open(p).read()):
    m = re.search(r'- name:\s*(\S+)', b); pa = re.search(r'path:\s*(\S+)', b); a = re.search(r'active:\s*(\S+)', b)
    if not m or not pa: continue
    if a and a.group(1).lower() in ('false', 'no', '0'): continue
    print(f"{m.group(1)}\t{pa.group(1)}")
PY
)
if [ ${#ACTIVE_REPOS[@]} -eq 0 ]; then
  echo "WARN: no active repos found in $TEMPLATE/.cto/projects.yaml" >&2
fi

# Parse args
DRY_RUN=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [repo1 repo2 ...]"
      echo "If no repos given, pushes to all active repos in .cto/projects.yaml."
      echo "CTO-home repos (*-cto / the template) get a mechanism sync via sync-cto-home.sh."
      exit 0
      ;;
    *) TARGETS+=("$arg") ;;
  esac
done

# Default to all active if no targets
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("${ACTIVE_REPOS[@]}")
fi

echo "Template: $TEMPLATE"
echo "Repos base: $REPOS_BASE"
echo "Dry-run: $DRY_RUN"
echo "Targets: ${TARGETS[*]}"
echo ""

# Verify source files exist
required_files=(
  "$TEMPLATE/CLAUDE.devteam.md"
  "$TEMPLATE/.claude/settings.devteam.json.template"
  "$TEMPLATE/.claude/hooks/auto-paste-brief.sh"
  "$TEMPLATE/.claude/hooks/session-end-record.sh"
  "$TEMPLATE/.claude/hooks/check-complete.sh"
)
for f in "${required_files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required source file missing: $f"
    exit 2
  fi
done

push_count=0
skip_count=0

for repo in "${TARGETS[@]}"; do
  DEST="${REPO_PATH_MAP[$repo]:-$REPOS_BASE/$repo}"

  if [ ! -d "$DEST" ]; then
    echo "  [skip] $repo — directory not found at $DEST"
    skip_count=$((skip_count + 1))
    continue
  fi

  # CTO-home repos get the MECHANISM sync (skills/scripts/personas/settings), NOT the
  # dev-team file copy. Detection per CLAUDE.md: name ends in -cto, or is the template.
  case "$repo" in
    *-cto|agent-workflow-template)
      echo "  -> $repo  [CTO home — mechanism sync via sync-cto-home.sh]"
      SYNC="$TEMPLATE/scripts/cto/sync-cto-home.sh"
      if [ -x "$SYNC" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then "$SYNC" "$DEST"; else "$SYNC" "$DEST" --apply; fi
      else
        echo "      WARN: $SYNC not found/executable — skipping CTO-home $repo"
      fi
      push_count=$((push_count + 1))
      continue
      ;;
  esac

  echo "  -> $repo"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "      would write: $DEST/CLAUDE.md"
    [ -f "$DEST/CLAUDE.md" ] && echo "        (overwrites existing — $(wc -l < "$DEST/CLAUDE.md") lines)"
    echo "      would write: $DEST/.claude/settings.json (from template, _comment_* stripped)"
    [ -f "$DEST/.claude/settings.json" ] && echo "        (overwrites existing)"
    echo "      would write: $DEST/.claude/hooks/auto-paste-brief.sh"
    echo "      would write: $DEST/.claude/hooks/session-end-record.sh"
    echo "      would write: $DEST/.claude/hooks/check-complete.sh"
    echo "      would add to .gitignore: .claude/current-session.id, .claude/CRASHED, .claude/COMPLETE, .claude/pending-prompt.md, .claude/used-prompts/, .claude/session.log, .claude/terminal-window.id"
    push_count=$((push_count + 1))
    continue
  fi

  # 1. CLAUDE.md
  cp "$TEMPLATE/CLAUDE.devteam.md" "$DEST/CLAUDE.md"
  echo "      wrote $DEST/CLAUDE.md"

  # 2. .claude/settings.json — strip _comment_* keys from template
  mkdir -p "$DEST/.claude"
  python3 - <<PYEOF > "$DEST/.claude/settings.json"
import json, sys
with open("$TEMPLATE/.claude/settings.devteam.json.template") as f:
    text = f.read()
# Strip _comment* lines before JSON parsing
clean = '\n'.join(l for l in text.split('\n') if '"_comment' not in l)
data = json.loads(clean)
print(json.dumps(data, indent=2))
PYEOF
  echo "      wrote $DEST/.claude/settings.json"

  # 3. Hook scripts
  mkdir -p "$DEST/.claude/hooks"
  cp "$TEMPLATE/.claude/hooks/auto-paste-brief.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/session-end-record.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/check-complete.sh" "$DEST/.claude/hooks/"
  chmod +x "$DEST/.claude/hooks/"*.sh
  echo "      wrote $DEST/.claude/hooks/auto-paste-brief.sh + session-end-record.sh + check-complete.sh"

  # 4a. Pre-trust the workspace in ~/.claude.json so /handoff doesn't hit the
  # "Quick safety check: do you trust this folder?" dialog on first claude run.
  # Without this, the auto-kickoff prompt is queued behind the dialog and the
  # dev team appears idle until the operator manually clicks "1, Yes" + Enter.
  python3 - "$DEST" <<'PYEOF' || echo "      WARN: failed to pre-trust workspace; first /handoff will require manual trust-dialog confirmation"
import json, sys
from pathlib import Path
dest = sys.argv[1]
claude_json = Path.home() / '.claude.json'
if claude_json.exists():
    data = json.loads(claude_json.read_text())
    projects = data.setdefault('projects', {})
    entry = projects.setdefault(dest, {})
    if not entry.get('hasTrustDialogAccepted'):
        entry['hasTrustDialogAccepted'] = True
        claude_json.write_text(json.dumps(data, indent=2))
        print(f'      pre-trusted workspace in ~/.claude.json')
    else:
        print(f'      workspace already pre-trusted')
else:
    print(f'      ~/.claude.json not found; skipping workspace pre-trust')
PYEOF

  # 4b. .gitignore entries for runtime state
  GITIGNORE="$DEST/.gitignore"
  for entry in '.claude/current-session.id' '.claude/CRASHED' '.claude/COMPLETE' '.claude/pending-prompt.md' '.claude/used-prompts/' '.claude/session.log' '.claude/terminal-window.id'; do
    if ! grep -qxF "$entry" "$GITIGNORE" 2>/dev/null; then
      echo "$entry" >> "$GITIGNORE"
    fi
  done
  echo "      ensured .gitignore entries for runtime state"

  push_count=$((push_count + 1))
done

echo ""
echo "Done. Pushed to $push_count repo(s), skipped $skip_count."
echo ""
echo "Next steps for the CEO:"
echo "  1. Verify each pushed repo's .claude/settings.json looks correct"
echo "  2. When ready to do Phase 2: run /handoff <sprint-XX> from the CTO session"
echo "  3. The CTO's /handoff will write per-repo .claude/pending-prompt.md and open Terminal tabs"
echo "  4. Each repo's SessionStart hook will auto-paste the brief into its claude session"
