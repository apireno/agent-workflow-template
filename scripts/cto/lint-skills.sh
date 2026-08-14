#!/usr/bin/env bash
# lint-skills.sh [--apply] — regression guard for the three defect classes that broke skills
# in the field on 2026-08-13. All three were invisible until a skill was actually invoked.
#
#   CHECK A  quoted heredoc that interpolates a shell variable
#            `python3 - <<'PYEOF'` … `open('$CTO_REGISTRY')` — the quotes stop expansion, so
#            python receives the literal string "$CTO_REGISTRY" and dies with
#            FileNotFoundError on EVERY invocation. /sprint-status was dead this way, and
#            /peek carried the same bug undiagnosed. Pass values as ARGS instead:
#                python3 - "$CTO_REGISTRY" <<'PYEOF'   +   sys.argv[1]
#
#   CHECK B  CTO-home anchor drift
#            Every skill that reads fleet state must carry the canonical anchor block from
#            scripts/cto/_cto-home-anchor.sh verbatim. Hand-edited variants are how
#            $CLAUDE_PROJECT_DIR-only anchoring survived in six skills.
#
#   CHECK C  an unanchored `!` block
#            Each ```! block in a SKILL.md is a SEPARATE shell — variables do not carry over.
#            A later block referencing $ROOT/$CTO_REGISTRY without re-anchoring silently uses
#            an empty value. /sprint-status' second block did exactly this.
#
# --apply rewrites the anchor block in place (CHECK B only); A and C are report-only because
# their fixes are not mechanical.
#
# Exit: 0 clean · 1 findings

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

python3 - "$ROOT" "$APPLY" <<'PYEOF'
import os, re, sys

root, apply_mode = sys.argv[1], sys.argv[2] == "1"
ANCHOR = open(os.path.join(root, "scripts/cto/_cto-home-anchor.sh")).read().rstrip("\n")
ANCHOR_LINES = ANCHOR.split("\n")
BEGIN, END = ANCHOR_LINES[0], ANCHOR_LINES[-1]

# Variables that are MEANT to survive as literal text: they are consumed by something other
# than this shell (Claude Code expands $CLAUDE_PROJECT_DIR in settings.json hook commands;
# $ARGUMENTS is substituted by the skill harness before the shell ever runs; $DOMSHELL_TOKEN
# is read by the MCP client from the config file we are writing). Anything else inside a
# quoted heredoc is a bug unless the line carries a "literal-ok" marker.
LITERAL_OK = {"CLAUDE_PROJECT_DIR", "ARGUMENTS", "DOMSHELL_TOKEN"}

# Skills that legitimately anchor on the CURRENT repo, not the CTO home:
#   setup / new-project  bootstrap a clone BEFORE .cto/projects.yaml exists — requiring a
#                        CTO home would make first-run setup impossible.
#   arch-map, lane-check, qa-ux, codegram
#                        operate on the repo you are standing in, using that repo's own
#                        scripts/agentic + docs/personas (push-to-repos installs them).
EXEMPT = {"setup", "new-project", "arch-map", "lane-check", "qa-ux", "codegram"}

findings = []


def heredoc_scan(path, text):
    lines = text.split("\n")
    in_hd, tag, start, body = False, None, 0, []
    for i, l in enumerate(lines, 1):
        if not in_hd:
            # A comment cannot open a heredoc. Without this, prose ABOUT the bug — a comment
            # naming <<'PYEOF' and $CTO_REGISTRY in the same breath — reads as the bug.
            if l.lstrip().startswith("#"):
                continue
            m = re.search(r"<<-?\s*(['\"])([A-Za-z_][A-Za-z0-9_]*)\1", l)
            if m:
                in_hd, tag, start, body = True, m.group(2), i, []
        else:
            if l.strip() == tag:
                for j, b in enumerate(body, 1):
                    if "literal-ok" in b:
                        continue
                    for v in re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", b):
                        if v not in LITERAL_OK:
                            findings.append(
                                f"A  {path}:{start+j}  quoted heredoc <<'{tag}' interpolates ${v} "
                                f"-> python/awk receives the literal text. Pass it as an argument."
                            )
                in_hd = False
            else:
                body.append(l)


def bash_blocks(text):
    """(start_line, block_text) for each ```! fenced block."""
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        if lines[i].strip() == "```!":
            j, buf = i + 1, []
            while j < len(lines) and lines[j].strip() != "```":
                buf.append(lines[j]); j += 1
            out.append((i + 2, "\n".join(buf)))
            i = j
        i += 1
    return out


def strip_legacy(lines):
    """Remove the pre-2026-08-14 hand-written anchor: a '# CTO-HOME ANCHORING:' comment
    block, and any cd/CTO_REGISTRY lines left stranded directly under the canonical END.
    Line-based on purpose — a regex that swallows 'following comment lines' also swallows
    the canonical block's own header, which silently duplicated anchors on the first try."""
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("# CTO-HOME ANCHORING:"):
            i += 1
            while i < len(lines) and lines[i].startswith("#") and lines[i] != BEGIN:
                i += 1
            continue
        out.append(lines[i]); i += 1

    res, j = [], 0
    while j < len(out):
        res.append(out[j])
        if out[j] == END:
            j += 1
            while j < len(out) and re.match(r'^(cd "\$ROOT"|CTO_REGISTRY=)', out[j]):
                j += 1
            continue
        j += 1
    return res


def insert_anchor(lines, require):
    """Replace each legacy `ROOT=` assignment with the canonical block, skipping any line
    that already sits inside an anchor block. `require` marks skills that read the fleet
    registry: for those a missing CTO home must be fatal, never a silent fallback to
    whatever repo the shell happens to be in — that fallback is the 2026-08-13 defect."""
    out, inside, n = [], False, 0
    for l in lines:
        if l == BEGIN:
            inside = True
        elif l == END:
            inside = False
        if not inside and re.match(r"^ROOT=", l):
            if require:
                out.append("CTO_HOME_REQUIRED=1")
            out.extend(ANCHOR_LINES); n += 1
            continue
        out.append(l)
    return out, n


skills_dir = os.path.join(root, ".claude/skills")
for name in sorted(os.listdir(skills_dir)):
    p = os.path.join(skills_dir, name, "SKILL.md")
    if not os.path.isfile(p):
        continue
    text = open(p).read()
    rel = os.path.relpath(p, root)

    heredoc_scan(rel, text)

    if name in EXEMPT:
        continue
    if not re.search(r"\$CTO_REGISTRY|\.cto/projects\.yaml|\$ROOT/scripts/|\$ROOT/docs/personas", text):
        continue

    reads_registry = "$CTO_REGISTRY" in text
    if apply_mode:
        lines = text.split("\n")
        if BEGIN in lines and ANCHOR not in text:
            # Refresh a drifted block in place. Revert-then-reinsert would also work but
            # throws away every hand fix made in the same file since.
            out, i, k = [], 0, 0
            while i < len(lines):
                if lines[i] == BEGIN:
                    while i < len(lines) and lines[i] != END:
                        i += 1
                    i += 1
                    out.extend(ANCHOR_LINES); k += 1
                    continue
                out.append(lines[i]); i += 1
            lines = out
            print(f"refreshed: {rel} ({k} anchor block(s))")
        if BEGIN not in lines:
            lines, n = insert_anchor(lines, reads_registry)
            if n == 0:
                findings.append(f"B  {rel}  needs the CTO-home anchor but has no ROOT= line to replace — add it by hand")
                continue
            print(f"applied: {rel} ({n} anchor site(s))")
        lines = strip_legacy(lines)
        new = "\n".join(lines)
        if new != text:
            open(p, "w").write(new)
            text = new
    elif BEGIN not in text.split("\n"):
        findings.append(f"B  {rel}  missing the canonical CTO-home anchor block (run --apply)")
        continue
    elif ANCHOR not in text:
        findings.append(f"B  {rel}  CTO-home anchor block has DRIFTED from the canonical copy (run --apply)")

    unanchored = [(ln, blk) for ln, blk in bash_blocks(text)
                  if re.search(r"\$CTO_REGISTRY|\$ROOT\b", blk) and BEGIN not in blk.split("\n")]
    if unanchored and apply_mode:
        lines = text.split("\n")
        for ln, blk in reversed(unanchored):        # bottom-up so earlier offsets stay valid
            ins = (["CTO_HOME_REQUIRED=1"] if "$CTO_REGISTRY" in blk else []) + ANCHOR_LINES
            lines[ln - 1:ln - 1] = ins
            print(f"anchored block: {rel}:{ln}")
        open(p, "w").write("\n".join(lines))
        continue
    for ln, blk in unanchored:
        findings.append(
            f"C  {rel}:{ln}  a `!` block uses $ROOT/$CTO_REGISTRY without re-anchoring — "
            f"each block is a separate shell, so the value is empty here."
        )

if findings:
    print(f"lint-skills: {len(findings)} finding(s)\n")
    for f in sorted(findings):
        print("  " + f)
    sys.exit(1)
print("lint-skills: clean — no quoted-heredoc interpolation, no anchor drift, no unanchored blocks.")
PYEOF
