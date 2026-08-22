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

# Modules whose configure reports "no" in this image (missing library or header, or a dependency on
# one) and that build nothing but a stub: configuring each costs ~2 s of the serial configure phase,
# per build. Listed per directory name as Pike's module configure reads it (modules/: lower case,
# post_modules/: exact case). Everything that does build (Gmp, Gz, Nettle, Image, Parser, ...) stays.
PIKE_SKIP_MODULES="--without-dvb --without-fuse --without-gdbm --without-java --without-mysql
 --without-odbc --without-oracle --without-pdf --without-postgres --without-sane --without-sybase
 --without-_ffmpeg --without-_image_freetype --without-_image_jpeg --without-_image_tiff
 --without-_image_ttf --without-_protocols_dns_sd
 --without-Bz2 --without-COM --without-Cairo --without-GI --without-GL --without-GLUT
 --without-GSSAPI --without-GTK2 --without-Kerberos --without-SDL --without-SQLite --without-VCDiff
 --without-_Image_AVIF --without-_Image_SVG --without-_Image_WebP --without-_Regexp_PCRE
 --without-_Regexp_PCRE2 --without-_Sass"
PIKE_SKIP_MODULES="$(echo $PIKE_SKIP_MODULES)"

# Configure is serial and dominates a Pike build, so the fuzz and the oracle build run side by side:
# the oracle in $SRC (test.sh runs from there), the fuzz build in a scratch copy of the tree.
# --config-cache shares the probe results between the module configures of one build; CONFIG_SHELL
# runs the generated configure scripts under dash, which forks faster than bash.
pike_build() {
  local srcdir="$1" prefix="$2" cflags="$3" ldflags="$4" label="$5" cc="$6" cxx="$7"
  local args="--prefix=$prefix CC=$cc CXX=$cxx CFLAGS='$cflags' CXXFLAGS='$cflags' LDFLAGS='$ldflags' --config-cache $PIKE_SKIP_MODULES"
  echo "=== Pike $label build (prefix=$prefix, CC=$cc) ==="
  cd "$srcdir"
  if [ -f Makefile ]; then make distclean >/dev/null 2>&1 || true; fi
  export CONFIG_SHELL=/bin/dash
  make -j"$MAYHEM_JOBS" CONFIGUREARGS="$args"
  make CONFIGUREARGS="$args" install
}

FUZZ_SRC="$(mktemp -d "${TMPDIR:-/tmp}/pike-fuzz-src.XXXXXX")"
trap 'rm -rf "$FUZZ_SRC"' EXIT
tar -C "$SRC" --exclude=./.git --exclude=./build --exclude=./mayhem/fuzz-prefix \
    --exclude=./mayhem/test-prefix -cf - . | tar -C "$FUZZ_SRC" -xf -
# The scratch copy is only a build directory: keep its path out of debug info and __FILE__.
FUZZ_FLAGS="$FUZZ_FLAGS -ffile-prefix-map=$FUZZ_SRC=$SRC"
FUZZ_LDFLAGS="$FUZZ_LDFLAGS -ffile-prefix-map=$FUZZ_SRC=$SRC"

( export AFL_LLVM_INSTRUMENT=CLASSIC AFL_MAP_SIZE=65536 AFL_QUIET=1
  pike_build "$FUZZ_SRC" "$FUZZ_PREFIX" "$FUZZ_FLAGS" "$FUZZ_LDFLAGS" "fuzz" "$AFL_CLANG" "$AFL_CLANGXX" \
    2>&1 | sed -u 's/^/[fuzz] /' ) &
FUZZ_PID=$!
( pike_build "$SRC" "$TEST_PREFIX" "-O2 -g" "-O2 -g" "oracle" "$CC" "$CXX" 2>&1 | sed -u 's/^/[oracle] /' ) &
ORACLE_PID=$!
FUZZ_RC=0; ORACLE_RC=0
wait "$FUZZ_PID" || FUZZ_RC=$?
wait "$ORACLE_PID" || ORACLE_RC=$?
[ "$FUZZ_RC" -eq 0 ] || { echo "ERROR: fuzz build failed (rc=$FUZZ_RC)" >&2; exit 1; }
[ "$ORACLE_RC" -eq 0 ] || { echo "ERROR: oracle build failed (rc=$ORACLE_RC)" >&2; exit 1; }
# Resolve the installed version dir dynamically and alias it to a stable "current" symlink, since
# the version string changes on every Pike bump and both the Mayhemfile's cmd/LD_LIBRARY_PATH need
# a path that survives that (was hardcoded to a specific version and broke on the next bump).
FUZZ_PIKE="$(find "$FUZZ_PREFIX/pike" -mindepth 3 -maxdepth 3 -type f -name pike -path '*/bin/pike' 2>/dev/null | head -1)"
[ -n "$FUZZ_PIKE" ] && [ -x "$FUZZ_PIKE" ] || { echo "ERROR: no fuzz pike binary found under $FUZZ_PREFIX/pike/*/bin/pike" >&2; exit 1; }
ln -sfn "$(basename "$(dirname "$(dirname "$FUZZ_PIKE")")")" "$FUZZ_PREFIX/pike/current"
echo "built $FUZZ_PREFIX/pike/current -> $(readlink "$FUZZ_PREFIX/pike/current")"

echo "oracle build ready for test.sh"
