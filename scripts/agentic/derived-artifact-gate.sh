#!/usr/bin/env bash
# derived-artifact-gate.sh — the generic gate for GOVERNED DERIVED ARTIFACTS (ADR-002).
#
# A derived artifact is a committed file (a code graph, a read-site registry, a capability
# matrix, a generated client) that must be a function of a computed input set and may change
# only by its generator. `.claude/generated-paths` + deny-generated-edit.sh govern the
# HAND-EDIT direction. This script governs the STALENESS direction: the inputs changed and
# the generator was not re-run.
#
# The gate NEVER reads the artifact. It asks the repo's generator three questions and hashes
# the answers against a stamp the gate itself wrote at the last regeneration:
#
#   <generator> closure   -> repo-relative paths of the covered set (pure function of the tree)
#   <generator> seams     -> path:line:kind for every seam site anywhere in the repo
#   <generator> roots     -> declared roots as path[:symbol]; each must resolve
#   <generator> build     -> writes the artifact (the gate writes the stamp afterwards)
#
# Four checks, each with the fix command in the message:
#   (a) STALE         closure hash != stamp        -> regenerate + re-stamp
#   (b) LEAK          a seam site outside closure  -> a root leaked past the generator's config
#   (c) DEAD-ROOT     a declared root doesn't resolve -> the generator describes a retired engine
#   (d) NO-GENERATOR  the manifest names a generator that is missing -> never a silent pass
#
# Manifest: <repo>/.claude/derived-artifacts.yaml (see .claude/derived-artifacts.yaml.example).
# INERT when the manifest is absent (exit 0) unless --require is passed (exit 4): a repo the
# registry flags `derived_artifacts: required` must not pass by having nothing declared.
#
# Usage:
#   derived-artifact-gate.sh [--worktree|--staged|--head] [--audit] [--fix] [--require]
#                            [--repo <path>] [--manifest <path>]
#   derived-artifact-gate.sh stamp <artifact-name> [--repo <path>]
#
#   --worktree  hash files on disk (default; the Stop hook, a human at the prompt, verify)
#   --staged    hash the index (the pre-commit hook: what is about to be committed)
#   --head      hash HEAD (CTO session start, CI)
#   --audit     report only; never --fix; exit 3 on ANY finding regardless of mode
#   --fix       for each STALE/NO-STAMP artifact: run `<generator> build`, write the stamp,
#               `git add` the artifact + stamp (scoped add, never -A)
#   stamp NAME  write the stamp for one artifact without running build (generator run by hand)
#
# Mode per artifact (the RIGOR KNOB — the project CTO's call, not the template's):
#   mode: block  (default)  a finding refuses (exit 3)
#   mode: warn              a finding prints the same text as a warning (exit 0)
#   warn_until: YYYY-MM-DD  warn through that date, block after it
#
# Exit: 0 clean (or warn-mode findings only) · 3 refused / findings under --audit
#       4 configuration error (no manifest with --require, unparsable manifest, bad args)

set -uo pipefail

SOURCE="worktree"; AUDIT=0; FIX=0; REQUIRE=0; REPO=""; MANIFEST=""; CMD="check"; STAMP_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --worktree|--staged|--head) SOURCE="${1#--}" ;;
        --audit)    AUDIT=1 ;;
        --fix)      FIX=1 ;;
        --require)  REQUIRE=1 ;;
        --repo)     REPO="$2"; shift ;;
        --manifest) MANIFEST="$2"; shift ;;
        stamp)      CMD="stamp"; STAMP_NAME="${2:-}"; [ -n "$STAMP_NAME" ] && shift ;;
        check)      CMD="check" ;;
        -h|--help)  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "derived-artifact-gate: unknown argument '$1'" >&2; exit 4 ;;
    esac
    shift
done
[ "$CMD" = "stamp" ] && [ -z "$STAMP_NAME" ] && { echo "derived-artifact-gate: stamp needs an artifact name" >&2; exit 4; }
[ "$AUDIT" -eq 1 ] && FIX=0

if [ -z "$REPO" ]; then
    REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || { echo "derived-artifact-gate: repo not found" >&2; exit 4; }
[ -z "$MANIFEST" ] && MANIFEST="$REPO/.claude/derived-artifacts.yaml"

if [ ! -f "$MANIFEST" ]; then
    if [ "$REQUIRE" -eq 1 ]; then
        echo "derived-artifact-gate: $(basename "$REPO") is flagged derived_artifacts: required but has no $MANIFEST"
        echo "  A required repo with nothing declared is not a pass. Author the manifest (see .claude/derived-artifacts.yaml.example)."
        exit 4
    fi
    exit 0   # inert: the repo governs nothing
fi

export DAG_REPO="$REPO" DAG_MANIFEST="$MANIFEST" DAG_SOURCE="$SOURCE" DAG_AUDIT="$AUDIT" \
       DAG_FIX="$FIX" DAG_CMD="$CMD" DAG_STAMP_NAME="$STAMP_NAME" DAG_SELF="$0"

python3 - <<'PY'
import os, re, sys, subprocess, hashlib, datetime, shlex, stat

REPO = os.environ["DAG_REPO"]; MANIFEST = os.environ["DAG_MANIFEST"]; SOURCE = os.environ["DAG_SOURCE"]
AUDIT = os.environ["DAG_AUDIT"] == "1"; FIX = os.environ["DAG_FIX"] == "1"
CMD = os.environ["DAG_CMD"]; STAMP_NAME = os.environ["DAG_STAMP_NAME"]; SELF = os.environ["DAG_SELF"]
REL_SELF = os.path.relpath(SELF, REPO) if SELF.startswith(REPO) else SELF

# ---------- manifest ----------
def parse_manifest(path):
    text = open(path, encoding="utf-8").read()
    try:
        import yaml  # optional; the subset below is what the mini-parser handles
        d = yaml.safe_load(text) or {}
        return d
    except ImportError:
        pass
    d = {"artifacts": [], "boundary": {}}
    top = None; cur = None
    for raw in text.splitlines():
        line = raw.split(" #", 1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        s = line.strip()
        if indent == 0 and s.endswith(":"):
            top = s[:-1]; cur = None
            d.setdefault(top, [] if top == "artifacts" else {})
            continue
        if top == "artifacts":
            if s.startswith("- "):
                cur = {}; d["artifacts"].append(cur); s = s[2:].strip()
            if cur is not None and ":" in s:
                k, v = s.split(":", 1); cur[k.strip()] = v.strip().strip("'\"")
        elif top and ":" in s:
            k, v = s.split(":", 1); d[top][k.strip()] = v.strip().strip("'\"")
    return d

try:
    M = parse_manifest(MANIFEST)
except Exception as e:
    print(f"derived-artifact-gate: cannot parse {MANIFEST}: {e}"); sys.exit(4)
ARTS = M.get("artifacts") or []
if not isinstance(ARTS, list) or not ARTS:
    print(f"derived-artifact-gate: {MANIFEST} declares no artifacts (an empty manifest is a configuration error, not a pass)"); sys.exit(4)

# ---------- git helpers ----------
def git(*a, check=False):
    r = subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout

IN_GIT = subprocess.run(["git", "-C", REPO, "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True).stdout.strip() == "true"
if SOURCE != "worktree" and not IN_GIT:
    print(f"derived-artifact-gate: --{SOURCE} needs a git repository; {REPO} is not one"); sys.exit(4)

_blob_cache = {}
def load_tree():
    """Map repo-relative path -> blob sha for the chosen source."""
    if SOURCE == "staged":
        for line in git("ls-files", "-s").splitlines():
            meta, p = line.split("\t", 1); _blob_cache[p] = meta.split()[1]
    elif SOURCE == "head":
        for line in git("ls-tree", "-r", "HEAD").splitlines():
            meta, p = line.split("\t", 1); _blob_cache[p] = meta.split()[2]
load_tree()

def blob(rel):
    if SOURCE == "worktree":
        p = os.path.join(REPO, rel)
        if not os.path.isfile(p): return None
        h = hashlib.sha1(); data = open(p, "rb").read()
        h.update(f"blob {len(data)}\0".encode()); h.update(data); return h.hexdigest()
    return _blob_cache.get(rel)

def content(rel):
    if SOURCE == "worktree":
        p = os.path.join(REPO, rel)
        return open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else None
    spec = f":{rel}" if SOURCE == "staged" else f"HEAD:{rel}"
    r = subprocess.run(["git", "-C", REPO, "show", spec], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def exists(rel):
    return blob(rel) is not None if SOURCE != "worktree" else os.path.exists(os.path.join(REPO, rel))

def norm(p):
    p = p.strip()
    if not p: return ""
    if os.path.isabs(p):
        p = os.path.relpath(p, REPO)
    return p[2:] if p.startswith("./") else p

# ---------- generator ----------
def gen_cmd(gen):
    """How to invoke the generator. Missing file -> None. Non-executable .py/.sh get an interpreter."""
    p = os.path.join(REPO, gen)
    if not os.path.isfile(p): return None
    if os.access(p, os.X_OK): return [p]
    if p.endswith(".py"): return [sys.executable, p]
    if p.endswith(".sh"): return ["bash", p]
    return None

def run_gen(cmd, sub):
    r = subprocess.run(cmd + [sub], cwd=REPO, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"`{' '.join(shlex.quote(c) for c in cmd)} {sub}` exited {r.returncode}: {r.stderr.strip()[:300]}")
    return [l for l in (x.rstrip() for x in r.stdout.splitlines()) if l and not l.startswith("#")]

def stamp_path(art_path):
    full = os.path.join(REPO, art_path)
    if art_path.endswith("/") or os.path.isdir(full):
        return os.path.join(art_path.rstrip("/"), ".stamp")
    return art_path + ".stamp"

def closure_hash(pairs):
    h = hashlib.sha256()
    for p, b in pairs:
        h.update(f"{p} {b or 'MISSING'}\n".encode())
    return h.hexdigest()

def read_stamp(rel):
    txt = content(rel)
    if txt is None: return None
    st = {"files": {}}
    for line in txt.splitlines():
        if line.startswith("#") or not line.strip(): continue
        if line.startswith("closure=") or line.startswith("generator="):
            k, v = line.split("=", 1); st[k] = v.strip()
        else:
            parts = line.rsplit(" ", 1)
            if len(parts) == 2: st["files"][parts[0]] = parts[1]
    return st

def write_stamp(rel, pairs, gen_blob):
    full = os.path.join(REPO, rel)
    os.makedirs(os.path.dirname(full) or ".", exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write("# derived-artifact stamp — written by derived-artifact-gate.sh; do not edit.\n")
        f.write("# closure = sha256 over the sorted (path, blob) pairs below; generator = blob of the generator.\n")
        f.write(f"closure={closure_hash(pairs)}\n")
        f.write(f"generator={gen_blob or 'MISSING'}\n")
        for p, b in pairs:
            f.write(f"{p} {b or 'MISSING'}\n")

def effective_mode(art):
    mode = str(art.get("mode", "block")).lower()
    wu = art.get("warn_until")
    if wu:
        try:
            until = datetime.date.fromisoformat(str(wu))
            mode = "warn" if datetime.date.today() <= until else "block"
        except ValueError:
            pass
    return mode if mode in ("block", "warn") else "block"

# ---------- the checks ----------
def check_artifact(art):
    """Return (findings, closure_pairs, gen_blob). Each finding: (STATE, detail)."""
    name = art.get("name") or "?"; path = norm(str(art.get("path", ""))); gen = norm(str(art.get("generator", "")))
    findings = []
    if not path or not gen:
        return [("BAD-ENTRY", "manifest entry needs name, path and generator")], [], None
    cmd = gen_cmd(gen)
    if cmd is None:
        return [("NO-GENERATOR", f"generator '{gen}' is missing or not runnable — a declared artifact with no generator never passes")], [], None
    gen_blob = blob(gen) or (hashlib.sha1(open(os.path.join(REPO, gen), "rb").read()).hexdigest())
    try:
        closure = sorted({norm(l) for l in run_gen(cmd, "closure")} - {""})
        seams = run_gen(cmd, "seams")
        roots = run_gen(cmd, "roots")
    except RuntimeError as e:
        return [("GEN-ERROR", str(e))], [], gen_blob
    pairs = [(p, blob(p)) for p in closure]
    cset = set(closure)

    # (c) dead root
    for r in roots:
        rp, _, sym = r.partition(":")
        rp = norm(rp)
        if not exists(rp):
            findings.append(("DEAD-ROOT", f"root '{r}' — path does not exist. The generator describes an engine the repo no longer has; update its roots."))
        elif sym:
            txt = content(rp) or ""
            if not re.search(r"\b" + re.escape(sym) + r"\b", txt):
                findings.append(("DEAD-ROOT", f"root '{r}' — symbol '{sym}' not found in {rp}. Update the generator's roots."))

    # (b) seam leak
    leaks = []
    for s in seams:
        parts = s.split(":", 2)
        sp = norm(parts[0])
        if sp and sp not in cset:
            leaks.append(s)
    for s in leaks[:8]:
        parts = s.split(":", 2); kind = parts[2] if len(parts) > 2 else "seam"
        findings.append(("LEAK", f"{parts[0]}:{parts[1] if len(parts)>1 else '?'} declares a '{kind}' seam outside the covered set — a root leaked past the generator's config. Add the root, or add the path to the generator's excludes if it is a test/wrapper/adapter."))
    if len(leaks) > 8:
        findings.append(("LEAK", f"... and {len(leaks)-8} more seam sites outside the closure"))

    # (a) stale
    sp = stamp_path(path)
    st = read_stamp(sp)
    shown = [os.path.basename(c) if i == 0 and len(cmd) > 1 else os.path.relpath(c, REPO) if c.startswith(REPO) else c for i, c in enumerate(cmd)]
    fix_cmd = f"{' '.join(shown)} build && bash {REL_SELF} stamp {name}   (or: bash {REL_SELF} --fix)"
    if st is None:
        findings.append(("NO-STAMP", f"'{path}' has never been stamped ({sp} missing). Run: {fix_cmd}"))
    else:
        if st.get("generator") and gen_blob and st["generator"] != gen_blob:
            findings.append(("STALE", f"the generator itself changed since the last build. Run: {fix_cmd}"))
        elif st.get("closure") != closure_hash(pairs):
            old = st.get("files", {}); new = dict(pairs)
            changed = sorted(p for p in new if p in old and old[p] != (new[p] or "MISSING"))
            added = sorted(p for p in new if p not in old); removed = sorted(p for p in old if p not in new)
            bits = []
            if changed: bits.append(f"{len(changed)} changed")
            if added: bits.append(f"{len(added)} added")
            if removed: bits.append(f"{len(removed)} removed")
            names = (changed + added + removed)[:5]
            more = len(changed) + len(added) + len(removed) - len(names)
            detail = ", ".join(bits) + ": " + ", ".join(names) + (f" (+{more} more)" if more > 0 else "")
            findings.append(("STALE", f"closure changed ({detail}) and '{name}' was not regenerated. Run: {fix_cmd}"))
    return findings, pairs, gen_blob

# ---------- stamp subcommand ----------
if CMD == "stamp":
    art = next((a for a in ARTS if a.get("name") == STAMP_NAME), None)
    if art is None:
        print(f"derived-artifact-gate: no artifact named '{STAMP_NAME}' in {MANIFEST}"); sys.exit(4)
    path = norm(str(art["path"])); gen = norm(str(art["generator"])); cmd = gen_cmd(gen)
    if cmd is None:
        print(f"derived-artifact-gate: generator '{gen}' missing"); sys.exit(3)
    closure = sorted({norm(l) for l in run_gen(cmd, "closure")} - {""})
    pairs = [(p, blob(p)) for p in closure]
    sp = stamp_path(path); write_stamp(sp, pairs, blob(gen))
    print(f"stamped {STAMP_NAME}: {sp} ({len(pairs)} files in closure, source={SOURCE})")
    sys.exit(0)

# ---------- check ----------
print(f"derived-artifact-gate: {os.path.basename(REPO)} (source={SOURCE}{', audit' if AUDIT else ''}{', fix' if FIX else ''})")
print(f"  {'ARTIFACT':<24} {'MODE':<6} {'STATE':<13} DETAIL")
print(f"  {'--------':<24} {'----':<6} {'-----':<13} ------")
refused = 0; warned = 0; total_findings = 0
for art in ARTS:
    name = str(art.get("name") or "?"); mode = effective_mode(art)
    findings, pairs, gen_blob = check_artifact(art)
    if FIX and any(f[0] in ("STALE", "NO-STAMP") for f in findings):
        path = norm(str(art["path"])); gen = norm(str(art["generator"])); cmd = gen_cmd(gen)
        try:
            run_gen(cmd, "build")
            # Re-walk after build: the closure is what the tree now says, hashed from the WORKTREE
            # (what `git add` will stage). A --staged re-check after adding must then match.
            closure = sorted({norm(l) for l in run_gen(cmd, "closure")} - {""})
            wt = []
            for p in closure:
                fp = os.path.join(REPO, p)
                if os.path.isfile(fp):
                    data = open(fp, "rb").read(); h = hashlib.sha1(); h.update(f"blob {len(data)}\0".encode()); h.update(data); wt.append((p, h.hexdigest()))
                else:
                    wt.append((p, None))
            gdata = open(os.path.join(REPO, gen), "rb").read(); gh = hashlib.sha1(); gh.update(f"blob {len(gdata)}\0".encode()); gh.update(gdata)
            sp = stamp_path(path); write_stamp(sp, wt, gh.hexdigest())
            if IN_GIT:
                subprocess.run(["git", "-C", REPO, "add", "--", path.rstrip("/"), sp], capture_output=True)
            findings = [f for f in findings if f[0] not in ("STALE", "NO-STAMP")]
            print(f"  {name:<24} {mode:<6} {'FIXED':<13} rebuilt + stamped + staged ({len(wt)} files in closure)")
        except RuntimeError as e:
            findings.append(("GEN-ERROR", f"--fix failed: {e}"))
    if not findings:
        print(f"  {name:<24} {mode:<6} {'OK':<13}")
        continue
    for state, detail in findings:
        total_findings += 1
        print(f"  {name:<24} {mode:<6} {state:<13} {detail}")
    if mode == "block": refused += 1
    else: warned += 1

print("")
if total_findings == 0:
    print("derived-artifact-gate: clean")
    sys.exit(0)
if AUDIT:
    print(f"derived-artifact-gate: {total_findings} finding(s) (audit — reported, not refused)")
    sys.exit(3)
if refused:
    print(f"REFUSED: {refused} artifact(s) in block mode have findings. Fix as shown, or set `mode: warn` in {os.path.relpath(MANIFEST, REPO)} (the project CTO's rigor call).")
    sys.exit(3)
print(f"WARN: {warned} artifact(s) in warn mode have findings — reported, not refused.")
sys.exit(0)
PY
