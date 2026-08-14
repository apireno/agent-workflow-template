---
name: escalate-drain
description: Read pending escalations dropped into ~/.cto/inbox/ by dev teams or VPs, present them to the CTO for handling. Use when CEO asks "any escalations?", "what's pending?", or starts the session — also can be wired to fire automatically via Stop hook.
allowed-tools: Bash(*) Read Write
---

# Escalation Inbox Drain

## Check inbox

```!
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
INBOX="$HOME/.cto/inbox"

if [ ! -d "$INBOX" ]; then
  echo "No inbox directory at $INBOX — nothing to drain."
  echo ""
  echo "(The inbox is populated by dev-team or VP Stop hooks when they drop"
  echo " .escalation-pending.md files. Until Phase 2 is live, this will be empty.)"
  exit 0
fi

PENDING=$(ls "$INBOX"/*.md 2>/dev/null)

if [ -z "$PENDING" ]; then
  echo "Inbox is empty — no pending escalations."
  exit 0
fi

COUNT=$(echo "$PENDING" | wc -l | tr -d ' ')
echo "Found $COUNT pending escalation(s) in $INBOX"
echo ""

for f in $PENDING; do
  echo "==================== $(basename $f) ===================="
  echo "Dropped: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f")"
  echo "Source: ${f%-*}"
  echo ""
  "$ROOT/scripts/agentic/wrap-untrusted.sh" "$f" "inbox:$(basename $f .md)"
  echo ""
done
```

## Your task as CTO

For each escalation above, respond inline:

1. **Ruling** — your direct answer or decision (1-3 sentences)
2. **Reasoning** — cross-repo implications, relevant ADRs, architectural constraints
3. **Action items** — what the escalating team does next, with file paths
4. **Cross-repo notes** — if other repos are affected, name them

After handling each escalation, **move the file** to `~/.cto/inbox/processed/{name}-$(date +%Y%m%d-%H%M%S).md` so it doesn't appear in subsequent drains.

If an escalation requires a lasting decision (e.g., an ADR, interface contract update, RCA), write that artifact to the affected repo path and reference it in your ruling.

Brief summary to CEO at the end: "Processed N escalations, X required ADRs/RCAs, Y deferred for next sync."

Sign as: — CTO
