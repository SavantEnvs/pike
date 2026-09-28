// Linked into every fuzz binary to disable LeakSanitizer while keeping ASan/UBSan active
// (SPEC.md §"Disable LeakSanitizer by default" — build-time only, never ASAN_OPTIONS at runtime).
extern "C" int __lsan_is_turned_off() { return 1; }
