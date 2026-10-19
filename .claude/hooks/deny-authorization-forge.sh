#!/bin/bash
# deny-authorization-forge.sh — PreToolUse guard (Edit|Write|NotebookEdit and Bash), in dev repos
# AND the CTO home. A session must never write a CEO authorization, for itself or for anyone.
#
# CEO-AUTHORIZATION.md records the CEO's own words for a human-only gate; only the CEO writes it,
# with scripts/agentic/ceo-authorize.sh in a real terminal. This hook closes the agent paths to it:
# a direct Edit/Write; a shell redirect / tee / sed -i / cp / mv / rm into it; Python in a heredoc that
# opens it for writing; and RUNNING the recorder (which an agent could drive through a faked pty).
#
# It matches what a command DOES, not what its text MENTIONS (fleet report 2026-10-19: the first
# version blocked any command naming the recorder, including prose inside a heredoc — a memo that
# tells the CEO which command to run). Each command line is tokenized with shlex; the recorder is
# an invocation only at a COMMAND POSITION (line start, after ; && || | & ( , or behind a wrapper:
# bash/sh/zsh/env/exec/nohup/time/xargs/script). A heredoc body is commands only when it is fed to a
# shell; otherwise it is data. Reading the file and running check-authorization.sh stay free.
set -uo pipefail
INPUT="$(cat)"
python3 - "$INPUT" <<'PY'
import json, os, re, shlex, sys
d = json.loads(sys.argv[1] or "{}"); ti = d.get("tool_input") or {}
REC = "ceo-authorize.sh"; FILE = "CEO-AUTHORIZATION.md"
def block(why):
    sys.stderr.write("BLOCKED (CEO authorization): " + why + "\n"
        "Only the CEO records an authorization, in their own words, by running in Terminal:\n"
        "  scripts/agentic/ceo-authorize.sh <sprint-dir> <gate> \"<the CEO's words>\"\n"
        "Hand the CEO that command. Never write the record or a sign-off token on anyone's behalf.\n")
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
    if cmds is None:   # unparseable line: fall back to a conservative textual check of THIS line
        if re.search(r"(^|[;&|(]\s*|\b(bash|sh|zsh|exec|env|script)\s+(\S+\s+)*)\S*" + re.escape(REC), line):
            block("this runs ceo-authorize.sh; it is the CEO's own command.")
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
        if k < len(c) and os.path.basename(c[k]) == REC:
            block("that runs ceo-authorize.sh; it is the CEO's own command.")
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
