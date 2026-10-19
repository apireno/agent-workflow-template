#!/usr/bin/env bash
# archive-worktree.sh — copy everything a linked worktree holds that git would NOT preserve, verify
# the copy byte for byte, and only then (with --remove) remove the worktree. Used by land-lane.sh and
# reap-worktrees.sh so there is ONE implementation of "never delete unarchived work".
#
#   archive-worktree.sh <worktree> --dest <archive-root> [--remove] [--dry-run]
#
# What is archived, into <archive-root>/<YYYY-MM-DD>/<worktree-name>/ (dir mode 700):
#   diff-HEAD.patch      `git diff HEAD` (uncommitted tracked changes; normally empty at landing)
#   status.txt           `git status --porcelain --ignored`
#   files/…              every UNTRACKED, non-ignored file, and the IGNORED paths on the project's
#                        archive allowlist (<main-repo>/.claude/land.yaml `archive:` list; default
#                        outputs/ data/). Other ignored paths (venvs, caches, build dirs) are counted,
#                        not copied — they are regenerable.
#   EXCLUDED.txt         secret-shaped files that were deliberately NOT copied (.env*, *.pem, *.key,
#                        *credential*, *secret*): names only.
#   MANIFEST.sha256      sha256 of every copied file, computed from the SOURCE.
# Verification recomputes every hash from the COPY; any mismatch or missing file = failure, and the
# worktree is kept. A failed archive never removes anything.
# Exit: 0 ok · 2 usage · 3 not a linked worktree · 4 archive failed (worktree kept)
set -uo pipefail
WT=""; DEST=""; REMOVE=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in --dest) DEST="${2:-}"; shift ;; --dest=*) DEST="${1#--dest=}" ;; --remove) REMOVE=1 ;; --dry-run) DRY=1 ;;
        -*) echo "archive-worktree: unknown flag '$1'" >&2; exit 2 ;; *) [ -z "$WT" ] && WT="$1" || { echo "archive-worktree: extra argument '$1'" >&2; exit 2; } ;; esac; shift
done
[ -n "$WT" ] && [ -n "$DEST" ] && [ -d "$WT" ] || { echo "usage: archive-worktree.sh <worktree> --dest <archive-root> [--remove] [--dry-run]" >&2; exit 2; }
WT="$(cd "$WT" && pwd -P)"
GD="$(git -C "$WT" rev-parse --git-dir 2>/dev/null)"; CD="$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null)"
[ -n "$GD" ] && [ "$(cd "$WT" && cd "$GD" && pwd -P)" != "$(cd "$WT" && cd "$CD" && pwd -P)" ] || { echo "archive-worktree: $WT is not a LINKED worktree (refusing to touch a main checkout)" >&2; exit 3; }
MAIN="$(cd "$WT" && cd "$CD/.." && pwd -P)"
ALLOW="outputs data"
if [ -f "$MAIN/.claude/land.yaml" ]; then
    A="$(python3 - "$MAIN/.claude/land.yaml" <<'PY'
import re,sys
t=open(sys.argv[1]).read(); m=re.search(r'^archive:\s*\[(.*?)\]', t, re.M)
items=[x.strip().strip("'\"") for x in m.group(1).split(",")] if m else re.findall(r'^\s*-\s*(\S+)', t.split("archive:",1)[1], re.M) if "archive:" in t else []
print(" ".join(i.rstrip("/") for i in items if i))
PY
)"; [ -n "$A" ] && ALLOW="$A"
fi
OUT="$DEST/$(date +%Y-%m-%d)/$(basename "$WT")"
export AW_WT="$WT" AW_OUT="$OUT" AW_ALLOW="$ALLOW" AW_DRY="$DRY"
python3 - <<'PY'
import os, sys, subprocess, hashlib, fnmatch, shutil, stat
WT=os.environ["AW_WT"]; OUT=os.environ["AW_OUT"]; ALLOW=os.environ["AW_ALLOW"].split(); DRY=os.environ["AW_DRY"]=="1"
SECRET=[".env", ".env.*", "*.pem", "*.key", "*credential*", "*secret*", "id_rsa*", "*.p12"]
def git(*a): return subprocess.run(["git","-C",WT,*a],capture_output=True,text=True).stdout
untracked=[l for l in git("ls-files","--others","--exclude-standard","-z").split("\0") if l]
ignored_all=[l for l in git("ls-files","--others","--ignored","--exclude-standard","-z","--directory").split("\0") if l]
def allowed(p): return any(p==a or p.startswith(a.rstrip("/")+"/") for a in ALLOW)
def expand(p):
    full=os.path.join(WT,p)
    if os.path.isdir(full):
        for r,_,fs in os.walk(full):
            for f in fs: yield os.path.relpath(os.path.join(r,f),WT)
    elif os.path.isfile(full): yield p
ignored_keep=[f for p in ignored_all if allowed(p.rstrip("/")) for f in expand(p.rstrip("/"))]
skipped=[p for p in ignored_all if not allowed(p.rstrip("/"))]
cand=sorted(set(untracked+ignored_keep))
secret=lambda p: any(fnmatch.fnmatch(os.path.basename(p),g) for g in SECRET)
copy=[p for p in cand if not secret(p) and os.path.isfile(os.path.join(WT,p)) and not os.path.islink(os.path.join(WT,p))]
excl=[p for p in cand if secret(p)]
diff=git("diff","HEAD")
print(f"archive-worktree: {WT}")
print(f"  copy {len(copy)} file(s) ({sum(os.path.getsize(os.path.join(WT,p)) for p in copy)} bytes): untracked + ignored under [{' '.join(ALLOW)}]")
print(f"  uncommitted tracked diff: {len(diff.splitlines())} line(s)")
if excl: print(f"  NOT copied (secret-shaped, names in EXCLUDED.txt): {', '.join(excl[:6])}{' …' if len(excl)>6 else ''}")
if skipped: print(f"  counted, not copied (ignored, outside the allowlist): {len(skipped)} path(s), e.g. {', '.join(s.rstrip('/') for s in skipped[:4])}")
print(f"  -> {OUT}")
if DRY: sys.exit(0)
def sha(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for b in iter(lambda: f.read(1<<20), b""): h.update(b)
    return h.hexdigest()
try:
    os.makedirs(os.path.join(OUT,"files"),exist_ok=True)
    for d in (os.path.dirname(os.path.dirname(OUT)), os.path.dirname(OUT), OUT): os.chmod(d,0o700)
    open(os.path.join(OUT,"diff-HEAD.patch"),"w").write(diff)
    open(os.path.join(OUT,"status.txt"),"w").write(git("status","--porcelain","--ignored"))
    open(os.path.join(OUT,"EXCLUDED.txt"),"w").write("".join(p+"\n" for p in excl))
    man=[]
    for p in copy:
        src=os.path.join(WT,p); dst=os.path.join(OUT,"files",p)
        os.makedirs(os.path.dirname(dst),exist_ok=True); shutil.copy2(src,dst); man.append((sha(src),p))
    open(os.path.join(OUT,"MANIFEST.sha256"),"w").write("".join(f"{h}  {p}\n" for h,p in man))
    bad=[p for h,p in man if not os.path.isfile(os.path.join(OUT,"files",p)) or sha(os.path.join(OUT,"files",p))!=h]
except OSError as e:
    print(f"archive-worktree: ARCHIVE FAILED ({e}). The worktree is kept."); sys.exit(4)
if bad:
    print(f"archive-worktree: VERIFY FAILED for {len(bad)} file(s), e.g. {bad[:3]}. The worktree is kept."); sys.exit(4)
print(f"  verified: {len(man)} file(s), sha256 match")
PY
RC=$?
[ "$RC" -ne 0 ] && exit "$RC"
[ "$DRY" = 1 ] && exit 0
if [ "$REMOVE" = 1 ]; then
    # --force: the uncommitted/untracked content was just archived and verified above.
    ERRF="$(mktemp "${TMPDIR:-/tmp}/aw.XXXXXX")"
    if git -C "$MAIN" worktree remove --force "$WT" 2>"$ERRF"; then echo "  removed worktree $WT"; rm -f "$ERRF"
    else echo "archive-worktree: archived, but 'git worktree remove' failed: $(cat "$ERRF")"; rm -f "$ERRF"; exit 4; fi
fi
exit 0
