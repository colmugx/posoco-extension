// moonc emits a C prototype for every extern binding; binding libc's own
// `system` name collides with glibc's system(const char*) on linux (stdlib.h
// reaches the translation unit through moonbit.h on x86), so the call goes
// through this prefixed shim instead.
#include <stdlib.h>

int herdr_ffi_system(const char *cmd) { return system(cmd); }
