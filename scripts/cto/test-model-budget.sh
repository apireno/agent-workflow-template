#!/usr/bin/env bash
# test-model-budget.sh — fixture test for model-budget.sh. Synthetic transcripts, fixed clock.
# Asserts: family/repo split + CTO share; runway math against a calibration; RUNWAY fires when
# the rate outruns the reset and not otherwise; LANE-ON-STRETCH names hand-opened vs /handoff
# sessions; SUB-ON-STRETCH; ROUTINE-ON-STRETCH on a shepherding-heavy CTO session and not on a
# judgment-heavy one; stale calibration; --quiet exit codes. Offline; no claude session touched.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; MB="$T/scripts/cto/model-budget.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }
has(){ printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || fail "$1 (missing /$2/)" "$3"; }
hasnt(){ printf '%s' "$3" | grep -qE -- "$2" && fail "$1 (unexpected /$2/)" "$3" || ok "$1"; }
W="$(mktemp -d "${TMPDIR:-/tmp}/mb-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
P="$W/projects"
python3 - "$P" <<'PY'
import json,os,sys,datetime
P=sys.argv[1]
tz=datetime.datetime(2026,9,25,12,0).astimezone().tzinfo
def ts(day,h,m=0): return datetime.datetime(2026,9,day,h,m,tzinfo=tz).astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def write(proj,sid,msgs,sub=False):
    d=os.path.join(P,proj,sid,"subagents") if sub else os.path.join(P,proj)
    os.makedirs(d,exist_ok=True)
    with open(os.path.join(d,(sid+"-a" if sub else sid)+".jsonl"),"w") as f:
        for i,(kind,day,h,model,out,tools) in enumerate(msgs):
            if kind=="user": f.write(json.dumps({"type":"user","timestamp":ts(day,h),"message":{"role":"user","content":out}})+"\n"); continue
            content=[{"type":"tool_use","name":n,"input":inp} for n,inp in tools] or [{"type":"text","text":"x"}]
            f.write(json.dumps({"type":"assistant","requestId":f"{sid}-{i}","timestamp":ts(day,h,i%60),
              "message":{"model":model,"content":content,"usage":{"input_tokens":1000,"output_tokens":out,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}})+"\n")
F="claude-fable-5-1"; O="claude-opus-5-5"
poll=("Bash",{"command":"sleep 600; stat -f %m x"}); send=("Skill",{"skill":"send","args":"acme-x \"CTO — go\""})
think=("Bash",{"command":"python3 analyze.py --design"}); read=("Read",{"file_path":"/a/b.md"})
# CTO: 30 Fable turns, 24 shepherding (80%), out 10k each; days 22-25
cto=[("user",22,9,None,"hi",[])]+[("a",22+i%4,10+i%8,F,10000,[poll if i%5 else think]) for i in range(30)]
write("-Users-x-repos-acme-cto","ctosess1",cto)
# judgment-heavy CTO session on Fable: 25 turns, all analysis -> no ROUTINE
write("-Users-x-repos-acme-cto","ctosess2",[("user",23,9,None,"design",[])]+[("a",23,10,F,2000,[think,read]) for i in range(25)])
# CTO subagent on Fable (inherited)
write("-Users-x-repos-acme-cto","ctosess1",[("a",24,11,F,1000,[read])],sub=True)
# lane via /handoff on Opus; lane opened by hand on Fable
write("-Users-x-repos-acme-core","lane1",[("user",23,8,None,"Read docs/sprints/sprint-x/brief.md in full as your mission brief",[])]+[("a",23,9,O,20000,[think]) for i in range(20)])
write("-Users-x-repos-acme-tuner","lane2",[("user",24,8,None,"CTO — new item while you wait",[])]+[("a",24,9,F,1000,[read]) for i in range(5)])
# before the reset (Fri 18 17:00) — must be excluded
write("-Users-x-repos-acme-cto","old",[("a",18,10,F,999999,[poll])])
PY
CONF="$W/mb.yaml"
# reset Sun 00:00 -> window Sun 09-20 .. now Fri 09-25 12:00, next reset in 36h
printf 'lane: opus\nstretch: fable\nreset: sun 00:00\ncalibration:\n  fable: 2026-09-24T12:00 90\n' > "$CONF"

echo "== split + CTO share =="
OUT=$(bash "$MB" --projects "$P" --config "$CONF" --now 2026-09-25T12:00 2>&1)
has "window starts at the last reset" "window Sun 09-20 00:00" "$OUT"
has "fable is tagged STRETCH and opus lane" "fable \(STRETCH\).*CTO share" "$OUT"
has "old pre-reset message excluded (no 999999-token row)" "fable \(STRETCH\): 1\.[0-9]M" "$OUT"
has "CTO share of fable is the CTO sessions' fraction" "fable \(STRETCH\): .*CTO share 9[0-9]%" "$OUT"
echo "== runway =="
has "runway line printed with calibration" "runway 'fable': [0-9]+% used \(calibrated 2026-09-24T12:00 at 90%\)" "$OUT"
has "RUNWAY fires: last-24h rate outruns the 36h to reset" "RUNWAY  'fable' runs out" "$OUT"
printf 'lane: opus\nstretch: fable\nreset: sun 00:00\ncalibration:\n  fable: 2026-09-24T12:00 1\n' > "$W/big.yaml"
OUT2=$(bash "$MB" --projects "$P" --config "$W/big.yaml" --now 2026-09-25T12:00 2>&1)
hasnt "a huge allowance does not fire RUNWAY" "RUNWAY" "$OUT2"
echo "== origin + inheritance + routine =="
has "hand-opened lane on stretch is named as such" "LANE-ON-STRETCH  1 lane session\(s\) ran on .fable., 1 opened by hand.*acme-tuner\(lane2\)" "$OUT"
hasnt "/handoff lane on the lane model is not flagged" "acme-core\(lane1\)" "$OUT"
has "CTO subagent on stretch is flagged" "SUB-ON-STRETCH  1 subagent transcript\(s\) under acme-cto" "$OUT"
has "shepherding-heavy CTO session flagged" "ROUTINE-ON-STRETCH  acme-cto session ctosess1: [0-9]+ of [0-9]+ tool turns" "$OUT"
hasnt "judgment-heavy CTO session not flagged" "session ctosess2" "$OUT"
echo "== stale calibration + quiet exits =="
printf 'lane: opus\nstretch: fable\nreset: sun 00:00\ncalibration:\n  fable: 2026-09-17T12:00 50\n' > "$W/stale.yaml"
OUT3=$(bash "$MB" --projects "$P" --config "$W/stale.yaml" --now 2026-09-25T12:00 2>&1)
has "calibration older than the reset is flagged" "CALIBRATION  'fable' was recorded 2026-09-17T12:00, before the last reset" "$OUT3"
bash "$MB" --quiet --projects "$P" --config "$CONF" --now 2026-09-25T12:00 >/dev/null 2>&1; r=$?; [ $r -eq 3 ] && ok "--quiet exits 3 with warnings" || fail "--quiet exit (want 3, got $r)"
mkdir -p "$W/empty"; printf 'lane: opus\nstretch: fable\n' > "$W/nocal.yaml"; bash "$MB" --quiet --projects "$W/empty" --config "$W/nocal.yaml" --now 2026-09-25T12:00 >/dev/null 2>&1; r=$?; [ $r -eq 0 ] && ok "--quiet exits 0 with nothing to say" || fail "--quiet clean exit (want 0, got $r)"
OUT4=$(bash "$MB" --quiet --projects "$W/empty" --config "$CONF" --now 2026-09-25T12:00 2>&1); has "no data since reset: calibration says so instead of crashing" "cannot be derived" "$OUT4"
echo ""; echo "model-budget tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
