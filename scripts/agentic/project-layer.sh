#!/usr/bin/env bash
# project-layer.sh — the PROJECT and REPO layers: what a project and each of its repos add on top of
# the template, kept where sync never reaches (CEO 2026-11-04).
#
#   project-layer.sh <moment> [--repo <path>] [--home <cto-home>] [--quiet]
#   project-layer.sh status   [--repo <path>] [--home <cto-home>]
#   project-layer.sh init     <dir>                 seed an empty layer from the template's skeleton
#
#   <moment> = preflight | kickoff | handoff | landing | accept
#
# THREE LAYERS.
#   template  everything this template ships          owned by the template team; sync/push copy it in
#   project   <cto-home>/.cto/project/                 owned by that project's CTO; sync NEVER writes it
#   repo      <repo>/.claude/project/                  owned by that repo's lane, committed in the repo;
#                                                      push-to-repos.sh NEVER writes it
# A project's own rules, checklists and checks live in the project/repo layers. Nothing project-
# specific goes into the template (the template is public); nothing the template ships is edited in
# a project home (sync would overwrite it). An ad-hoc rule in a CLAUDE.md section, a memo or a
# scratchpad script is a rule nobody runs: move it here.
#
# WHAT A LAYER HOLDS (same shape at both levels):
#   standing-orders.md         binding rules, printed at every session start (moment `preflight`).
#                              One `## <id> — <rule>` heading per order; body: why, since, repeated.
#                              An order repeated often is a mechanism request to the template team.
#   checklists/<moment>.md     `- [ ]` items printed at that moment. At `accept`, /sprint-accept requires
#                              the decision file to answer each item (done / N/A: <why> / waived by CEO).
#   checks/<moment>/*.sh       executable checks run at that moment, from the repo root, with
#                              PROJECT_LAYER_REPO and PROJECT_LAYER_MOMENT set. Non-zero exit refuses
#                              (exit 3 here), naming the check. A check that is not executable is
#                              reported, never skipped silently.
#   settings-overlay.json      (project layer) permission grants unioned into lanes by push-to-repos.sh.
#
# Moments run both layers that exist: project first (fleet-wide), then repo. `preflight` in a CTO home
# prints the project layer; a lane session (inject hook) prints the project layer it can find via
# .cto-path / ~/.cto/home plus its own repo layer.
#
# Exit: 0 ok · 2 usage · 3 a check refused
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TPL_ROOT="$(cd "$HERE/../.." && pwd -P)"
MOMENT="${1:-}"; shift || true
REPO=""; HOME_CTO=""; QUIET=0; INIT_DIR=""
[ "$MOMENT" = init ] && { INIT_DIR="${1:-}"; shift || true; }
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:-}"; shift ;; --repo=*) REPO="${1#--repo=}" ;;
        --home) HOME_CTO="${2:-}"; shift ;; --home=*) HOME_CTO="${1#--home=}" ;;
        --quiet) QUIET=1 ;;
        *) echo "project-layer: unknown argument '$1'" >&2; exit 2 ;;
    esac; shift
done
case "$MOMENT" in preflight|kickoff|handoff|landing|accept|status|init) ;;
    *) echo "usage: project-layer.sh preflight|kickoff|handoff|landing|accept|status [--repo <path>] [--home <cto-home>] | init <dir>" >&2; exit 2 ;; esac

if [ "$MOMENT" = init ]; then
    [ -n "$INIT_DIR" ] || { echo "project-layer: init needs a directory" >&2; exit 2; }
    SKEL="$TPL_ROOT/docs/project-layer/_templates"
    [ -d "$SKEL" ] || { echo "project-layer: skeleton missing at $SKEL" >&2; exit 2; }
    mkdir -p "$INIT_DIR"
    # never overwrite: a layer is its owner's; init only fills what is absent
    (cd "$SKEL" && find . -type f) | while read -r f; do
        [ -e "$INIT_DIR/$f" ] && continue
        mkdir -p "$INIT_DIR/$(dirname "$f")" && cp "$SKEL/$f" "$INIT_DIR/$f"
    done
    echo "project-layer: $INIT_DIR seeded (existing files untouched)"
    exit 0
fi

REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || { echo "project-layer: repo not found" >&2; exit 2; }
is_home(){ case "$(basename "$1")" in agent-workflow-template|*-cto) return 0 ;; esac; [ -f "$1/.cto/projects.yaml" ]; }
if [ -z "$HOME_CTO" ]; then
    if is_home "$REPO"; then HOME_CTO="$REPO"
    elif [ -n "${CTO_HOME:-}" ]; then HOME_CTO="$CTO_HOME"
    elif [ -f "$REPO/.cto-path" ]; then HOME_CTO="$(tr -d '[:space:]' < "$REPO/.cto-path")"
    elif [ -f "$HOME/.cto/home" ]; then HOME_CTO="$(tr -d '[:space:]' < "$HOME/.cto/home")"; fi
fi
LAYERS=()
[ -n "$HOME_CTO" ] && [ -d "$HOME_CTO/.cto/project" ] && LAYERS+=("project:$HOME_CTO/.cto/project")
if ! is_home "$REPO" && [ -d "$REPO/.claude/project" ]; then LAYERS+=("repo:$REPO/.claude/project"); fi

# Read a layer file without its <!-- ... --> blocks (the skeleton's examples live in comments).
live(){ [ -f "$1" ] && awk '/<!--/{c=1} !c{print} /-->/{c=0}' "$1"; }
orders_in(){ live "$1/standing-orders.md" | grep -c '^## ' || true; }

if [ "$MOMENT" = status ]; then
    if is_home "$REPO"; then
        L="$REPO/.cto/project"
        if [ ! -d "$L" ]; then echo "project layer: MISSING ($L) — seed: bash scripts/agentic/project-layer.sh init .cto/project"; exit 1; fi
        n="$(orders_in "$L")"; c="$(for f in "$L"/checklists/*.md; do live "$f" | grep -qE '^[[:space:]]*- \[' && echo x; done 2>/dev/null | wc -l | tr -d ' ')"; k="$(ls "$L"/checks/*/*.sh 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$n" -eq 0 ]; then echo "project layer: EMPTY — no standing orders in $L/standing-orders.md"; exit 1; fi
        echo "project layer: ok ($n standing orders, $c checklists, $k checks)"; exit 0
    fi
    L="$REPO/.claude/project"
    [ -d "$L" ] || { echo "repo layer: none ($L) — optional; seed: bash scripts/agentic/project-layer.sh init .claude/project"; exit 0; }
    echo "repo layer: $(orders_in "$L") standing orders, $(ls "$L"/checklists/*.md 2>/dev/null | wc -l | tr -d ' ') checklists, $(ls "$L"/checks/*/*.sh 2>/dev/null | wc -l | tr -d ' ') checks"; exit 0
fi

[ ${#LAYERS[@]} -eq 0 ] && exit 0
rc=0
for entry in "${LAYERS[@]}"; do
    kind="${entry%%:*}"; L="${entry#*:}"
    if [ "$MOMENT" = preflight ] || [ "$MOMENT" = kickoff ]; then
        if [ -s "$L/standing-orders.md" ] && [ "$(orders_in "$L")" -gt 0 ]; then
            echo "[STANDING ORDERS — $kind layer, $L/standing-orders.md] binding; follow them as you follow the contract:"
            live "$L/standing-orders.md" | grep '^## ' | sed 's/^## /    - /'
        fi
    fi
    items="$(live "$L/checklists/$MOMENT.md" | grep -E '^[[:space:]]*- \[[ xX]\]' | sed 's/^[[:space:]]*/    /')"
    if [ -n "$items" ]; then
        echo "[CHECKLIST — $kind layer, $MOMENT] $L/checklists/$MOMENT.md"
        printf '%s\n' "$items"
        [ "$MOMENT" = accept ] && echo "    The decision file answers each item: done · N/A: <why> · waived by CEO (<words>)."
    fi
    for chk in "$L/checks/$MOMENT"/*.sh; do
        [ -e "$chk" ] || continue
        name="$kind/$(basename "$chk")"
        if [ ! -x "$chk" ]; then echo "[CHECK $name] NOT EXECUTABLE — chmod +x $chk (never skipped silently)"; rc=3; continue; fi
        out="$(cd "$REPO" && PROJECT_LAYER_REPO="$REPO" PROJECT_LAYER_MOMENT="$MOMENT" PROJECT_LAYER_HOME="$HOME_CTO" "$chk" 2>&1)"; c=$?
        if [ $c -ne 0 ]; then
            echo "[CHECK $name] REFUSED (exit $c)"; printf '%s\n' "$out" | sed 's/^/    /'; rc=3
        elif [ "$QUIET" = 0 ]; then
            echo "[CHECK $name] ok${out:+ — $(printf '%s' "$out" | tail -1)}"
        fi
    done
done
exit $rc
