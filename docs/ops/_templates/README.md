# Ops templates — jobs that run outside any session

## CTO heartbeat (`com.cto.heartbeat.plist`)

A session cannot wake itself. When lanes finish overnight and nobody is watching, they wait — a
10-hour gap was observed on 2026-11-04. The heartbeat runs every 10 minutes from launchd:

1. `scripts/cto/cto-heartbeat.sh check` looks at the fleet's live lanes (`lane-watch.sh` writes
   `~/.cto/state/lanes-live`; otherwise recent transcripts) and at the CTO home's newest transcript.
2. If lanes are live and the CTO has been quiet 60 min, it injects a `[HEARTBEAT]` message into the
   CTO's window (registered by preflight at every session start) through `qa-send.sh` — which waits
   until the operator has stopped typing — and posts a macOS notification plus an inbox memo.
3. The woken CTO checks the lanes and pages the CEO with `PushNotification`; Remote Control delivers
   it to the phone (`/config` → *Push when Claude decides*).

Install (from the CTO home; `launchctl load` is on the ask list, so it prompts once):

```bash
sed -e "s#__CTO_HOME__#$PWD#g" -e "s#__HOME__#$HOME#g" docs/ops/_templates/com.cto.heartbeat.plist \
  > ~/Library/LaunchAgents/com.cto.heartbeat.plist
launchctl load ~/Library/LaunchAgents/com.cto.heartbeat.plist
bash scripts/cto/cto-heartbeat.sh check --dry-run --quiet-min 0   # what a wake-up would say
```

Remove: `launchctl unload ~/Library/LaunchAgents/com.cto.heartbeat.plist`. Preflight reports
`[HEARTBEAT] not installed` until it is loaded.
