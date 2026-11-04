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
#   (d) NO-GENERATOR  the manifest names a generator that is missing -> never a silent pass;
#                     refuses in EVERY mode (warn included): a derived artifact nobody can rebuild
#                     is not derived (fleet report 2026-11-04)
#   (e) BYTE-DRIFT    with --bytes: the gate rebuilds the artifact in place, compares bytes with what
#                     is committed, restores the original, and refuses on any difference. The stamp
#                     proves the INPUTS were unchanged; only a rebuild proves the BYTES are what the
#                     generator makes from them (BUG class: a stale report passed on a matching stamp).
#                     Opt out per artifact: `bytes_check: off` + `bytes_reason: <why>` (a reason is
#                     required; `off` without one is a BAD-ENTRY). /sprint-accept and land-lane pass it.
#   (f) BLIND         `seam_probes: <file>` names a TSV the PROJECT maintains, independent of the
#                     scanner: `kind<TAB>regex[<TAB>pathglob]`. A probe kind with matches in the code
#                     but zero sites of that kind in `<generator> seams` means the scanner cannot see
#                     a seam the code uses (fleet report 2026-11-04: run-service keys).
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
#   --bytes     also run the BYTE-DRIFT rebuild check (e) — accept and landing use it
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

BYTES=0; SOURCE="worktree"; AUDIT=0; FIX=0; REQUIRE=0; REPO=""; MANIFEST=""; CMD="check"; STAMP_NAME=""; REPIN_SHA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --worktree|--staged|--head) SOURCE="${1#--}" ;;
        --audit)    AUDIT=1 ;;
        --fix)      FIX=1 ;;
        --bytes)    BYTES=1 ;;
        --require)  REQUIRE=1 ;;
        --repo)     REPO="$2"; shift ;;
        --manifest) MANIFEST="$2"; shift ;;
        stamp)      CMD="stamp"; STAMP_NAME="${2:-}"; [ -n "$STAMP_NAME" ] && shift ;;
        repin)      CMD="repin"; STAMP_NAME="${2:-}"; REPIN_SHA="${3:-}"; [ -n "$STAMP_NAME" ] && shift; [ -n "$REPIN_SHA" ] && shift ;;
        check)      CMD="check" ;;
        -h|--help)  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "derived-artifact-gate: unknown argument '$1'" >&2; exit 4 ;;
    esac
    shift
done
[ "$CMD" = "stamp" ] && [ -z "$STAMP_NAME" ] && { echo "derived-artifact-gate: stamp needs an artifact name" >&2; exit 4; }
[ "$CMD" = "repin" ] && { [ -z "$STAMP_NAME" ] || [ -z "$REPIN_SHA" ]; } && { echo "derived-artifact-gate: repin needs an artifact name and a sha" >&2; exit 4; }
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
       DAG_FIX="$FIX" DAG_CMD="$CMD" DAG_STAMP_NAME="$STAMP_NAME" DAG_SELF="$0" DAG_REPIN_SHA="$REPIN_SHA" DAG_BYTES="$BYTES"

python3 - <<'PY'
import os, re, sys, json, subprocess, hashlib, datetime, shlex, stat

REPO = os.environ["DAG_REPO"]; MANIFEST = os.environ["DAG_MANIFEST"]; SOURCE = os.environ["DAG_SOURCE"]
AUDIT = os.environ["DAG_AUDIT"] == "1"; FIX = os.environ["DAG_FIX"] == "1"
CMD = os.environ["DAG_CMD"]; STAMP_NAME = os.environ["DAG_STAMP_NAME"]; SELF = os.environ["DAG_SELF"]
REPIN_SHA = os.environ.get("DAG_REPIN_SHA", "")
BYTES = os.environ.get("DAG_BYTES") == "1"
HARD = ("NO-GENERATOR", "BAD-ENTRY")   # refuse in every mode
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

def run_gen(cmd, sub, extra=()):
    r = subprocess.run(cmd + [sub] + list(extra), cwd=REPO, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"`{' '.join(shlex.quote(c) for c in cmd + [sub] + list(extra))}` exited {r.returncode}: {r.stderr.strip()[:300]}")
    return [l for l in (x.rstrip() for x in r.stdout.splitlines()) if l and not l.startswith("#")]

# ---------- pins (2026-10-19) ----------
# An artifact that MEASURES a sibling repo must be rebuilt at the sibling commit its lock file pins,
# never from the sibling's working tree: `--fix` used to call `build` bare, the generator then read
# whatever the sibling had on disk (mid-sprint dirt included), and the stamped artifact described an
# engine state that existed in no commit. Manifest keys (flat, so no YAML library is needed):
#   pin_lock: <repo-relative lock file>   pin_key: <JSON key, or empty for a bare-sha file>
#   pin_arg:  <flag the generator takes>  (default --rev)
#   external: true                         (measures a sibling; with no pin_lock, --fix refuses)
SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
def truthy(v): return str(v).strip().lower() in ("1", "true", "yes", "on")
def pinned_sha(art):
    lock = norm(str(art.get("pin_lock") or ""))
    if not lock: return None
    full = os.path.join(REPO, lock)
    if not os.path.isfile(full): raise RuntimeError(f"pin_lock '{lock}' does not exist")
    key = str(art.get("pin_key") or "").strip()
    txt = open(full, encoding="utf-8", errors="replace").read()
    if key:
        try: val = json.loads(txt).get(key, "")
        except Exception as e: raise RuntimeError(f"pin_lock '{lock}' is not JSON ({e}); set pin_key empty for a bare-sha file")
        m = SHA_RE.search(str(val))
    else:
        m = SHA_RE.search(txt)
    if not m: raise RuntimeError(f"no sha found in pin_lock '{lock}'" + (f" under key '{key}'" if key else ""))
    return m.group(0)
def build_args(art, sha=None):
    """Extra args for `build`: the pin flag + sha; [] if not pinned; raises if external and unpinned."""
    sha = sha or pinned_sha(art)
    if sha: return [str(art.get("pin_arg") or "--rev"), sha]
    if truthy(art.get("external", "")):
        raise RuntimeError("UNPINNED: this artifact measures a sibling repo (external: true) but declares no pin_lock — "
                           "a build would read the sibling's working tree. Declare pin_lock (and pin_key), or repin it.")
    return []

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

    # (f) scanner blindness: project-declared probes vs the kinds the generator reports
    probes = norm(str(art.get("seam_probes") or ""))
    if probes:
        pf = os.path.join(REPO, probes)
        if not os.path.isfile(pf):
            findings.append(("BAD-ENTRY", f"seam_probes '{probes}' does not exist"))
        else:
            seen = {s.split(":", 2)[2] for s in seams if s.count(":") >= 2}
            tracked = (git("ls-files", "--cached", "--others", "--exclude-standard") if SOURCE == "worktree" else git("ls-files")).splitlines() if IN_GIT else [os.path.relpath(os.path.join(dp, f), REPO) for dp, _, fs in os.walk(REPO) for f in fs if "/.git/" not in dp]
            import fnmatch
            for ln in open(pf, encoding="utf-8"):
                if not ln.strip() or ln.lstrip().startswith("#"): continue
                cols = ln.rstrip("\n").split("\t")
                if len(cols) < 2: findings.append(("BAD-ENTRY", f"seam_probes line needs kind<TAB>regex: {ln.strip()[:60]}")); continue
                kind, rx = cols[0].strip(), cols[1]; glob = cols[2].strip() if len(cols) > 2 and cols[2].strip() else "*"
                if kind in seen: continue
                try: cre = re.compile(rx)
                except re.error as e: findings.append(("BAD-ENTRY", f"seam_probes '{kind}': bad regex: {e}")); continue
                hits = []
                for f in tracked:
                    if not fnmatch.fnmatch(f, glob) or f == probes: continue
                    txt = content(f)
                    if not txt: continue
                    for i, l in enumerate(txt.splitlines(), 1):
                        if cre.search(l): hits.append(f"{f}:{i}"); break
                    if len(hits) >= 50: break
                if hits:
                    findings.append(("BLIND", f"the code has '{kind}' seams ({len(hits)}{'+' if len(hits) >= 50 else ''} file(s), first {hits[0]}) but `{os.path.basename(gen)} seams` reports none of that kind — teach the scanner the kind, or drop the probe if it is not a seam"))
    bc = str(art.get("bytes_check", "on")).lower()
    if bc in ("off", "false", "no") and not str(art.get("bytes_reason") or "").strip():
        findings.append(("BAD-ENTRY", "bytes_check: off needs bytes_reason: <why the rebuild check is skipped>"))

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

def rebuild_and_stamp(art, sha=None):
    """Run the generator's build (at the pin, if any), then stamp from the worktree and stage."""
    path = norm(str(art["path"])); gen = norm(str(art["generator"])); cmd = gen_cmd(gen)
    if cmd is None: raise RuntimeError(f"generator '{gen}' missing")
    extra = build_args(art, sha)
    run_gen(cmd, "build", extra)
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
        paths = [path.rstrip("/"), sp]
        lock = norm(str(art.get("pin_lock") or ""))
        if lock: paths.append(lock)
        subprocess.run(["git", "-C", REPO, "add", "--"] + paths, capture_output=True)
    how = f"at pin {extra[1][:12]}" if extra else "(unpinned)"
    return len(wt), how

def byte_drift(art):
    """Rebuild in place, compare with what is on disk now, restore. Returns a finding or None."""
    path = norm(str(art["path"])); cmd = gen_cmd(norm(str(art["generator"])))
    full = os.path.join(REPO, path.rstrip("/"))
    def snap(root):
        out = {}
        if os.path.isfile(root):
            out[""] = open(root, "rb").read()
        elif os.path.isdir(root):
            for dp, _, fs in os.walk(root):
                for f in fs:
                    fp = os.path.join(dp, f); out[os.path.relpath(fp, root)] = open(fp, "rb").read()
        return out
    before = snap(full)
    try:
        run_gen(cmd, "build", build_args(art, None))
        after = snap(full)
    except RuntimeError as e:
        after = None; err = str(e)
    finally:
        # restore exactly what was there: the check never changes the tree
        import shutil
        if os.path.isdir(full) and not os.path.isfile(full): shutil.rmtree(full)
        elif os.path.isfile(full): os.remove(full)
        for rel, data in before.items():
            fp = full if rel == "" else os.path.join(full, rel)
            os.makedirs(os.path.dirname(fp) or ".", exist_ok=True)
            open(fp, "wb").write(data)
    if after is None:
        return ("GEN-ERROR", f"--bytes rebuild failed: {err}")
    if after == before:
        return None
    diff = sorted(set(before) ^ set(after)) + sorted(k for k in set(before) & set(after) if before[k] != after[k])
    names = ", ".join((d or os.path.basename(path)) for d in diff[:4]) + (f" (+{len(diff)-4} more)" if len(diff) > 4 else "")
    return ("BYTE-DRIFT", f"a rebuild produces different bytes than the committed '{path}' ({names}) — the stamp matched the inputs, the artifact is still stale. Rebuild and commit it")

# ---------- repin subcommand: the deliberate act of MOVING a pin ----------
if CMD == "repin":
    art = next((a for a in ARTS if a.get("name") == STAMP_NAME), None)
    if art is None:
        print(f"derived-artifact-gate: no artifact named '{STAMP_NAME}' in {MANIFEST}"); sys.exit(4)
    if not norm(str(art.get("pin_lock") or "")):
        print(f"derived-artifact-gate: '{STAMP_NAME}' declares no pin_lock — nothing to repin."); sys.exit(4)
    try:
        before = pinned_sha(art)
        n, how = rebuild_and_stamp(art, REPIN_SHA)
        after = pinned_sha(art)
    except RuntimeError as e:
        print(f"derived-artifact-gate: repin failed: {e}"); sys.exit(3)
    if not after.startswith(REPIN_SHA[:len(after)]) and not REPIN_SHA.startswith(after):
        print(f"derived-artifact-gate: the generator built at {REPIN_SHA} but its lock still says {after} — "
              "the generator must rewrite its own lock on build. Artifact NOT trustworthy."); sys.exit(3)
    print(f"repinned {STAMP_NAME}: {before[:12]} -> {after[:12]}; rebuilt + stamped + staged ({n} files in closure)")
    sys.exit(0)

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
        try:
            n, how = rebuild_and_stamp(art)
            findings = [f for f in findings if f[0] not in ("STALE", "NO-STAMP")]
            print(f"  {name:<24} {mode:<6} {'FIXED':<13} rebuilt {how} + stamped + staged ({n} files in closure)")
        except RuntimeError as e:
            st = "UNPINNED" if str(e).startswith("UNPINNED") else "GEN-ERROR"
            findings.append((st, f"--fix refused: {e}" if st == "UNPINNED" else f"--fix failed: {e}"))
    if BYTES and not FIX and not any(f[0] in HARD + ("GEN-ERROR",) for f in findings) \
            and str(art.get("bytes_check", "on")).lower() not in ("off", "false", "no"):
        bd = byte_drift(art)
        if bd: findings.append(bd)
    if not findings:
        print(f"  {name:<24} {mode:<6} {'OK':<13}")
        continue
    for state, detail in findings:
        total_findings += 1
        print(f"  {name:<24} {mode:<6} {state:<13} {detail}")
    if mode == "block" or any(f[0] in HARD for f in findings): refused += 1
    else: warned += 1

print("")
if total_findings == 0:
    print("derived-artifact-gate: clean")
    sys.exit(0)
if AUDIT:
    print(f"derived-artifact-gate: {total_findings} finding(s) (audit — reported, not refused)")
    sys.exit(3)
if refused:
    print(f"REFUSED: {refused} artifact(s) have blocking findings (block mode, or NO-GENERATOR/BAD-ENTRY in any mode). Fix as shown, or set `mode: warn` in {os.path.relpath(MANIFEST, REPO)} (the project CTO's rigor call).")
    sys.exit(3)
print(f"WARN: {warned} artifact(s) in warn mode have findings — reported, not refused.")
sys.exit(0)
PY
