#!/usr/bin/env bash
# test-fleet-watch.sh — ci-lint, log-line, lane-watch and cto-heartbeat on fixture transcripts
# (fleet report 2026-11-04). Offline: private HOME, fake transcripts, no Terminal, no gh.
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; fail(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -8 | sed 's/^/       | /'; return 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/fleetwatch.XXXXXX")"; W="$(cd "$W" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME/.claude/projects"

echo "== ci-lint =="
R="$W/acme-ci"; mkdir -p "$R/.github/workflows" "$R/.claude"; cp "$T/docs/ci/_templates/heavy-job.yml" "$R/.github/workflows/"
printf 'ci_hook_max_wait_min: 180\n' > "$R/.claude/land.yaml"
OUT=$(bash "$T/scripts/agentic/ci-lint.sh" "$R" 2>&1); [ $? -eq 0 ] && ok "the shipped heavy-job template is clean against a 180-min wait" || fail "template" "$OUT"
cat > "$R/.github/workflows/bad.yml" <<'Y'
on:
  pull_request:
    types: [opened, synchronize, labeled]
concurrency: {group: "x-${{ github.ref }}", cancel-in-progress: true}
jobs:
  slow: {runs-on: [self-hosted, mac], timeout-minutes: 15, steps: [{run: "true"}]}
  quick: {runs-on: ubuntu-latest, timeout-minutes: 5, steps: [{run: "true"}]}
Y
OUT=$(bash "$T/scripts/agentic/ci-lint.sh" "$R" 2>&1); RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q "TIMEOUT-UNDER-WAIT.*'slow'" && echo "$OUT" | grep -q "LABEL-CANCELS-HEAVY.*'slow'" && ! echo "$OUT" | grep -q "'quick'" && ok "15-min self-hosted job under a 180-min wait + label-cancel flagged; a light hosted job is not" || fail "bad rc=$RC" "$OUT"
rm "$R/.claude/land.yaml"; OUT=$(bash "$T/scripts/agentic/ci-lint.sh" "$R" 2>&1); echo "$OUT" | grep -q "timeout-vs-wait not checked" && ! echo "$OUT" | grep -q TIMEOUT-UNDER && ok "no declared wait -> says the timeout check did not run" || fail "nowait" "$OUT"

echo "== log-line =="
H="$W/acme-cto"; mkdir -p "$H/.cto"; echo "America/Los_Angeles" > "$H/.cto/timezone"
OUT=$(CTO_HOME="$H" bash "$T/scripts/cto/log-line.sh" "$W/log.md" "lanes ticked"); exp="$(date -u +%Y-%m-%dT%H:)"
echo "$OUT" | grep -qE "^- ${exp}[0-9]{2}Z \([0-9]{2}:[0-9]{2} P[SD]T\) lanes ticked$" && ok "stamp = clock UTC + the CEO zone from .cto/timezone" || fail "log-line" "$OUT"
OUT=$(CEO_TZ=UTC CTO_HOME="$H" bash "$T/scripts/cto/log-line.sh" --now); echo "$OUT" | grep -q "(.* UTC)" && ok "CEO_TZ overrides; --now prints a CEO-facing time" || fail "now" "$OUT"

echo "== lane-watch =="
enc(){ printf '%s' "$1" | sed 's#[/.]#-#g'; }
L1="$W/acme-a"; L2="$W/acme-b"; mkdir -p "$L1/.git" "$L2/.git" "$H/.git"
printf 'projects:\n  - name: acme-a\n    path: %s\n    active: true\n  - name: acme-b\n    path: %s\n    active: true\n' "$L1" "$L2" > "$H/.cto/projects.yaml"
tr(){ # tr <repo> <file> <minutes-ago-of-last-tool-use> <end_turn:yes|no> <uuid> <text>
  local d="$HOME/.claude/projects/$(enc "$1")"; mkdir -p "$d"
  python3 - "$d/$2.jsonl" "$1" "$3" "$4" "$5" "$6" <<'PY'
import json, sys, datetime
f, cwd, ago, end, uid, text = sys.argv[1:]
t = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(ago))).strftime("%Y-%m-%dT%H:%M:%S.000Z")
with open(f, "w") as o:
    o.write(json.dumps({"type": "user", "cwd": cwd, "timestamp": t, "message": {"role": "user", "content": "go"}}) + "\n")
    o.write(json.dumps({"type": "assistant", "cwd": cwd, "timestamp": t, "uuid": "t-" + uid, "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {}}], "stop_reason": "tool_use"}}) + "\n")
    if end == "yes":
        o.write(json.dumps({"type": "assistant", "cwd": cwd, "timestamp": t, "uuid": uid, "message": {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}}) + "\n")
PY
}
tr "$L1" s1 2 yes u1 "Report: phase 2 done. I continue with phase 3."
tr "$L2" s2 45 no u2 ""
LW(){ CTO_HOME="$H" LANE_WATCH_STATE="$W/lw" bash "$T/scripts/cto/lane-watch.sh" --once 2>&1; }
OUT=$(LW); [ -z "$OUT" ] && ok "first pass seeds silently" || fail "seed" "$OUT"
OUT=$(LW); [ -z "$OUT" ] && ok "nothing new -> nothing printed" || fail "quiet" "$OUT"
tr "$L1" s1 1 yes u3 "Need a GO on the schema change."
OUT=$(LW); echo "$OUT" | grep -q "acme-a WAITING: Need a GO on the schema change." && ok "a new turn end prints WAITING once, with the text" || fail "waiting" "$OUT"
rm -f "$W/lw/acme-b.idle"; touch "$W/lw/.seeded"
OUT=$(LW); echo "$OUT" | grep -q "acme-b IDLE: no tool use for 4[5-9] min" && ok "no tool use >= 30 min -> IDLE" || fail "idle" "$OUT"
OUT=$(LW); ! echo "$OUT" | grep -q "acme-b IDLE" && ok "IDLE is not repeated within the hour" || fail "idle repeat" "$OUT"
rm -f "$W/lw/acme-b.idle"; touch "$L2/.claude-idle"; mkdir -p "$L2/.claude"; touch "$L2/.claude/idle-by-design"
OUT=$(LW); ! echo "$OUT" | grep -q "acme-b IDLE" && ok "a lane marked idle-by-design is not flagged" || fail "idle-by-design" "$OUT"
grep -qx "$L1" "$HOME/.cto/state/lanes-live" && ok "lanes-live written for the heartbeat" || fail "lanes-live: $(cat "$HOME/.cto/state/lanes-live" 2>/dev/null)"

echo "== cto-heartbeat =="
HB(){ CTO_HOME="$H" bash "$T/scripts/cto/cto-heartbeat.sh" check --dry-run "$@" 2>&1; }
mkdir -p "$HOME/.claude/projects/$(enc "$H")"; tr "$H" cto 0 no c1 ""
OUT=$(HB); [ -z "$OUT" ] && ok "CTO active -> silent" || fail "active" "$OUT"
touch -t "$(date -v-90M +%Y%m%d%H%M)" "$HOME/.claude/projects/$(enc "$H")/cto.jsonl"
OUT=$(HB); echo "$OUT" | grep -q "would wake: \[HEARTBEAT\].*quiet 9[0-9] min while .* lane(s) are live: acme-a" && ok "lanes live + CTO quiet 90 min -> a wake-up naming the lanes" || fail "wake" "$OUT"
rm -f "$HOME/.cto/state/lanes-live"; rm -rf "$HOME/.claude/projects/$(enc "$L1")" "$HOME/.claude/projects/$(enc "$L2")"
OUT=$(HB); [ -z "$OUT" ] && ok "no live lanes -> silent however quiet the CTO is" || fail "no lanes" "$OUT"
bash "$T/scripts/cto/cto-heartbeat.sh" bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown subcommand -> usage (exit 2)" || fail "usage"
echo ""; echo "fleet-watch tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
