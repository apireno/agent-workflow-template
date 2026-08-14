#!/usr/bin/env bash
# check-native-dupes.sh [--refresh] [--quiet] [--python <interpreter>]
#
# Detect two copies of the same compiled C/C++ library inside one Python
# environment — the condition that produces interpreter-teardown crashes.
#
# WHY THIS EXISTS (kgspin-core BUG-308, 2026-08-14). A machine accumulated 41
# Python crash dumps; 38 were one signature:
#
#     absl::Flag<bool>::~Flag()  <-  __cxa_finalize_ranges  <-  exit
#     EXC_BAD_ACCESS (SIGBUS), byte write to __DATA_CONST
#
# Two packages each vendored their own sentencepiece + abseil:
#   sentencepiece/_sentencepiece…so        (pip sentencepiece)
#   curated_tokenizers/_spp…so             (spaCy, statically linked)
# At exit() the C++ static destructors from ONE copy run against the OTHER's
# __DATA_CONST, which dyld has already remapped read-only. Write → SIGBUS.
#
# The tell is that it is ORDER-DEPENDENT, which is what distinguishes it from
# ordinary flakiness:
#     import sentencepiece  →  curated_tokenizers    CRASH
#     import curated_tokenizers  →  sentencepiece    clean
#
# It crashes at TEARDOWN, after the work is done and the artifacts are written,
# so it costs noise rather than measurements — which is exactly why it survives
# for months: every individual crash looks ignorable, and it never fails a test.
# That is the failure class this template keeps meeting under different names:
# a real defect wearing noise's clothing.
#
# COST + CACHING. A full symbol scan is ~6s over ~170 large libraries, far too
# slow for a SessionStart hook. Results only change when packages change, so the
# scan is cached and keyed on (library count + newest mtime) of site-packages.
# preflight reads the cached verdict instantly and refreshes in the background.
#
# Exit: 0 clean (or cached-clean) · 1 duplicates found · 2 could not scan

set -uo pipefail

REFRESH=0; QUIET=0; PYBIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --refresh) REFRESH=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        --python)  PYBIN="${2:?--python needs an interpreter}"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# Prefer the repo's own venv — that is the environment the dev team actually runs.
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if [ -z "$PYBIN" ]; then
    for c in "$REPO_ROOT/.venv/bin/python3" "$REPO_ROOT/venv/bin/python3" "$(command -v python3 2>/dev/null)"; do
        [ -x "$c" ] && { PYBIN="$c"; break; }
    done
fi
[ -x "$PYBIN" ] || { [ "$QUIET" = 1 ] || echo "check-native-dupes: no python3 found" >&2; exit 2; }

SP="$("$PYBIN" -c 'import site,sys; p=[d for d in site.getsitepackages() if d.endswith("site-packages")]; print(p[0] if p else "")' 2>/dev/null)"
[ -n "$SP" ] && [ -d "$SP" ] || { [ "$QUIET" = 1 ] || echo "check-native-dupes: no site-packages for $PYBIN" >&2; exit 2; }

CACHE_DIR="$HOME/.cto/native-dupes"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE="$CACHE_DIR/$(printf '%s' "$SP" | cksum | cut -d' ' -f1).txt"

# Fingerprint the environment cheaply: number of native libs + newest mtime.
# Any install/upgrade/removal moves one of the two.
fingerprint() {
    local n mt
    n=$(find "$SP" \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null | wc -l | tr -d ' ')
    mt=$(stat -f %m "$SP" 2>/dev/null || stat -c %Y "$SP" 2>/dev/null || echo 0)
    printf 'FP %s %s\n' "$n" "$mt"
}
FP="$(fingerprint)"

if [ "$REFRESH" -eq 0 ] && [ -f "$CACHE" ] && [ "$(head -1 "$CACHE")" = "$FP" ]; then
    BODY="$(tail -n +2 "$CACHE")"
    [ -z "$BODY" ] && exit 0
    [ "$QUIET" = 1 ] || printf '%s\n' "$BODY"
    exit 1
fi

# ── the scan ──────────────────────────────────────────────────────────────────
# Namespaces whose duplicate presence is genuinely dangerous: each registers
# PROCESS-GLOBAL state (flag registries, descriptor pools, thread pools), so two
# copies fight over one global. A duplicate of a stateless library is harmless
# and deliberately NOT reported — a checker that cries wolf gets switched off,
# and the first draft of this one reported 60+ benign vendored copies.
#
# Mangled prefixes, Itanium C++ ABI with the macOS leading underscore.
PROBE_RE='^(__ZN4absl|__ZN13sentencepiece|__ZN6google8protobuf|__ZN3re2|__ZN3tbb)'
MIN_SYMS=10          # a handful of stray symbols is not a vendored copy

# A package may VENDOR a whole second interpreter (nexaai ships python3.10 with
# its own site-packages). Those libraries never share a process with ours, so
# every pair they form is a false positive. Prune nested runtimes.
prune_nested() { grep -vE '/(python_runtime|site-packages)/.*/site-packages/|/python_runtime/'; }

OUT=""

# 1. Two copies of a library that owns PROCESS-GLOBAL state. Restricted to a
#    hazard list on purpose: duplicate cv2/ffmpeg dylibs are ordinary vendoring
#    and harmless, while two OpenMP runtimes in one process is a documented
#    source of hangs, wrong results and crashes.
HAZARD_LIBS='libomp|libiomp5|libgomp|libtbb|libprotobuf|libmkl_rt'
DUPE_NAMES="$(find "$SP" \( -name '*.dylib' -o -name 'lib*.so*' \) 2>/dev/null \
    | prune_nested | sed 's|.*/||' | grep -E "^($HAZARD_LIBS)" | sort | uniq -d)"
for nm_ in $DUPE_NAMES; do
    paths="$(find "$SP" -name "$nm_" 2>/dev/null | prune_nested | sed "s|$SP/||" | sed 's|^|      |')"
    cnt="$(printf '%s\n' "$paths" | grep -c . )"
    [ "$cnt" -lt 2 ] && continue
    OUT="$OUT
  DUPLICATE RUNTIME LIBRARY: $nm_  (x$cnt)
$paths"
done

# 2. Same C++ namespace EXPORTED by two different extension modules — the case
#    name-matching cannot see, because the filenames are unrelated
#    (_sentencepiece…so vs _spp…so). ONE nm pass per file, all probes counted in
#    that pass: the first draft ran nm once per probe per file and took 2 minutes.
CANDIDATES="$(find "$SP" \( -name '*.so' -o -name '*.dylib' \) -size +300k 2>/dev/null | prune_nested)"
COUNTS="$(for f in $CANDIDATES; do
    nm -gjU "$f" 2>/dev/null | grep -E "$PROBE_RE" | sed -E 's/^(__ZN4absl|__ZN13sentencepiece|__ZN6google8protobuf|__ZN3re2|__ZN3tbb).*/\1/' \
      | sort | uniq -c | awk -v p="${f#"$SP"/}" '{print $2, $1, p}'
done)"
for sym in __ZN4absl __ZN13sentencepiece __ZN6google8protobuf __ZN3re2 __ZN3tbb; do
    case "$sym" in
        __ZN4absl)            label="absl" ;;
        __ZN13sentencepiece)  label="sentencepiece" ;;
        __ZN6google8protobuf) label="google::protobuf" ;;
        __ZN3re2)             label="re2" ;;
        __ZN3tbb)             label="tbb" ;;
    esac
    # Group by owning PACKAGE, not by file. pyarrow ships four interlinked
    # libraries that all export absl; that is ONE vendored copy, not four, and
    # counting files made a single package look like a four-way collision.
    owners="$(printf '%s\n' "$COUNTS" \
        | awk -v s="$sym" -v m="$MIN_SYMS" '$1==s && $2>=m {split($3,a,"/"); if ($2>best[a[1]]) {best[a[1]]=$2; rep[a[1]]=$3}}
             END {for (k in best) printf "      %-14s %s   (%s symbols)\n", k, rep[k], best[k]}' | sort)"
    n=$(printf '%s\n' "$owners" | grep -c . )
    [ "$n" -lt 2 ] && continue
    OUT="$OUT
  DUPLICATE C++ RUNTIME: $label  — vendored by $n separate packages
$owners"
done

{
    printf '%s\n' "$FP"
    if [ -n "$OUT" ]; then
        echo "[WARN] duplicate native libraries in $SP"
        printf '%s\n' "$OUT"
        cat <<'GUIDANCE'

  Two copies of one C++ runtime in a single interpreter share process-global
  state. The usual symptom is a crash at EXIT — after the work is done, so it
  looks like ignorable noise — and it is ORDER-DEPENDENT: whichever copy loads
  first wins the destructor symbol and runs it over the other's read-only data.

  Confirm the order-dependence before believing it:
      python3 -c "import A, B"      # crash
      python3 -c "import B, A"      # clean

  Fixes, best first:
    1. Remove the duplicate — check whether one package is a transitive
       passenger nothing imports at runtime. NOTE: changing the import graph of
       an extraction path is an ENGINE CHANGE; re-derive checkpoints per ADR-087.
    2. os._exit(code) at the end of the entrypoint (after flushing stdout and
       stderr) — skips __cxa_finalize entirely, so the crash cannot happen.
       Last line only: it also skips atexit handlers.
    3. Suppress the dialogs while you fix it (macOS, machine-wide, reversible):
       defaults write com.apple.CrashReporter DialogType none
GUIDANCE
    fi
} > "$CACHE.tmp.$$" && mv "$CACHE.tmp.$$" "$CACHE"

BODY="$(tail -n +2 "$CACHE")"
[ -z "$BODY" ] && exit 0
[ "$QUIET" = 1 ] || printf '%s\n' "$BODY"
exit 1
