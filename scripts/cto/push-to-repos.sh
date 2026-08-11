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
FORCE_UPSTREAM=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --upstream)  FORCE_UPSTREAM=1 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--upstream] [repo1 repo2 ...]"
      echo "If no repos given, pushes to all active repos in .cto/projects.yaml."
      echo "CTO-home repos (*-cto / the template) get a mechanism sync via sync-cto-home.sh."
      echo ""
      echo "  --upstream   Force UPSTREAM MODE: the repo is a clone of a project we do not own"
      echo "               (a public OSS fork). No tracked file is touched — the contract goes to"
      echo "               CLAUDE.devteam.md instead of CLAUDE.md, and the scaffolding is excluded"
      echo "               via .git/info/exclude instead of the tracked .gitignore. Auto-detected"
      echo "               when the repo tracks a CLAUDE.md that isn't ours, or was installed this"
      echo "               way before."
      exit 0
      ;;
    *) TARGETS+=("$arg") ;;
  esac
done

# ── Upstream mode ────────────────────────────────────────────────────────────
# Paths the workflow owns inside a target repo. In upstream mode these are written
# to .git/info/exclude so the scaffolding never appears in `git status` and can
# never ride along in a PR sent upstream. Broader than what this script installs:
# a running dev team also creates sprint dirs, ADRs, PRDs and bug reports.
WORKFLOW_PATHS=(
  '/CLAUDE.devteam.md' '/GEMINI.md' '/setup.sh'
  '/.claude/' '/.agents/' '/.skills/' '/.cto/' '/.cto-path' '/.cto-path.example'
  '/.review-engine'
  '/scripts/agentic/' '/scripts/cto/'
  '/docs/personas/' '/docs/sprints/' '/docs/roadmap/' '/docs/architecture/'
  '/docs/backlog/' '/docs/ideation/' '/docs/initiatives/' '/docs/operations/'
  '/docs/security/' '/docs/compliance/' '/docs/memos/'
)
EXCLUDE_BEGIN='# >>> agent-workflow-template: local scaffolding (LOCAL ONLY, managed block) >>>'
EXCLUDE_END='# <<< agent-workflow-template: end managed block <<<'
OWN_CONTRACT_MARKER='Your default role is \*\*Dev Team\*\*'

# Is this repo somebody else's? Three signals, any one is enough.
detect_upstream() {
  local dest="$1" gitdir
  [ "$FORCE_UPSTREAM" -eq 1 ] && return 0
  gitdir="$(git -C "$dest" rev-parse --absolute-git-dir 2>/dev/null || true)"
  # Sticky: already installed in upstream mode.
  [ -n "$gitdir" ] && grep -qF "$EXCLUDE_BEGIN" "$gitdir/info/exclude" 2>/dev/null && return 0
  # A TRACKED CLAUDE.md that is not our contract belongs to the upstream project.
  if git -C "$dest" ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1; then
    grep -qE "$OWN_CONTRACT_MARKER" "$dest/CLAUDE.md" 2>/dev/null || return 0
  fi
  return 1
}

# Rewrite the managed block in .git/info/exclude. Idempotent; preserves the
# operator's own lines (personal scratch files etc.) and drops legacy hand-written
# duplicates of the paths we now manage.
write_git_exclude() {
  local dest="$1"; shift
  local gitdir; gitdir="$(git -C "$dest" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  mkdir -p "$gitdir/info"

  # Never exclude a path the upstream project TRACKS. Our path list is generic
  # ('/.agents/', '/docs/roadmap/' …) and an upstream repo may legitimately own one
  # of those names — lancedb ships its own tracked /.agents/. Excluding it would not
  # touch the tracked files, but it WOULD hide any new untracked file upstream adds
  # there, so `git status` would quietly stop telling the truth about their tree.
  local -a safe=() bare
  for p in "$@"; do
    bare="${p#/}"; bare="${bare%/}"
    if [ -n "$(git -C "$dest" ls-files -- "$bare" 2>/dev/null | head -1)" ]; then
      echo "      note: '$p' is TRACKED upstream — left out of the exclude block (upstream owns that path)"
      continue
    fi
    safe+=("$p")
  done

  python3 - "$gitdir/info/exclude" "$EXCLUDE_BEGIN" "$EXCLUDE_END" "${safe[@]}" <<'PYEOF'
import sys, os
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
managed = sys.argv[4:]
old = open(path).read().splitlines() if os.path.exists(path) else []
kept, in_block = [], False
for line in old:
    if line.strip() == begin: in_block = True;  continue
    if line.strip() == end:   in_block = False; continue
    if in_block: continue
    # legacy hand-written copies of paths this block now owns
    if line.strip() in managed: continue
    if line.strip().startswith('# --- agent-workflow-template'): continue
    if 'must not be committed. Kept in .git/info/exclude' in line: continue
    kept.append(line)
while kept and not kept[-1].strip(): kept.pop()
out = kept + ['', begin,
    '# Written by scripts/cto/push-to-repos.sh --upstream. This repo is a clone of a',
    '# project we do not own: the agent workflow scaffolding stays LOCAL. Excluded here',
    "# rather than in .gitignore so the tracked tree stays byte-identical to upstream.",
    ] + managed + [end, '']
open(path, 'w').write('\n'.join(out))
PYEOF
}

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
  "$TEMPLATE/.claude/hooks/deny-self-commit.sh"
  "$TEMPLATE/.claude/hooks/deny-generated-edit.sh"
  "$TEMPLATE/.claude/hooks/inject-devteam-contract.sh"
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

  UPSTREAM=0
  if detect_upstream "$DEST"; then
    UPSTREAM=1
    echo "  -> $repo  [UPSTREAM MODE — clone of a project we don't own; no tracked file is touched]"
  else
    echo "  -> $repo"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$UPSTREAM" -eq 1 ]; then
      echo "      would write: $DEST/CLAUDE.devteam.md (tracked CLAUDE.md left alone)"
      echo "      would exclude ${#WORKFLOW_PATHS[@]} scaffolding paths via .git/info/exclude"
    else
      echo "      would write: $DEST/CLAUDE.md"
      [ -f "$DEST/CLAUDE.md" ] && echo "        (overwrites existing — $(wc -l < "$DEST/CLAUDE.md") lines)"
      echo "      would add to .gitignore: .claude/current-session.id, .claude/CRASHED, .claude/COMPLETE, .claude/pending-prompt.md, .claude/used-prompts/, .claude/session.log, .claude/terminal-window.id"
    fi
    echo "      would write: $DEST/.claude/settings.json (from template, _comment_* stripped)"
    [ -f "$DEST/.claude/settings.json" ] && echo "        (overwrites existing)"
    echo "      would write: $DEST/.claude/hooks/ (6: inject-devteam-contract, auto-paste-brief,"
    echo "                     session-end-record, check-complete, deny-self-commit, deny-generated-edit)"
    echo "      would write: $DEST/scripts/agentic/* + docs/personas/* + docs/sprints/_templates/*"
    [ -f "$DEST/.review-engine" ] || echo "      would write: $DEST/.review-engine = subagent"
    push_count=$((push_count + 1))
    continue
  fi

  # 1. The dev-team contract. In upstream mode the root CLAUDE.md is the upstream
  #    project's own file (often a symlink to AGENTS.md) and is TRACKED — writing
  #    over it dirties their tree and can ride along in a PR. Install beside it and
  #    let the SessionStart hook load it as context instead.
  if [ "$UPSTREAM" -eq 1 ]; then
    cp "$TEMPLATE/CLAUDE.devteam.md" "$DEST/CLAUDE.devteam.md"
    echo "      wrote $DEST/CLAUDE.devteam.md (loaded by the inject-devteam-contract SessionStart hook)"
  else
    cp "$TEMPLATE/CLAUDE.devteam.md" "$DEST/CLAUDE.md"
    echo "      wrote $DEST/CLAUDE.md"
  fi

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
  # Every hook settings.devteam.json.template WIRES must be installed here. A settings file
  # referencing a hook script that does not exist is a silently broken guard — the two
  # PreToolUse deny-hooks were wired in the template but never copied, so a repo onboarded
  # through this script (rather than self-healed by /handoff) had the rule without the guard.
  cp "$TEMPLATE/.claude/hooks/auto-paste-brief.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/session-end-record.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/check-complete.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/deny-self-commit.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/deny-generated-edit.sh" "$DEST/.claude/hooks/"
  cp "$TEMPLATE/.claude/hooks/inject-devteam-contract.sh" "$DEST/.claude/hooks/"
  chmod +x "$DEST/.claude/hooks/"*.sh
  echo "      wrote $DEST/.claude/hooks/ (6: contract, brief, session-end, complete, deny-self-commit, deny-generated-edit)"

  # 3b. scripts/agentic + persona defs + sprint doc templates. CLAUDE.devteam.md
  # (just written above) explicitly instructs the dev team to run
  # ./scripts/agentic/vp-review.sh etc. LOCALLY — without these files present,
  # those instructions are dead on arrival. (Same gap that had to be patched
  # by hand for the 2026-07-01 kimi-engine rollout; fixed here at the source.)
  mkdir -p "$DEST/scripts/agentic" "$DEST/docs/personas" "$DEST/docs/sprints/_templates"
  cp -r "$TEMPLATE/scripts/agentic/." "$DEST/scripts/agentic/"
  chmod +x "$DEST/scripts/agentic/"*.sh 2>/dev/null || true
  cp -r "$TEMPLATE/docs/personas/." "$DEST/docs/personas/"
  [ -d "$TEMPLATE/docs/sprints/_templates" ] && cp -r "$TEMPLATE/docs/sprints/_templates/." "$DEST/docs/sprints/_templates/"
  # Review engine: seed unset repos with the PROJECT's choice and heal dead values to it.
  # The choice is made once at project start (/new-project, /setup) and stored in the CTO
  # home's own .review-engine; set-review-engine.sh --fleet-default reports it. Writing goes
  # through that script so validation and the .claude/ stray-file cleanup live in one place.
  SETENG="$TEMPLATE/scripts/agentic/set-review-engine.sh"
  FLEET_ENG="$(bash "$SETENG" --fleet-default 2>/dev/null || echo subagent)"
  cur=""
  [ -f "$DEST/.review-engine" ] && cur="$(tr -d '[:space:]' < "$DEST/.review-engine" | tr '[:upper:]' '[:lower:]')"
  case "$cur" in
    "")
      bash "$SETENG" "$DEST" "$FLEET_ENG" >/dev/null 2>&1
      echo "      .review-engine unset -> seeded project default '$FLEET_ENG'" ;;
    gemini|dual|claude|claude-p)
      # Dead or quarantined. Leaving it defers the surprise to review time, where a missing
      # engine reads as a review that passed.
      bash "$SETENG" "$DEST" "$FLEET_ENG" >/dev/null 2>&1
      echo "      .review-engine was '$cur' (unavailable/quarantined) -> reset to project default '$FLEET_ENG'" ;;
    *)
      # A deliberate per-repo choice. Leave it; just clear the unread stray copy if present.
      [ -f "$DEST/.claude/.review-engine" ] && {
        echo "      removing unread $DEST/.claude/.review-engine (=$(tr -d '[:space:]' < "$DEST/.claude/.review-engine"))"
        rm -f "$DEST/.claude/.review-engine"; } ;;
  esac
  echo "      wrote $DEST/scripts/agentic + docs/personas + docs/sprints/_templates ; .review-engine=$(cat "$DEST/.review-engine" 2>/dev/null)"

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

  # 4b. Keep the scaffolding out of the repo's history.
  if [ "$UPSTREAM" -eq 1 ]; then
    # Not .gitignore — that file is tracked upstream, so editing it is itself a
    # diff we'd have to carry forever and strip out of every PR.
    if write_git_exclude "$DEST" "${WORKFLOW_PATHS[@]}"; then
      echo "      excluded ${#WORKFLOW_PATHS[@]} scaffolding paths in .git/info/exclude (tracked .gitignore untouched)"
      DIRTY="$(git -C "$DEST" status --porcelain | wc -l | tr -d ' ')"
      if [ "$DIRTY" != "0" ]; then
        echo "      WARN: $repo has $DIRTY entries in git status — expected 0 after an upstream-mode push."
        git -C "$DEST" status --short | sed 's/^/        /' | head -10
      else
        echo "      verified: git status clean — nothing we installed is visible to git"
      fi
    else
      echo "      ERROR: could not write .git/info/exclude for $repo — scaffolding is NOT hidden from git" >&2
    fi
  else
    GITIGNORE="$DEST/.gitignore"
    for entry in '.claude/current-session.id' '.claude/CRASHED' '.claude/COMPLETE' '.claude/pending-prompt.md' '.claude/used-prompts/' '.claude/session.log' '.claude/terminal-window.id'; do
      if ! grep -qxF "$entry" "$GITIGNORE" 2>/dev/null; then
        echo "$entry" >> "$GITIGNORE"
      fi
    done
    echo "      ensured .gitignore entries for runtime state"
  fi

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
