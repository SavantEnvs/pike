/* Build-time LeakSanitizer opt-out for the fuzzed Pike interpreter.
 *
 * -fsanitize=address always bundles LeakSanitizer. Leaks are not the bug class this target is
 * fuzzed for (ASan memory-corruption checks and UBSan are), and Pike's interpreter keeps its
 * module/program tables alive until process exit, so LSan would report every exit as a leak.
 * The ASan runtime calls this hook at exit and skips leak checking when it returns non-zero.
 * ASan and UBSan stay on and halting. build.sh compiles this file with $SANITIZER_FLAGS and
 * links it into the interpreter (and every binary the build links). */
int __lsan_is_turned_off(void) { return 1; }
