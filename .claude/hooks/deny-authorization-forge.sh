#!/bin/bash
# deny-authorization-forge.sh — PreToolUse guard (Edit|Write|NotebookEdit and Bash). Dev lanes do not
# write CEO approvals; the CTO does.
#
# CEO ruling 2026-10-30: the CEO approves in the CTO conversation, and the CTO records the CEO's words
# verbatim in <sprint-dir>/CEO-AUTHORIZATION.md (scripts/agentic/record-approval.sh). So a session
# rooted in a CTO home (named agent-workflow-template or *-cto, or carrying .cto/projects.yaml) may
# write the file. Any other session is a dev lane, and the write is blocked: a direct Edit/Write; a
# shell redirect / tee / sed -i / cp / mv / rm into it; Python in a heredoc that opens it for writing.
# (The file name is historical; settings across the fleet already wire it, so it keeps the name.)
#
# It matches what a command DOES, not what its text MENTIONS: each command line is tokenized with
# shlex, and a heredoc body is commands only when it is fed to a shell; otherwise it is data.
# Reading the file and running check-authorization.sh stay free everywhere.
set -uo pipefail
INPUT="$(cat)"
python3 - "$INPUT" <<'PY'
import json, os, re, shlex, sys
d = json.loads(sys.argv[1] or "{}"); ti = d.get("tool_input") or {}
FILE = "CEO-AUTHORIZATION.md"
def project_root():
    p = os.path.abspath(os.environ.get("CLAUDE_PROJECT_DIR") or d.get("cwd") or os.getcwd())
    while p != "/" and not os.path.exists(os.path.join(p, ".git")):
        p = os.path.dirname(p)
    return p
root = project_root(); name = os.path.basename(root)
if name == "agent-workflow-template" or name.endswith("-cto") or os.path.isfile(os.path.join(root, ".cto", "projects.yaml")):
    sys.exit(0)   # a CTO home: the CTO records the CEO's words here
def block(why):
    sys.stderr.write("BLOCKED (CEO approval): " + why + "\n"
        "Dev lanes do not record CEO approvals; the CTO records the CEO's words from the CTO\n"
        "conversation (scripts/agentic/record-approval.sh). Stop at the gate, write\n"
        "`signature-pending: <gate>` in dev-report.md, and let the CTO ask the CEO.\n")
    sys.exit(2)
target = ti.get("file_path") or ti.get("notebook_path") or ""
if os.path.basename(target) == FILE:
    block("sessions do not write " + FILE + ".")
cmd = ti.get("command") or ""
if not cmd: sys.exit(0)

# 1. Split heredoc bodies out. Body of a heredoc fed to a shell = more commands; otherwise = data.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
lines = cmd.split("\n"); cmdlines, datas = [], []
i = 0
while i < len(lines):
    ln = lines[i]; cmdlines.append(ln)
    for m in re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", ln):
        tag = m.group(2); body = []; i += 1
        while i < len(lines) and lines[i].strip() != tag:
            body.append(lines[i]); i += 1
        first = (ln.strip().split() or [""])[0]
        (cmdlines.extend(body) if os.path.basename(first) in SHELLS else datas.append("\n".join(body)))
    i += 1

# 2. Tokenize each command line; find commands and their arguments.
WRAP = {"bash", "sh", "zsh", "dash", "env", "exec", "nohup", "time", "xargs", "command", "sudo", "nice"}
SEP = {";", "&&", "||", "|", "&", "(", ")", "|&"}
def commands(line):
    try:
        lx = shlex.shlex(line, posix=True, punctuation_chars=";&|()<>"); lx.whitespace_split = True
        toks = list(lx)
    except ValueError:
        return None
    out, cur = [], []
    for t in toks:
        if t in SEP: (out.append(cur) if cur else None); cur = []
        else: cur.append(t)
    if cur: out.append(cur)
    return out
for line in cmdlines:
    cmds = commands(line)
    if cmds is None:   # unparseable line: conservative textual check of THIS line
        if re.search(r"(>>?|\b(tee|cp|mv|rm)\b[^;&|]*)\s*\S*" + re.escape(FILE), line):
            block("that writes " + FILE + ".")
        continue
    for c in cmds:
        # strip leading VAR=val and wrappers (and `script -q /dev/null` style wrappers)
        k = 0
        while k < len(c):
            t = c[k]; b = os.path.basename(t)
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t): k += 1; continue
            if b in WRAP: k += 1; continue
            if b == "script":
                k += 1
                while k < len(c) and c[k].startswith("-"): k += 1
                k += 1  # the typescript file
                continue
            break
        args = c[k:]
        for j, t in enumerate(args):
            if t in (">", ">>") and j + 1 < len(args) and os.path.basename(args[j + 1]) == FILE:
                block("that redirects into " + FILE + ".")
        prog = os.path.basename(args[0]) if args else ""
        if prog in ("tee", "cp", "mv", "rm", "truncate", "install", "ln", "dd") or (prog == "sed" and any(a.startswith("-i") for a in args)):
            if any(os.path.basename(a) == FILE or a.endswith("of=" + FILE) for a in args[1:]):
                block("that " + prog + " writes " + FILE + ".")
# 3. Data heredocs: only real write code counts (open(..., 'w'|'a'), write_text, Path(...).write)
for body in datas:
    if FILE in body and re.search(r"open\([^)]*" + re.escape(FILE) + r"[^)]*,\s*['\"][wa]|write_text|write_bytes", body):
        block("that code writes " + FILE + ".")
sys.exit(0)
PY
