---
name: escalate-drain
description: Read pending escalations dropped into ~/.cto/inbox/ by dev teams or VPs, present them to the CTO for handling. Use when CEO asks "any escalations?", "what's pending?", or starts the session — also can be wired to fire automatically via Stop hook.
allowed-tools: Bash(*) Read Write
---

# Escalation Inbox Drain

## Check inbox

```!
INBOX="$HOME/.cto/inbox"

if [ ! -d "$INBOX" ]; then
  echo "No inbox directory at $INBOX — nothing to drain."
  echo ""
  echo "(The inbox is populated by dev-team or VP Stop hooks when they drop"
  echo " .escalation-pending.md files. Until Phase 2 is live, this will be empty.)"
  exit 0
fi

PENDING=$(ls "$INBOX"/*.md 2>/dev/null)

if [ -z "$PENDING" ]; then
  echo "Inbox is empty — no pending escalations."
  exit 0
fi

COUNT=$(echo "$PENDING" | wc -l | tr -d ' ')
echo "Found $COUNT pending escalation(s) in $INBOX"
echo ""

for f in $PENDING; do
  echo "==================== $(basename $f) ===================="
  echo "Dropped: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f")"
  echo "Source: ${f%-*}"
  echo ""
  /Users/apireno/repos/agent-workflow-template/scripts/agentic/wrap-untrusted.sh "$f" "inbox:$(basename $f .md)"
  echo ""
done
```

## Your task as CTO

For each escalation above, respond inline:

1. **Ruling** — your direct answer or decision (1-3 sentences)
2. **Reasoning** — cross-repo implications, relevant ADRs, architectural constraints
3. **Action items** — what the escalating team does next, with file paths
4. **Cross-repo notes** — if other repos are affected, name them

After handling each escalation, **move the file** to `~/.cto/inbox/processed/{name}-$(date +%Y%m%d-%H%M%S).md` so it doesn't appear in subsequent drains.

If an escalation requires a lasting decision (e.g., an ADR, interface contract update, RCA), write that artifact to the affected repo path and reference it in your ruling.

Brief summary to CEO at the end: "Processed N escalations, X required ADRs/RCAs, Y deferred for next sync."

Sign as: — CTO
