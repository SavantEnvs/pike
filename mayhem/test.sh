#!/usr/bin/env bash
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{"results":{"tool":{"name":"$tool"},"summary":{"tests":$tests,"passed":$passed,"failed":$failed,"pending":$pending,"skipped":$skipped,"other":$other}}}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

parse_summary() {
  local out="$1"
  FAILED=$(printf '%s\n' "$out" | sed -n 's/.*Failed tests: \([0-9][0-9]*\).*/\1/p' | tail -1)
  TOTAL=$(printf '%s\n' "$out" | sed -n 's/.*Total tests: \([0-9][0-9]*\).*/\1/p' | tail -1)
  SKIPPED=$(printf '%s\n' "$out" | sed -n 's/.*Total tests: [0-9][0-9]* (\([0-9][0-9]*\) tests skipped).*/\1/p' | tail -1)
  FAILED=${FAILED:-0}; TOTAL=${TOTAL:-0}; SKIPPED=${SKIPPED:-0}
  PASSED=$(( TOTAL - FAILED - SKIPPED ))
}

# Resolve the installed version dir dynamically (was hardcoded and broke on every Pike bump).
PIKE_VER="$(find "$SRC/mayhem/test-prefix/pike" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | xargs -n1 basename 2>/dev/null | head -1)"
BUILDDIR=$(find "$SRC/build" -maxdepth 1 -type d -name 'linux-*' 2>/dev/null | head -1)
if [ -z "$PIKE_VER" ] || [ -z "$BUILDDIR" ] || [ ! -f Makefile ]; then
  echo "ERROR: oracle build tree missing (PIKE_VER='$PIKE_VER' BUILDDIR='$BUILDDIR')" >&2
  emit_ctrf "pike-just_verify" 0 1 0; exit 1
fi

export PATH="$SRC/mayhem/test-prefix/pike/${PIKE_VER}/bin:$PATH"
export LD_LIBRARY_PATH="$SRC/mayhem/test-prefix/lib:$SRC/mayhem/test-prefix/pike/${PIKE_VER}/lib:${LD_LIBRARY_PATH:-}"

make -j"$MAYHEM_JOBS" testsuites
RUNPIKE="$BUILDDIR/pike -DNOT_INSTALLED -DPRECOMPILED_SEARCH_MORE -m$BUILDDIR/master.pike"

MODULE_SUITES=()
while IFS= read -r f; do
  case "$f" in
    */modules/Parser/*|*/modules/Gmp/*|*/modules/Image/*|*/modules/Gettext/*|*/modules/system/*)
      MODULE_SUITES+=("$f") ;;
  esac
done < <(find "$BUILDDIR/modules" -name testsuite 2>/dev/null)

TPASSED=0; TFAILED=0; TSKIPPED=0

echo "=== main testsuite (stop before Readline TTY shift/CRNL block at ~6991) ==="
out="$($RUNPIKE -x test_pike -F --notty -v -e 6990 "$BUILDDIR/testsuite" 2>&1)" || true
echo "$out" | tail -5
parse_summary "$out"
TPASSED=$(( TPASSED + PASSED )); TFAILED=$(( TFAILED + FAILED )); TSKIPPED=$(( TSKIPPED + SKIPPED ))

echo "=== src module testsuites (${#MODULE_SUITES[@]}) ==="
out="$($RUNPIKE -x test_pike -F --notty -v "${MODULE_SUITES[@]}" 2>&1)" || true
echo "$out" | tail -5
parse_summary "$out"
TPASSED=$(( TPASSED + PASSED )); TFAILED=$(( TFAILED + FAILED )); TSKIPPED=$(( TSKIPPED + SKIPPED ))

emit_ctrf "pike-just_verify" "$TPASSED" "$TFAILED" "$TSKIPPED"
