#!/usr/bin/env bash
# settings-posture.sh — the CTO home's permissions posture, checked and applied from the template.
#
#   settings-posture.sh --check [<cto-home>]   exit 0 in posture · 1 drifted (one line per gap) · 2 usage
#   settings-posture.sh --apply [<cto-home>]   merge the template posture into <cto-home>/.claude/settings.json
#
# POSTURE (CEO 2026-11-01, docs/memos/20261101-permissions-posture-ruling.md): the conversation is the
# gate, the harness is lenient. defaultMode acceptEdits; allow carries the blanket Bash so routine work
# runs silently; ask carries only the NEVER-UNINVITED set (force-push, remote branch deletion, launchd
# persistence, GitHub repo create/delete, edits to the permission files). An ask rule beats any allow
# rule in any scope (deny > ask > allow, specificity does not matter), so those prompt every time — by
# design; "don't ask again" cannot silence them, only removing the rule can. Everything the CEO approved
# in the conversation (a batch of merges, a reap, a push) runs without a harness prompt.
#
# Auto mode DROPS the blanket Bash allow on entry and judges every call with a classifier whose block is
# not a prompt. The ask list still prompts there. preflight.sh reports the session's mode.
#
# --apply is a MERGE, not a copy: it sets defaultMode, unions allow and ask with the template's, adds the
# SessionStart preflight hook and skillListingBudgetFraction if missing, and leaves everything else in
# settings.json alone (MCP servers, additionalDirectories, the home's own hooks). _comment keys from the
# template are never written.
set -uo pipefail
MODE="${1:-}"; HOME_DIR="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
case "$MODE" in --check|--apply) ;; *) echo "usage: settings-posture.sh --check|--apply [<cto-home>]" >&2; exit 2 ;; esac
TPL="$HOME_DIR/.claude/settings.cto.json.template"; SET="$HOME_DIR/.claude/settings.json"
[ -f "$TPL" ] || { echo "settings-posture: no template at $TPL" >&2; exit 2; }
python3 -I -B - "$MODE" "$TPL" "$SET" <<'PY'
import json, os, sys
mode, tpl_path, set_path = sys.argv[1:4]

def strip_comments(x):           # _comment* keys are valid JSON; drop them after parsing, never by line
    if isinstance(x, dict):
        return {k: strip_comments(v) for k, v in x.items() if not k.startswith("_")}
    return [strip_comments(v) for v in x] if isinstance(x, list) else x

def load(path, template):
    if not os.path.isfile(path):
        return {}
    d = json.load(open(path))
    return strip_comments(d) if template else d

tpl = load(tpl_path, True)
cur = load(set_path, False)
tperm, cperm = tpl.get("permissions") or {}, cur.get("permissions") or {}
# Rules the template once shipped in ask and has since retired (sync never deletes on its own, so
# they are named explicitly): the raw template's permissions._retired_ask, read before stripping.
retired = ((json.load(open(tpl_path)).get("permissions") or {}).get("_retired_ask") or [])
stale = [r for r in cperm.get("ask") or [] if r in retired]
BLANKET = ("Bash", "Bash(*)")           # the docs: Bash(*) is equivalent to Bash

def has_preflight(d):
    for entry in (d.get("hooks") or {}).get("SessionStart") or []:
        for h in entry.get("hooks") or []:
            if "preflight.sh" in (h.get("command") or ""):
                return True
    return False

gaps = []
if cur.get("defaultMode") != tpl.get("defaultMode"):
    gaps.append("defaultMode is %r (template: %r)" % (cur.get("defaultMode"), tpl.get("defaultMode")))
if not any(r in BLANKET for r in cperm.get("allow") or []):
    gaps.append("allow has no blanket Bash — routine shepherding prompts on every call")
missing_ask = [r for r in tperm.get("ask") or [] if r not in (cperm.get("ask") or [])]
if missing_ask:
    gaps.append("ask list lacks %d never-uninvited rule(s): %s" % (len(missing_ask), ", ".join(missing_ask)))
dead = [r for r in cperm.get("ask") or [] if r in (cperm.get("allow") or [])]
if dead:
    gaps.append("in both ask and allow (ask wins; the allow entry is dead): %s" % ", ".join(dead))
if stale:
    gaps.append("ask list carries %d rule(s) the template retired (prompts on routine work): %s" % (len(stale), ", ".join(stale)))
if not has_preflight(cur):
    gaps.append("hooks.SessionStart has no preflight.sh")
if "skillListingBudgetFraction" in tpl and "skillListingBudgetFraction" not in cur:
    gaps.append("skillListingBudgetFraction missing (template: %s)" % tpl["skillListingBudgetFraction"])

if mode == "--check":
    for g in gaps:
        print("  gap: " + g)
    print("settings posture: %s" % ("ok" if not gaps else "%d gap(s)" % len(gaps)))
    sys.exit(0 if not gaps else 1)

# --apply: merge
cur["defaultMode"] = tpl.get("defaultMode", "acceptEdits")
perm = cur.setdefault("permissions", {})
allow = perm.setdefault("allow", [])
for r in tperm.get("allow") or []:
    if r in BLANKET and any(a in BLANKET for a in allow):
        continue
    if r not in allow:
        allow.append(r)
ask = perm.setdefault("ask", [])
for r in tperm.get("ask") or []:
    if r not in ask:
        ask.append(r)
ask[:] = [r for r in ask if r not in retired]
if not has_preflight(cur):
    cur.setdefault("hooks", {}).setdefault("SessionStart", []).extend((tpl.get("hooks") or {}).get("SessionStart") or [])
if "skillListingBudgetFraction" in tpl and "skillListingBudgetFraction" not in cur:
    cur["skillListingBudgetFraction"] = tpl["skillListingBudgetFraction"]
os.makedirs(os.path.dirname(set_path), exist_ok=True)
with open(set_path, "w") as o:
    o.write(json.dumps(cur, indent=2) + "\n")
print("settings posture: applied to %s (%d gap(s) closed; MCP/dirs/hooks kept)" % (set_path, len(gaps)))
PY
