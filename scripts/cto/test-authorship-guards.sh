#!/usr/bin/env bash
# test-authorship-guards.sh — regression guard for "observed text is not attributed text".
#
# THE DEFECT (2026-08-27). A watcher reported STRANDED INPUT in a live dev-team window and,
# per standing doctrine, tried to SUBMIT it with a space-payload keystroke — twice. The text
# was not the CEO's. It was Claude Code's own generated grey composer suggestion, which is
# rendered in the same input cells as typed characters and differs only by colour — and the
# window-content API every watcher here reads returns plain text with colour stripped. Only a
# busy composer stopped the submit. Had it landed, the session would have received its own
# last recommendation back as a CEO directive, and every downstream artifact would have
# recorded it as one.
#
# Two mechanisms now stand in the way, and this file holds them there:
#   1. PREVENTION — every orchestrated launch path exports CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0,
#      so the ambiguity cannot arise in a window we opened.
#   2. REFUSAL — qa-send.sh rejects a whitespace-only payload (the exact shape of the attempted
#      action: the smallest edit that submits whatever is already in the box) unless a named
#      human attests to having typed the text.
#
# Runs entirely offline except the two Terminal probes, which open and close a plain shell
# window and never send a keystroke. No claude session is touched.
#
# Exit: 0 all assertions pass · 1 a guard has regressed

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

printf '\n== 1. PREVENTION: every interactive launch path disables composer suggestions ==\n'
# The launch sites are the complete set of places this template starts a `claude` a watcher
# will later read. A new one added without the export reopens the hole, so the test is
# "every `do script` that starts claude", not a hand-listed set of files.
MISSING=0
while IFS= read -r line; do
    case "$line" in
        *"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0"*) ;;
        *) MISSING=$((MISSING+1)); printf '        unguarded launch: %s\n' "$(printf '%s' "$line" | cut -c1-110)" ;;
    esac
done < <(grep -rhE --exclude='test-authorship-guards.sh' 'do script "[^"]*claude' \
             "$ROOT/scripts" "$ROOT/.claude" 2>/dev/null)
check "no interactive launch site starts claude with suggestions enabled" "$MISSING" "0"

# The env var is the vendor's own switch, read before any feature gate or setting. Asserting
# the NAME here is what catches a typo'd variable, which would look identical and do nothing.
grep -q '"promptSuggestionEnabled": false' "$ROOT/.claude/settings.devteam.json.template" \
    && ok "dev-team settings template also disables suggestions (covers hand-started sessions)" \
    || bad "dev-team settings template is missing promptSuggestionEnabled:false"

printf '\n== 2. REFUSAL: qa-send rejects a payload whose only effect is to submit foreign text ==\n'
printf ' \n'   > "$TMP/space.txt"
printf '\t\n' > "$TMP/tab.txt"
printf 'a real message\n' > "$TMP/real.txt"

bash "$ROOT/scripts/cto/qa-send.sh" 999999 "$TMP/space.txt" >"$TMP/o1" 2>&1
check "space-only payload is refused with exit 7" "$?" "7"
grep -q 'REFUSED' "$TMP/o1" && ok "refusal says REFUSED" || bad "refusal message missing"
grep -qi 'suggestion' "$TMP/o1" && ok "refusal names the cause (generated suggestion)" \
    || bad "refusal does not explain WHY, so the next operator will just work around it"
grep -q 'submit-composer-text' "$TMP/o1" && ok "refusal names the attested escape hatch" \
    || bad "refusal offers no legitimate path, which invites a hand-rolled osascript"

bash "$ROOT/scripts/cto/qa-send.sh" 999999 "$TMP/tab.txt" >/dev/null 2>&1
check "tab-only payload is refused too (the check is whitespace, not a literal space)" "$?" "7"

# The refusal must fire BEFORE any keystroke machinery — a guard that aborts after focusing
# the target has already reached across to another app.
grep -q 'FOCUS-GUARD\|osascript' "$TMP/o1" && bad "refusal ran osascript before refusing" \
    || ok "refusal is reached before any window is touched"

# ...and it must not fire on a real message, or the fix has broken the tool it protects.
bash "$ROOT/scripts/cto/qa-send.sh" 999999 "$TMP/real.txt" >"$TMP/o2" 2>&1
grep -q 'REFUSED' "$TMP/o2" && bad "a normal message was caught by the authorship gate" \
    || ok "a normal message passes the gate untouched"

printf '\n== 3. NEGATIVE CONTROL: the pre-fix script would have sent it ==\n'
# Reconstruct the guard's absence rather than trusting that it matters. Without this, a test
# that passes proves only that the file parses.
sed '/THE AUTHORSHIP GATE/,/^fi$/d' "$ROOT/scripts/cto/qa-send.sh" > "$TMP/prefix-qa-send.sh"
bash "$TMP/prefix-qa-send.sh" 999999 "$TMP/space.txt" >"$TMP/o3" 2>&1
RC=$?
if [ "$RC" = "7" ]; then
    bad "negative control still refused — the gate was not actually removed, so test 2 proves nothing"
else
    grep -q 'FOCUS-GUARD\|ABORTED' "$TMP/o3" \
        && ok "without the gate the space payload proceeds to the keystroke path (exit $RC)" \
        || bad "negative control failed for an unrelated reason: $(head -1 "$TMP/o3")"
fi

printf '\n== 4. window-peek states authorship it can prove, and nothing more ==\n'
grep -q 'UNVERIFIED AUTHORSHIP' "$ROOT/scripts/cto/window-peek.sh" \
    && ok "--input warns that composer text is unattributable" \
    || bad "--input reports composer text without the authorship warning"

TAB=$(osascript -e 'tell application "Terminal"
    set newTab to do script "export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 && echo [authorship-probe]"
    newTab
end tell' 2>&1 | tail -1)
TW=$(printf '%s' "$TAB" | grep -oE 'window id [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$TW" ]; then
    sleep 1
    bash "$ROOT/scripts/cto/window-peek.sh" "$TW" --authorship >/dev/null 2>&1
    check "--authorship proves OFF for a window launched the way /handoff launches" "$?" "0"
    osascript -e "tell application \"Terminal\" to close (first window whose id is $TW)" >/dev/null 2>&1

    TAB2=$(osascript -e 'tell application "Terminal"
        set newTab to do script "echo [authorship-probe-plain]"
        newTab
    end tell' 2>&1 | tail -1)
    TW2=$(printf '%s' "$TAB2" | grep -oE 'window id [0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$TW2" ]; then
        sleep 1
        bash "$ROOT/scripts/cto/window-peek.sh" "$TW2" --authorship >/dev/null 2>&1
        check "--authorship returns UNPROVEN (3) for a hand-started window, never a guess" "$?" "3"
        osascript -e "tell application \"Terminal\" to close (first window whose id is $TW2)" >/dev/null 2>&1
    fi
else
    printf '  SKIP  Terminal probes (could not open a window — Automation permission?)\n'
fi

printf '\n%s\n' "----------------------------------------------------------------"
printf 'authorship guards: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
