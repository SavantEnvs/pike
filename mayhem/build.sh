#!/usr/bin/env bash
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# DWARF < 4 debug info on every target binary — Mayhem's triage cannot read DWARF >= 4 and clang-19's
# plain -g emits DWARF-5, so thread $DEBUG_FLAGS explicitly (§6.2 item 10). The base leaves it empty;
# default it to -gdwarf-3 so the installed pike carries a readable (< 4) .debug_info.
: "${DEBUG_FLAGS:=-gdwarf-3}"

# Pike is self-hosting: `make` builds tpike (a fresh Pike) and runs it as the module precompiler for
# every module. Halting UBSan trips several benign UB patterns baked into Pike's own low-level data
# structures on every module: an unaligned read in pike_memory.h's get_unaligned* helpers,
# interpret.c's setjmp/catch handling calling a restore function through a differently-typed function
# pointer (the same `-fsanitize=function` false-positive as quickjs's DynBuf realloc callback),
# `o->storage+0` on a NULL storage pointer in interpret.c's call-frame setup (the same NULL+0
# `pointer-overflow` false-positive as gfatools's radix_sort_arc), and multiset.c/mapping.c computing
# a member address off a NULL node pointer as part of an empty-container check that never actually
# dereferences it (`-fsanitize=null`), and pike_types.cmod's radix-sort pivot computation deliberately shifting `1` into
# an int's sign bit as a bit-pattern sentinel (`-fsanitize=shift`). Relax ONLY those checks, same class
# as the gfatools/hh-suite/quickjs cases, and keep ASan plus the rest of UBSan halting — none of them
# disable the OS-delivered SIGSEGV a genuine null/OOB dereference still raises at runtime, only the
# extra compile-time address-computation/shift checks. ASan's leak checker would otherwise abort tpike
# (and later the installed pike) at
# exit; disable LSan at build time via mayhem/lsan_off.cc linked into every binary (never ASAN_OPTIONS
# at runtime). The MFUZZ_COMPAT_LEVEL Mayhemfile env (learned from the mayhemheroes fork's own fixup
# at FUZZED) is what stops Mayhem's sanitizer-compat layer from treating the ASan binary's clean
# interpreter error-exits as crashes.
# SanitizerCoverage edge feedback for Mayhem WITHOUT the libFuzzer main. A plain file-input pike
# carries no coverage otherwise, so Mayhem sees 0 edges. -fsanitize=fuzzer-no-link links a
# self-contained SanCov runtime (defines __sanitizer_cov_* itself, no undefined refs, no abort-on-
# error) alongside ASan/UBSan. Threaded into CFLAGS/CXXFLAGS/LDFLAGS below.
FUZZ_COV="-fsanitize=fuzzer-no-link"
FUZZ_SAN="$SANITIZER_FLAGS -fno-sanitize=alignment,function,pointer-overflow,null,shift"
# $DEBUG_FLAGS last: $SANITIZER_FLAGS carries a trailing plain -g (DWARF-5); -gdwarf-3 must win.
FUZZ_FLAGS="-O2 $FUZZ_COV $FUZZ_SAN $DEBUG_FLAGS"

: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX MAYHEM_JOBS
export PATH="/usr/bin:$PATH"

cd "$SRC"
FUZZ_PREFIX="$SRC/mayhem/fuzz-prefix"
TEST_PREFIX="$SRC/mayhem/test-prefix"

"$CXX" -O2 -c -o mayhem/lsan_off.o mayhem/lsan_off.cc
FUZZ_LDFLAGS="$FUZZ_FLAGS $SRC/mayhem/lsan_off.o"

pike_build() {
  local prefix="$1" cflags="$2" cxxflags="$3" ldflags="$4" label="$5"
  echo "=== Pike $label build (prefix=$prefix) ==="
  if [ -f Makefile ]; then make distclean >/dev/null 2>&1 || true; fi
  make -j"$MAYHEM_JOBS" \
    CONFIGUREARGS="--prefix=$prefix CC=$CC CXX=$CXX CFLAGS='$cflags' CXXFLAGS='$cxxflags' LDFLAGS='$ldflags'"
  make CONFIGUREARGS="--prefix=$prefix CC=$CC CXX=$CXX CFLAGS='$cflags' CXXFLAGS='$cxxflags' LDFLAGS='$ldflags'" \
    install
}

pike_build "$FUZZ_PREFIX" "$FUZZ_FLAGS" "$FUZZ_FLAGS" "$FUZZ_LDFLAGS" "fuzz"
# Resolve the installed version dir dynamically and alias it to a stable "current" symlink, since
# the version string changes on every Pike bump and both the Mayhemfile's cmd/LD_LIBRARY_PATH need
# a path that survives that (was hardcoded to a specific version and broke on the next bump).
FUZZ_PIKE="$(find "$FUZZ_PREFIX/pike" -mindepth 3 -maxdepth 3 -type f -name pike -path '*/bin/pike' 2>/dev/null | head -1)"
[ -n "$FUZZ_PIKE" ] && [ -x "$FUZZ_PIKE" ] || { echo "ERROR: no fuzz pike binary found under $FUZZ_PREFIX/pike/*/bin/pike" >&2; exit 1; }
ln -sfn "$(basename "$(dirname "$(dirname "$FUZZ_PIKE")")")" "$FUZZ_PREFIX/pike/current"
echo "built $FUZZ_PREFIX/pike/current -> $(readlink "$FUZZ_PREFIX/pike/current")"

pike_build "$TEST_PREFIX" "-O2 -g" "-O2 -g" "-O2 -g" "oracle"
echo "oracle build ready for test.sh"
