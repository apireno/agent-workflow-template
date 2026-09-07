#!/usr/bin/env bash
# join-ledger.sh — the CROSS-REPO JOIN for governed derived artifacts (ADR-002 §7).
#
# Each repo's graph stops at its boundary: a sibling is a black box with inputs and outputs.
# This script, run from the CTO home, asks every registered repo's generators for their
# `boundary` declaration and joins them CONSUMER-DRIVEN: the consumer's needs must be a
# subset of what the producer emits. Equality is never required (a producer adding an
# optional parameter is not a mismatch).
#
# Boundary JSON (what `<generator> boundary` prints):
#   {"producers":[{"name":"pkg.mod.func","params":[{"name":"x","kind":"positional|keyword|
#                  var_positional|var_keyword","default":false,"annotation":"str"}],
#                 "returns":"Result","returns_fields":["a","b"]}],      # returns_fields optional
#    "consumers":[{"callee":"pkg.mod.func","positional":1,"keywords":["k"],"reads":["a"]}]}
#
# Checks per consumer call:
#   1 MISSING-CALLEE   callee not declared by any producer in the fleet
#   2 UNKNOWN-KEYWORD  a keyword passed that the producer has no parameter for (and no **kwargs)
#   3 MISSING-ARG      a producer parameter without a default that the call does not supply
#   4 UNKNOWN-FIELD    a field read off the result that the producer's returns_fields lacks —
#                      only when returns_fields is declared; otherwise the row is UNVERIFIED
#
# Rigor knob per CONSUMER repo (its manifest's boundary.join): off — repo skipped;
# advisory (default) — reported here + at CTO session start; verify-row — the same, and the
# row is meant to be carried into that repo's next /sprint-verify by the CTO.
#
# Writes <cto-home>/.cto/join-ledger.md (untracked). A mismatch NEVER blocks a commit anywhere;
# the CTO rules which side moves.
#
# Usage: join-ledger.sh [--quiet] [--registry <projects.yaml>]
# Exit: 0 no mismatch (UNVERIFIED rows allowed) · 3 at least one mismatch · 4 config error

set -uo pipefail
QUIET=0; REG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=1 ;;
        --registry) REG="$2"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "join-ledger: unknown argument $1" >&2; exit 4 ;;
    esac; shift
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
[ -z "$REG" ] && REG="$ROOT/.cto/projects.yaml"
[ -f "$REG" ] || { echo "join-ledger: no registry at $REG" >&2; exit 4; }
OUT_MD="$(dirname "$REG")/join-ledger.md"
export JL_REG="$REG" JL_OUT="$OUT_MD" JL_QUIET="$QUIET"

python3 - <<'PY'
import os, re, sys, json, subprocess, datetime
REG=os.environ["JL_REG"]; OUT=os.environ["JL_OUT"]; QUIET=os.environ["JL_QUIET"]=="1"

# --- registry: active repos ---
repos=[]
t=open(REG).read()
for b in re.split(r'(?=- name:)',t):
    n=re.search(r'- name:\s*(\S+)',b); p=re.search(r'path:\s*(\S+)',b); a=re.search(r'active:\s*(\S+)',b)
    if n and p and ((a is None) or a.group(1).lower() not in ('false','no','0')):
        repos.append((n.group(1), p.group(1)))

# --- per-repo manifest (same mini-parser subset as the gate) ---
def manifest(repo):
    mp=os.path.join(repo,".claude/derived-artifacts.yaml")
    if not os.path.isfile(mp): return None
    d={"artifacts":[],"boundary":{}}; top=None; cur=None
    for raw in open(mp):
        line=raw.split(" #",1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip(): continue
        indent=len(line)-len(line.lstrip()); s=line.strip()
        if indent==0 and s.endswith(":"): top=s[:-1]; cur=None; d.setdefault(top,[] if top=="artifacts" else {}); continue
        if top=="artifacts":
            if s.startswith("- "): cur={}; d["artifacts"].append(cur); s=s[2:].strip()
            if cur is not None and ":" in s: k,v=s.split(":",1); cur[k.strip()]=v.strip().strip("'\"")
        elif top and ":" in s: k,v=s.split(":",1); d[top][k.strip()]=v.strip().strip("'\"")
    return d

def gen_cmd(repo, gen):
    p=os.path.join(repo,gen)
    if not os.path.isfile(p): return None
    if os.access(p,os.X_OK): return [p]
    if p.endswith(".py"): return [sys.executable,p]
    if p.endswith(".sh"): return ["bash",p]
    return None

producers={}   # name -> (repo, spec)
consumers=[]   # (repo, mode, call)
skipped=[]
for name,path in repos:
    m=manifest(path)
    if not m: continue
    mode=(m.get("boundary") or {}).get("join","advisory").lower()
    if mode=="off": skipped.append(name); continue
    for art in m.get("artifacts") or []:
        cmd=gen_cmd(path, art.get("generator",""))
        if not cmd: continue
        r=subprocess.run(cmd+["boundary"],cwd=path,capture_output=True,text=True)
        if r.returncode!=0 or not r.stdout.strip(): continue   # generator does not participate
        try: b=json.loads(r.stdout)
        except json.JSONDecodeError: continue
        for pr in b.get("producers") or []:
            producers[pr["name"]]=(name,pr)
        for c in b.get("consumers") or []:
            consumers.append((name,mode,c))

rows=[]; mismatches=0; unverified=0
for crepo,mode,c in consumers:
    callee=c.get("callee","?"); base=f"{crepo} → {callee}"
    if callee not in producers:
        rows.append((crepo,mode,callee,"MISSING-CALLEE","no producer in the fleet declares this callee")); mismatches+=1; continue
    prepo,pr=producers[callee]; params=pr.get("params") or []
    names={p["name"] for p in params}
    has_varkw=any(p.get("kind")=="var_keyword" for p in params)
    has_varpos=any(p.get("kind")=="var_positional" for p in params)
    ok=True
    for k in c.get("keywords") or []:
        if k not in names and not has_varkw:
            rows.append((crepo,mode,callee,"UNKNOWN-KEYWORD",f"passes `{k}=`; {prepo} has no such parameter (params: {', '.join(sorted(names)) or 'none'})")); mismatches+=1; ok=False
    pos=int(c.get("positional") or 0); kws=set(c.get("keywords") or [])
    positional_params=[p for p in params if p.get("kind") in ("positional","positional_or_keyword",None)]
    for i,p in enumerate(params):
        if p.get("kind") in ("var_positional","var_keyword"): continue
        if p.get("default"): continue
        supplied = (p["name"] in kws) or (p.get("kind")!="keyword" and i < pos)
        if not supplied:
            rows.append((crepo,mode,callee,"MISSING-ARG",f"{prepo} requires `{p['name']}`; the call supplies {pos} positional + {sorted(kws) or 'no'} keywords")); mismatches+=1; ok=False
    reads=c.get("reads") or []
    if reads:
        rf=pr.get("returns_fields")
        if rf is None:
            rows.append((crepo,mode,callee,"UNVERIFIED",f"reads {reads} off the result; {prepo} declares returns={pr.get('returns') or 'unannotated'} without returns_fields")); unverified+=1
        else:
            bad=[r for r in reads if r not in rf]
            if bad:
                rows.append((crepo,mode,callee,"UNKNOWN-FIELD",f"reads {bad} off the result; {prepo} declares fields {rf}")); mismatches+=1; ok=False
    if ok and not reads:
        rows.append((crepo,mode,callee,"OK",f"producer {prepo}"))
    elif ok and reads and pr.get("returns_fields") is not None:
        rows.append((crepo,mode,callee,"OK",f"producer {prepo}; fields verified"))

# --- ledger ---
lines=[f"# Cross-repo join ledger — ADR-002 §7","",
       f"**Generated:** {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%MZ')} · **Registry:** {REG}",
       f"**Producers declared:** {len(producers)} · **Consumer calls:** {len(consumers)} · **Mismatches:** {mismatches} · **Unverified:** {unverified}" + (f" · **Skipped (join: off):** {', '.join(skipped)}" if skipped else ""),"",
       "> Consumer-driven: a consumer's needs must be a subset of what the producer emits. A mismatch never blocks a commit; the CTO rules which side moves and records the contract change. `verify-row` consumers carry their rows into their next /sprint-verify.","",
       "| Consumer repo | join mode | Callee | State | Detail |","|---|---|---|---|---|"]
for r in rows: lines.append("| "+" | ".join(str(x) for x in r)+" |")
if not rows: lines.append("| — | — | — | — | no boundary declarations found (no generator answered `boundary`) |")
lines += ["", "— CTO (generated)"]
os.makedirs(os.path.dirname(OUT), exist_ok=True); open(OUT,"w").write("\n".join(lines)+"\n")

if not QUIET or mismatches:
    print(f"join-ledger: {len(producers)} producers, {len(consumers)} consumer calls, {mismatches} mismatch(es), {unverified} unverified → {OUT}")
    for r in rows:
        if QUIET and r[3] in ("OK",): continue
        print(f"  {r[0]:<20} {r[1]:<10} {r[2]:<40} {r[3]:<16} {r[4]}")
sys.exit(3 if mismatches else 0)
PY
