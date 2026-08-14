#!/usr/bin/env bash
# window-registry.sh — append-only registry of Terminal windows per repo.
#
#   window-registry.sh add     <repo-path> <win-id> [label]
#   window-registry.sh list    <repo-path>
#   window-registry.sh resolve <repo-path> [label]     # prints ONE id, or errors with choices
#   window-registry.sh close   <repo-path> <win-id>
#
# WHY. Each repo used to have exactly one address: .claude/terminal-window.id, a single slot
# that every /handoff overwrote. Start a second sprint on a repo and the first session — often
# a long-running one — loses its name: /send, /peek and /close-window all resolve to the new
# window, and the only way back to the old one is a raw numeric id the operator has to keep in
# their head. That is how an entire session was addressed by hand on 2026-08-13.
#
# The registry is APPEND-ONLY on purpose: a window's row survives the next handoff, so history
# stays readable and a stale row is a fact to be explained, not silently overwritten.
# Liveness is not inferred from the file — it is checked against Terminal on every resolve,
# because a row saying "open" for a window the operator closed is exactly the kind of
# confident-but-wrong answer this mechanism keeps producing.
#
# Format (TSV): <iso-ts>\t<win-id>\t<label>\t<state>      state = open | closed
# Location:     <repo-path>/.claude/terminal-windows.tsv
#
# .claude/terminal-window.id is still written by /handoff for backward compatibility; it now
# means "most recent", not "the one".
#
# Exit: 0 ok · 1 usage/IO · 2 resolve found nothing · 3 resolve is ambiguous (choices printed)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CMD="${1:?usage: window-registry.sh add|list|resolve|close <repo-path> [...]}"
REPO="${2:?need a repo path}"
shift 2
REG="$REPO/.claude/terminal-windows.tsv"

live_ids() { bash "$HERE/window-peek.sh" list 2>/dev/null | awk -F' *\\| *' '{print $1}' | tr -d ' '; }
is_live()  { live_ids | grep -qx "$1"; }

case "$CMD" in
    add)
        WIN="${1:?need a window id}"; LABEL="${2:-unlabelled}"
        mkdir -p "$REPO/.claude" || exit 1
        printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$WIN" "$LABEL" "open" >> "$REG"
        echo "window-registry: recorded $WIN ($LABEL) in $REG"
        ;;

    list)
        [ -f "$REG" ] || { echo "window-registry: no registry at $REG" >&2; exit 2; }
        LIVE="$(live_ids)"
        printf '%-22s %-10s %-34s %-8s %s\n' "WHEN" "WINDOW" "LABEL" "STATE" "LIVE?"
        while IFS=$'\t' read -r ts win label state; do
            [ -n "${win:-}" ] || continue
            if printf '%s\n' "$LIVE" | grep -qx "$win"; then live="yes"; else live="GONE"; fi
            printf '%-22s %-10s %-34s %-8s %s\n' "$ts" "$win" "$label" "$state" "$live"
        done < "$REG"
        ;;

    resolve)
        WANT="${1:-}"
        [ -f "$REG" ] || { echo "window-registry: no registry at $REG" >&2; exit 2; }
        LIVE="$(live_ids)"
        MATCHES=""
        # Newest first, de-duplicated by window id: a window relaunched under the same label
        # should resolve once, to its latest row.
        while IFS=$'\t' read -r ts win label state; do
            [ -n "${win:-}" ] || continue
            [ "$state" = "open" ] || continue
            printf '%s\n' "$LIVE" | grep -qx "$win" || continue
            [ -n "$WANT" ] && [ "$label" != "$WANT" ] && continue
            printf '%s\n' "$MATCHES" | grep -qx "$win	$label" && continue
            MATCHES="$(printf '%s\n%s\t%s' "$MATCHES" "$win" "$label")"
        done < "$REG"
        MATCHES="$(printf '%s' "$MATCHES" | grep -v '^$')"
        COUNT="$(printf '%s\n' "$MATCHES" | grep -c . )"
        if [ "$COUNT" -eq 0 ]; then
            echo "window-registry: no LIVE window for $(basename "$REPO")${WANT:+ with label '$WANT'}" >&2
            echo "  rows on file (may all be closed/gone):" >&2
            [ -f "$REG" ] && sed 's/^/    /' "$REG" >&2
            exit 2
        fi
        if [ "$COUNT" -gt 1 ]; then
            echo "window-registry: AMBIGUOUS — $(basename "$REPO") has $COUNT live windows:" >&2
            printf '%s\n' "$MATCHES" | while IFS=$'\t' read -r w l; do echo "    id=$w  label=$l" >&2; done
            echo "  Name one:  /send <window-id> <message>   (or pass the label)" >&2
            exit 3
        fi
        printf '%s\n' "$MATCHES" | cut -f1
        ;;

    close)
        WIN="${1:?need a window id}"
        [ -f "$REG" ] || { echo "window-registry: no registry at $REG" >&2; exit 2; }
        TMP="$REG.tmp.$$"
        awk -F'\t' -v OFS='\t' -v w="$WIN" '{ if ($2 == w) $4 = "closed"; print }' "$REG" > "$TMP" && mv "$TMP" "$REG"
        echo "window-registry: marked $WIN closed in $REG"
        ;;

    *)
        echo "ERROR: unknown command '$CMD' (want: add | list | resolve | close)" >&2
        exit 1 ;;
esac
