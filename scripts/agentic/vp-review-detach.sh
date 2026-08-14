#!/usr/bin/env bash
# vp-review-detach.sh <artifact> <out-dir> <vp1,vp2,...> [--engine <engine>]
#
# Launch CLI-engine VP reviews DETACHED, and return immediately.
#
# WHY THIS EXISTS. The /vp-review skill used to fire the reviews inline and `wait`. A skill's
# shell body has a ~2-minute budget; a kimi review of a long artifact runs past it. When the
# budget expired the shell was killed and the children went with it — "Terminated: 15", no
# verdicts, and (before the temp-then-rename fix in vp-review.sh) zero-byte .md files that
# read downstream as completed-but-empty reviews. Reviews are minutes-long work being run by
# a seconds-long caller; the fix is to stop coupling their lifetime to it.
#
# Children ignore SIGTERM/SIGHUP/SIGINT before exec'ing the review, and ignored dispositions
# survive exec — so a kill aimed at the launching shell's process group no longer reaches them.
#
# Poll with:  scripts/agentic/vp-review-wait.sh <out-dir>
#
# Per VP, in <out-dir>:  <vp>.md  verdict (only ever exists WITH a body)
#                        <vp>.log engine stdout+stderr
#                        <vp>.status  running | ok | failed
#                        <vp>.pid     launcher pid
#
# Exit: 0 launched · 1 usage/setup error

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPSH="$HERE/vp-review.sh"

ART="${1:?usage: vp-review-detach.sh <artifact> <out-dir> <vp1,vp2,...> [--engine <engine>]}"
OUTDIR="${2:?need an output directory}"
VPS="${3:?need a comma-separated VP list}"
shift 3
ENGINE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE="${2:?--engine needs a value}"; shift 2 ;;
        --engine=*) ENGINE="${1#--engine=}"; shift ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

[ -f "$ART" ] || { echo "ERROR: artifact not found: $ART" >&2; exit 1; }
mkdir -p "$OUTDIR" || exit 1

if [ -z "$ENGINE" ]; then
    ENGINE="$("$HERE/resolve-review-engine.sh" 2>/dev/null)" || { echo "ERROR: engine resolution refused" >&2; exit 1; }
fi
case "$ENGINE" in
    subagent|handoff)
        echo "ERROR: engine '$ENGINE' is orchestrator-driven — there is no CLI process to detach." >&2
        echo "  The /vp-review skill fans those via the Agent tool / windows instead." >&2
        exit 1 ;;
esac

echo "detaching ${ENGINE} reviews of $(basename "$ART") -> $OUTDIR"
N=0
IFS=','
for vp in $VPS; do
    vp="$(printf '%s' "$vp" | tr -d '[:space:]')"
    [ -n "$vp" ] || continue
    OUT="$OUTDIR/${vp}.md"; LOG="$OUTDIR/${vp}.log"; ST="$OUTDIR/${vp}.status"
    printf 'running\n' > "$ST"
    rm -f "$OUT"
    # `trap "" TERM HUP INT` then exec: SIG_IGN survives exec, so the whole review subtree is
    # immune to the group kill that ends the caller's shell.
    nohup bash -c '
        trap "" TERM HUP INT
        _vp="$1"; _art="$2"; _out="$3"; _log="$4"; _st="$5"; _sh="$6"; _eng="$7"
        if REVIEW_ENGINE="$_eng" "$_sh" "$_vp" "$_art" "$_out" > "$_log" 2>&1; then
            printf "ok\n" > "$_st"
        else
            printf "failed\n" > "$_st"
        fi
    ' _ "$vp" "$ART" "$OUT" "$LOG" "$ST" "$VPSH" "$ENGINE" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$OUTDIR/${vp}.pid"
    echo "  launched $vp (pid $!)"
    N=$((N + 1))
done
unset IFS

echo "DETACHED=$N"
echo "POLL=bash scripts/agentic/vp-review-wait.sh $OUTDIR"
