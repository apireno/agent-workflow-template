#!/usr/bin/env bash
# model-budget.sh — WEEKLY MODEL BUDGET READ from the session transcripts.
#
# WHY. Nothing in the mechanism decided which model a stretch of work ran on. In the week
# that prompted this, ~90% of the stretch model's weighted tokens went to the CTO session —
# much of it routine shepherding (polling, sends, commits, logs) — while subagents inherited
# the parent's model and a handful of hand-opened lane sessions came up on it too. The quota
# ran out a day early and the first signal was the quota. This makes the spend visible at
# session start, per model and per repo, with a runway against the weekly reset.
#
# WHAT IT COUNTS. Every assistant message in ~/.claude/projects/**/*.jsonl (subagents
# included) since the window start, deduplicated by requestId. Weighted tokens are a
# PRICE-SHAPED PROXY for the meter, not the meter itself:
#     input x1 · cache write 5m x1.25 · cache write 1h x2 · cache read x0.1 · output x5
# Output alone is printed beside it. Calibration (.cto/model-budget.yaml) absorbs the scale.
#
# WHAT IT WARNS (exit 3 with --quiet when any fires):
#   RUNWAY      a calibrated limit runs out before the weekly reset at the last-24h rate
#   LANE-ON-STRETCH  a non-CTO session ran on the stretch family; origin is shown — a
#               session whose first message is not the /handoff kickoff was opened by hand,
#               and a hand-typed `claude` takes whatever /model last saved
#   SUB-ON-STRETCH   a subagent ran on the stretch family (it inherited the parent)
#   ROUTINE-ON-STRETCH  a CTO session's recent run on the stretch family was mostly
#               shepherding tool calls (sleep/poll/tail/send/commit/log). HEURISTIC: the
#               tool-call mix is the only signal; judgment work that happens to poll a lot
#               will trip it too.
#
# USAGE: model-budget.sh [--quiet] [--days N] [--config <path>] [--projects <dir>]
#   --quiet   print only warnings (preflight); exit 3 when any fire, 0 otherwise
#   --days N  ignore the reset and use a rolling N-day window
#   --now ISO pretend the local time is ISO (tests)
# Exit: 0 ok · 3 warnings (with --quiet) · 4 config error

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
QUIET=0; DAYS=""; CONF=""; NOW=""; PROJ="${HOME}/.claude/projects"
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=1 ;;
        --days) DAYS="$2"; shift ;;
        --config) CONF="$2"; shift ;;
        --projects) PROJ="$2"; shift ;;
        --now) NOW="$2"; shift ;;   # test hook: pretend it is this local ISO time
        -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "model-budget: unknown argument $1" >&2; exit 4 ;;
    esac; shift
done
if [ -z "$CONF" ]; then
    [ -f "$HERE/_cto-home-anchor.sh" ] && . "$HERE/_cto-home-anchor.sh" 2>/dev/null || true
    for _b in "${ROOT:-}" "$(cd "$HERE/../.." && pwd)"; do
        [ -n "$_b" ] && [ -f "$_b/.cto/model-budget.yaml" ] && { CONF="$_b/.cto/model-budget.yaml"; break; }
    done
fi
export MB_QUIET="$QUIET" MB_DAYS="$DAYS" MB_CONF="$CONF" MB_PROJ="$PROJ" MB_NOW="$NOW"

python3 - <<'PY'
import os, re, sys, json, glob, datetime, collections
QUIET=os.environ["MB_QUIET"]=="1"; DAYS=os.environ["MB_DAYS"]; CONF=os.environ["MB_CONF"]; PROJ=os.environ["MB_PROJ"]
now=datetime.datetime.fromisoformat(os.environ["MB_NOW"]).astimezone() if os.environ.get("MB_NOW") else datetime.datetime.now().astimezone()

# ---------- config ----------
cfg={"lane":"opus","stretch":"fable","reset":None,"cal":{}}
if CONF and os.path.isfile(CONF):
    incal=False
    for raw in open(CONF):
        line=raw.split("#",1)[0].rstrip()
        if not line.strip(): continue
        if re.match(r"^calibration:\s*$",line): incal=True; continue
        if incal and line.startswith((" ","\t")):
            m=re.match(r"\s*(\S+):\s*(\S+)\s+([\d.]+)",line)
            if m: cfg["cal"][m.group(1)]=(m.group(2),float(m.group(3)))
            continue
        incal=False
        m=re.match(r"^(lane|stretch|reset):\s*(.+?)\s*$",line)
        if m: cfg[m.group(1)]=m.group(2).strip("'\"")
LANE=cfg["lane"].lower(); STRETCH=cfg["stretch"].lower()

def last_reset():
    if DAYS or not cfg["reset"]: return None
    m=re.match(r"(mon|tue|wed|thu|fri|sat|sun)\w*\s+(\d{1,2}):(\d{2})",cfg["reset"].lower())
    if not m: return None
    wd=["mon","tue","wed","thu","fri","sat","sun"].index(m.group(1))
    t=now.replace(hour=int(m.group(2)),minute=int(m.group(3)),second=0,microsecond=0)
    t-=datetime.timedelta(days=(t.weekday()-wd)%7)
    if t>now: t-=datetime.timedelta(days=7)
    return t
RESET=last_reset()
START=RESET or (now-datetime.timedelta(days=float(DAYS or 7)))
NEXT=RESET+datetime.timedelta(days=7) if RESET else None

def fam(model):
    for f in ("fable","opus","sonnet","haiku","mythos"):
        if f in model: return f
    return model
def parse_ts(s):
    try: return datetime.datetime.fromisoformat(s.replace("Z","+00:00"))
    except Exception: return None
def weight(u):
    cc=u.get("cache_creation") or {}
    w5=cc.get("ephemeral_5m_input_tokens"); w1=cc.get("ephemeral_1h_input_tokens")
    cw = (1.25*(w5 or 0)+2*(w1 or 0)) if (w5 is not None or w1 is not None) else 1.25*u.get("cache_creation_input_tokens",0)
    return u.get("input_tokens",0)+cw+0.1*u.get("cache_read_input_tokens",0)+5*u.get("output_tokens",0)

SHEPHERD=re.compile(r"\b(sleep|stat -f|tail|wc -l|ls -la?|git (add|commit|push|log|status|diff --stat|pull|fetch)|qa-send|window-peek|window-registry|osascript|cat [^|]*\.output|grep -c|shasum)\b")
SHEP_TOOLS={"Monitor","TaskStop","TaskOutput","ScheduleWakeup","CronCreate","CronDelete","ReadNotifications"}
SHEP_SKILLS={"send","peek","sprint-status","close-window","resume-dev-team","digest","escalate-drain"}
def is_shepherd(tu):
    n=tu.get("name"); inp=tu.get("input") or {}
    if n in SHEP_TOOLS: return True
    if n=="Skill": return (inp.get("skill") or "") in SHEP_SKILLS
    if n=="Bash": return bool(SHEPHERD.search(str(inp.get("command",""))[:600]))
    return False
KICKOFF=re.compile(r"^Read docs/sprints/.*brief\.md")
ROUTINE_SHARE=0.35   # share of stretch-family tool turns that were pure shepherding

# ---------- scan ----------
rows=collections.defaultdict(lambda: {"w":0.0,"out":0,"n":0})
day=collections.defaultdict(float)      # family -> weighted tokens in last 24h
cal_w=collections.defaultdict(float)    # calibration key -> weighted tokens reset..cal time
cal_t={k:parse_ts(v[0]+":00").astimezone() if parse_ts(v[0]+":00") else None for k,v in cfg["cal"].items()}
for k,t in list(cal_t.items()):
    if t and t.tzinfo is None: cal_t[k]=t.replace(tzinfo=now.tzinfo)
lane_on_stretch=[]; sub_on_stretch=collections.Counter(); routine=[]
cutoff=START.timestamp()
for f in glob.glob(os.path.join(PROJ,"**","*.jsonl"),recursive=True):
    try:
        if os.path.getmtime(f)<cutoff and not os.environ.get("MB_NOW"): continue
    except OSError: continue
    projdir=os.path.relpath(f,PROJ).split(os.sep)[0]
    repo=re.sub(r"^-Users-[^-]+-(repos-)?","",projdir) or projdir
    is_cto = repo.endswith("-cto") or repo=="agent-workflow-template"
    is_sub = f"{os.sep}subagents{os.sep}" in f
    seen=set(); first_user=None; first_model=None; turns=[]
    try: fh=open(f,encoding="utf-8",errors="replace")
    except OSError: continue
    for line in fh:
        try: d=json.loads(line)
        except Exception: continue
        if d.get("type")=="user" and first_user is None and not d.get("isMeta"):
            c=(d.get("message") or {}).get("content")
            first_user=c if isinstance(c,str) else next((x.get("text","") for x in (c or []) if isinstance(x,dict) and x.get("type")=="text"),"")
        m=d.get("message") or {}; u=m.get("usage"); mod=m.get("model","")
        if d.get("type")!="assistant" or not u or not mod.startswith("claude"): continue
        t=parse_ts(d.get("timestamp",""))
        if not t or t.timestamp()<cutoff or t>now: continue
        rid=d.get("requestId") or d.get("uuid")
        if rid in seen: continue
        seen.add(rid)
        F=fam(mod); first_model=first_model or F; w=weight(u)
        r=rows[(F,"cto" if is_cto else "lane",repo[:36],"sub" if is_sub else "main")]
        r["w"]+=w; r["out"]+=u.get("output_tokens",0); r["n"]+=1
        if (now-t).total_seconds()<86400: day[F]+=w; day["all"]+=w
        for k,ct in cal_t.items():
            if ct and t<=ct and (k=="all" or k==F): cal_w[k]+=w
        if F==STRETCH and is_cto and not is_sub:
            tus=[x for x in (m.get("content") or []) if isinstance(x,dict) and x.get("type")=="tool_use"]
            if tus: turns.append((w, all(is_shepherd(x) for x in tus)))
    fh.close()
    if not seen: continue
    if first_model==STRETCH and is_sub:
        sub_on_stretch[repo[:36]]+=1
    elif first_model==STRETCH and not is_cto:
        if True:
            origin="via /handoff" if first_user and KICKOFF.match(first_user.strip()) else "opened by hand (first message is not the /handoff kickoff)"
            lane_on_stretch.append((repo[:36],os.path.splitext(os.path.basename(f))[0][:8],origin))
    # Whole-window mix, not a recent slice: a week-long CTO session is one transcript.
    if is_cto and not is_sub and len(turns)>=20:
        shep=[w for w,sh in turns if sh]
        if len(shep)/len(turns)>=ROUTINE_SHARE:
            routine.append((repo[:36],os.path.splitext(os.path.basename(f))[0][:8],len(shep),len(turns),sum(shep)))

# ---------- report ----------
warns=[]
fams=sorted({k[0] for k in rows}, key=lambda x:-sum(r["w"] for k,r in rows.items() if k[0]==x))
out=[]
out.append(f"model-budget: window {START.strftime('%a %m-%d %H:%M')} → now" + (f" · next reset {NEXT.strftime('%a %m-%d %H:%M')}" if NEXT else " (rolling — set `reset:` in .cto/model-budget.yaml for a runway)") + f" · lane={LANE} stretch={STRETCH}")
for F in fams:
    fr=[(k,r) for k,r in rows.items() if k[0]==F]; tot=sum(r["w"] for _,r in fr) or 1
    cto=sum(r["w"] for k,r in fr if k[1]=="cto")
    tag=" (STRETCH)" if F==STRETCH else " (lane)" if F==LANE else ""
    out.append(f"  {F}{tag}: {tot/1e6:.1f}M weighted · CTO share {100*cto/tot:.0f}% · last 24h {day[F]/1e6:.1f}M")
    for k,r in sorted(fr,key=lambda kr:-kr[1]["w"])[:6]:
        out.append(f"      {k[1]:<4} {k[2]:<36} {k[3]:<4} {100*r['w']/tot:>3.0f}%  {r['w']/1e6:>7.1f}M  out {r['out']/1e3:>6.0f}k  msgs {r['n']}")

for key,(ts,pct) in cfg["cal"].items():
    if not RESET or not cal_t.get(key) or pct<=0: continue
    if cal_t[key] < RESET:
        warns.append(f"CALIBRATION  '{key}' was recorded {ts}, before the last reset — re-run /usage and update .cto/model-budget.yaml"); continue
    allowance=cal_w[key]/(pct/100.0)
    if allowance<=0:
        warns.append(f"CALIBRATION  '{key}': no {key} tokens seen between the reset and {ts}, so the allowance cannot be derived — recalibrate after some use"); continue
    used=sum(r["w"] for k,r in rows.items() if key=="all" or k[0]==key)
    rate=day[key]
    left=allowance-used
    hrs_to_reset=(NEXT-now).total_seconds()/3600
    runway=(left/rate*24) if rate>0 else float("inf")
    line=f"  runway '{key}': {100*used/allowance:.0f}% used (calibrated {ts} at {pct:.0f}%) · {runway:.0f}h at the last-24h rate · reset in {hrs_to_reset:.0f}h"
    out.append(line)
    if runway < hrs_to_reset:
        warns.append(f"RUNWAY  '{key}' runs out in ~{runway:.0f}h at the last-24h rate; the reset is in {hrs_to_reset:.0f}h. Move routine work to '{LANE}'.")
if lane_on_stretch:
    byhand=[x for x in lane_on_stretch if x[2].startswith("opened by hand")]
    listing=", ".join(f"{r}({s})" for r,s,_ in lane_on_stretch[:6]) + (f" +{len(lane_on_stretch)-6} more" if len(lane_on_stretch)>6 else "")
    warns.append(f"LANE-ON-STRETCH  {len(lane_on_stretch)} lane session(s) ran on '{STRETCH}', {len(byhand)} opened by hand (first message is not the /handoff kickoff): {listing}. Lanes run on '{LANE}'; a hand-typed `claude` takes whatever /model last saved — type `claude --model {LANE}`.")
for repo,n in sub_on_stretch.items():
    warns.append(f"SUB-ON-STRETCH  {n} subagent transcript(s) under {repo} ran on '{STRETCH}' — they inherited the parent. Skills pass `model:` explicitly (resolve-devteam-model.sh --alias).")
for repo,sid,shep,nt,w in routine:
    warns.append(f"ROUTINE-ON-STRETCH  {repo} session {sid}: {shep} of {nt} tool turns on '{STRETCH}' this window were pure shepherding (poll/sleep/send/peek/commit/log), {w/1e6:.1f}M weighted. That work belongs on '{LANE}' (heuristic: tool mix only).")

if not QUIET:
    print("\n".join(out))
    if warns: print("\nWARNINGS:"); print("\n".join("  "+w for w in warns))
    sys.exit(0)
if warns:
    print("\n".join(out[:1]+[l for l in out if l.lstrip().startswith(("runway",f"{STRETCH}"))]))
    print("\n".join("  "+w for w in warns))
    sys.exit(3)
sys.exit(0)
PY
