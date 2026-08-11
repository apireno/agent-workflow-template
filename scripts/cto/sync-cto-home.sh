#!/usr/bin/env bash
# sync-cto-home.sh — propagate TEMPLATE MECHANISM into a CTO-home repo (e.g. <project>-cto).
#
# THE MISSING LINK: push-to-repos.sh distributes dev-team mechanism (CLAUDE.devteam.md,
# settings, hooks) to DEV-TEAM repos. Nothing kept the CTO HOME (a clone of this template
# with its own private IP + history) in sync with template skill/script/persona updates —
# so CTO-home skills silently went stale. This is that sync.
#
# Copies ONLY mechanism: .claude/skills, .claude/hooks, scripts/, the persona DEFINITIONS
# (docs/personas/*.md), and the settings templates + CLAUDE.devteam.md.
# NEVER touches the CTO home's IP or instance state:
#   docs/architecture · docs/roadmap · docs/ideation · docs/sprints  (PRDs/ADRs/decisions)
#   docs/personas/context · docs/personas/concerns                   (project-authored)
#   CLAUDE.md (project-customized) · .cto/projects.yaml · .git
# No --delete: the target's own extra files are never removed, only matching files overwritten.
#
# Dry-run by DEFAULT (shows what would change); pass --apply to write. Run from the TEMPLATE.
# After --apply: review `git -C <target> status`, then commit + push the CTO home.
#
# Usage:
#   scripts/cto/sync-cto-home.sh <cto-home-path>            # preview (dry-run)
#   scripts/cto/sync-cto-home.sh <cto-home-path> --apply    # write the files

set -uo pipefail
TARGET="${1:?usage: sync-cto-home.sh <cto-home-path> [--apply]}"
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
TEMPLATE="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -d "$TARGET" ] || { echo "ERROR: target not found: $TARGET"; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"
[ "$TARGET" = "$TEMPLATE" ] && { echo "ERROR: target is the template itself — nothing to sync."; exit 1; }
command -v rsync >/dev/null || { echo "ERROR: rsync not found."; exit 1; }

RS="-a --itemize-changes"; [ "$APPLY" = 0 ] && RS="$RS -n"
echo "TEMPLATE: $TEMPLATE"
echo "TARGET  : $TARGET   (CTO home)"
echo "MODE    : $([ "$APPLY" = 1 ] && echo '*** APPLY (writing) ***' || echo 'DRY-RUN (no writes)')"
echo "Itemized changes below ('>f' = file to copy/update; blank = nothing stale):"
echo

CHANGES=0
sync_one() { # rsync wrapper that counts itemized lines
  local out; out=$(rsync $RS "$@" 2>/dev/null); printf '%s' "$out" | sed 's/^/    /'
  local n; n=$(printf '%s' "$out" | grep -cE '^[<>ch.][fdL]' || true); CHANGES=$((CHANGES+n))
}

for d in .claude/skills .claude/hooks scripts; do
  [ -d "$TEMPLATE/$d" ] || continue
  echo "== $d/ =="; mkdir -p "$TARGET/$d" 2>/dev/null || true
  sync_one "$TEMPLATE/$d/" "$TARGET/$d/"
done

echo "== docs/personas/*.md (persona definitions only — context/ + concerns/ left alone) =="
mkdir -p "$TARGET/docs/personas" 2>/dev/null || true
for f in "$TEMPLATE"/docs/personas/*.md; do
  [ -f "$f" ] || continue
  sync_one "$f" "$TARGET/docs/personas/$(basename "$f")"
done

# Doc TEMPLATES are mechanism (the _templates/ dirs the project copies from), distinct from the
# CTO home's actual IP (real sprint dirs, ADRs, PRDs). Sync every docs/*/_templates/ dir; the
# IP siblings (docs/sprints/<sprint>, docs/architecture/decisions, docs/roadmap/prds, ...) are
# never matched because they aren't under a _templates/ path.
echo "== docs/*/_templates/ (sprint/qa/architecture/ideation doc templates — mechanism) =="
for tdir in "$TEMPLATE"/docs/*/_templates; do
  [ -d "$tdir" ] || continue
  rel="docs/$(basename "$(dirname "$tdir")")/_templates"
  mkdir -p "$TARGET/$rel" 2>/dev/null || true
  sync_one "$tdir/" "$TARGET/$rel/"
done

echo "== settings templates + CLAUDE.devteam.md =="
for f in .claude/settings.permissive.json .claude/settings.devteam.json.template .claude/settings.cto.json.template CLAUDE.devteam.md; do
  [ -f "$TEMPLATE/$f" ] || continue
  sync_one "$TEMPLATE/$f" "$TARGET/$f"
done

echo
echo "Total stale/changed files: $CHANGES"
if [ "$APPLY" = 0 ]; then
  echo ">>> DRY-RUN — nothing written. Re-run with --apply to sync, then:"
  echo "    git -C \"$TARGET\" status   # review, then commit + push the CTO home"
else
  echo ">>> APPLIED. Review, then stage ONLY the mechanism paths — never 'git add -A' here:"
  echo "    git -C \"$TARGET\" status"
  echo "    git -C \"$TARGET\" add .claude scripts docs/personas CLAUDE.devteam.md"
  echo "    git -C \"$TARGET\" commit -m 'sync template mechanism' && git -C \"$TARGET\" push"
  echo "    (a CTO home usually has its own uncommitted IP in flight; -A sweeps it into your commit)"
fi
