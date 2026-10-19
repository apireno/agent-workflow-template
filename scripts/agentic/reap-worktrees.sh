#!/usr/bin/env bash
# reap-worktrees.sh — report every linked worktree of a repo, and (with --reap) archive+remove only
# the ones that are merged, have no uncommitted edits, and NOTHING LIVE references.
#
#   reap-worktrees.sh <repo> [--reap] [--worktree <path>] [--data-root <dir>] [--archive-root <dir>]
#
# WHY (fleet request 2026-10-19). A census found 21 worktrees / 37 GB, 12 merged and dead — and the
# CTO had removed an engine worktree a live lane was READING, twice in one month. Deleting by "looks
# finished" is the failure; this script refuses whenever any of these still points at a worktree:
#   PROCESS   a process whose cwd is inside it, or whose command line names it
#   WINDOW    an open Terminal window registered to it (.claude/terminal-windows.tsv, checked live)
#   SESSION   a Claude session (transcript touched in the last 2 h) whose latest cwd is inside it
#   PIN       a pin config that names it: .claude/pins.yaml or config/*pin*.y*ml in any registered repo
#   MANIFEST  a data manifest that names it: *.json/*.yaml/*.yml/*.md under the project's data root
#   LANE      a live lane's current sprint dir (brief, plan, notes) that names it
# There is no --force. The only way past a live reference is to end it.
#
# Default is REPORT ONLY. --reap removes the REAPABLE rows through archive-worktree.sh (archive,
# sha256-verify, then remove; a failed archive keeps the worktree). --worktree checks one path and
# exits 3 if it is not reapable (used by /sprint-accept's offer).
# Data root default: ~/<project>-data (project = CTO home name minus -cto). Archive root default:
# <data-root>/wt-archive.
# Exit: 0 ok · 2 usage · 3 the --worktree target is not reapable · 4 a reap failed
set -uo pipefail
REPO=""; REAP=0; ONLY=""; DATA=""; ARCH=""
while [ $# -gt 0 ]; do
    case "$1" in --reap) REAP=1 ;; --worktree) ONLY="${2:-}"; shift ;; --worktree=*) ONLY="${1#--worktree=}" ;;
        --data-root) DATA="${2:-}"; shift ;; --archive-root) ARCH="${2:-}"; shift ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "reap-worktrees: unknown flag '$1'" >&2; exit 2 ;; *) [ -z "$REPO" ] && REPO="$1" || { echo "reap-worktrees: extra argument '$1'" >&2; exit 2; } ;; esac; shift
done
[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "usage: reap-worktrees.sh <repo> [--reap] [--worktree <path>]" >&2; exit 2; }
# --git-common-dir is RELATIVE (".git") unless asked otherwise; resolving it against this script's
# cwd pointed MAIN at whatever repo the caller happened to be in.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"
HOME_CTO="${CTO_HOME:-}"; [ -z "$HOME_CTO" ] && [ -f "$MAIN/.cto-path" ] && HOME_CTO="$(tr -d '[:space:]' < "$MAIN/.cto-path")"
[ -z "$HOME_CTO" ] && [ -f "$HOME/.cto/home" ] && HOME_CTO="$(tr -d '[:space:]' < "$HOME/.cto/home")"
PROJECT="$(basename "${HOME_CTO:-$MAIN}")"; PROJECT="${PROJECT%-cto}"
DATA="${DATA:-$HOME/$PROJECT-data}"; ARCH="${ARCH:-$DATA/wt-archive}"
WINS=""; command -v osascript >/dev/null 2>&1 && WINS="$(osascript -e 'tell application "System Events" to (name of processes) contains "Terminal"' -e '' 2>/dev/null | grep -q true && osascript -e 'tell application "Terminal" to get id of windows' 2>/dev/null | tr ', ' '\n\n' | grep -E '^[0-9]+$')"
CWDS="$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
ARGS="$(ps -axo command= 2>/dev/null)"
export RW_MAIN="$MAIN" RW_ONLY="$ONLY" RW_DATA="$DATA" RW_HOME="$HOME_CTO" RW_WINS="$WINS" RW_CWDS="$CWDS" RW_ARGS="$ARGS"
# Not `PLAN="$(python3 - <<'PY' …)"`: bash 3.2 (macOS) misparses a quoted heredoc inside $( ).
PLANF="$(mktemp "${TMPDIR:-/tmp}/reap.XXXXXX")"; trap 'rm -f "$PLANF"' EXIT
python3 - > "$PLANF" <<'PY'
import os, re, sys, glob, json, time, subprocess
MAIN=os.environ["RW_MAIN"]; ONLY=os.environ["RW_ONLY"]; DATA=os.environ["RW_DATA"]; HOME_CTO=os.environ["RW_HOME"]
WINS=set(os.environ["RW_WINS"].split()); CWDS=[os.path.realpath(p) for p in os.environ["RW_CWDS"].splitlines() if p]
ARGS=os.environ["RW_ARGS"].splitlines()
def git(*a, cwd=MAIN): return subprocess.run(["git","-C",cwd,*a],capture_output=True,text=True)
# Base: what origin/HEAD names (origin/main). "Merged" is judged against BOTH origin/<base> and the
# LOCAL <base> (fleet report 2026-10-19): a fleet that lands locally and pushes rarely has origins that
# lag, and judging only against origin kept every locally-merged worktree alive forever. A worktree
# whose commits are in the local base is safe to reap — the commits stay in the repo; only the
# checkout goes. The row says which ("merged-local" = in local base, not yet pushed).
obase=git("symbolic-ref","--short","refs/remotes/origin/HEAD").stdout.strip()
lbase=obase.split("/",1)[1] if "/" in obase else (git("symbolic-ref","--short","HEAD").stdout.strip())
base=obase or lbase
# worktrees
wts=[]; cur={}
for line in git("worktree","list","--porcelain").stdout.splitlines()+[""]:
    if not line:
        if cur: wts.append(cur); cur={}
        continue
    k,_,v=line.partition(" "); cur[k]=v or True
wts=[w for w in wts if os.path.realpath(w["worktree"])!=MAIN]
if ONLY: wts=[w for w in wts if os.path.realpath(w["worktree"])==os.path.realpath(ONLY)]
# reference sources (read once)
repos=[MAIN]
reg=os.path.join(HOME_CTO,".cto","projects.yaml") if HOME_CTO else ""
if reg and os.path.isfile(reg):
    for b in re.split(r'(?=- name:)', open(reg).read()):
        m=re.search(r'path:\s*(\S+)',b)
        if m: repos.append(m.group(1))
pinfiles=[f for r in set(repos) for f in glob.glob(os.path.join(r,".claude","pins.yaml"))+glob.glob(os.path.join(r,"config","*pin*.y*ml"))]
if HOME_CTO: pinfiles+=glob.glob(os.path.join(HOME_CTO,".cto","*pin*"))
pintext={f:open(f,errors="replace").read() for f in pinfiles if os.path.isfile(f)}
manifests={}
if os.path.isdir(DATA):
    for r,ds,fs in os.walk(DATA):
        if "wt-archive" in ds: ds.remove("wt-archive")
        for f in fs:
            if f.endswith((".json",".yaml",".yml",".md")):
                p=os.path.join(r,f)
                try:
                    if os.path.getsize(p)<5_000_000: manifests[p]=open(p,errors="replace").read()
                except OSError: pass
# live sessions (last 2 h): latest cwd, and their repo's current sprint dir
live_cwds=[]; lane_dirs=[]
for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    try:
        if os.path.getmtime(f)<time.time()-7200: continue
        with open(f,"rb") as fh:
            fh.seek(0,2); n=fh.tell(); fh.seek(max(0,n-131072)); tail=fh.read().decode("utf-8","replace").splitlines()
    except OSError: continue
    for line in reversed(tail):
        if '"cwd"' not in line: continue
        try: c=os.path.realpath(json.loads(line).get("cwd",""))
        except Exception: continue
        live_cwds.append((c, os.path.basename(f)[:8]))
        top=subprocess.run(["git","-C",c,"rev-parse","--show-toplevel"],capture_output=True,text=True).stdout.strip()
        if top and os.path.isfile(os.path.join(top,".claude","current-sprint")):
            sp=open(os.path.join(top,".claude","current-sprint")).read().strip()
            d=os.path.join(top,"docs","sprints",sp)
            if os.path.isdir(d): lane_dirs.append(d)
        break
lane_text={}
for d in set(lane_dirs):
    for p in glob.glob(os.path.join(d,"*.md")):
        lane_text[p]=open(p,errors="replace").read()
def inside(p,w): return p==w or p.startswith(w+os.sep)
for w in wts:
    path=os.path.realpath(w["worktree"]); name=os.path.basename(path); refs=[]
    for c in CWDS:
        if inside(c,path): refs.append(f"PROCESS cwd {c}"); break
    for a in ARGS:
        if path in a and "reap-worktrees" not in a: refs.append("PROCESS args: "+a[:80]); break
    tsv=os.path.join(path,".claude","terminal-windows.tsv")
    if os.path.isfile(tsv):
        state={}
        for line in open(tsv):
            c=line.rstrip("\n").split("\t")
            if len(c)>=4: state[c[1]]=c[3]
        for wid,st in state.items():
            if st=="open" and wid in WINS: refs.append(f"WINDOW {wid} open"); break
    for c,sid in live_cwds:
        if inside(c,path): refs.append(f"SESSION {sid} working in it"); break
    for f,t in pintext.items():
        if path in t or name in t: refs.append(f"PIN {f}"); break
    for f,t in manifests.items():
        if path in t: refs.append(f"MANIFEST {f}"); break
    for f,t in lane_text.items():
        if path in t or name in t: refs.append(f"LANE {f}"); break
    branch=w.get("branch","").replace("refs/heads/","") if isinstance(w.get("branch"),str) else ""
    ref=branch or w.get("HEAD","")
    m_origin = bool(obase) and git("merge-base","--is-ancestor",ref,obase).returncode==0
    m_local = bool(lbase) and git("rev-parse","--verify","-q",lbase).returncode==0 and git("merge-base","--is-ancestor",ref,lbase).returncode==0
    merged = m_origin or m_local
    mstate = "merged" if m_origin else ("merged-local" if m_local else "unmerged")
    st=git("status","--porcelain",cwd=path).stdout.splitlines()
    dirty=sum(1 for l in st if not l.startswith("??")); untracked=sum(1 for l in st if l.startswith("??"))
    try: age=int((time.time()-int(git("log","-1","--format=%ct",cwd=path).stdout.strip() or 0))/86400)
    except ValueError: age=-1
    verdict="REAPABLE" if merged and not dirty and not refs else "KEEP"
    why=([] if verdict=="REAPABLE" else (["not merged into "+lbase+" or "+(obase or "-")] if not merged else []))+([f"{dirty} uncommitted edit(s)"] if dirty else [])+refs
    if verdict=="REAPABLE" and mstate=="merged-local": why=[f"in local {lbase}, not yet on {obase} — commits stay in the repo; push {lbase} soon"]
    print("\t".join([verdict, path, branch or "(detached)", mstate, str(dirty), str(untracked), str(age), " | ".join(why)]))
PY
PLAN="$(cat "$PLANF")"
# WORKTREE shows the name next to the repo (fleet report: the old column cut the leading characters
# off a long absolute path — "rs/apireno/…"); the full path is on the line below each row.
printf '%-9s %-40s %-24s %-12s %5s %5s %4s  %s\n' VERDICT WORKTREE BRANCH MERGED DIRTY UNTRK AGE WHY
printf '%s\n' "$PLAN" | awk -F'\t' 'NF{n=$2; sub(/.*\//,"",n); printf "%-9s %-40s %-24s %-12s %5s %5s %3sd  %s\n          %s\n",$1,n,substr($3,1,24),$4,$5,$6,$7,$8,$2}'
N_REAP=$(printf '%s\n' "$PLAN" | grep -c '^REAPABLE')
echo ""; echo "reap-worktrees: $(printf '%s\n' "$PLAN" | grep -c .) linked worktree(s); $N_REAP reapable; archive root $ARCH"
if [ -n "$ONLY" ]; then
    [ -z "$PLAN" ] && { echo "reap-worktrees: '$ONLY' is not a linked worktree of $MAIN" >&2; exit 2; }
    printf '%s\n' "$PLAN" | grep -q '^REAPABLE' || { [ "$REAP" = 1 ] && echo "reap-worktrees: NOT reaped — see WHY." >&2; exit 3; }
fi
[ "$REAP" = 1 ] || { [ "$N_REAP" -gt 0 ] && echo "  report only. Re-run with --reap to archive and remove the REAPABLE rows."; exit 0; }
RC=0
while IFS=$'\t' read -r V P _; do
    [ "$V" = REAPABLE ] || continue
    bash "$(dirname "$0")/archive-worktree.sh" "$P" --dest "$ARCH" --remove || RC=4
done <<< "$PLAN"
exit $RC
