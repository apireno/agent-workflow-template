---
name: handoff
description: Phase 2 execution launcher. Writes per-repo mission briefs to each target repo's docs/sprints/<sprint>/brief.md and opens a Terminal tab per repo running claude interactively; the kickoff prompt tells each session to read its brief. Use when the CEO approves a sprint plan and wants to fan out dev work across repos.
allowed-tools: Bash(*) Read Write
argument-hint: <sprint-XX> [--repos repo1,repo2] [--dry-run]
---

# Phase 2 Handoff: $ARGUMENTS

Generates mission briefs and launches per-repo dev-team sessions.

## Generate briefs + dispatch

```!
set -uo pipefail
# CTO-HOME ANCHORING. These skills read the fleet registry, which lives in the CTO home
# — but `git rev-parse` returns whatever repo the SHELL happens to sit in. A lingering cd
# into a project repo made /handoff report "no target repos found" and made vp-review
# resolve personas against the wrong tree. $CLAUDE_PROJECT_DIR is the session's project
# root regardless of cwd drift, so it is the correct anchor; git root is the fallback.
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
  echo "ERROR: fleet registry not found at $CTO_REGISTRY"
  echo "  This skill must run from the CTO home (the repo holding .cto/projects.yaml)."
  echo "  If you are in a project repo, the session project dir is wrong — reopen in the CTO home."
  exit 1
fi

# zsh doesn't word-split unquoted parameter expansion by default. Skills run
# in whatever shell the harness uses (zsh on macOS). This makes `for tok in $ARGS`
# behave consistently in both bash and zsh.
[ -n "${ZSH_VERSION:-}" ] && setopt sh_word_split

ARGS="$ARGUMENTS"
SPRINT=""
REPOS_FILTER=""
DRY_RUN=0

for tok in $ARGS; do
  case "$tok" in
    --repos=*)   REPOS_FILTER="${tok#--repos=}" ;;
    --dry-run)   DRY_RUN=1 ;;
    --*)         echo "Unknown flag: $tok" >&2 ;;
    *)           [ -z "$SPRINT" ] && SPRINT="$tok" ;;
  esac
done

if [ -z "$SPRINT" ]; then
  echo "Usage: /handoff <sprint-XX> [--repos r1,r2] [--dry-run]"
  exit 1
fi

# Normalize: the CEO types the slug either as `sprint-foo-20260101` (with prefix)
# or `foo-20260101` (bare). Strip the `sprint-` prefix once here so every
# downstream use of $SPRINT is the BARE slug — then `sprint-$SPRINT` is always
# correct. Bug fix for the doubled-`sprint-` prefix in the mission-brief paths
# observed across every sprint of session 2026-05-22/24 (handoff, corpus-gen,
# corpus-curate, llm-validation, model-selection).
SPRINT="${SPRINT#sprint-}"

# Resolve target repos
TARGETS=$(python3 - <<PYEOF
import re
with open('$CTO_REGISTRY') as f:
    text = f.read()
filter_set = set("$REPOS_FILTER".split(',')) if "$REPOS_FILTER" else None
for b in re.split(r'(?=- name:)', text):
    m = re.search(r'- name:\s*(\S+)', b)
    p = re.search(r'path:\s*(\S+)', b)
    a = re.search(r'active:\s*(\S+)', b)
    if not m or not p:
        continue
    is_active = (a is None) or a.group(1).lower() not in ('false','no','0')
    if not is_active:
        continue
    if filter_set and m.group(1) not in filter_set:
        continue
    # NOTE: str.lstrip() takes a CHARSET, not a prefix. Use removeprefix (Python 3.9+).
    _sprint = '$SPRINT'.removeprefix('sprint-') if '$SPRINT'.startswith('sprint-') else '$SPRINT'
    sprint_dir = f"{p.group(1)}/docs/sprints/sprint-{_sprint}"
    plan = f"{sprint_dir}/sprint-plan.md"
    import os
    if os.path.isfile(plan):
        print(f"{m.group(1)}\t{p.group(1)}\t{plan}")
PYEOF
)

if [ -z "$TARGETS" ]; then
  echo "ERROR: no target repos found with a sprint-plan.md at sprint-$SPRINT"
  exit 1
fi

NUM=$(echo "$TARGETS" | wc -l | tr -d ' ')
echo "Target repos with sprint-plan.md present: $NUM"
# Display the target list with a bash read-loop, NOT awk with $1/$3 — the skill
# harness substitutes $1/$3 as positional-arg placeholders, which clobbers awk
# field references and produces a syntax error.
echo "$TARGETS" | while IFS=$'\t' read -r d_name d_path d_plan; do
  printf "  %-32s -> %s\n" "$d_name" "$d_plan"
done
echo ""

# Build mission brief per repo and drop into docs/sprints/<sprint>/brief.md
# docs/, NOT .claude/ — writes to .claude/ are gated as security-sensitive
# (hooks/permissions live there) and prompt even under acceptEdits; docs/ is an
# ordinary reviewable artifact path. (CEO 2026-06-08)
echo "Building mission briefs..."
PATHS_TO_OPEN=""
while IFS=$'\t' read -r REPO_NAME REPO_PATH PLAN_PATH; do
  BRIEF_FILE="$REPO_PATH/docs/sprints/sprint-$SPRINT/brief.md"
  mkdir -p "$REPO_PATH/docs/sprints/sprint-$SPRINT"

  # --- SELF-HEAL: guarantee session-tracking is wired in the target repo ---
  # A repo set up without the dev-team hooks (or via settings.permissive.json,
  # which carries no hooks) would otherwise run UNTRACKED — no current-session.id
  # (/peek + /resume blind) and no COMPLETE (/sprint-status never sees done).
  # Install the latest hooks, merge their wiring into the repo's settings.json
  # (idempotent), and record the active sprint for the completion hooks' scope.
  mkdir -p "$REPO_PATH/.claude/hooks"
  for h in auto-paste-brief check-complete session-end-record deny-self-commit deny-generated-edit; do
    cp "$ROOT/.claude/hooks/$h.sh" "$REPO_PATH/.claude/hooks/$h.sh" 2>/dev/null && chmod +x "$REPO_PATH/.claude/hooks/$h.sh"
  done
  echo "sprint-$SPRINT" > "$REPO_PATH/.claude/current-sprint"
  python3 - "$REPO_PATH/.claude/settings.json" "$REPO_PATH" <<'PYWIRE'
import json, sys, os
p = sys.argv[1]; repo = sys.argv[2]; s = {}
if os.path.exists(p):
    try: s = json.load(open(p))
    except Exception: s = {}
allow = s.setdefault("permissions", {}).setdefault("allow", ["Bash(*)","Edit","Write","Read","Glob","Grep","WebFetch","WebSearch"])
# Pre-trust the repo's MCP servers so per-tool prompts don't stall the auto-kickoff.
# Each MCP tool otherwise prompts separately (e.g. codegram, domshell) — `mcp__<server>`
# allows all of that server's tools, and enableAllProjectMcpServers skips the trust prompt.
servers = []
mj = os.path.join(repo, ".mcp.json")
if os.path.exists(mj):
    try: servers = list(json.load(open(mj)).get("mcpServers", {}).keys())
    except Exception: servers = []
for srv in servers:
    rule = "mcp__%s" % srv
    if rule not in allow: allow.append(rule)
if servers: s["enableAllProjectMcpServers"] = True
hooks = s.setdefault("hooks", {})

def anchor(cmd):
    # Hooks run from whatever cwd the harness happens to use, so a repo-relative
    # command yields "No such file or directory" at hook time — silently, since a
    # failing Stop hook just logs. $CLAUDE_PROJECT_DIR is the documented anchor.
    if cmd.startswith(".claude/") or cmd.startswith("scripts/"):
        return "$CLAUDE_PROJECT_DIR/" + cmd
    return cmd

# Migrate any relative hook command already in this repo's settings — repos stamped
# before the fix carry the latent form, and self-heal is the moment we can see them.
for _ev, _groups in hooks.items():
    if not isinstance(_groups, list): continue          # skip _comment_* string entries
    for _g in _groups:
        for _h in _g.get("hooks", []):
            _h["command"] = anchor(_h.get("command", ""))

def ensure(event, cmd, matcher="*"):
    target = anchor(cmd)
    arr = hooks.setdefault(event, [])
    for g in arr:
        for h in g.get("hooks", []):
            if h.get("command","").endswith(cmd):
                h["command"] = target
                return
    arr.append({"matcher":matcher,"hooks":[{"type":"command","command":target}]})
ensure("SessionStart", ".claude/hooks/auto-paste-brief.sh")
ensure("Stop", ".claude/hooks/check-complete.sh")
ensure("SessionEnd", ".claude/hooks/session-end-record.sh")
# The no-self-commit guard: dev teams write artifacts; the CTO commits after the
# independent Phase-3 review. Without this wired, a repo silently permits self-commit
# AND self-review, which collapses the gate the whole sprint lifecycle rests on.
ensure("PreToolUse", ".claude/hooks/deny-self-commit.sh", matcher="Bash")
# Generated artifacts change through their generator, never by hand. INERT unless the
# repo declares globs in .claude/generated-paths — see CLAUDE.md "Generated artifacts".
ensure("PreToolUse", ".claude/hooks/deny-generated-edit.sh", matcher="Edit|Write|NotebookEdit")
open(p,"w").write(json.dumps(s, indent=2) + "\n")   # trailing newline: json.dump omits it
print("  self-heal: wired hooks + pre-trusted MCP servers %s in %s" % (servers or "(none)", p))
PYWIRE

  # Pre-trust the repo's MCP servers at the USER scope too (~/.claude.json), so the
  # startup "Use this .mcp.json server?" dialog never blocks the auto-kickoff keystroke.
  python3 - "$REPO_PATH" <<'PYMCP'
import json, sys, os
from pathlib import Path
repo = sys.argv[1]; mj = os.path.join(repo, ".mcp.json"); servers = []
if os.path.exists(mj):
    try: servers = list(json.load(open(mj)).get("mcpServers", {}).keys())
    except Exception: servers = []
cj = Path.home()/".claude.json"
if cj.exists() and servers:
    try:
        d = json.loads(cj.read_text())
        proj = d.setdefault("projects", {}).setdefault(repo, {})
        proj["hasTrustDialogAccepted"] = True
        en = proj.setdefault("enabledMcpjsonServers", [])
        for srv in servers:
            if srv not in en: en.append(srv)
        cj.write_text(json.dumps(d, indent=2) + "\n")
        print("  self-heal: pre-trusted MCP in ~/.claude.json:", servers)
    except Exception as e:
        print("  WARN: could not pre-trust MCP in ~/.claude.json:", e)
PYMCP

  # Clear any stale pending-prompt.md so the SessionStart hook can't auto-paste an
  # old brief; the kickoff prompt points the session at the docs brief explicitly.
  rm -f "$REPO_PATH/.claude/pending-prompt.md"

  cat > "$BRIEF_FILE" <<BRIEFEOF
# Mission Brief — sprint-$SPRINT (Phase 2 execution)

You are the Dev Team for $REPO_NAME. The CTO has approved the sprint plan below.
Implement it. When done, write \`docs/sprints/sprint-$SPRINT/dev-report.md\` and tests.

## Sprint plan

$(cat "$PLAN_PATH")

## Acceptance criteria

- All tasks in the sprint plan complete
- Tests pass (run them; report failures in dev-report.md)
- dev-report.md committed to docs/sprints/sprint-$SPRINT/dev-report.md
- demo-output.md if any [AUTO] demo steps exist
- Sign-off: — Dev

## On crash recovery

This session was launched via the CTO's \`/handoff\` skill. If you crash:
- Your session ID is recorded in \`.claude/current-session.id\`
- The CTO can resume you with \`/resume-dev-team $REPO_NAME\`
- A new Terminal tab will open running \`claude --resume <session-id>\`
BRIEFEOF
  echo "  wrote $BRIEF_FILE"
  PATHS_TO_OPEN="$PATHS_TO_OPEN $REPO_PATH"
done <<< "$TARGETS"

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "DRY-RUN: briefs dropped. No Terminal tabs opened."
  echo "Inspect the briefs at each repo's docs/sprints/sprint-$SPRINT/brief.md, then re-run without --dry-run."
  exit 0
fi

# Open Terminal tab per repo
#
# Note on the kickoff prompt: the brief lives in docs/sprints/<sprint>/brief.md
# (NOT .claude/ — those writes are gated and prompt even under acceptEdits). We
# pass a kickoff prompt as the positional `prompt` argument to `claude` telling it
# to READ that docs brief and execute — this becomes the first user message and
# triggers immediate execution. The legacy SessionStart auto-paste-brief.sh hook
# (which read .claude/pending-prompt.md) is now vestigial; we rm the stale file
# above so it can't paste an old brief.
# CARVE-OUT (required, do not remove): the blanket pre-approval below is what makes
# the session self-starting, but a dev team has read it as satisfying a SIGNATURE gate
# — it self-signed a statistical pre-registration and executed a scored run without the
# CTO round-trip. Blanket authority in the kickoff outranks a caveat buried in the brief,
# so the limit must travel WITH the grant, in the same sentence that confers it. Same
# lesson as the qa-drive claude-in-chrome deny: an instruction elsewhere does not survive
# contact with a stronger instruction here.
# Keep this string free of double quotes and backslashes — it is interpolated into an
# AppleScript `do script` argument below.
KICKOFF="Read docs/sprints/sprint-$SPRINT/brief.md in full as your mission brief, then execute it. You are pre-approved by the CTO and the reviewing VPs for IMPLEMENTATION — do not ask for permission to proceed with building, testing, or writing the sprint artifacts. CARVE-OUT: this pre-approval NEVER satisfies a signature or sign-off gate. If your sprint requires a signed pre-registration, approval, or sign-off before a scored or statistical run, a release, or any irreversible action, then AUTHOR the artifact and STOP: write dev-report.md declaring signature-pending and let the CTO obtain the signature. Never self-sign under delegated authority, and never cite this kickoff as the signature."

# Short task descriptor for the Terminal tab title: strip the `sprint-` prefix
# and any trailing -YYYYMMDD date.
#   sprint-lexical-primitive-migration-20260520  ->  lexical-primitive-migration
SHORT_DESC=$(echo "$SPRINT" | sed -E 's/^sprint-//; s/-[0-9]{8}$//')

echo ""
echo "Opening Terminal tabs (one per repo) with auto-kickoff..."
for REPO_PATH in $PATHS_TO_OPEN; do
  REPO_NAME=$(basename "$REPO_PATH")
  echo "  -> $REPO_NAME"
  # Terminal tab title: "<repo> · <task>" so the CEO can ID tabs at a glance.
  # Claude Code itself writes the Terminal `custom title` slot with its current-
  # task summary — an external `set custom title` alone gets overwritten within
  # seconds. CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 stops Claude Code touching the
  # title; the `set custom title` below then sticks for the life of the session.
  #
  # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 turns OFF the composer's grey inline
  # suggestion in every ORCHESTRATED window. This is a safety control, not a
  # preference. Claude Code renders a generated suggestion in the same input cells
  # as typed text, differing only by colour — and `Terminal get contents` (what
  # every watcher here reads) returns plain text with the colour stripped. A ghost
  # suggestion and a human's typed-but-unsubmitted draft are therefore BYTE-
  # IDENTICAL to any watcher, and a watcher that submits "stranded input" submits
  # the session its own generated advice wearing the CEO's authority. Observed
  # 2026-08-27: two submit attempts on a suggestion, stopped only by a busy
  # composer. See docs/memos/2026-08-27-rca-observed-text-is-not-attributed-text.md.
  # Turning the feature off in orchestrated windows removes the ambiguity at the
  # source; the human's OWN session keeps its suggestions.
  # The trailing bare `newTab` keeps "tab N of window id NNNN" as the last output
  # line so the window-id parse below still works unchanged.
  TAB_TITLE="$REPO_NAME · $SHORT_DESC"
  TAB_INFO=$(osascript <<APPLESCRIPT 2>&1 | tail -1
tell application "Terminal"
    activate
    set newTab to do script "cd $REPO_PATH && export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 && echo '[handoff] launching claude for $REPO_NAME...' && claude \"$KICKOFF\""
    set custom title of newTab to "$TAB_TITLE"
    newTab
end tell
APPLESCRIPT
)
  echo "      $TAB_INFO"
  # Parse window id from "tab N of window id NNNN" and persist for /send + /close-window
  WIN_ID=$(echo "$TAB_INFO" | grep -oE 'window id [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -n "$WIN_ID" ]; then
    # The single slot is kept for backward compatibility, but it now means "most recent",
    # not "the one" — every handoff used to overwrite it, so a second sprint on a repo stole
    # the first session's address and long-lived windows could only be reached by raw id.
    echo "$WIN_ID" > "$REPO_PATH/.claude/terminal-window.id"
    bash "$ROOT/scripts/cto/window-registry.sh" add "$REPO_PATH" "$WIN_ID" "sprint-$SPRINT" >/dev/null 2>&1 \
      && echo "      recorded window id: $WIN_ID (registry: .claude/terminal-windows.tsv, label sprint-$SPRINT)" \
      || echo "      recorded window id: $WIN_ID -> $REPO_PATH/.claude/terminal-window.id (registry unavailable)"
  else
    echo "      WARN: could not parse window id from osascript output; /send + /close-window will not work for this repo until manually set"
  fi
done
echo ""
echo "All sessions launched with auto-kickoff prompt."
```

## Your task as CTO

The handoff is fired. Per-repo briefs are at each `<repo>/docs/sprints/sprint-<slug>/brief.md`. Terminal tabs are opening.

Summarize for the CEO:

1. **Headline:** "N repos handed off — Terminal tabs opening"
2. **Per repo:** name + sprint-plan path (or paths from above)
3. **CEO next actions:**
   - Watch the Terminal tabs for the SessionStart hook auto-paste (you should see the brief appear in each session)
   - Use `/peek <repo>` from the CTO session to monitor any specific repo's thinking
   - Use `/sprint-status` for at-a-glance
   - When all repos write `dev-report.md`, run `/sprint-accept <sprint-dir>` per repo
4. **Crash recovery reminder:** if any tab crashes, `/resume-dev-team <repo>` will spin a new tab via `claude --resume`

Sign as: — CTO
