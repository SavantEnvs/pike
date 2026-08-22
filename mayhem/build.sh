#!/usr/bin/env bash
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# DWARF < 4 debug info on every target binary — Mayhem's triage cannot read DWARF >= 4 and clang-19's
# plain -g emits DWARF-5, so thread $DEBUG_FLAGS explicitly (§6.2 item 10). The base leaves it empty;
# default it to -gdwarf-3 so the installed pike carries a readable (< 4) .debug_info.
: "${DEBUG_FLAGS:=-gdwarf-3}"

# The fuzzed interpreter carries the full $SANITIZER_FLAGS (ASan + UBSan, both halting) by default.
# Defaulted with `=`, not `:=`: an explicit empty `--build-arg SANITIZER_FLAGS=` builds with NO
# sanitizers. Pike is self-hosting: `make` runs the freshly built (so: sanitized) pike as the module
# precompiler and to dump master.pike/.pmod files, so every sanitizer report that would abort a
# valid Pike program also aborts the build. Two measures keep that build — and the fuzz target on
# valid input — clean, without making any sanitizer recoverable:
#  - LeakSanitizer is turned off at build time by linking mayhem/lsan_off.c (a
#    __lsan_is_turned_off() hook) into every linked binary via LDFLAGS. Pike keeps its program and
#    module tables alive until exit, so LSan would report on every exit. ASan stays on.
#  - UBSAN_RELAX (below) names the narrow UBSan checks that fire on valid Pike programs.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# UBSan checks relaxed, each measured on VALID Pike programs: the self-hosting build itself
# (precompile.pike over the shipped .cmod files, dumping master.pike and the .pmod modules), run under
# a recoverable discovery build that logged every report. Every other UBSan check and all of ASan
# stay on and halting; the whole module build raised 0 ASan reports.
#  - alignment:        pike_memory.h:163 get_unaligned32() is a deliberate unaligned load (global.h
#                      defines HANDLES_UNALIGNED_MEMORY_ACCESS on x86); also the CRC32 hash in
#                      pike_memory.c:280 and the refcount pun in svalue.c:2092.
#  - function:         Pike's error-unwinding (SET_ONERROR, 500+ sites) and callback tables store
#                      handlers as void (*)(void *); first report interpret.c:3276
#                      restore_catching_eval_jmpbuf "through pointer to incorrect function type".
#  - pointer-overflow: "applying zero offset to null pointer" for storage-less objects
#                      (interpret.c:2710 o->storage+offset, object.c:997) and empty byte buffers
#                      (buffer.h:119 NULL+len).
#  - null:             "member access within null pointer of type 'union msnode'" at multiset.c:355,
#                      an address-of (&node->rb_hdr) on an empty multiset that rb_first() handles.
#                      A real NULL dereference still faults (SEGV), so it is still caught.
#  - shift-base:       pike_types.cmod:14485 "left shift of 1 by 31 places cannot be represented in
#                      type 'int'" (type-range pivot). shift-exponent (oversized shifts) stays on.
UBSAN_RELAX=""
case "$SANITIZER_FLAGS" in
  *undefined*) UBSAN_RELAX="-fno-sanitize=alignment,function,pointer-overflow,null,shift-base" ;;
esac
# Coverage for Mayhem: the fuzz build is compiled with afl-clang-fast (Mayhemfile `afl: true`), so
# pike and every dynamic module it loads carry compiled-in AFL edge instrumentation. CLASSIC
# (vanilla-AFL) mode with the fixed 64 KB map: Mayhem's engine records 0 edges with AFL++'s dynamic
# PCGUARD maps. The modules' map references resolve against the pike executable, which links the
# AFL runtime. Without a fork server (the self-hosting build runs this pike as its precompiler) the
# runtime writes to a private dummy map, so the build is unaffected.
# Named AFL_CLANG, not AFL_CC: afl-cc reads AFL_CC as its OWN back-end compiler and would recurse.
: "${AFL_CLANG:=afl-clang-fast}" ; : "${AFL_CLANGXX:=afl-clang-fast++}"
# $DEBUG_FLAGS goes AFTER $SANITIZER_FLAGS: the base's SANITIZER_FLAGS carries a plain -g (DWARF-5
# under clang-19) and the last -g* wins.
FUZZ_FLAGS="-O2 $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS"
FUZZ_LDFLAGS="$FUZZ_FLAGS"

: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX MAYHEM_JOBS
export PATH="/usr/bin:$PATH"

cd "$SRC"
FUZZ_PREFIX="$SRC/mayhem/fuzz-prefix"
TEST_PREFIX="$SRC/mayhem/test-prefix"

# LSan hook: compiled with the fuzz flags and linked into every binary of the fuzz build (pike and
# the configure probes alike). Only meaningful when ASan is on; without ASan there is no LSan.
case "$SANITIZER_FLAGS" in
  *address*)
    LSAN_OFF_OBJ="$SRC/mayhem/lsan_off.o"
    AFL_LLVM_INSTRUMENT=CLASSIC AFL_QUIET=1 "$AFL_CLANG" $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"
    FUZZ_LDFLAGS="$FUZZ_FLAGS $LSAN_OFF_OBJ" ;;
esac

pike_build() {
  local prefix="$1" cflags="$2" ldflags="$3" label="$4" cc="$5" cxx="$6"
  echo "=== Pike $label build (prefix=$prefix, CC=$cc) ==="
  if [ -f Makefile ]; then make distclean >/dev/null 2>&1 || true; fi
  make -j"$MAYHEM_JOBS" \
    CONFIGUREARGS="--prefix=$prefix CC=$cc CXX=$cxx CFLAGS='$cflags' CXXFLAGS='$cflags' LDFLAGS='$ldflags'"
  make CONFIGUREARGS="--prefix=$prefix CC=$cc CXX=$cxx CFLAGS='$cflags' CXXFLAGS='$cflags' LDFLAGS='$ldflags'" \
    install
}

( export AFL_LLVM_INSTRUMENT=CLASSIC AFL_MAP_SIZE=65536 AFL_QUIET=1
  pike_build "$FUZZ_PREFIX" "$FUZZ_FLAGS" "$FUZZ_LDFLAGS" "fuzz" "$AFL_CLANG" "$AFL_CLANGXX" )
# Resolve the installed version dir dynamically and alias it to a stable "current" symlink, since
# the version string changes on every Pike bump and both the Mayhemfile's cmd/LD_LIBRARY_PATH need
# a path that survives that (was hardcoded to a specific version and broke on the next bump).
FUZZ_PIKE="$(find "$FUZZ_PREFIX/pike" -mindepth 3 -maxdepth 3 -type f -name pike -path '*/bin/pike' 2>/dev/null | head -1)"
[ -n "$FUZZ_PIKE" ] && [ -x "$FUZZ_PIKE" ] || { echo "ERROR: no fuzz pike binary found under $FUZZ_PREFIX/pike/*/bin/pike" >&2; exit 1; }
ln -sfn "$(basename "$(dirname "$(dirname "$FUZZ_PIKE")")")" "$FUZZ_PREFIX/pike/current"
echo "built $FUZZ_PREFIX/pike/current -> $(readlink "$FUZZ_PREFIX/pike/current")"

pike_build "$TEST_PREFIX" "-O2 -g" "-O2 -g" "oracle" "$CC" "$CXX"
echo "oracle build ready for test.sh"
